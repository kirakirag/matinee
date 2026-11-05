import Foundation
import Testing
@testable import MatineeKit

/// Serves `bytes` for `range=a-b` requests and records every request.
private final class FakeServer: @unchecked Sendable {
    let bytes: [UInt8]
    var contentRange = false
    var delay: Duration?
    var fails = false
    /// Thrown by the next requests, one each, before serving normally.
    var errors: [any Error] = []
    /// Answers every request with the whole file, like a server that ignores `range=`.
    var ignoresRange = false
    /// Answers every request with an empty 200.
    var emptyBody = false
    /// Ranges that never answer (until cancelled).
    var hold: Set<String> = []
    /// Every body sends its first `stallAfter` bytes, then nothing more.
    var stallAfter: Int?
    /// The next body sends its first `failAfter` bytes, then fails with a network error.
    var failAfter: Int?
    /// Every body ends this long after its last byte (the connection's close arrives after the data).
    var endDelay: Duration?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var stalled: [AsyncThrowingStream<Data, any Error>.Continuation] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(size: Int) { bytes = (0..<size).map { UInt8($0 % 256) } }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var ranges: [String] {
        requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "range" }!.value! }
    }

    func fetch(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let range = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "range" }!.value!
        lock.withLock {
            recorded.append(request)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if hold.contains(range) { try await Task.sleep(for: .seconds(60)) }
        if let delay { try await Task.sleep(for: delay) }
        if fails { throw URLError(.networkConnectionLost) }
        if let error = lock.withLock({ errors.isEmpty ? nil : errors.removeFirst() }) { throw error }
        let ok = { (headers: [String: String]) in HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)! }
        if emptyBody { return (ok([:]), body(Data())) }
        if ignoresRange { return (ok([:]), body(Data(bytes))) }
        let parts = range.split(separator: "-").map { Int($0)! }
        let end = min(parts[1], bytes.count - 1)
        let data = Data(bytes[parts[0]...end])
        let headers = contentRange ? ["Content-Range": "bytes \(parts[0])-\(end)/\(bytes.count)"] : [:]
        if let n = stallAfter { return (ok(headers), body(data.prefix(n), stall: true)) }
        if let n = lock.withLock({ () -> Int? in defer { failAfter = nil }; return failAfter }) {
            return (ok(headers), body(data.prefix(n), error: URLError(.networkConnectionLost)))
        }
        return (ok(headers), body(data))
    }

    /// A body of `data`, then the end, an error, or (`stall`) nothing until the reader stops.
    private func body(_ data: Data, error: (any Error)? = nil, stall: Bool = false) -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        if !data.isEmpty { continuation.yield(data) }
        if stall {
            lock.withLock { stalled.append(continuation) }
        } else if let endDelay {
            Task { try? await Task.sleep(for: endDelay); continuation.finish(throwing: error) }
        } else {
            continuation.finish(throwing: error)
        }
        return stream
    }
}

private func stream(_ server: FakeServer, clen: Int?, chunk: Int64 = 10, firstChunk: Int64 = 10, maxAhead: Int64 = 1 << 30, headers: [String: String] = [:]) -> RangedStream {
    let url = URL(string: "https://example.com/videoplayback?id=1" + (clen.map { "&clen=\($0)" } ?? ""))!
    return RangedStream(url: url, headers: headers, chunkSize: chunk, firstChunkSize: firstChunk, maxAhead: maxAhead, fetch: { try await server.fetch($0) })
}

/// Runs a blocking call off the cooperative pool, as mpv's own threads would.
private func blocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: body()) } }
}

/// Reads `count` bytes with as many calls as it takes; nil on error.
private func read(_ s: RangedStream, _ count: Int) async -> [UInt8]? {
    await blocking {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = buffer.withUnsafeMutableBytes { s.read(into: $0.baseAddress!, count: count - out.count) }
            if n < 0 { return nil }
            if n == 0 { break }
            out += buffer[0..<n]
        }
        return out
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var url: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Answers with a 200 declaring a 1 GB body, sends 1 KiB of it and never finishes; records when the task is stopped.
private final class EndlessBody: URLProtocol, @unchecked Sendable {
    static let stopped = Flag()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "1000000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: 1024))
    }
    override func stopLoading() { Self.stopped.set() }
}

struct RangedStreamTests {
    @Test func readsAcrossChunkBoundary() async {
        let server = FakeServer(size: 25)
        let s = stream(server, clen: 25)
        #expect(await read(s, 25) == server.bytes)
        #expect(await read(s, 1) == [])
        #expect(server.ranges == ["0-9", "10-19", "20-24"])
    }

    /// Chunks start at the reader's offset, not at a multiple of the chunk size; the fetch in flight is abandoned.
    @Test func seekOutsideChunkFetchesFromOffset() async {
        let server = FakeServer(size: 100)
        server.hold = ["10-19"]
        let s = stream(server, clen: 100)
        #expect(await read(s, 2) == [0, 1])
        #expect(s.seek(to: 57))
        #expect(await read(s, 3) == [57, 58, 59])
        #expect(Array(server.ranges.prefix(3)) == ["0-9", "10-19", "57-66"])
    }

