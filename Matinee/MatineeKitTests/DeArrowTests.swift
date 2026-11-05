import CryptoKit
import Foundation
import Testing
import MatineeKit

private func fixtureData() throws -> Data {
    try Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/branding_prefix.json"))
}

private actor Counter {
    var urls: [URL] = []
    func add(_ u: URL) { urls.append(u) }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var value: Date { lock.withLock { date } }
    func advance(_ s: TimeInterval) { lock.withLock { date += s } }
}

private struct Boom: Error {}

/// Answers every request with a branding entry for each id in `ids`; `absent` ids are left out.
private func response(titled ids: [String]) -> Data {
    let body = ids.map { "\"\($0)\": {\"titles\": [{\"title\": \"T \($0)\", \"original\": false, \"votes\": 1, \"locked\": false}], \"thumbnails\": []}" }
    return Data("{\(body.joined(separator: ","))}".utf8)
}

@Test func hashPrefixMatchesSHA256() {
    let id = "testVideo01"
    let expected = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
    let prefix = DeArrow.hashPrefix(id)
    #expect(prefix == String(expected))
    #expect(prefix.count == 4)
    #expect(prefix.allSatisfy { "0123456789abcdef".contains($0) })
}

@Test func urlsAreBuilt() {
    #expect(DeArrow.brandingURL(prefix: "ab12").absoluteString == "https://sponsor.ajay.app/api/branding/ab12")
    #expect(DeArrow.thumbnailURL(videoId: "AAAAAAAAAAA", time: 42.1)?.absoluteString
        == "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=AAAAAAAAAAA&time=42.1")
    #expect(DeArrow.thumbnailURL(videoId: "bad/id", time: 1) == nil)
}

@Test func parsePicksTrustedNonOriginal() throws {
    let out = try DeArrow.parse(fixtureData())
    #expect(out["AAAAAAAAAAA"] == Branding(title: "A good title", thumbnailTime: 42.1))
    #expect(out["BBBBBBBBBBB"]?.title == "Quoted title")
    #expect(out["CCCCCCCCCCC"] == Branding(title: nil, thumbnailTime: 180))   // random frame only
    #expect(out["DDDDDDDDDDD"]?.title == "With original thumb")
    #expect(out["DDDDDDDDDDD"]?.thumbnailTime == nil)   // a trusted original on top: no custom or random one
}

