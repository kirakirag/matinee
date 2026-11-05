import Foundation
import Testing
@testable import MatineeKit

private actor Fake {
    struct Call: Equatable { var id: String; var clients: [String]?; var maxHeight: Int? = nil }
    private(set) var calls: [Call] = []
    private var results: [[String]?: Result<Resolved, any Error>] = [:]
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var gated = false
    private var open = false

    func set(_ clients: [String]?, _ result: Result<Resolved, any Error>) { results[clients] = result }
    func blockCalls() { gated = true }
    func release() {
        open = true
        gates.forEach { $0.resume() }
        gates = []
    }

    func call(_ id: String, _ clients: [String]?, _ maxHeight: Int? = nil) async throws -> Resolved {
        calls.append(Call(id: id, clients: clients, maxHeight: maxHeight))
        if gated && !open {
            await withCheckedContinuation { gates.append($0) }
        }
        return try results[clients]!.get()
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func set(_ d: Date) { lock.withLock { date = d } }
}

private func resolved(height: Int, expire: TimeInterval = 100_000) -> Resolved {
    let json: [String: Any] = ["video_url": "https://example.com/v.mp4", "height": height, "expire": expire]
    return try! JSONDecoder().decode(Resolved.self, from: JSONSerialization.data(withJSONObject: json))
}

private func makeResolver(_ fake: Fake, clock: Clock = Clock(Date(timeIntervalSince1970: 0))) -> PlaybackResolver {
    PlaybackResolver(resolve: { try await fake.call($0, $1, $2) }, now: { clock.now })
}

struct PlaybackResolverTests {
    @Test func usesVisionosWhenGood() async throws {
        let fake = Fake()
        await fake.set(["visionos"], .success(resolved(height: 1080)))
        let r = try await makeResolver(fake).resolve("a")
        #expect(r.height == 1080)
        #expect(await fake.calls == [.init(id: "a", clients: ["visionos"])])
    }

    @Test func fallsBackOnError() async throws {
        let fake = Fake()
        await fake.set(["visionos"], .failure(WorkerError.crashed))
        await fake.set(nil, .success(resolved(height: 720)))
        let r = try await makeResolver(fake).resolve("a")
        #expect(r.height == 720)
        #expect(await fake.calls == [.init(id: "a", clients: ["visionos"]), .init(id: "a", clients: nil)])
    }

    @Test func fallsBackOnLowQuality() async throws {
        let fake = Fake()
        await fake.set(["visionos"], .success(resolved(height: 360)))
        await fake.set(nil, .success(resolved(height: 1080)))
        #expect(try await makeResolver(fake).resolve("a").height == 1080)
    }

    @Test func keepsBetterWhenFallbackIsWorse() async throws {
        let fake = Fake()
        await fake.set(["visionos"], .success(resolved(height: 480)))
        await fake.set(nil, .success(resolved(height: 360)))
        #expect(try await makeResolver(fake).resolve("a").height == 480)
    }

    @Test func lowQualityThenFallbackErrorThrows() async {
        let fake = Fake()
        await fake.set(["visionos"], .success(resolved(height: 360)))
        await fake.set(nil, .failure(WorkerError.failed("boom")))
        await #expect(throws: WorkerError.failed("boom")) {
            try await makeResolver(fake).resolve("a")
        }
    }

    @Test func cachesUntilNearExpiry() async throws {
        let fake = Fake()
        await fake.set(["visionos"], .success(resolved(height: 1080, expire: 10_000)))
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let resolver = makeResolver(fake, clock: clock)
        _ = try await resolver.resolve("a")
        clock.set(Date(timeIntervalSince1970: 8_199))
        _ = try await resolver.resolve("a")
        #expect(await fake.calls.count == 1)
        clock.set(Date(timeIntervalSince1970: 8_200))
        _ = try await resolver.resolve("a")
        #expect(await fake.calls.count == 2)
    }

    @Test func concurrentSameIdShareOneResolve() async throws {
        let fake = Fake()
        await fake.blockCalls()
        await fake.set(["visionos"], .success(resolved(height: 1080)))
        let resolver = makeResolver(fake)
        async let x = resolver.resolve("a")
        async let y = resolver.resolve("a")
        await Task.yield()
        await fake.release()
        _ = try await (x, y)
        #expect(await fake.calls.count == 1)
    }

    @Test func prefetchQueueKeepsOnlyNewest() async throws {
        let fake = Fake()
        await fake.blockCalls()
        await fake.set(["visionos"], .success(resolved(height: 1080)))
        let resolver = makeResolver(fake)
        for id in ["A", "B", "C", "D"] { await resolver.prefetch(id) }
        await fake.release()
        _ = try await resolver.resolve("A")
        _ = try await resolver.resolve("D")
        #expect(await fake.calls.map(\.id) == ["A", "D"])
    }

    @Test func cacheIsPerQuality() async throws {
        let fake = Fake()
        await fake.set(["visionos"], .success(resolved(height: 720)))
        let resolver = makeResolver(fake)
        _ = try await resolver.resolve("a")
        _ = try await resolver.resolve("a", maxHeight: 720)
        _ = try await resolver.resolve("a", maxHeight: 720)
        #expect(await fake.calls == [.init(id: "a", clients: ["visionos"]), .init(id: "a", clients: ["visionos"], maxHeight: 720)])
    }

    @Test func lowCapDoesNotTriggerFallback() async throws {
        let fake = Fake()
        await fake.set(["visionos"], .success(resolved(height: 480)))
        #expect(try await makeResolver(fake).resolve("a", maxHeight: 480).height == 480)
        #expect(await fake.calls == [.init(id: "a", clients: ["visionos"], maxHeight: 480)])
    }
}

