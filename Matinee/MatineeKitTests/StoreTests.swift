import Foundation
import Testing
import MatineeKit
import SQLite3

extension HistoryEntry {
    /// Distinct, valid-looking entry number `i`; later `i` means watched later.
    static func sample(i: Int, title: String? = nil) -> HistoryEntry {
        HistoryEntry(videoId: String(format: "vid%08d", i), title: title ?? "Video \(i)", channelId: "UC" + String(repeating: "a", count: 22),
                     channelName: "Channel", lengthSeconds: 60 + i, publishedAt: Date(timeIntervalSince1970: 1_600_000_000),
                     watchedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), positionSeconds: 0)
    }
}

private func channel(_ id: String, _ name: String) -> Channel {
    Channel(id: id, name: name, thumbnailURL: URL(string: "https://yt3.ggpht.com/\(id)"),
            subscribedAt: Date(timeIntervalSince1970: 1_650_000_000))
}

@Test func roundTripsChannels() throws {
    let s = try Store.inMemory()
    let a = channel("UCaaaaaaaaaaaaaaaaaaaaaa", "beta"), b = channel("UCbbbbbbbbbbbbbbbbbbbbbb", "Alpha")
    try s.upsert([a, b])
    #expect(try s.subscriptions() == [b, a])   // by name, case-insensitive
}

@Test func unsubscribeRemoves() throws {
    let s = try Store.inMemory()
    try s.upsert([channel("UCaaaaaaaaaaaaaaaaaaaaaa", "A"), channel("UCbbbbbbbbbbbbbbbbbbbbbb", "B")])
    try s.unsubscribe(channelId: "UCaaaaaaaaaaaaaaaaaaaaaa")
    #expect(try s.subscriptions().map(\.id) == ["UCbbbbbbbbbbbbbbbbbbbbbb"])
}

@Test func historyNewestFirst() throws {
    let s = try Store.inMemory()
    try s.upsert([HistoryEntry.sample(i: 1), .sample(i: 3), .sample(i: 2)])
    #expect(try s.history() == [.sample(i: 3), .sample(i: 2), .sample(i: 1)])
}

@Test func deletingFromHistoryCanBeUndoneExactly() throws {
    let s = try Store.inMemory()
    try s.upsert([HistoryEntry.sample(i: 1), .sample(i: 2)])
    let removed = try #require(try s.historyEntry(videoId: HistoryEntry.sample(i: 1).videoId))
    try s.deleteHistory(videoId: removed.videoId)
    #expect(try s.history() == [.sample(i: 2)])
    try s.upsert([removed])   // undo: watch time and position come back as they were
    #expect(try s.history() == [.sample(i: 2), .sample(i: 1)])
}

@Test func upsertReplacesSameVideo() throws {
    let s = try Store.inMemory()
    try s.upsert([HistoryEntry.sample(i: 1, title: "old")])
    var newer = HistoryEntry.sample(i: 1, title: "new")
    newer.positionSeconds = 42
    try s.upsert([newer])
    #expect(try s.history() == [newer])
    #expect(try s.counts().history == 1)
}

@Test func upsertWithoutLengthKeepsStoredLength() throws {
    let s = try Store.inMemory()
    let original = HistoryEntry.sample(i: 1)
    try s.upsert([original])
    var again = original
    again.lengthSeconds = nil
    again.positionSeconds = 5
    try s.upsert([again])
    #expect(try s.historyEntry(videoId: original.videoId)?.lengthSeconds == original.lengthSeconds)
    #expect(try s.historyEntry(videoId: original.videoId)?.positionSeconds == 5)
}

@Test func reopenKeepsData() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "nested/matinee.sqlite")
    do {
        let s = try Store(path: url)
        try s.upsert([channel("UCaaaaaaaaaaaaaaaaaaaaaa", "A")])
        try s.upsert([HistoryEntry.sample(i: 7)])
    }
    let reopened = try Store(path: url)
    #expect(try reopened.counts() == (channels: 1, history: 1))
    #expect(try reopened.history() == [.sample(i: 7)])
}

