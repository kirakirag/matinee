import Foundation

/// A read-only byte stream over one YouTube media URL, fetched in chunks with YouTube's `range=` parameter:
/// googlevideo throttles one open-ended GET to roughly playback speed but serves ranged requests at full speed.
/// Calls block; they are made on mpv's threads, never the main thread.
/// Chunks are fetched back to back from the reader's offset (a seek to 17 with 10-byte chunks fetches 17-26, 27-36, ...)
/// to the end of the file, one at a time; a read outside the fetched data restarts the fetching at its offset.
/// The first chunk after a (re)start is small, so the first frame and a far seek wait for 1 MiB rather than 10.
/// Bytes are readable as they arrive, not when their chunk completes.
/// Fetching pauses while `maxAhead` bytes are held ahead of the reader, and chunks the reader has moved past are dropped
/// (mpv keeps its own cache); the one it has just reached the end of, or is waiting on, stays for a small seek back.
public final class RangedStream: @unchecked Sendable {
    /// Returns the response once its headers arrive, then the body in pieces as they arrive.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)

    public struct BadStatus: LocalizedError {
        public let code: Int
        public var errorDescription: String? { "HTTP error \(code)" }
    }

    /// The server sent more than the requested range, so the bytes can't be placed.
    public struct RangeIgnored: LocalizedError {
        public var errorDescription: String? { "The server ignored the requested range" }
    }

    /// The server sent nothing for a range before the known end of the file.
    public struct EmptyChunk: LocalizedError {
        public var errorDescription: String? { "The server sent an empty chunk" }
    }

