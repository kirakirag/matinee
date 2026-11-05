import Foundation
import Testing
import MatineeKit

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

private func tempFile() -> URL { FileManager.default.temporaryDirectory.appending(path: "matinee-test-\(UUID().uuidString)") }

private func fake(_ script: String = "fake_worker.sh", env: [String: String], timeout: Duration = .seconds(5),
                  firstTimeout: Duration? = nil, parallel: Int = 1) -> WorkerClient {
    WorkerClient(executable: URL(filePath: "/bin/sh"), arguments: [fixtures.appending(path: script).path],
                 workingDirectory: FileManager.default.temporaryDirectory, environment: env, timeout: timeout,
                 firstTimeout: firstTimeout ?? timeout, parallel: parallel)
}

@Test func resolvesAndDecodes() async throws {
    let w = fake(env: ["MODE": "normal"])
    let r = try await w.resolve("testVideo01")
    await w.shutdown()
    #expect(r.videoURL == URL(string: "https://example.invalid/testVideo01"))
    #expect(r.audioURL == URL(string: "https://example.invalid/a"))
    #expect(r.height == 1080)
    #expect(r.vcodec == "vp9")
    #expect(r.expire == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(r.headers == ["User-Agent": "x"])
    #expect(r.availableAt == nil)
    #expect(r.jsc == "deno")
    #expect(r.qualities == [])
}

@Test func decodesResolvedWithAndWithoutMetadata() throws {
    func decode(_ extra: String) throws -> Resolved {
        try JSONDecoder().decode(Resolved.self, from: Data(#"{"video_url": "https://v/x", "expire": 1\#(extra)}"#.utf8))
    }
    let full = try decode(#", "title": "Title", "channel": "Uploader", "channel_id": "UCtestChannel00000000000", "duration": 213.5"#)
    #expect(full.title == "Title")
    #expect(full.channel == "Uploader")
    #expect(full.channelId == "UCtestChannel00000000000")
    #expect(full.duration == 213.5)
    let nulls = try decode(#", "title": null, "channel": null, "channel_id": null, "duration": null"#)
    let old = try decode("")
    for r in [nulls, old] {
        #expect(r.title == nil && r.channel == nil && r.channelId == nil && r.duration == nil)
    }
}

@Test func resolveSendsMaxHeight()async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "normal", "LOG": log.path])
    _ = try await w.resolve("testVideo01", maxHeight: 1440)
    _ = try await w.resolve("testVideo01")
    await w.shutdown()
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("\"max_height\":1440"))
    #expect(!lines[1].contains("max_height"))
}

@Test func invalidIdNeverReachesWorker() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "normal", "LOG": log.path])
    await #expect(throws: WorkerError.invalidID) { try await w.resolve("--exec=x") }
    await #expect(throws: WorkerError.invalidID) {
        try await w.download("--exec=x", to: URL(filePath: "/tmp"), progress: { _ in })
    }
    _ = try await w.resolve("testVideo01")
    await w.shutdown()
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines.allSatisfy { !$0.contains("--exec") })
}

@Test func concurrentRequestsMatchByRid() async throws {
    let w = fake(env: ["MODE": "normal"])
    async let a = w.resolve("aaaaaaaaaaa")
    async let b = w.resolve("bbbbbbbbbbb")
    let (ra, rb) = try await (a, b)
    await w.shutdown()
    #expect(ra.videoURL.lastPathComponent == "aaaaaaaaaaa")
    #expect(rb.videoURL.lastPathComponent == "bbbbbbbbbbb")
}

@Test func garbageLineIsSkipped() async throws {   // Review Focus 2
    let w = fake(env: ["MODE": "garbage"])
    let r = try await w.resolve("testVideo01")
    await w.shutdown()
    #expect(r.height == 1080)
}

@Test func workerCrashFailsPendingAndRestarts() async throws {   // Review Focus 1
    let state = tempFile()
    defer { try? FileManager.default.removeItem(at: state) }
    let w = fake("crash_worker.sh", env: ["STATE": state.path])
    await #expect(throws: WorkerError.crashed) { try await w.resolve("testVideo01") }
    let r = try await w.resolve("testVideo01")
    await w.shutdown()
    #expect(r.height == 1080)
}

@Test func workerTimeout() async throws {
    let w = fake(env: ["MODE": "silent"], timeout: .milliseconds(500))
    await #expect(throws: WorkerError.timedOut) { try await w.resolve("testVideo01") }
    await w.shutdown()
}

@Test func queuedRequestsEachGetTheirOwnTimeout() async throws {   // final review, Important 1
    // Three 0.6 s answers take 1.8 s in total; each must still fit its own 1 s timeout.
    let w = fake(env: ["MODE": "slow"], timeout: .seconds(1))
    async let a = w.resolve("aaaaaaaaaaa")
    async let b = w.resolve("bbbbbbbbbbb")
    async let c = w.resolve("ccccccccccc")
    let all = try await [a, b, c]
    await w.shutdown()
    #expect(all.map(\.videoURL.lastPathComponent).sorted() == ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
}