@Test func historyOf20kLoadsFast() throws {
    let s = try Store.inMemory()
    try s.upsert((0..<20_000).map { HistoryEntry.sample(i: $0) })
    let clock = ContinuousClock()
    var loaded: Result<[HistoryEntry], any Error> = .success([])
    let d = clock.measure { loaded = Result { try s.history() } }
    #expect(try loaded.get().count == 20_000)
    #expect(d < .milliseconds(150))
}

// MARK: Feed and DeArrow cache (schema v2)

extension FeedVideo {
    static func sample(i: Int, channel: String) -> FeedVideo {
        FeedVideo(videoId: String(format: "fv%09d", i), channelId: channel, channelName: "rss",
                  title: "Feed \(i)", publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), views: 10 * i)
    }
}

private let chA = "UCaaaaaaaaaaaaaaaaaaaaaa", chB = "UCbbbbbbbbbbbbbbbbbbbbbb"
private let fetched = Date(timeIntervalSince1970: 1_700_001_000)

private func feedStore() throws -> Store {
    let s = try Store.inMemory()
    try s.upsert([channel(chA, "A"), channel(chB, "B")])
    try s.replaceFeed(channelId: chA, videos: [.sample(i: 1, channel: chA), .sample(i: 3, channel: chA)], fetchedAt: fetched)
    try s.replaceFeed(channelId: chB, videos: [.sample(i: 2, channel: chB)], fetchedAt: fetched)
    return s
}

private func ids(_ ns: Int...) -> [String] { ns.map { String(format: "fv%09d", $0) } }

@Test func feedNewestFirstAcrossChannels() throws {
    #expect(try feedStore().feed().map(\.videoId) == ids(3, 2, 1))
}

@Test func feedHidesUnsubscribedChannels() throws {
    let s = try feedStore()
    try s.unsubscribe(channelId: chB)
    #expect(try s.feed().map(\.videoId) == ids(3, 1))
    try s.upsert([channel(chB, "B")])
    #expect(try s.feed().map(\.videoId) == ids(3, 2, 1))
}

@Test func replaceFeedReplacesOnlyThatChannel() throws {
    let s = try feedStore()
    try s.replaceFeed(channelId: chA, videos: [.sample(i: 4, channel: chA)], fetchedAt: fetched)
    #expect(try s.feed().map(\.videoId) == ids(4, 2))
}

@Test func feedUsesSubscriptionName() throws {
    let s = try Store.inMemory()
    try s.upsert([channel(chA, "New")])
    var v = FeedVideo.sample(i: 1, channel: chA)
    v.channelName = "old"
    try s.replaceFeed(channelId: chA, videos: [v], fetchedAt: fetched)
    #expect(try s.feed().map(\.channelName) == ["New"])
}

@Test func historyEntryLookup() throws {
    let s = try Store.inMemory()
    try s.upsert([HistoryEntry.sample(i: 5)])
    #expect(try s.historyEntry(videoId: HistoryEntry.sample(i: 5).videoId) == .sample(i: 5))
    #expect(try s.historyEntry(videoId: "nope0000000") == nil)
}

