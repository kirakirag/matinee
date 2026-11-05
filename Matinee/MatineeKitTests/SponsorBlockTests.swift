import Foundation
import Testing
import MatineeKit

private let vid = "testVideo01"

private func seg(_ category: String, _ start: Double, _ end: Double, _ uuid: String = UUID().uuidString) -> SponsorSegment {
    SponsorSegment(category: category, start: start, end: end, uuid: uuid)
}

private let defaultOn: Set<String> = ["sponsor", "selfpromo"]

@Test func parseKeepsSkipSegmentsOfThisVideo() throws {
    let json = """
        [{"videoID": "\(vid)", "hash": "x", "segments": [
            {"category": "sponsor", "actionType": "skip", "segment": [10.5, 20], "UUID": "a", "videoDuration": 100},
            {"category": "sponsor", "actionType": "mute", "segment": [30, 40], "UUID": "b"},
            {"category": "intro", "actionType": "skip", "segment": [30, 10], "UUID": "c"},
            {"category": "selfpromo", "actionType": "skip", "segment": [50, 60], "UUID": "d"},
            {"category": "sponsor", "actionType": "skip", "segment": [1], "UUID": "e"}]},
         {"videoID": "other000000", "segments": [{"category": "sponsor", "actionType": "skip", "segment": [1, 2], "UUID": "z"}]}]
        """
    #expect(try SponsorBlock.parse(Data(json.utf8), videoId: vid) == [seg("sponsor", 10.5, 20, "a"), seg("selfpromo", 50, 60, "d")])
    #expect(try SponsorBlock.parse(Data("[]".utf8), videoId: vid) == [])
    #expect(throws: (any Error).self) { try SponsorBlock.parse(Data("{".utf8), videoId: vid) }
}

@Test func urlUsesHashPrefixAndAsksForEveryCategory() throws {
    let prefix = DeArrow.hashPrefix(vid)
    let url = SponsorBlock.skipSegmentsURL(prefix: prefix)
    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect("\(parts.scheme!)://\(parts.host!)\(parts.path)" == "https://sponsor.ajay.app/api/skipSegments/\(prefix)")
    // Without `categories` the server answers with sponsor segments only.
    let categories = try #require(parts.queryItems?.first { $0.name == "categories" }?.value)
    #expect(try JSONDecoder().decode([String].self, from: Data(categories.utf8)) == SponsorBlock.categories.map(\.id))
}

@Test func categoriesAndDefaults() throws {
    #expect(SponsorBlock.categories.map(\.id) ==
            ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic", "filler"])
    #expect(Set(SponsorBlock.categories.filter(\.defaultOn).map(\.id)) == defaultOn)
    let defaults = try #require(UserDefaults(suiteName: "sponsorblock-test-\(UUID().uuidString)"))
    #expect(SponsorBlock.enabledCategories(defaults) == defaultOn)
    defaults.set(false, forKey: "sponsorblock.sponsor")
    defaults.set(true, forKey: "sponsorblock.intro")
    #expect(SponsorBlock.enabledCategories(defaults) == ["selfpromo", "intro"])
}

@Test func skipsOnceInsideAndNotAfterUndo() {
    var s = SponsorSkipper(segments: [seg("sponsor", 10, 20)], enabled: defaultOn)
    #expect(s.check(position: 5) == nil)
    #expect(s.check(position: 10.2)?.end == 20)
    #expect(s.undo() == 10)
    #expect(s.check(position: 10.5) == nil)
    #expect(s.check(position: 25) == nil)
    #expect(s.undo() == nil)
}

@Test func skipsAgainOnReentryUnlessUndone() {
    var s = SponsorSkipper(segments: [seg("sponsor", 10, 20)], enabled: defaultOn)
    #expect(s.check(position: 11) != nil)
    #expect(s.check(position: 20) == nil)   // landed at the end
    #expect(s.check(position: 12) != nil)   // seeked back into it
}

@Test func skipsWhenStartingInsideASegment() {
    var s = SponsorSkipper(segments: [seg("sponsor", 0, 8)], enabled: defaultOn)
    #expect(s.check(position: 0)?.end == 8)
    var resumed = SponsorSkipper(segments: [seg("sponsor", 0, 8)], enabled: defaultOn)
    #expect(resumed.check(position: 4)?.end == 8)
}

@Test func nothingToSkipNearTheEnd() {
    var s = SponsorSkipper(segments: [seg("sponsor", 10, 20)], enabled: defaultOn)
    #expect(s.check(position: 19.6) == nil)
}

@Test func disabledCategoryIsNotSkipped() {
    var s = SponsorSkipper(segments: [seg("intro", 0, 30)], enabled: defaultOn)
    #expect(s.check(position: 5) == nil)
}

private struct Boom: Error {}

private func segmentsJSON(_ id: String) -> Data {
    Data(#"[{"videoID": "\#(id)", "segments": [{"category": "sponsor", "actionType": "skip", "segment": [1, 5], "UUID": "u1"}]}]"#.utf8)
}

@Test func serviceStoresAndFallsBackToCache() async throws {
    let store = try Store.inMemory()
    let online = SponsorBlockService(store: store, fetch: { _ in segmentsJSON(vid) })
    let expected = [seg("sponsor", 1, 5, "u1")]
    #expect(await online.segments(for: vid) == expected)
    #expect(try store.segments(videoId: vid) == expected)
    let offline = SponsorBlockService(store: store, fetch: { _ in throw Boom() })
    #expect(await offline.segments(for: vid) == expected)
    let none = SponsorBlockService(store: store, fetch: { _ in Data("[]".utf8) })   // what urlSession gives for a 404
    #expect(await none.segments(for: "abcdefghijk") == [])
    #expect(try store.segments(videoId: "abcdefghijk") == [])
    #expect(try store.segments(videoId: "zzzzzzzzzzz") == nil)
    #expect(await offline.segments(for: "--exec=xxxx") == [])
}

@Test func slowSponsorBlockGivesUpAfterTimeout() async throws {
    let store = try Store.inMemory()
    try store.saveSegments([seg("sponsor", 1, 5, "old")], videoId: vid, fetchedAt: .now)
    let slow = SponsorBlockService(store: store, fetch: { _ in
        try await Task.sleep(for: .seconds(10))
        return segmentsJSON(vid)
    }, timeout: .milliseconds(200))
    let started = ContinuousClock.now
    #expect(await slow.segments(for: vid).map(\.uuid) == ["old"])
    #expect(await slow.segments(for: "abcdefghijk") == [])
    #expect(ContinuousClock.now - started < .seconds(2))   // two 200 ms timeouts, not the 10 s fetch; slack for a loaded machine
}
