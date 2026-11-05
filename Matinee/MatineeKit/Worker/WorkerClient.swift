import Foundation
import os

/// Talks to the long-lived yt-dlp worker (`matinee_worker.py`) over JSON lines on stdin/stdout.
/// The process starts on first use; if it exits, pending requests fail with `.crashed` and the next
/// request starts a new one. Up to `parallel` requests are sent at once (the worker runs them concurrently);
/// the rest queue here, and each one's timeout starts when it is sent. A request that times out kills the
/// worker, failing the others in flight with it, and the queue moves on to a fresh one.
public actor WorkerClient {
    private let executable: URL
    private let arguments: [String]
    private let workingDirectory: URL
    private let environment: [String: String]
    private let timeout: Duration
    private let firstTimeout: Duration
    private let parallel: Int
    private static let log = Logger(subsystem: "local.kirakirag.matinee", category: "worker")
    /// MATINEE_WORKER_DEBUG=1 in the app's environment: the worker logs verbosely and its stderr is echoed.
    private static let debugEcho = ProcessInfo.processInfo.environment["MATINEE_WORKER_DEBUG"] == "1"

    private var process: Process?
    private var stdin: FileHandle?
    private var generation = 0
    private var nextRid = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var queue: [(rid: Int, line: Data)] = []
    /// Requests sent and not yet answered, with their timeout timers.
    private var inFlight: [Int: Task<Void, Never>] = [:]
    /// Progress callbacks of downloads, by rid.
    private var progressHandlers: [Int: @Sendable (DownloadProgress) -> Void] = [:]
    /// Rids whose replies nobody waits for any more (cancelled downloads and the cancel requests themselves).
    private var droppedReplies: Set<Int> = []
    /// Whether the current process has answered yet; until then requests get `firstTimeout` (it may still be loading).
    private var responded = false

    public init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
                timeout: Duration = .seconds(30), firstTimeout: Duration = .seconds(90), parallel: Int = 1) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.firstTimeout = firstTimeout
        self.parallel = max(parallel, 1)
    }

    /// The worker bundled in `Runtime.bundle`, run with its cwd and caches in the container's Caches folder.
    public static func bundled(parallel: Int = 1, timeout: Duration = .seconds(30)) -> WorkerClient {
        let runtime = Bundle.main.url(forResource: "Runtime", withExtension: "bundle")
            ?? Bundle.main.resourceURL!.appending(path: "Runtime.bundle")
        let mpv = Bundle.main.url(forResource: "Mpv", withExtension: "bundle")
            ?? Bundle.main.resourceURL!.appending(path: "Mpv.bundle")
        let caches = URL.cachesDirectory.appending(path: "Worker")
        try? FileManager.default.createDirectory(at: caches.appending(path: "tmp"), withIntermediateDirectories: true)
        var environment = [
            "HOME": caches.path,
            "XDG_CACHE_HOME": caches.path,
            "DENO_DIR": caches.appending(path: "deno").path,
            "TMPDIR": caches.appending(path: "tmp").path,
            "MATINEE_DENO": runtime.appending(path: "deno").path,
            "MATINEE_FFMPEG": mpv.appending(path: "bin/ffmpeg").path,   // merges downloads' video and audio
        ]
        if debugEcho { environment["MATINEE_WORKER_DEBUG"] = "1" }
        return WorkerClient(
            executable: runtime.appending(path: "python/bin/python3"),
            arguments: ["-I", runtime.appending(path: "matinee_worker.py").path],
            workingDirectory: caches,
            environment: environment,
            timeout: timeout,
            parallel: parallel)
    }

    public func resolve(_ id: String, clients: [String]? = nil, maxHeight: Int? = nil) async throws -> Resolved {
        guard VideoID.isValid(id) else { throw WorkerError.invalidID }
        let rid = nextRid
        nextRid += 1
        var request: [String: Any] = ["rid": rid, "op": "resolve", "id": id]
        if let clients { request["clients"] = clients }
        if let maxHeight { request["max_height"] = maxHeight }
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(UInt8(ascii: "\n"))

        let data = try await enqueue(rid, line)
        do {
            return try JSONDecoder().decode(Resolved.self, from: data)
        } catch {
            throw WorkerError.failed("bad response: \(error)")
        }
    }

    public func list(_ url: YouTubeURL, first n: Int) async throws -> ListPage {
        guard let url = url.url else { throw WorkerError.invalidID }
        return try await page(["op": "list", "url": url.absoluteString, "n": n])
    }

    public func more(cursor: Int, n: Int) async throws -> ListPage {
        try await page(["op": "more", "cursor": cursor, "n": n])
    }

    /// The first `n` (1…100) of the video's top-level comments, best first. Read-only.
    public func comments(of id: String, first n: Int) async throws -> CommentPage {
        guard VideoID.isValid(id) else { throw WorkerError.invalidID }
        return try await commentPage(["op": "comments", "id": id, "n": n])
    }

    /// The next `n` comments after a page that wasn't `done`.
    public func moreComments(cursor: Int, n: Int) async throws -> CommentPage {
        try await commentPage(["op": "more", "cursor": cursor, "n": n])
    }

    /// The next `n` replies to comment `id`, from the comments cursor of its first page.
    public func replies(cursor: Int, of id: String, n: Int) async throws -> ReplyPage {
        try await commentPage(["op": "replies", "cursor": cursor, "id": id, "n": n])
    }

    private func commentPage<Page: Decodable>(_ fields: [String: Any]) async throws -> Page {
        let rid = nextRid
        nextRid += 1
        var line = try JSONSerialization.data(withJSONObject: fields.merging(["rid": rid]) { $1 })
        line.append(UInt8(ascii: "\n"))
        let data = try await enqueue(rid, line)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Page.self, from: data)
        } catch {
            throw WorkerError.failed("bad response: \(error)")
        }
    }

    /// The videos the watch page suggests next, in its order.
    public func related(of id: String) async throws -> [ListedEntry] {
        guard VideoID.isValid(id) else { throw WorkerError.invalidID }
        let rid = nextRid
        nextRid += 1
        var line = try JSONSerialization.data(withJSONObject: ["rid": rid, "op": "related", "id": id] as [String: Any])
        line.append(UInt8(ascii: "\n"))
        let data = try await enqueue(rid, line)
        struct Reply: Decodable { let videos: [ListedEntry] }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Reply.self, from: data).videos.filter(\.hasValidID)
        } catch {
            throw WorkerError.failed("bad response: \(error)")
        }
    }

    /// Cleaned descriptions of the videos, fetched a second apart: 5 per request, so each stays well inside the
    /// request timeout (which would restart the worker), with `pause` between requests. `stopped`: YouTube throttled,
    /// so the rest are missing and the caller shouldn't ask again this session.
    public func descriptions(of ids: [String], pause: Duration = .seconds(1)) async throws
        -> (descriptions: [String: String], stopped: Bool) {
        guard ids.allSatisfy(VideoID.isValid) else { throw WorkerError.invalidID }
        struct Reply: Decodable { let descriptions: [String: String]; let stopped: Bool }
        var out: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 5) {
            if start > 0 { try await Task.sleep(for: pause) }
            let reply: Reply = try await commentPage(["op": "descriptions", "ids": Array(ids[start..<min(start + 5, ids.count)])])
            out.merge(reply.descriptions.filter { VideoID.isValid($0.key) }) { $1 }
            if reply.stopped { return (out, true) }
        }
        return (out, false)
    }

    /// Playlists of the video's channel that may contain it; the caller checks membership.
    public func playlists(of id: String) async throws -> [ChannelPlaylist] {
        guard VideoID.isValid(id) else { throw WorkerError.invalidID }
        let rid = nextRid
        nextRid += 1
        var line = try JSONSerialization.data(withJSONObject: ["rid": rid, "op": "playlists", "id": id] as [String: Any])
        line.append(UInt8(ascii: "\n"))
        let data = try await enqueue(rid, line)
        struct Reply: Decodable { let playlists: [ChannelPlaylist] }
        do {
            return try JSONDecoder().decode(Reply.self, from: data).playlists.filter { PlaylistID.isValid($0.id) }
        } catch {
            throw WorkerError.failed("bad response: \(error)")
        }
    }

    private func page(_ fields: [String: Any]) async throws -> ListPage {
        let rid = nextRid
        nextRid += 1
        var line = try JSONSerialization.data(withJSONObject: fields.merging(["rid": rid]) { $1 })
        line.append(UInt8(ascii: "\n"))
        let data = try await enqueue(rid, line)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ListPage.self, from: data).keepingValidEntries()
        } catch {
            throw WorkerError.failed("bad response: \(error)")
        }
    }

    /// Downloads the video into `dir` as `<id>.mp4`, reporting progress as it goes. Each progress line restarts the
    /// request's timeout, so only a stalled download times out. Cancelling the task stops the download in the worker.
    public func download(_ id: String, to dir: URL, maxHeight: Int? = nil,
                         progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> Downloaded {
        guard VideoID.isValid(id) else { throw WorkerError.invalidID }
        let rid = nextRid
        nextRid += 1
        var request: [String: Any] = ["rid": rid, "op": "download", "id": id, "dir": dir.path]
        if let maxHeight { request["max_height"] = maxHeight }
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(UInt8(ascii: "\n"))
        progressHandlers[rid] = progress
        defer { progressHandlers[rid] = nil }
        let data = try await enqueue(rid, line)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Downloaded.self, from: data)
        } catch {
            throw WorkerError.failed("bad response: \(error)")
        }
    }

    /// Starts the worker and loads yt-dlp and Deno ahead of the first real request. Errors are ignored.
    public func warmUp() async {
        let rid = nextRid
        nextRid += 1
        guard var line = try? JSONSerialization.data(withJSONObject: ["rid": rid, "op": "warm"] as [String: Any]) else { return }
        line.append(UInt8(ascii: "\n"))
        _ = try? await enqueue(rid, line)
    }

    private func enqueue(_ rid: Int, _ line: Data) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[rid] = continuation
                queue.append((rid, line))
                sendNext()
            }
        } onCancel: {
            Task { await self.cancel(rid) }
        }
    }

    /// A queued request is dropped. A download already sent is stopped in the worker: the cancel line goes straight to
    /// stdin, past the parallel cap, and the caller gets `CancellationError` without waiting for the worker's reply.
    private func cancel(_ rid: Int) {
        if queue.contains(where: { $0.rid == rid }) { return cancelQueued(rid) }
        guard progressHandlers[rid] != nil, inFlight[rid] != nil, let continuation = pending.removeValue(forKey: rid) else { return }
        let cancelRid = nextRid
        nextRid += 1
        droppedReplies.formUnion([rid, cancelRid])
        if var line = try? JSONSerialization.data(withJSONObject: ["rid": cancelRid, "op": "cancel", "target": rid] as [String: Any]) {
            line.append(UInt8(ascii: "\n"))
            try? stdin?.write(contentsOf: line)
        }
        continuation.resume(throwing: CancellationError())
        finished(rid)
    }

    /// Drops a request that is still waiting its turn. One already sent runs to its end and its result is ignored.
    private func cancelQueued(_ rid: Int) {
        guard let i = queue.firstIndex(where: { $0.rid == rid }) else { return }
        queue.remove(at: i)
        pending.removeValue(forKey: rid)?.resume(throwing: CancellationError())
    }

    /// Sends the oldest queued requests while fewer than `parallel` are in flight, and starts their timeouts.
    private func sendNext() {
        while inFlight.count < parallel, !queue.isEmpty {
            let (rid, line) = queue.removeFirst()
            do {
                try startIfNeeded()
                try stdin?.write(contentsOf: line)
            } catch let error as WorkerError {
                pending.removeValue(forKey: rid)?.resume(throwing: error)
                continue
            } catch {
                pending.removeValue(forKey: rid)?.resume(throwing: WorkerError.crashed)
                stop()
                continue
            }
            startTimer(rid, responded ? timeout : firstTimeout)
        }
    }

    /// (Re)starts the request's timeout.
    private func startTimer(_ rid: Int, _ timeout: Duration) {
        inFlight[rid]?.cancel()
        inFlight[rid] = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            await self?.timedOut(rid)
        }
    }

    private func finished(_ rid: Int) {
        guard let timer = inFlight.removeValue(forKey: rid) else { return }
        timer.cancel()
        sendNext()
    }

    public func shutdown() {
        stop()
        failAll(.crashed)
    }

    // MARK: Process

    private func startIfNeeded() throws {
        guard process == nil else { return }
        signal(SIGPIPE, SIG_IGN)   // a dead worker must surface as a write error, not kill the app
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.currentDirectoryURL = workingDirectory
        p.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { throw WorkerError.failed("cannot start worker: \(error.localizedDescription)") }

        generation += 1
        let gen = generation
        process = p
        responded = false
        stdin = input.fileHandleForWriting
        // Reads happen on Dispatch (readabilityHandler), not in the Swift concurrency pool: FileHandle.bytes
        // blocks pool threads, and a few workers' readers were enough to starve every actor.
        let lines = Self.lines(of: output.fileHandleForReading)
        Task { [weak self] in
            for await line in lines { await self?.receive(line) }
            await self?.ended(gen)
        }
        let errorLines = Self.lines(of: errors.fileHandleForReading)
        Task.detached {
            for await line in errorLines {
                Self.log.debug("\(line, privacy: .public)")
                if Self.debugEcho { FileHandle.standardError.write(Data("worker: \(line)\n".utf8)) }
            }
        }
    }

    /// The handle's output split into lines, in order; finishes at EOF.
    private static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let pending = LineBuffer()
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else {
                    h.readabilityHandler = nil
                    if !pending.data.isEmpty { continuation.yield(String(decoding: pending.data, as: UTF8.self)) }
                    continuation.finish()
                    return
                }
                pending.data.append(chunk)
                while let nl = pending.data.firstIndex(of: UInt8(ascii: "\n")) {
                    continuation.yield(String(decoding: pending.data[pending.data.startIndex..<nl], as: UTF8.self))
                    pending.data.removeSubrange(pending.data.startIndex...nl)
                }
            }
        }
    }

    /// Bytes after the last newline. Only touched from one handle's readabilityHandler, which runs serially.
    private final class LineBuffer: @unchecked Sendable { var data = Data() }

    private func stop() {
        try? stdin?.close()
        if let process, process.isRunning {
            let pid = process.processIdentifier
            let ownGroup = pid > 1 && getpgid(pid) == pid   // the worker made its own group; never signal ours
            process.terminate()
            if ownGroup { kill(-pid, SIGKILL) }   // takes Deno and anything else it started along
        }
        process = nil
        stdin = nil
        generation += 1
    }

    private struct Header: Decodable { let rid: Int; let ok: Bool?; let error: String?; let event: String? }

    private func receive(_ line: String) {
        let data = Data(line.utf8)
        let header = try? JSONDecoder().decode(Header.self, from: data)
        if let header, header.event == "progress" {
            guard pending[header.rid] != nil, inFlight[header.rid] != nil else { return }
            responded = true
            startTimer(header.rid, timeout)   // a download that makes progress isn't stuck
            if let p = try? JSONDecoder().decode(DownloadProgress.self, from: data) { progressHandlers[header.rid]?(p) }
            return
        }
        if let header, droppedReplies.remove(header.rid) != nil { return }
        guard let header, let continuation = pending.removeValue(forKey: header.rid) else {
            if !line.contains("\"ready\"") { Self.log.error("worker sent an unexpected line") }
            return
        }
        responded = true
        defer { finished(header.rid) }
        guard header.ok == true else { return continuation.resume(throwing: WorkerError.failed(header.error ?? "unknown error")) }
        continuation.resume(returning: data)
    }

    private func ended(_ gen: Int) {
        guard gen == generation else { return }   // an old process; its requests were already failed
        process = nil
        stdin = nil
        failAll(.crashed)
    }

    /// A request took too long: the worker is stuck, so replace it and carry on with the queue. The other
    /// requests in flight die with the process.
    private func timedOut(_ rid: Int) {
        guard inFlight[rid] != nil, let continuation = pending.removeValue(forKey: rid) else { return }
        continuation.resume(throwing: WorkerError.timedOut)
        stop()
        let others = inFlight
        inFlight = [:]
        for (other, timer) in others where other != rid {
            timer.cancel()
            pending.removeValue(forKey: other)?.resume(throwing: WorkerError.crashed)
        }
        sendNext()
    }

    private func failAll(_ error: WorkerError) {
        let all = pending
        pending = [:]
        queue = []
        for timer in inFlight.values { timer.cancel() }
        inFlight = [:]
        for c in all.values { c.resume(throwing: error) }
    }
}