@Test func brandingRoundTrip() throws {
    let s = try Store.inMemory()
    let saved = CachedBranding(title: "T", thumbnailTime: 12.5, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    try s.saveBranding(["aaaaaaaaaaa": saved])
    #expect(try s.branding(videoIds: ["aaaaaaaaaaa", "bbbbbbbbbbb"]) == ["aaaaaaaaaaa": saved])
}

@Test func brandingLooksUpManyIdsAtOnce() throws {
    let s = try Store.inMemory()
    let id = { (i: Int) in String(format: "v%010d", i) }
    let saved = Dictionary(uniqueKeysWithValues: stride(from: 0, to: 1000, by: 2).map {
        (id($0), CachedBranding(title: $0 % 4 == 0 ? "T\($0)" : nil, thumbnailTime: nil, fetchedAt: fetched))
    })
    try s.saveBranding(saved)
    #expect(try s.branding(videoIds: (0..<1000).map(id) + [id(0), "quote\"'id"]) == saved)
    #expect(try s.branding(videoIds: []).isEmpty)
}

@Test func migratesV1Database() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "v1.sqlite")
    var h: OpaquePointer?
    #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
    let v1 = """
        CREATE TABLE channel(id TEXT PRIMARY KEY, name TEXT NOT NULL, thumbnail TEXT, subscribed_at REAL NOT NULL);
        CREATE TABLE history(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_id TEXT,
            channel_name TEXT NOT NULL, length_seconds INTEGER, published_at REAL,
            watched_at REAL NOT NULL, position REAL NOT NULL);
        CREATE INDEX history_watched ON history(watched_at DESC);
        INSERT INTO history VALUES('vid00000001', 'Old', NULL, 'Ch', NULL, NULL, 1700000000, 0);
        PRAGMA user_version = 1;
        """
    #expect(sqlite3_exec(h, v1, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(h)
    let s = try Store(path: url)
    #expect(try s.history().map(\.videoId) == ["vid00000001"])
    #expect(try s.feed().isEmpty)
}

// MARK: Recent playlists and progress (schema v3)

private func playlist(_ id: String, at t: Double) -> RecentPlaylist {
    RecentPlaylist(id: id, title: "Playlist \(id)", channelName: "Ch", videoCount: 5,
                   openedAt: Date(timeIntervalSince1970: 1_700_000_000 + t))
}

@Test func recentPlaylistsNewestFirst() throws {
    let s = try Store.inMemory()
    try s.touchPlaylist(playlist("a", at: 1))
    try s.touchPlaylist(playlist("c", at: 3))
    try s.touchPlaylist(playlist("b", at: 2))
    #expect(try s.recentPlaylists().map(\.id) == ["c", "b", "a"])
    #expect(try s.recentPlaylists().first == playlist("c", at: 3))
}

@Test func touchUpdatesOpenedAt() throws {
    let s = try Store.inMemory()
    try s.touchPlaylist(playlist("a", at: 1))
    try s.touchPlaylist(playlist("b", at: 2))
    try s.touchPlaylist(playlist("a", at: 3))
    #expect(try s.recentPlaylists().map(\.id) == ["a", "b"])
}

@Test func removePlaylist() throws {
    let s = try Store.inMemory()
    try s.touchPlaylist(playlist("a", at: 1))
    try s.touchPlaylist(playlist("b", at: 2))
    try s.removePlaylist(id: "a")
    #expect(try s.recentPlaylists().map(\.id) == ["b"])
}

@Test func progressFractions() throws {
    let s = try Store.inMemory()
    func entry(_ i: Int, position: Double, length: Int?) -> HistoryEntry {
        var e = HistoryEntry.sample(i: i)
        e.positionSeconds = position
        e.lengthSeconds = length
        return e
    }
    try s.upsert([entry(1, position: 30, length: 60), entry(2, position: 0, length: 60),
                  entry(3, position: 10, length: nil), entry(4, position: 90, length: 60)])
    let id = { (i: Int) in HistoryEntry.sample(i: i).videoId }
    #expect(try s.progress() == [id(1): 0.5, id(4): 1])
}

