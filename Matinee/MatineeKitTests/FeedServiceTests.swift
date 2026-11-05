import Foundation
import Testing
import MatineeKit

private let fixtureChannelId = "UCq2fDk8Tn3ZbWm0yLpXeR7A"

private func fixture(channelId: String, tag: String) throws -> Data {
    let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/feed_channel.xml")
    // Video ids are the store's primary key, so each channel needs its own.
    let xml = try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: fixtureChannelId, with: channelId)
        .replacingOccurrences(of: "k3Jx9QpLm2A", with: "k3Jx9" + tag)
        .replacingOccurrences(of: "Yd7Ng2hRbQe", with: "Yd7Ng" + tag)
    return Data(xml.utf8)
}

private func chan(_ i: Int) -> Channel {
    Channel(id: "UC" + String(format: "%022d", i), name: "Channel \(i)", thumbnailURL: nil,
            subscribedAt: Date(timeIntervalSince1970: 1_650_000_000))
}

private struct Boom: Error {}

private func channelId(of url: URL) -> String {
    URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "channel_id" }!.value!
}

/// Serves the fixture for every channel except `failing`.
private func fakeFetch(failing: Set<String> = []) -> FeedService.Fetch {
    { url in
        let id = channelId(of: url)
        if failing.contains(id) { throw Boom() }
        return try fixture(channelId: id, tag: String(id.suffix(6)))
    }
}

private actor InFlight {
    var current = 0, peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

private actor Recorder {
    var urls: [URL] = []
    func add(_ u: URL) { urls.append(u) }
}

@Test func refreshStoresEveryChannel() async throws {
    let store = try Store.inMemory()
    let channels = (1...3).map(chan)
    try store.upsert(channels)
    let result = await FeedService(store: store, fetch: fakeFetch()).refresh(channels: channels)
    #expect(result == FeedRefreshResult(updated: 3, failed: []))
    #expect(try store.feed().count == 6)
}

@Test func refreshKeepsOtherChannelsWhenOneFails() async throws {
    let store = try Store.inMemory()
    let channels = (1...3).map(chan)
    try store.upsert(channels)
    let result = await FeedService(store: store, fetch: fakeFetch(failing: [channels[1].id])).refresh(channels: channels)
    #expect(result == FeedRefreshResult(updated: 2, failed: [channels[1].id]))
    #expect(Set(try store.feed().map(\.channelId)) == [channels[0].id, channels[2].id])
}

@Test func failedChannelKeepsItsOldRows() async throws {
    let store = try Store.inMemory()
    let channels = (1...3).map(chan)
    try store.upsert(channels)
    _ = await FeedService(store: store, fetch: fakeFetch()).refresh(channels: [channels[1]])
    let before = try store.feed()
    #expect(before.count == 2)
    let result = await FeedService(store: store, fetch: fakeFetch(failing: [channels[1].id])).refresh(channels: channels)
    #expect(result.failed == [channels[1].id])
    #expect(try store.feed().filter { $0.channelId == channels[1].id } == before)
}

@Test func concurrencyIsCapped() async throws {
    let store = try Store.inMemory()
    let channels = (1...20).map(chan)
    try store.upsert(channels)
    let counter = InFlight()
    let service = FeedService(store: store, fetch: { url in
        await counter.enter()
        try? await Task.sleep(for: .milliseconds(20))
        await counter.leave()
        let id = channelId(of: url)
        return try fixture(channelId: id, tag: String(id.suffix(6)))
    }, maxConcurrent: 3)
    let result = await service.refresh(channels: channels)
    #expect(result.updated == 20)
    let peak = await counter.peak
    #expect(peak <= 3)
    #expect(peak > 1)
}

@Test func invalidChannelIdIsNotFetched() async throws {
    let store = try Store.inMemory()
    let bad = Channel(id: "x/../y", name: "Bad", thumbnailURL: nil, subscribedAt: Date())
    let recorder = Recorder()
    let service = FeedService(store: store, fetch: { url in await recorder.add(url); throw Boom() })
    let result = await service.refresh(channels: [bad])
    #expect(result == FeedRefreshResult(updated: 0, failed: ["x/../y"]))
    #expect(await recorder.urls.isEmpty)
    #expect(FeedService.feedURL(channelId: "x/../y") == nil)
    #expect(FeedService.feedURL(channelId: chan(1).id)?.absoluteString
            == "https://www.youtube.com/feeds/videos.xml?channel_id=UC0000000000000000000001")
}

// MARK: Conditional requests

private actor Validated {
    var sent: [FeedService.Validators?] = []
    func add(_ v: FeedService.Validators?) { sent.append(v) }
}

@Test func unchangedFeedIsNotParsedOrRewritten() async throws {
    let store = try Store.inMemory()
    let channel = chan(1)
    try store.upsert([channel])   // the feed shows subscribed channels only
    let sent = Validated()
    let service = FeedService(store: store, conditionalFetch: { url, validators in
        await sent.add(validators)
        if validators?.etag == "\"v1\"" { return .unchanged }
        return .fresh(try fixture(channelId: channelId(of: url), tag: "AAAAAA"),
                      FeedService.Validators(etag: "\"v1\"", lastModified: "Tue, 03 Nov 2026 10:00:00 GMT"))
    })
    #expect(await service.refresh(channels: [channel]) == FeedRefreshResult(updated: 1, failed: []))
    let rows = try store.feed()
    #expect(!rows.isEmpty)
    #expect(try store.feedValidators(channelId: channel.id) ==
            FeedService.Validators(etag: "\"v1\"", lastModified: "Tue, 03 Nov 2026 10:00:00 GMT"))
    #expect(await service.refresh(channels: [channel]) == FeedRefreshResult(updated: 1, failed: []))
    #expect(try store.feed() == rows)   // a 304 leaves the cached videos as they were
    #expect(await sent.sent == [nil, FeedService.Validators(etag: "\"v1\"", lastModified: "Tue, 03 Nov 2026 10:00:00 GMT")])
}

@Test func plainFetchSendsNoValidators() async throws {
    let store = try Store.inMemory()
    try store.saveFeedValidators(FeedService.Validators(etag: "\"x\"", lastModified: nil), channelId: chan(1).id)
    let result = await FeedService(store: store, fetch: fakeFetch()).refresh(channels: [chan(1)])
    #expect(result.updated == 1)
}