    /// Pauses before the second and third attempt of a chunk that failed with a network error or a 5xx.
    private static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1)]

    private struct Chunk {
        var start: Int64
        var data: Data
        var end: Int64 { start + Int64(data.count) }
    }

    /// The chunk being fetched; `next` is its first byte not yet received (a retry asks for `next...end`).
    private final class Pending: @unchecked Sendable {
        let end: Int64
        var next: Int64
        /// Whether the last of `chunks` is this one's, so arriving bytes extend it.
        var filling = false
        var task: Task<Void, Never>?
        init(start: Int64, end: Int64) { self.next = start; self.end = end }
    }

    private let url: URL
    private let headers: [String: String]
    private let chunkSize: Int64
    private let firstChunkSize: Int64
    private let maxAhead: Int64
    private let fetch: Fetch
    private let onFailure: @Sendable (String) -> Void
    /// Guards everything below.
    private let condition = NSCondition()
    private var total: Int64?
    private var position: Int64 = 0
    /// Contiguous, from the reader's chunk on; the last one grows while its bytes arrive.
    private var chunks: [Chunk] = []
    private var pending: Pending?
    /// Where fetching continues once the reader drains below `maxAhead`.
    private var paused: Int64?
    private var failure: (any Error)?
    /// Whether a read was waiting on the fetch when it failed, so its retries already ran while the reader waited.
    private var failureWaited = false
    private var readerWaiting = false
    private var cancelled = false

    /// `onFailure` gets a description of a failed fetch, e.g. "HTTP error 403".
    public init(url: URL, headers: [String: String], chunkSize: Int64 = 10 << 20, firstChunkSize: Int64 = 1 << 20, maxAhead: Int64 = 256 << 20, fetch: @escaping Fetch = RangedStream.urlSession,
                onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.url = url
        self.headers = headers
        self.chunkSize = chunkSize
        self.firstChunkSize = min(firstChunkSize, chunkSize)
        self.maxAhead = maxAhead
        self.fetch = fetch
        self.onFailure = onFailure
        total = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "clen" }?.value.flatMap { Int64($0) }
    }

    public static let urlSession: Fetch = sessionFetch(session)

    static func sessionFetch(_ session: URLSession) -> Fetch { { request in
        let task = session.dataTask(with: request)
        let delegate = BodyDelegate()
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { delegate.start(task, $0) }
        } onCancel: { task.cancel() }
    } }

    /// No disk cache: every chunk is read once.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Hands over the response when its headers arrive, then streams the body.
    private final class BodyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        /// Guarded by `lock`; nil once resumed.
        private var head: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, any Error>), any Error>?
        /// Not kept once handed over: when the reader drops it, it terminates and cancels the task.
        private var body: AsyncThrowingStream<Data, any Error>?
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

        override init() {
            let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            self.body = body
            self.continuation = continuation
        }

        func start(_ task: URLSessionDataTask, _ head: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, any Error>), any Error>) {
            lock.withLock { self.head = head }
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                resume(.failure(URLError(.badServerResponse)))
                return completionHandler(.cancel)
            }
            guard (200..<300).contains(http.statusCode) else {
                resume(.failure(BadStatus(code: http.statusCode)))
                return completionHandler(.cancel)
            }
            resume(.success(http))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            resume(.failure(error ?? URLError(.badServerResponse)))
            continuation.finish(throwing: error)
        }

        private func resume(_ result: Result<HTTPURLResponse, any Error>) {
            let (head, body) = lock.withLock {
                defer { self.head = nil; self.body = nil }
                return (self.head, self.body)
            }
            if let head, let body { head.resume(with: result.map { ($0, body) }) }
        }
    }

    /// Copies up to `count` bytes at the current position; returns the number copied, 0 at the end, -1 on error or after `cancel`.
    public func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        while !cancelled {
            if let total, position >= total { return 0 }
            chunks.removeAll { $0.end < position }
            if let c = chunks.first(where: { position >= $0.start && position < $0.end }) {
                let n = Int(min(Int64(count), c.end - position))
                let offset = Int(position - c.start)
                c.data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: n) }
                position += Int64(n)
                chunks.removeAll { $0.end < position }
                if let next = paused, (chunks.last?.end ?? position) - position < maxAhead {
                    paused = nil
                    startFetch(at: next, size: chunkSize)
                }
                return n
            }
            if let error = failure {
                failure = nil
                if failureWaited {
                    onFailure(error.localizedDescription)
                    return -1
                }
                // A fetch ahead of the reader failed while nothing waited on it (a network drop minutes ago, or before
                // a seek): try again from here before failing playback.
            } else if let p = pending, position >= p.next, position <= p.end || position == p.next {
                // At `p.next` past its end, every byte of `p` has arrived and its end is on the way; `finished` then
                // starts the next chunk right here. Restarting instead would make it a small first chunk.
                readerWaiting = true
                condition.wait()
                readerWaiting = false
                continue
            }
            chunks = []
            paused = nil
            pending?.task?.cancel()
            startFetch(at: position, size: firstChunkSize)
        }
        return -1
    }

    /// Moves the read position; the data is fetched by the next read. False after `cancel`.
    public func seek(to offset: Int64) -> Bool {
        condition.withLock {
            guard !cancelled, offset >= 0 else { return false }
            position = offset
            return true
        }
    }

    /// The total size: the URL's `clen`, else the first response's Content-Range total; nil while unknown.
    public func size() -> Int64? { condition.withLock { total } }

    /// Bytes held in memory.
    var heldBytes: Int { condition.withLock { chunks.reduce(0) { $0 + $1.data.count } } }

    /// Fails the current and every later read or seek, and stops the fetch in flight. Does not block.
    public func cancel() {
        condition.withLock {
            cancelled = true
            pending?.task?.cancel()
            pending = nil
            chunks = []
            condition.broadcast()
        }
    }

    // MARK: Fetching

    /// Condition held.
    private func startFetch(at start: Int64, size: Int64) {
        let p = Pending(start: start, end: min(start + size, total ?? .max) - 1)
        pending = p
        let fetch = fetch
        let sizeKnown = total != nil   // then start < total, so an empty body is wrong, not the end
        p.task = Task {
            for attempt in 0... {
                do {
                    let from = self.condition.withLock { p.next }
                    let (response, body) = try await fetch(self.request(from: from, to: p.end))
                    try self.began(p, response)
                    for try await data in body { try self.received(p, data) }
                    if sizeKnown, self.condition.withLock({ p.next == from }) { throw EmptyChunk() }
                    return self.finished(p, nil)
                } catch {
                    guard attempt < Self.retryDelays.count, Self.isTransient(error), !Task.isCancelled else {
                        return self.finished(p, error)
                    }
                    try? await Task.sleep(for: Self.retryDelays[attempt])
                }
            }
        }
    }

    private func request(from start: Int64, to end: Int64) -> URLRequest {
        Self.rangeRequest(url, headers: headers, from: start, to: end)
    }

    /// YouTube's `range=` request for bytes `start...end` (also used by StreamWarmer, so its requests match).
    static func rangeRequest(_ url: URL, headers: [String: String], from start: Int64, to end: Int64) -> URLRequest {
        var request = URLRequest(url: URL(string: url.absoluteString + (url.query == nil ? "?" : "&") + "range=\(start)-\(end)")!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        #if canImport(Darwin)
        // Races QUIC from the first request instead of discovering HTTP/3 through Alt-Svc on a TCP+TLS response
        // first (Apple: "enables QUIC racing without HTTP/3 service discovery"); TCP still races alongside.
        request.assumesHTTP3Capable = true
        #endif
        return request
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if let status = error as? BadStatus { return status.code >= 500 }
        return error is URLError || error is EmptyChunk
    }

    /// Learns the total from Content-Range; a declared body longer than the range is refused before any byte is kept.
    private func began(_ p: Pending, _ response: HTTPURLResponse) throws {
        try condition.withLock {
            if response.expectedContentLength > p.end - p.next + 1 { throw RangeIgnored() }
            if total == nil, let range = response.value(forHTTPHeaderField: "Content-Range"), let t = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                total = t
            }
        }
    }

    /// Makes a piece of the body readable.
    private func received(_ p: Pending, _ data: Data) throws {
        try condition.withLock {
            guard pending === p else { throw CancellationError() }
            guard p.next + Int64(data.count) <= p.end + 1 else { throw RangeIgnored() }
            if p.filling, let last = chunks.last, last.end == p.next {
                chunks[chunks.count - 1].data.append(data)
            } else {
                var fresh = Data(capacity: Int(p.end + 1 - p.next))
                fresh.append(data)
                chunks.append(Chunk(start: p.next, data: fresh))
                p.filling = true
            }
            p.next += Int64(data.count)
            condition.broadcast()
        }
    }

    /// Starts the next chunk, or pauses while `maxAhead` bytes are held ahead of the reader; a short body without a known total is the end.
    private func finished(_ p: Pending, _ error: (any Error)?) {
        condition.withLock {
            guard pending === p else { return }
            pending = nil
            if let error {
                failure = error
                failureWaited = readerWaiting
            } else {
                if total == nil, p.next <= p.end { total = p.next }
                if p.next < total ?? .max {
                    if (chunks.last?.end ?? p.next) - position < maxAhead {
                        startFetch(at: p.next, size: chunkSize)
                    } else {
                        paused = p.next
                    }
                }
            }
            condition.broadcast()
        }
    }
}