@Test func migratesV2Database() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "v2.sqlite")
    var h: OpaquePointer?
    #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
    let v2 = """
        CREATE TABLE channel(id TEXT PRIMARY KEY, name TEXT NOT NULL, thumbnail TEXT, subscribed_at REAL NOT NULL);
        CREATE TABLE history(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_id TEXT,
            channel_name TEXT NOT NULL, length_seconds INTEGER, published_at REAL,
            watched_at REAL NOT NULL, position REAL NOT NULL);
        CREATE INDEX history_watched ON history(watched_at DESC);
        CREATE TABLE feed_video(video_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, channel_name TEXT NOT NULL,
            title TEXT NOT NULL, published_at REAL NOT NULL, views INTEGER, fetched_at REAL NOT NULL);
        CREATE INDEX feed_published ON feed_video(published_at DESC);
        CREATE TABLE dearrow(video_id TEXT PRIMARY KEY, title TEXT, thumb_time REAL, fetched_at REAL NOT NULL);
        INSERT INTO history VALUES('vid00000001', 'Old', NULL, 'Ch', NULL, NULL, 1700000000, 0);
        PRAGMA user_version = 2;
        """
    #expect(sqlite3_exec(h, v2, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(h)
    let s = try Store(path: url)
    #expect(try s.history().map(\.videoId) == ["vid00000001"])
    #expect(try s.recentPlaylists().isEmpty)
    var h2: OpaquePointer?
    #expect(sqlite3_open(url.path, &h2) == SQLITE_OK)
    var st: OpaquePointer?
    sqlite3_prepare_v2(h2, "PRAGMA user_version", -1, &st, nil)
    #expect(sqlite3_step(st) == SQLITE_ROW)
    #expect(sqlite3_column_int(st, 0) == 13)
    sqlite3_finalize(st)
    sqlite3_close(h2)
}

@Test func migratesV3Database() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "v3.sqlite")
    var h: OpaquePointer?
    #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
    let v3 = """
        CREATE TABLE channel(id TEXT PRIMARY KEY, name TEXT NOT NULL, thumbnail TEXT, subscribed_at REAL NOT NULL);
        CREATE TABLE history(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_id TEXT,
            channel_name TEXT NOT NULL, length_seconds INTEGER, published_at REAL,
            watched_at REAL NOT NULL, position REAL NOT NULL);
        CREATE INDEX history_watched ON history(watched_at DESC);
        CREATE TABLE feed_video(video_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, channel_name TEXT NOT NULL,
            title TEXT NOT NULL, published_at REAL NOT NULL, views INTEGER, fetched_at REAL NOT NULL);
        CREATE INDEX feed_published ON feed_video(published_at DESC);
        CREATE TABLE dearrow(video_id TEXT PRIMARY KEY, title TEXT, thumb_time REAL, fetched_at REAL NOT NULL);
        CREATE TABLE recent_playlist(id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_name TEXT,
            video_count INTEGER, opened_at REAL NOT NULL);
        INSERT INTO history VALUES('vid00000001', 'Old', NULL, 'Ch', NULL, NULL, 1700000000, 0);
        INSERT INTO recent_playlist VALUES('PLaaaaaaaaaaaa', 'P', NULL, 3, 1700000000);
        PRAGMA user_version = 3;
        """
    #expect(sqlite3_exec(h, v3, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(h)
    let s = try Store(path: url)
    #expect(try s.history().map(\.videoId) == ["vid00000001"])
    #expect(try s.recentPlaylists().map(\.id) == ["PLaaaaaaaaaaaa"])
    #expect(try s.segments(videoId: "vid00000001") == nil)
    let segments = [SponsorSegment(category: "sponsor", start: 1, end: 2, uuid: "u")]
    try s.saveSegments(segments, videoId: "vid00000001", fetchedAt: .now)
    #expect(try s.segments(videoId: "vid00000001") == segments)
    var h2: OpaquePointer?
    #expect(sqlite3_open(url.path, &h2) == SQLITE_OK)
    var st: OpaquePointer?
    sqlite3_prepare_v2(h2, "PRAGMA user_version", -1, &st, nil)
    #expect(sqlite3_step(st) == SQLITE_ROW)
    #expect(sqlite3_column_int(st, 0) == 13)
    sqlite3_finalize(st)
    // replaceFeed's delete-by-channel uses the v6 index instead of scanning every channel's rows.
    var plan: OpaquePointer?
    sqlite3_prepare_v2(h2, "EXPLAIN QUERY PLAN DELETE FROM feed_video WHERE channel_id = 'x'", -1, &plan, nil)
    #expect(sqlite3_step(plan) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(plan, 3)).contains("feed_channel"))
    sqlite3_finalize(plan)
    sqlite3_close(h2)
}