// MARK: Kept across launches

private func full(_ id: String, expire: TimeInterval) -> Resolved {
    let json: [String: Any] = ["video_url": "https://r1.googlevideo.com/videoplayback?id=\(id)", "audio_url": "https://a/\(id)",
                               "height": 1080, "vcodec": "vp9", "expire": expire, "headers": ["User-Agent": "UA"],
                               "available_at": 0, "qualities": [1080, 720], "jsc": "deno", "title": "T", "channel": "C",
                               "channel_id": "UCaaaaaaaaaaaaaaaaaaaaaa", "duration": 61.5]
    return try! JSONDecoder().decode(Resolved.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func resolvedRoundTripsThroughTheStore() throws {
    let store = try Store.inMemory()
    let r = full("aaaaaaaaaaa", expire: 2_000_000_000)
    try store.saveResolved(r, videoId: "aaaaaaaaaaa", maxHeight: nil, now: Date(timeIntervalSince1970: 1_000_000_000))
    try store.saveResolved(full("bbbbbbbbbbb", expire: 5), videoId: "bbbbbbbbbbb", maxHeight: 720,
                           now: Date(timeIntervalSince1970: 1_000_000_000))   // expired: dropped by the next save
    #expect(try store.resolved(videoId: "aaaaaaaaaaa", maxHeight: nil) == r)
    #expect(try store.resolved(videoId: "aaaaaaaaaaa", maxHeight: 720) == nil)   // another cap is another entry
    try store.saveResolved(r, videoId: "ccccccccccc", maxHeight: 720, now: Date(timeIntervalSince1970: 1_000_000_000))
    #expect(try store.resolved(videoId: "bbbbbbbbbbb", maxHeight: 720) == nil)
    try store.deleteResolved(videoId: "aaaaaaaaaaa")
    #expect(try store.resolved(videoId: "aaaaaaaaaaa", maxHeight: nil) == nil)
    #expect(try store.resolved(videoId: "ccccccccccc", maxHeight: 720) == r)
}

@Test func storedResolveIsUsedAfterARelaunch() async throws {
    let store = try Store.inMemory()
    let clock = Clock(Date(timeIntervalSince1970: 10_000))
    let fake = Fake()
    await fake.set(["visionos"], .success(resolved(height: 1080)))
    let first = PlaybackResolver(resolve: { try await fake.call($0, $1, $2) }, now: { clock.now }, store: store)
    let r = try await first.resolve("aaaaaaaaaaa")
    // A new resolver, as after a relaunch: the stored result is used without asking the worker.
    let second = PlaybackResolver(resolve: { try await fake.call($0, $1, $2) }, now: { clock.now }, store: store)
    #expect(try await second.resolve("aaaaaaaaaaa") == r)
    #expect(await fake.calls.count == 1)
    // Within 30 minutes of expiring, it's resolved again (and saved over).
    clock.set(Date(timeIntervalSince1970: 100_000 - 1700))
    let third = PlaybackResolver(resolve: { try await fake.call($0, $1, $2) }, now: { clock.now }, store: store)
    _ = try await third.resolve("aaaaaaaaaaa")
    #expect(await fake.calls.count == 2)
}

@Test func invalidateForgetsAResolveInMemoryAndInTheStore() async throws {
    let store = try Store.inMemory()
    let fake = Fake()
    await fake.set(["visionos"], .success(resolved(height: 1080)))
    let resolver = PlaybackResolver(resolve: { try await fake.call($0, $1, $2) }, now: { Date(timeIntervalSince1970: 10_000) },
                                    store: store)
    _ = try await resolver.resolve("aaaaaaaaaaa")
    _ = try await resolver.resolve("aaaaaaaaaaa", maxHeight: 720)
    await resolver.invalidate("aaaaaaaaaaa")   // e.g. a 403 after a network change: the URLs carry the old IP
    #expect(try store.resolved(videoId: "aaaaaaaaaaa", maxHeight: nil) == nil)
    _ = try await resolver.resolve("aaaaaaaaaaa")
    _ = try await resolver.resolve("aaaaaaaaaaa", maxHeight: 720)
    #expect(await fake.calls.count == 4)
}

// MARK: Racing the fallback when visionos has been falling short

@Test func afterVisionosFellShortTheNextResolveRacesBothClients() async throws {
    let fake = Fake()
    await fake.set(["visionos"], .success(resolved(height: 480)))
    await fake.set(nil, .success(resolved(height: 1080)))
    let resolver = PlaybackResolver { try await fake.call($0, $1, $2) }
    #expect(try await resolver.resolve("aaaaaaaaaaa").height == 1080)   // one after the other: visionos, then the fallback
    #expect(await fake.calls.map(\.clients) == [["visionos"], nil])

    await fake.blockCalls()
    let racing = Task { try await resolver.resolve("bbbbbbbbbbb") }
    for _ in 0..<100 where await fake.calls.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await fake.calls.count == 4)   // both started before either answered
    await fake.release()
    #expect(try await racing.value.height == 1080)
}

@Test func whenVisionosIsGoodAgainResolvesGoBackToOneClient() async throws {
    let fake = Fake()
    await fake.set(["visionos"], .success(resolved(height: 480)))
    await fake.set(nil, .success(resolved(height: 1080)))
    let resolver = PlaybackResolver { try await fake.call($0, $1, $2) }
    _ = try await resolver.resolve("aaaaaaaaaaa")
    await fake.set(["visionos"], .success(resolved(height: 1080)))
    #expect(try await resolver.resolve("bbbbbbbbbbb").height == 1080)   // raced; visionos was enough
    let before = await fake.calls.count
    _ = try await resolver.resolve("ccccccccccc")
    #expect(await fake.calls.dropFirst(before).map(\.clients) == [["visionos"]])
}

@Test func aPrefetchNeverRacesSoItLeavesASlotForAnOpen() async throws {
    let fake = Fake()
    await fake.set(["visionos"], .success(resolved(height: 480)))
    await fake.set(nil, .success(resolved(height: 1080)))
    let resolver = PlaybackResolver { try await fake.call($0, $1, $2) }
    _ = try await resolver.resolve("aaaaaaaaaaa")   // visionos fell short
    await fake.blockCalls()
    await resolver.prefetch("bbbbbbbbbbb")
    try await Task.sleep(for: .milliseconds(100))
    #expect(await fake.calls.count == 3)   // only visionos for the prefetch, one worker slot
    await fake.release()
}