@Test func randomFrameWhenNoThumbnailSubmission() throws {
    let out = try DeArrow.parse(fixtureData())
    #expect(out["BBBBBBBBBBB"]?.thumbnailTime == 180)   // 0.3 × 600
    #expect(out["AAAAAAAAAAA"]?.thumbnailTime == 42.1)  // a trusted submission still wins
    // An untrusted (downvoted, unlocked) top submission falls back to the random frame, as in DeArrow's extension.
    let json = #"""
    {"AAAAAAAAAAA": {"titles": [], "thumbnails": [{"timestamp": 9, "original": false, "votes": -2, "locked": false}],
                     "randomTime": 0.5, "videoDuration": 100}}
    """#
    #expect(try DeArrow.parse(Data(json.utf8))["AAAAAAAAAAA"]?.thumbnailTime == 50)
}

@Test func noRandomFrameWithoutDuration() throws {
    let json = #"""
    {"AAAAAAAAAAA": {"titles": [], "thumbnails": [], "randomTime": 0.3, "videoDuration": null},
     "BBBBBBBBBBB": {"titles": [], "thumbnails": [], "randomTime": 0.3, "videoDuration": 0},
     "CCCCCCCCCCC": {"titles": [], "thumbnails": [], "videoDuration": 600}}
    """#
    #expect(try DeArrow.parse(Data(json.utf8)).isEmpty)
}

@Test func topOriginalTitleOrThumbnailMeansNoCustomOne() throws {
    let json = """
    {"AAAAAAAAAAA": {"titles": [{"title": "Orig", "original": true, "votes": 9, "locked": false},
                                {"title": "Lower", "original": false, "votes": 1, "locked": false}],
                     "thumbnails": [{"timestamp": null, "original": true, "votes": 9, "locked": false},
                                    {"timestamp": 5.0, "original": false, "votes": 1, "locked": false}]}}
    """
    #expect(try DeArrow.parse(Data(json.utf8))["AAAAAAAAAAA"] == nil)
}

@Test func ignoresBrandingForOtherOrInvalidIds() throws {
    #expect(try DeArrow.parse(fixtureData())["bad/id"] == nil)
}

@Test func titleIsSanitised() throws {
    let title = #"a\u0007b"# + String(repeating: "x", count: 1000)
    let json = #"{"AAAAAAAAAAA": {"titles": [{"title": "\#(title)", "original": false, "votes": 1, "locked": false}], "thumbnails": []}}"#
    let out = try #require(DeArrow.parse(Data(json.utf8))["AAAAAAAAAAA"]?.title)
    #expect(out.count <= 300)
    #expect(out.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control })
    #expect(out.hasPrefix("a b"))
}

@Test func serviceCachesWithinTTL() async throws {
    let counter = Counter()
    let svc = DeArrowService(store: try .inMemory(), fetch: { url in
        await counter.add(url)
        return response(titled: ["AAAAAAAAAAA"])
    })
    let first = await svc.branding(for: ["AAAAAAAAAAA"])
    let second = await svc.branding(for: ["AAAAAAAAAAA"])
    #expect(first["AAAAAAAAAAA"]?.title == "T AAAAAAAAAAA")
    #expect(second == first)
    #expect(await counter.urls.count == 1)
}

@Test func serviceRefetchesAfterTTL() async throws {
    let counter = Counter()
    let time = LockedDate()
    let svc = DeArrowService(store: try .inMemory(), fetch: { url in
        await counter.add(url)
        return response(titled: ["AAAAAAAAAAA"])
    }, now: { time.value })
    _ = await svc.branding(for: ["AAAAAAAAAAA"])
    time.advance(86_401)
    _ = await svc.branding(for: ["AAAAAAAAAAA"])
    #expect(await counter.urls.count == 2)
}

@Test func serviceCachesMisses() async throws {
    let counter = Counter()
    let svc = DeArrowService(store: try .inMemory(), fetch: { url in
        await counter.add(url)
        return Data("{}".utf8)
    })
    #expect(await svc.branding(for: ["AAAAAAAAAAA"]).isEmpty)
    #expect(await svc.branding(for: ["AAAAAAAAAAA"]).isEmpty)
    #expect(await counter.urls.count == 1)
}

@Test func serviceOneRequestPerPrefix() async throws {
    var seen: [String: String] = [:]
    var pair: (String, String)?
    for i in 0..<100_000 {
        let id = String(format: "dearrow%04d", i)
        let prefix = DeArrow.hashPrefix(id)
        if let other = seen[prefix] { pair = (other, id); break }
        seen[prefix] = id
    }
    let (a, b) = try #require(pair)
    let counter = Counter()
    let svc = DeArrowService(store: try .inMemory(), fetch: { url in
        await counter.add(url)
        return response(titled: [a, b])
    })
    let out = await svc.branding(for: [a, b])
    #expect(out.count == 2)
    #expect(await counter.urls.count == 1)
}

@Test func serviceSurvivesNetworkFailure() async throws {
    let store = try Store.inMemory()
    let svc = DeArrowService(store: store, fetch: { _ in throw Boom() })
    #expect(await svc.branding(for: ["AAAAAAAAAAA"]) == [:])
    #expect(try store.branding(videoIds: ["AAAAAAAAAAA"]).isEmpty)
}

@Test func malformedEntryDoesNotSinkTheResponse() async throws {
    let json = #"""
    {"AAAAAAAAAAA": {"titles": [{"title": "Good", "votes": 1}, {"original": null}, {"title": null}],
                     "thumbnails": [7, {"timestamp": 5.5, "original": false, "votes": 1}]},
     "BBBBBBBBBBB": "garbage",
     "CCCCCCCCCCC": {"titles": 7}}
    """#
    let out = try DeArrow.parse(Data(json.utf8))
    #expect(out["AAAAAAAAAAA"] == Branding(title: "Good", thumbnailTime: 5.5))
    #expect(out["BBBBBBBBBBB"] == nil)

    let store = try Store.inMemory()
    let counter = Counter()
    let svc = DeArrowService(store: store, fetch: { url in await counter.add(url); return Data(json.utf8) })
    _ = await svc.branding(for: ["AAAAAAAAAAA"])
    _ = await svc.branding(for: ["AAAAAAAAAAA"])
    #expect(await counter.urls.count == 1)
    #expect(try store.branding(videoIds: ["AAAAAAAAAAA"])["AAAAAAAAAAA"]?.title == "Good")
}

private actor InFlight {
    var current = 0, peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

@Test func prefixesAreFetchedConcurrentlyWithACap() async throws {
    var ids: [String] = []
    var prefixes = Set<String>()
    var i = 0
    while prefixes.count < 40 {
        let id = String(format: "conc%07d", i); i += 1
        if prefixes.insert(DeArrow.hashPrefix(id)).inserted { ids.append(id) }
    }
    let flight = InFlight()
    let svc = DeArrowService(store: try .inMemory(), fetch: { _ in
        await flight.enter()
        try? await Task.sleep(for: .milliseconds(20))
        await flight.leave()
        return Data("{}".utf8)
    })
    _ = await svc.branding(for: ids)
    let peak = await flight.peak
    #expect(peak > 1)
    #expect(peak <= 8)
}

@Test func cancelledCallerStartsNoRequests() async throws {
    let store = try Store.inMemory()
    let counter = Counter()
    let svc = DeArrowService(store: store, fetch: { url in await counter.add(url); return Data("{}".utf8) })
    let task = Task {
        while !Task.isCancelled { await Task.yield() }   // runs the lookup only once cancelled
        return await svc.branding(for: ["AAAAAAAAAAA", "BBBBBBBBBBB"])
    }
    task.cancel()
    #expect(await task.value.isEmpty)
    #expect(await counter.urls.isEmpty)
}