@Test func timeoutKillsWorkersChildren() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "group", "LOG": log.path], timeout: .milliseconds(300))
    await #expect(throws: WorkerError.timedOut) { try await w.resolve("testVideo01") }
    let pid = try #require(pid_t(String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var gone = false
    for _ in 0..<20 where !gone {
        gone = kill(pid, 0) == -1 && errno == ESRCH
        if !gone { try await Task.sleep(for: .milliseconds(50)) }
    }
    await w.shutdown()
    #expect(gone)
}

@Test func requestAfterTimeoutSucceeds() async throws {
    let state = tempFile()
    defer { try? FileManager.default.removeItem(at: state) }
    let w = fake(env: ["MODE": "slowfirst", "STATE": state.path], timeout: .milliseconds(300))
    await #expect(throws: WorkerError.timedOut) { try await w.resolve("testVideo01") }
    let r = try await w.resolve("testVideo01")
    await w.shutdown()
    #expect(r.height == 1080)
}

@Test func firstRequestGetsLongerTimeout() async throws {
    let w = fake(env: ["MODE": "slow"], timeout: .milliseconds(200), firstTimeout: .seconds(2))
    let r = try await w.resolve("testVideo01")
    #expect(r.height == 1080)
    await #expect(throws: WorkerError.timedOut) { try await w.resolve("testVideo01") }
    await w.shutdown()
}

@Test func warmUpDoesNotDisturbResolve() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "normal", "LOG": log.path])
    await w.warmUp()
    let r = try await w.resolve("testVideo01")
    await w.shutdown()
    #expect(r.height == 1080)
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines.first?.contains("\"warm\"") == true)
}

@Test func queuedRequestCancelledBeforeSendingNeverReachesWorker() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "slow", "LOG": log.path])
    let first = Task { try await w.resolve("aaaaaaaaaaa") }
    try await Task.sleep(for: .milliseconds(200))   // the first request is in flight (the fake takes 0.6 s)
    let second = Task { try await w.resolve("bbbbbbbbbbb") }
    try await Task.sleep(for: .milliseconds(100))
    second.cancel()
    _ = try await first.value
    await #expect(throws: CancellationError.self) { try await second.value }
    try await Task.sleep(for: .milliseconds(900))   // long enough for a wrongly kept request to be sent and logged
    await w.shutdown()
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines.allSatisfy { !$0.contains("bbbbbbbbbbb") })
}

@Test func parallelRequestDoesNotWaitForASlowOne() async throws {
    let w = fake(env: ["MODE": "parallel"], parallel: 2)
    let slow = Task { try await w.resolve("sssssssssss") }
    try await Task.sleep(for: .milliseconds(100))   // the slow one is in flight (the fake takes 1 s)
    let started = ContinuousClock.now
    let fast = try await w.resolve("fffffffffff")
    #expect(ContinuousClock.now - started < .milliseconds(500))
    #expect(fast.videoURL.lastPathComponent == "fffffffffff")
    #expect(try await slow.value.videoURL.lastPathComponent == "sssssssssss")
    await w.shutdown()
}

@Test func timeoutFailsTheOtherRequestsInFlightToo() async throws {
    let w = fake(env: ["MODE": "silent"], timeout: .milliseconds(300), parallel: 2)
    let a = Task { try await w.resolve("aaaaaaaaaaa") }
    let b = Task { try await w.resolve("bbbbbbbbbbb") }
    let results = [await a.result, await b.result]
    await w.shutdown()
    // Neither may hang: the one that times out kills the worker, and the other fails with it.
    #expect(results.allSatisfy { if case .failure = $0 { true } else { false } })
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DownloadProgress] = []
    var all: [DownloadProgress] { lock.withLock { values } }
    func add(_ p: DownloadProgress) { lock.withLock { values.append(p) } }
}

@Test func downloadReportsProgressThenResult() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "download", "LOG": log.path])
    let seen = Seen()
    let d = try await w.download("testVideo01", to: URL(filePath: "/m"), maxHeight: 1080) { seen.add($0) }
    await w.shutdown()
    #expect(seen.all == [DownloadProgress(downloaded: 10, total: 100),
                         DownloadProgress(downloaded: 50, total: 100, fraction: 0.5, speed: 2048.5, eta: 24.4),
                         DownloadProgress(downloaded: 100, total: 100, fraction: 1, stage: .finishing)])
    #expect(d.file == "/m/testVideo01.mp4")
    #expect(d.bytes == 100)
    #expect(d.title == "T" && d.channel == "C" && d.channelId == nil && d.duration == 9.5)
    let line = try String(contentsOf: log, encoding: .utf8)
    #expect(line.contains("\"op\":\"download\"") && line.contains("\"max_height\":1080"))
    #expect(line.contains("\"dir\":\"\\/m\"") || line.contains("\"dir\":\"/m\""))
}

@Test func progressKeepsADownloadAlive() async throws {
    let w = fake(env: ["MODE": "downloadslow"], timeout: .milliseconds(500))   // the download takes 1 s
    let seen = Seen()
    let d = try await w.download("testVideo01", to: URL(filePath: "/m")) { seen.add($0) }
    await w.shutdown()
    #expect(d.bytes == 100)
    #expect(seen.all.map(\.downloaded) == [1, 2, 3, 4, 5])
    #expect(seen.all.allSatisfy { $0.total == nil })
}