    @Test func sizeFromClen() {
        let server = FakeServer(size: 25)
        #expect(stream(server, clen: 25).size() == 25)
        #expect(server.requests.isEmpty)
    }

    @Test func sizeFromContentRangeWhenNoClen() async {
        let server = FakeServer(size: 25)
        server.contentRange = true
        let s = stream(server, clen: nil)
        #expect(await read(s, 1) == [0])
        #expect(s.size() == 25)
    }

    @Test func fetchesAheadToEndOfFile() async throws {
        let server = FakeServer(size: 35)
        server.delay = .milliseconds(5)
        let s = stream(server, clen: 35)
        #expect(await read(s, 1) == [0])
        let deadline = ContinuousClock.now + .seconds(2)
        while server.requests.count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.ranges == ["0-9", "10-19", "20-29", "30-34"])
        #expect(server.maxInFlight == 1)
        #expect(await read(s, 34) == Array(server.bytes[1...]))
    }

    /// A small first chunk after every (re)start, so playback and far seeks don't wait for a whole chunk.
    @Test func firstChunkIsSmall() async throws {
        let server = FakeServer(size: 100)
        server.hold = ["4-13"]
        let s = stream(server, clen: 100, firstChunk: 4)
        #expect(await read(s, 1) == [0])
        #expect(s.seek(to: 50))
        #expect(await read(s, 6) == Array(server.bytes[50..<56]))
        #expect(Array(server.ranges.prefix(4)) == ["0-3", "4-13", "50-53", "54-63"])
    }

    @Test func fetchErrorFailsRead() async {
        let server = FakeServer(size: 25)
        server.fails = true
        #expect(await read(stream(server, clen: 25), 5) == nil)
        #expect(server.requests.count == 3)
    }

    @Test func retriesTransientChunkFailure() async {
        let server = FakeServer(size: 25)
        server.errors = [URLError(.networkConnectionLost)]
        let s = stream(server, clen: 25)
        #expect(await read(s, 25) == server.bytes)
        #expect(Array(server.ranges.prefix(2)) == ["0-9", "0-9"])
    }

    /// The fetch ahead failed while the reader was still on held bytes (a short network drop); the reader must not
    /// fail when it gets there later, once the network is back.
    @Test func failedFetchAheadIsRetriedWhenTheReaderGetsThere() async throws {
        let server = FakeServer(size: 30)
        let s = stream(server, clen: 30, maxAhead: 5)
        #expect(await read(s, 1) == [0])
        server.fails = true
        #expect(await read(s, 5) == Array(server.bytes[1..<6]))   // drops below maxAhead: fetching 10-19 resumes, and fails
        let deadline = ContinuousClock.now + .seconds(5)
        while server.requests.count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.requests.count == 4)
        server.fails = false
        #expect(await read(s, 24) == Array(server.bytes[6...]))
    }

    /// A reader that has every byte of the fetch in flight waits for the next chunk; it doesn't restart with a small
    /// first chunk (an extra request each time a starved reader catches up) because the fetch hasn't seen its end yet.
    @Test func readerAtTheEndOfACompleteChunkWaitsForTheNext() async {
        let server = FakeServer(size: 25)
        server.endDelay = .milliseconds(100)
        let s = stream(server, clen: 25, firstChunk: 4)
        #expect(await read(s, 25) == server.bytes)
        #expect(server.ranges == ["0-3", "4-13", "14-23", "24-24"])
    }

    @Test func retriesServerError() async {
        let server = FakeServer(size: 25)
        server.errors = [RangedStream.BadStatus(code: 503)]
        #expect(await read(stream(server, clen: 25), 5) == Array(server.bytes[0..<5]))
    }

    @Test func doesNotRetry403() async {
        let server = FakeServer(size: 25)
        server.errors = [RangedStream.BadStatus(code: 403)]
        #expect(await read(stream(server, clen: 25), 5) == nil)
        #expect(server.requests.count == 1)
    }

    @Test func cancelDuringBackoffReturnsPromptly() async throws {
        let server = FakeServer(size: 25)
        server.fails = true
        let s = stream(server, clen: 25)
        let done = Flag()
        async let result = { let r = await read(s, 5); done.set(); return r }()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!done.value)   // still backing off, not failed yet
        let cancelled = ContinuousClock.now
        s.cancel()
        #expect(await result == nil)
        #expect(ContinuousClock.now - cancelled < .milliseconds(300))
    }

    @Test func emptyBodyBeforeEndFailsWithoutStorm() async throws {
        let server = FakeServer(size: 25)
        server.emptyBody = true
        let s = stream(server, clen: 25)
        let done = Flag()
        async let result = { let r = await read(s, 5); done.set(); return r }()
        let deadline = ContinuousClock.now + .seconds(3)
        while !done.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        s.cancel()
        #expect(await result == nil)
        #expect(server.requests.count <= 3)
    }

    /// Bytes that don't start at the requested offset would silently corrupt the stream.
    @Test func overlongBodyFailsRead() async {
        let server = FakeServer(size: 25)
        server.ignoresRange = true
        let s = stream(server, clen: 25)
        #expect(s.seek(to: 12))
        #expect(await read(s, 3) == nil)
    }

    /// A refused body must stop downloading, not buffer the whole file: runs the real URLSession fetch against a stub.
    @Test func overlongDeclaredBodyCancelsTheDownload() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EndlessBody.self]
        let s = RangedStream(url: URL(string: "https://example.com/videoplayback?clen=25")!, headers: [:], chunkSize: 10,
                             fetch: RangedStream.sessionFetch(URLSession(configuration: config)))
        #expect(await read(s, 3) == nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while !EndlessBody.stopped.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(EndlessBody.stopped.value)
    }

    @Test func backwardSeekInsideFillingChunkDoesNotRefetch() async {
        let server = FakeServer(size: 1000)
        server.stallAfter = 100
        let s = stream(server, clen: 1000, chunk: 1000, firstChunk: 1000)
        #expect(await read(s, 100) == Array(server.bytes[0..<100]))
        #expect(s.seek(to: 50))
        #expect(await read(s, 50) == Array(server.bytes[50..<100]))
        #expect(server.ranges.count == 1)
        s.cancel()
    }

    @Test func rangeUsesQuestionMarkWithoutQuery() async {
        let seen = URLBox()
        let s = RangedStream(url: URL(string: "https://example.com/videoplayback")!, headers: [:], chunkSize: 10, fetch: {
            seen.url = $0.url
            throw RangedStream.BadStatus(code: 404)
        })
        _ = await read(s, 1)
        #expect(seen.url?.absoluteString == "https://example.com/videoplayback?range=0-9")
    }

    @Test func cancelUnblocksPendingRead() async throws {
        let server = FakeServer(size: 25)
        server.delay = .seconds(30)
        let s = stream(server, clen: 25)
        let started = ContinuousClock.now
        async let result = read(s, 5)
        try await Task.sleep(for: .milliseconds(100))
        s.cancel()
        #expect(await result == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func readReturnsBeforeChunkCompletes() async throws {
        let server = FakeServer(size: 10 << 20)
        server.stallAfter = 100
        let s = stream(server, clen: 10 << 20, chunk: 10 << 20, firstChunk: 10 << 20)
        let done = Flag()
        async let result = { let r = await read(s, 50); done.set(); return r }()
        let deadline = ContinuousClock.now + .seconds(2)
        while !done.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        s.cancel()
        #expect(await result == Array(server.bytes[0..<50]))
    }

    @Test func retryResumesAfterPartialBody() async {
        let server = FakeServer(size: 25)
        server.failAfter = 4
        let s = stream(server, clen: 25)
        #expect(await read(s, 25) == server.bytes)
        #expect(Array(server.ranges.prefix(3)) == ["0-9", "4-9", "10-19"])
    }

    @Test func fetchAheadPausesAtCap() async throws {
        let server = FakeServer(size: 100)
        let s = stream(server, clen: 100, maxAhead: 25)
        #expect(await read(s, 1) == [0])
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.ranges == ["0-9", "10-19", "20-29"])
        #expect(await read(s, 10) == Array(server.bytes[1...10]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.ranges == ["0-9", "10-19", "20-29", "30-39"])
    }

    @Test func chunksBehindReaderAreDropped() async throws {
        let server = FakeServer(size: 30)
        let s = stream(server, clen: 30)
        #expect(await read(s, 1) == [0])
        let deadline = ContinuousClock.now + .seconds(2)
        while server.requests.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.heldBytes == 30)
        #expect(await read(s, 9) == Array(server.bytes[1..<10]))
        #expect(s.heldBytes == 30)   // kept at exactly its end, for a small seek back
        #expect(await read(s, 1) == [10])
        #expect(s.heldBytes == 20)
    }

    @Test func cancelUnblocksReadMidBody() async throws {
        let server = FakeServer(size: 1000)
        server.stallAfter = 100
        let s = stream(server, clen: 1000, chunk: 1000, firstChunk: 1000)
        let done = Flag()
        async let result = { let r = await read(s, 200); done.set(); return r }()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!done.value)   // has the first 100 bytes, waiting for more
        let cancelled = ContinuousClock.now
        s.cancel()
        #expect(await result == nil)
        #expect(ContinuousClock.now - cancelled < .milliseconds(300))
    }

    @Test func rangeParameterAppended() async {
        let server = FakeServer(size: 25)
        let s = stream(server, clen: 25, headers: ["User-Agent": "UA/1", "X-B": "2"])
        _ = await read(s, 1)
        let request = server.requests[0]
        #expect(request.url?.absoluteString == "https://example.com/videoplayback?id=1&clen=25&range=0-9")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UA/1")
        #expect(request.value(forHTTPHeaderField: "X-B") == "2")
    }
}
