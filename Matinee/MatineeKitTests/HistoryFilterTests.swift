import Foundation
import Testing
import MatineeKit

private func entry(_ title: String, _ channel: String) -> HistoryEntry {
    HistoryEntry(videoId: "aaaaaaaaaaa", title: title, channelId: nil, channelName: channel, lengthSeconds: nil,
                 publishedAt: nil, watchedAt: Date(timeIntervalSince1970: 0), positionSeconds: 0)
}

@Test func emptyQueryReturnsAll() {
    let all = [entry("A", "x"), entry("B", "y")]
    #expect(HistoryFilter.apply("", to: all) == all)
    #expect(HistoryFilter.apply("   ", to: all) == all)
}

@Test func allWordsMustMatch() {
    let e = entry("Lofi beats", "Lofi Girl")
    #expect(HistoryFilter.apply("lofi girl", to: [e]) == [e])
    #expect(HistoryFilter.apply("lofi cat", to: [e]).isEmpty)
}

@Test func diacriticsIgnored() {
    let e = entry("Café music", "Somebody")
    #expect(HistoryFilter.apply("cafe", to: [e]) == [e])
}

@Test func matchesAnyField() {
    #expect(HistoryFilter.matches("foo", "x", "a FOO b") == true)
    #expect(HistoryFilter.matches("foo", "x") == false)
}

@Test func parsedQueryMatchesLikeTheString() {
    let q = HistoryFilter.Query("  café  GIRL ")
    #expect(!q.isEmpty)
    #expect(q.matches("Cafe music", "Lofi Girl"))
    #expect(!q.matches("Cafe music", "Somebody"))
    #expect(HistoryFilter.Query(" ").isEmpty)
    #expect(HistoryFilter.Query(" ").matches("anything"))
}