@Test func cancellingADownloadSendsCancel() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "downloadhang", "LOG": log.path])
    let seen = Seen()
    let task = Task { try await w.download("testVideo01", to: URL(filePath: "/m")) { seen.add($0) } }
    for _ in 0..<40 where seen.all.isEmpty { try await Task.sleep(for: .milliseconds(50)) }   // it is in flight
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    try await Task.sleep(for: .milliseconds(200))   // the cancel line reaches the fake's log
    await w.shutdown()
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    let rid = try #require(lines.first.flatMap { $0.firstMatch(of: /"rid":(\d+)/) }.map { String($0.1) })
    #expect(lines.contains { $0.contains("\"op\":\"cancel\"") && $0.contains("\"target\":\(rid)") })
}

@Test func commentsAreDecodedAndOnlyValidIdsAreSent() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "comments", "LOG": log.path])
    let page = try await w.comments(of: "testVideo01", first: 30)
    await #expect(throws: WorkerError.invalidID) { try await w.comments(of: "--exec=x", first: 30) }
    let next = try await w.moreComments(cursor: 7, n: 20)
    let replies = try await w.replies(cursor: 7, of: "c2", n: 10)
    await w.shutdown()
    #expect(replies.replies.map(\.id) == ["c1.0"] && !replies.done)
    #expect(page.comments[0].replyCount == nil && !page.comments[0].hasReplies)
    #expect(page.comments[1].replyCount == 670 && page.comments[1].hasReplies)
    #expect(page.count == 1234 && page.cursor == 7 && !page.done)
    #expect(next.comments.map(\.id) == ["c3"] && next.done && next.count == nil)
    #expect(page.comments.map(\.id) == ["c1", "c2"])
    #expect(page.comments[0] == VideoComment(id: "c1", text: "Hi", author: "@a", authorId: "UCaaaaaaaaaaaaaaaaaaaaaa",
                                             likes: 12, time: "2 days ago", isUploader: true, hearted: false))
    #expect(page.comments[1].authorId == nil && page.comments[1].hearted)
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[2].contains("\"op\":\"replies\"") && lines[2].contains("\"id\":\"c2\"") && lines[2].contains("\"cursor\":7"))
    #expect(lines[0].contains("\"op\":\"comments\"") && lines[0].contains("\"n\":30"))
    #expect(lines[1].contains("\"op\":\"more\"") && lines[1].contains("\"cursor\":7"))
}

@Test func playlistsSendsTheVideoIdAndDropsInvalidCandidates() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "playlists", "LOG": log.path])
    let found = try await w.playlists(of: "testVideo01")
    await #expect(throws: WorkerError.invalidID) { try await w.playlists(of: "--exec=x") }
    await w.shutdown()
    #expect(found == [ChannelPlaylist(id: "PLaaaaaaaaaaaa", title: "Course")])
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines[0].contains("\"op\":\"playlists\"") && lines[0].contains("\"id\":\"testVideo01\""))
}

@Test func descriptionsSendIdsAndReadStopped() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "descriptions", "LOG": log.path])
    let got = try await w.descriptions(of: ["testVideo01", "aaaaaaaaaaa"])
    await #expect(throws: WorkerError.invalidID) { try await w.descriptions(of: ["--x"]) }
    await w.shutdown()
    #expect(got.descriptions == ["testVideo01": "About it", "aaaaaaaaaaa": ""] && got.stopped)
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1 && lines[0].contains("\"op\":\"descriptions\"") && lines[0].contains("aaaaaaaaaaa"))
}

@Test func descriptionsGoInBatchesOfFiveAndStopAtAThrottle() async throws {
    let ids = (0..<12).map { String(format: "v%010d", $0) }
    for (mode, requests) in [("descriptionsok", 3), ("descriptions", 1)] {
        let log = tempFile()
        defer { try? FileManager.default.removeItem(at: log) }
        let w = fake(env: ["MODE": mode, "LOG": log.path])
        let got = try await w.descriptions(of: ids)
        await w.shutdown()
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == requests, "\(mode)")
        #expect(lines.allSatisfy { $0.components(separatedBy: "\"v0").count - 1 <= 5 }, "each request asks for at most 5")
        #expect(got.stopped == (mode == "descriptions"))
    }
}

@Test func relatedSendsTheVideoIdAndDropsInvalidEntries() async throws {
    let log = tempFile()
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "related", "LOG": log.path])
    let videos = try await w.related(of: "testVideo01")
    await #expect(throws: WorkerError.invalidID) { try await w.related(of: "--x") }
    await w.shutdown()
    #expect(videos.map(\.id) == ["aaaaaaaaaaa"])
    #expect(videos[0].channelId == "UCaaaaaaaaaaaaaaaaaaaaaa" && videos[0].duration == 61)
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1 && lines[0].contains("\"op\":\"related\"") && lines[0].contains("testVideo01"))
}
