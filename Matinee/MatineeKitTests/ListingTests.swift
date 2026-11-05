import Foundation
import Testing
import MatineeKit

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

private func fake(env: [String: String]) -> WorkerClient {
    WorkerClient(executable: URL(filePath: "/bin/sh"), arguments: [fixtures.appending(path: "fake_worker.sh").path],
                 workingDirectory: FileManager.default.temporaryDirectory, environment: env,
                 timeout: .seconds(5), firstTimeout: .seconds(5))
}

@Test func decodesPageAndDropsInvalidIds() async throws {
    let w = fake(env: ["MODE": "list"])
    let page = try await w.list(.search("cats", SearchFilter()), first: 20)
    await w.shutdown()
    #expect(page.entries.map(\.kind) == [.video, .channel, .playlist])
    #expect(page.cursor == 1)
    #expect(page.title == "T")
    #expect(page.done == false)
    let video = page.entries[0]
    #expect(video.channel == "C")
    #expect(video.duration == 61)
    #expect(video.views == 7)
    #expect(video.thumbnail == nil)   // http is dropped
    #expect(page.entries[1].thumbnail == URL(string: "https://example.invalid/c.jpg"))
    #expect(page.entries[2].count == 3)
}

@Test func moreReturnsDone() async throws {
    let w = fake(env: ["MODE": "list"])
    let page = try await w.more(cursor: 1, n: 20)
    await w.shutdown()
    #expect(page.entries.isEmpty)
    #expect(page.done)
}

@Test func invalidURLNeverReachesWorker() async throws {
    let log = FileManager.default.temporaryDirectory.appending(path: "matinee-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: log) }
    let w = fake(env: ["MODE": "list", "LOG": log.path])
    await #expect(throws: WorkerError.invalidID) { try await w.list(.search("  ", SearchFilter()), first: 20) }
    _ = try await w.more(cursor: 1, n: 1)
    await w.shutdown()
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(!text.contains("\"list\""))
}

@Test func workerRejectsUrlOutsideAllowlist() async throws {
    let w = fake(env: ["MODE": "reject"])
    await #expect(throws: WorkerError.failed("url not allowed")) {
        try await w.list(.search("cats", SearchFilter()), first: 20)
    }
    await w.shutdown()
}
