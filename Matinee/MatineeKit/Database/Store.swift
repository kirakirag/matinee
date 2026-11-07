import Foundation
import Synchronization

/// The app's database: subscriptions and watch history. One connection, serialised by a mutex.
public final class Store: Sendable {
    private let db: Mutex<SQLite>

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conn = try SQLite(path: path.path)
        try Store.migrate(conn)
        db = Mutex(conn)
    }

    private init(memory: Void) throws {
        let conn = try SQLite(path: ":memory:")
        try Store.migrate(conn)
        db = Mutex(conn)
    }

    public static func inMemory() throws -> Store { try Store(memory: ()) }

    /// `<Application Support>/Matinee/matinee.sqlite` (inside the sandbox container when sandboxed).
    public static func defaultURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "Matinee/matinee.sqlite")
    }

    private static func migrate(_ db: SQLite) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        // With WAL this can't corrupt the file; a power loss may only drop the last commits (a history position, a
        // cache row). FULL syncs on every commit: once per channel on a feed refresh, per DeArrow prefix, and on the
        // main thread for each history save during playback.
        try db.execute("PRAGMA synchronous = NORMAL")
        let version = try db.query("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0
        if version < 1 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE channel(id TEXT PRIMARY KEY, name TEXT NOT NULL, thumbnail TEXT, subscribed_at REAL NOT NULL)
                    """)
                try db.execute("""
                    CREATE TABLE history(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_id TEXT,
                        channel_name TEXT NOT NULL, length_seconds INTEGER, published_at REAL,
                        watched_at REAL NOT NULL, position REAL NOT NULL)
                    """)
                try db.execute("CREATE INDEX history_watched ON history(watched_at DESC)")
                try db.execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE feed_video(video_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, channel_name TEXT NOT NULL,
                        title TEXT NOT NULL, published_at REAL NOT NULL, views INTEGER, fetched_at REAL NOT NULL)
                    """)
                try db.execute("CREATE INDEX feed_published ON feed_video(published_at DESC)")
                try db.execute("""
                    CREATE TABLE dearrow(video_id TEXT PRIMARY KEY, title TEXT, thumb_time REAL, fetched_at REAL NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE recent_playlist(id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_name TEXT,
                        video_count INTEGER, opened_at REAL NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try db.transaction {
                try db.execute("CREATE TABLE sponsor_segments(video_id TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at REAL NOT NULL)")
                try db.execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE download(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_name TEXT NOT NULL,
                        channel_id TEXT, length_seconds INTEGER, state TEXT NOT NULL, error TEXT, bytes INTEGER,
                        added_at REAL NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 5")
            }
        }
        if version < 6 {
            try db.transaction {
                // replaceFeed deletes by channel once per channel per refresh; without this each delete scans the table.
                try db.execute("CREATE INDEX IF NOT EXISTS feed_channel ON feed_video(channel_id)")
                try db.execute("PRAGMA user_version = 6")
            }
        }
        if version < 7 {
            try db.transaction {
                // max_height 0 is "best". Rows are dropped once expired (on save) or after a 403 (deleteResolved).
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS resolved_stream(video_id TEXT NOT NULL, max_height INTEGER NOT NULL, json TEXT NOT NULL,
                        expire REAL NOT NULL, PRIMARY KEY(video_id, max_height))
                    """)
                try db.execute("PRAGMA user_version = 7")
            }
        }
        if version < 8 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS feed_validator(channel_id TEXT PRIMARY KEY, etag TEXT, last_modified TEXT)
                    """)
                try db.execute("PRAGMA user_version = 8")
            }
        }
        if version < 9 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS related(video_id TEXT PRIMARY KEY, fetched_at REAL NOT NULL,
                                                       entries TEXT NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 9")
            }
        }
        if version < 10 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS dismissal(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_id TEXT,
                                                         hides_channel INTEGER NOT NULL, at REAL NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 10")
            }
        }
        if version < 11 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS title_vector(video_id TEXT PRIMARY KEY, script TEXT NOT NULL,
                                                            vector BLOB NOT NULL, at REAL NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 11")
            }
        }
        if version < 12 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS video_text(video_id TEXT PRIMARY KEY, description TEXT NOT NULL,
                                                          fetched_at REAL NOT NULL)
                    """)
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS e5_vector(video_id TEXT PRIMARY KEY, described INTEGER NOT NULL,
                                                         vector BLOB NOT NULL, at REAL NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 12")
            }
        }
        if version < 13 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS imported_watch(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, channel_id TEXT,
                                                              channel_name TEXT NOT NULL, watched_at REAL NOT NULL)
                    """)
                try db.execute("PRAGMA user_version = 13")
            }
        }
    }

    // MARK: Subscriptions

    public func subscriptions() throws -> [Channel] {
        try db.withLock { db in
            try db.query("SELECT id, name, thumbnail, subscribed_at FROM channel ORDER BY name COLLATE NOCASE, id") { r in
                Channel(id: r.text(0)!, name: r.text(1)!, thumbnailURL: r.text(2).flatMap(URL.init(string:)),
                        subscribedAt: Date(timeIntervalSince1970: r.real(3)!))
            }
        }
    }

    public func upsert(_ channels: [Channel]) throws {
        try db.withLock { db in
            try db.transaction {
                for c in channels {
                    try db.execute("""
                        INSERT INTO channel(id, name, thumbnail, subscribed_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, thumbnail = excluded.thumbnail,
                            subscribed_at = excluded.subscribed_at
                        """, [.text(c.id), .text(c.name), c.thumbnailURL.map { .text($0.absoluteString) } ?? .null,
                              .real(c.subscribedAt.timeIntervalSince1970)])
                }
            }
        }
    }

    /// Subscribes to the channels not already subscribed, leaving existing ones as they are; returns how many were new.
    public func addSubscriptions(_ channels: [Channel]) throws -> Int {
        try db.withLock { db in
            let sql = "SELECT COUNT(*) FROM channel"
            let before = try db.query(sql) { $0.int(0) ?? 0 }.first ?? 0
            try db.transaction {
                for c in channels {
                    try db.execute("""
                        INSERT INTO channel(id, name, thumbnail, subscribed_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO NOTHING
                        """, [.text(c.id), .text(c.name), c.thumbnailURL.map { .text($0.absoluteString) } ?? .null,
                              .real(c.subscribedAt.timeIntervalSince1970)])
                }
            }
            return (try db.query(sql) { $0.int(0) ?? 0 }.first ?? 0) - before
        }
    }

    public func unsubscribe(channelId: String) throws {
        try db.withLock { db in try db.execute("DELETE FROM channel WHERE id = ?", [.text(channelId)]) }
    }

    // MARK: History

    public func history() throws -> [HistoryEntry] {
        try db.withLock { db in
            try db.query("""
                SELECT video_id, title, channel_id, channel_name, length_seconds, published_at, watched_at, position
                FROM history ORDER BY watched_at DESC
                """) { r in
                HistoryEntry(videoId: r.text(0)!, title: r.text(1)!, channelId: r.text(2), channelName: r.text(3)!,
                             lengthSeconds: r.int(4), publishedAt: r.real(5).map(Date.init(timeIntervalSince1970:)),
                             watchedAt: Date(timeIntervalSince1970: r.real(6)!), positionSeconds: r.real(7)!)
            }
        }
    }

    public func upsert(_ history: [HistoryEntry]) throws {
        try db.withLock { db in
            try db.transaction {
                for h in history {
                    try db.execute("""
                        INSERT INTO history(video_id, title, channel_id, channel_name, length_seconds, published_at,
                            watched_at, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(video_id) DO UPDATE SET title = excluded.title, channel_id = excluded.channel_id,
                            channel_name = excluded.channel_name, length_seconds = COALESCE(excluded.length_seconds, length_seconds),
                            published_at = excluded.published_at, watched_at = excluded.watched_at,
                            position = excluded.position
                        """, [.text(h.videoId), .text(h.title), h.channelId.map { .text($0) } ?? .null, .text(h.channelName),
                              h.lengthSeconds.map { .int($0) } ?? .null,
                              h.publishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                              .real(h.watchedAt.timeIntervalSince1970), .real(h.positionSeconds)])
                }
            }
        }
    }

    /// Upserting the entry again undoes it.
    public func deleteHistory(videoId: String) throws {
        try db.withLock { db in try db.execute("DELETE FROM history WHERE video_id = ?", [.text(videoId)]) }
    }

    public func historyEntry(videoId: String) throws -> HistoryEntry? {
        try db.withLock { db in
            try db.query("""
                SELECT video_id, title, channel_id, channel_name, length_seconds, published_at, watched_at, position
                FROM history WHERE video_id = ?
                """, [.text(videoId)]) { r in
                HistoryEntry(videoId: r.text(0)!, title: r.text(1)!, channelId: r.text(2), channelName: r.text(3)!,
                             lengthSeconds: r.int(4), publishedAt: r.real(5).map(Date.init(timeIntervalSince1970:)),
                             watchedAt: Date(timeIntervalSince1970: r.real(6)!), positionSeconds: r.real(7)!)
            }.first
        }
    }

    /// Watched fraction (0...1) per video, for history rows with a position and a known length.
    public func progress() throws -> [String: Double] {
        try db.withLock { db in
            let rows = try db.query("""
                SELECT video_id, MIN(position / length_seconds, 1.0) FROM history
                WHERE position > 0 AND length_seconds > 0
                """) { r in (r.text(0)!, r.real(1)!) }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    // MARK: Recent playlists

    public func recentPlaylists() throws -> [RecentPlaylist] {
        try db.withLock { db in
            try db.query("""
                SELECT id, title, channel_name, video_count, opened_at FROM recent_playlist ORDER BY opened_at DESC, id
                """) { r in
                RecentPlaylist(id: r.text(0)!, title: r.text(1)!, channelName: r.text(2), videoCount: r.int(3),
                               openedAt: Date(timeIntervalSince1970: r.real(4)!))
            }
        }
    }

    public func touchPlaylist(_ p: RecentPlaylist) throws {
        try db.withLock { db in
            try db.execute("""
                INSERT INTO recent_playlist(id, title, channel_name, video_count, opened_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, channel_name = excluded.channel_name,
                    video_count = excluded.video_count, opened_at = excluded.opened_at
                """, [.text(p.id), .text(p.title), p.channelName.map { .text($0) } ?? .null,
                      p.videoCount.map { .int($0) } ?? .null, .real(p.openedAt.timeIntervalSince1970)])
        }
    }

    public func removePlaylist(id: String) throws {
        try db.withLock { db in try db.execute("DELETE FROM recent_playlist WHERE id = ?", [.text(id)]) }
    }

    // MARK: Feed cache

    /// Replaces one channel's cached videos in a single transaction.
    public func replaceFeed(channelId: String, videos: [FeedVideo], fetchedAt: Date) throws {
        try db.withLock { db in
            try db.transaction {
                try db.execute("DELETE FROM feed_video WHERE channel_id = ?", [.text(channelId)])
                for v in videos {
                    try db.execute("""
                        INSERT OR REPLACE INTO feed_video(video_id, channel_id, channel_name, title, published_at, views, fetched_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, [.text(v.videoId), .text(v.channelId), .text(v.channelName), .text(v.title),
                              .real(v.publishedAt.timeIntervalSince1970), v.views.map { .int($0) } ?? .null,
                              .real(fetchedAt.timeIntervalSince1970)])
                }
            }
        }
    }

    /// Cached videos of subscribed channels, newest first. Unsubscribing hides a channel's videos without deleting them.
    public func feed(limit: Int = 1000) throws -> [FeedVideo] {
        try db.withLock { db in
            try db.query("""
                SELECT f.video_id, f.channel_id, c.name, f.title, f.published_at, f.views
                FROM feed_video f JOIN channel c ON c.id = f.channel_id
                ORDER BY f.published_at DESC, f.video_id LIMIT ?
                """, [.int(limit)]) { r in
                FeedVideo(videoId: r.text(0)!, channelId: r.text(1)!, channelName: r.text(2)!, title: r.text(3)!,
                          publishedAt: Date(timeIntervalSince1970: r.real(4)!), views: r.int(5))
            }
        }
    }

    // MARK: DeArrow cache

    public func branding(videoIds: [String]) throws -> [String: CachedBranding] {
        // One statement for the whole batch (ids as a JSON array), not one query per id under the lock.
        let ids = String(decoding: try JSONEncoder().encode(videoIds), as: UTF8.self)
        return try db.withLock { db in
            let rows = try db.query("""
                SELECT video_id, title, thumb_time, fetched_at FROM dearrow
                WHERE video_id IN (SELECT value FROM json_each(?))
                """, [.text(ids)]) { r in
                (r.text(0)!, CachedBranding(title: r.text(1), thumbnailTime: r.real(2),
                                            fetchedAt: Date(timeIntervalSince1970: r.real(3)!)))
            }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    public func saveBranding(_ b: [String: CachedBranding]) throws {
        try db.withLock { db in
            try db.transaction {
                for (id, v) in b {
                    try db.execute("""
                        INSERT OR REPLACE INTO dearrow(video_id, title, thumb_time, fetched_at) VALUES (?, ?, ?, ?)
                        """, [.text(id), v.title.map { .text($0) } ?? .null, v.thumbnailTime.map { .real($0) } ?? .null,
                              .real(v.fetchedAt.timeIntervalSince1970)])
                }
            }
        }
    }

    // MARK: SponsorBlock

    /// The stored segments, or nil when the video was never looked up.
    public func segments(videoId: String) throws -> [SponsorSegment]? {
        let json = try db.withLock { db in
            try db.query("SELECT json FROM sponsor_segments WHERE video_id = ?", [.text(videoId)]) { $0.text(0) }.first
        }
        guard let json = json ?? nil else { return nil }
        return try JSONDecoder().decode([SponsorSegment].self, from: Data(json.utf8))
    }

    public func saveSegments(_ s: [SponsorSegment], videoId: String, fetchedAt: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        try db.withLock { db in
            try db.execute("INSERT OR REPLACE INTO sponsor_segments(video_id, json, fetched_at) VALUES (?, ?, ?)",
                           [.text(videoId), .text(json), .real(fetchedAt.timeIntervalSince1970)])
        }
    }

    // MARK: Downloads

    private static let downloadColumns = "video_id, title, channel_name, channel_id, length_seconds, state, error, bytes, added_at"

    private static func downloadRow(_ r: SQLite.Row) -> Download {
        let state: Download.State = switch r.text(5) {
        case "done": .done
        case "downloading": .downloading
        case "failed": .failed(r.text(6) ?? "")
        default: .queued
        }
        return Download(videoId: r.text(0)!, title: r.text(1)!, channelName: r.text(2)!, channelId: r.text(3),
                        lengthSeconds: r.int(4), state: state, bytes: r.int(7),
                        addedAt: Date(timeIntervalSince1970: r.real(8)!))
    }

    /// Newest first.
    public func downloads() throws -> [Download] {
        try db.withLock { db in
            try db.query("SELECT \(Self.downloadColumns) FROM download ORDER BY added_at DESC, video_id", row: Self.downloadRow)
        }
    }

    public func download(videoId: String) throws -> Download? {
        try db.withLock { db in
            try db.query("SELECT \(Self.downloadColumns) FROM download WHERE video_id = ?", [.text(videoId)], row: Self.downloadRow).first
        }
    }

    public func upsertDownload(_ d: Download) throws {
        let (state, error): (String, String?) = switch d.state {
        case .queued: ("queued", nil)
        case .downloading: ("downloading", nil)
        case .done: ("done", nil)
        case .failed(let message): ("failed", message)
        }
        try db.withLock { db in
            try db.execute("INSERT OR REPLACE INTO download(\(Self.downloadColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                .text(d.videoId), .text(d.title), .text(d.channelName), d.channelId.map { .text($0) } ?? .null,
                d.lengthSeconds.map { .int($0) } ?? .null, .text(state), error.map { .text($0) } ?? .null,
                d.bytes.map { .int($0) } ?? .null, .real(d.addedAt.timeIntervalSince1970)])
        }
    }

    public func removeDownload(videoId: String) throws {
        try db.withLock { db in try db.execute("DELETE FROM download WHERE video_id = ?", [.text(videoId)]) }
    }

    // MARK: Resolved streams (kept across launches until they expire)

    public func resolved(videoId: String, maxHeight: Int?) throws -> Resolved? {
        let json = try db.withLock { db in
            try db.query("SELECT json FROM resolved_stream WHERE video_id = ? AND max_height = ?",
                         [.text(videoId), .int(maxHeight ?? 0)]) { $0.text(0) }.first
        }
        guard let json = json ?? nil else { return nil }
        return try? JSONDecoder().decode(Resolved.self, from: Data(json.utf8))   // an unreadable row is a miss
    }

    public func saveResolved(_ r: Resolved, videoId: String, maxHeight: Int?, now: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        try db.withLock { db in
            try db.transaction {
                try db.execute("DELETE FROM resolved_stream WHERE expire < ?", [.real(now.timeIntervalSince1970)])
                try db.execute("INSERT OR REPLACE INTO resolved_stream(video_id, max_height, json, expire) VALUES (?, ?, ?, ?)",
                               [.text(videoId), .int(maxHeight ?? 0), .text(json), .real(r.expire.timeIntervalSince1970)])
            }
        }
    }

    public func deleteResolved(videoId: String) throws {
        try db.withLock { db in try db.execute("DELETE FROM resolved_stream WHERE video_id = ?", [.text(videoId)]) }
    }

    // MARK: Feed validators

    public func feedValidators(channelId: String) throws -> FeedService.Validators? {
        try db.withLock { db in
            try db.query("SELECT etag, last_modified FROM feed_validator WHERE channel_id = ?", [.text(channelId)]) {
                FeedService.Validators(etag: $0.text(0), lastModified: $0.text(1))
            }.first
        }
    }

    /// nil forgets them (the server sent none), so a stale validator is never sent.
    public func saveFeedValidators(_ v: FeedService.Validators?, channelId: String) throws {
        try db.withLock { db in
            if let v {
                try db.execute("INSERT OR REPLACE INTO feed_validator(channel_id, etag, last_modified) VALUES (?, ?, ?)",
                               [.text(channelId), v.etag.map { .text($0) } ?? .null, v.lastModified.map { .text($0) } ?? .null])
            } else {
                try db.execute("DELETE FROM feed_validator WHERE channel_id = ?", [.text(channelId)])
            }
        }
    }

    // MARK: Related videos

    /// The videos a watch page suggested next, as cached, and when they were fetched.
    public func related(videoId: String) throws -> (entries: [ListedEntry], fetchedAt: Date)? {
        let row = try db.withLock { db in
            try db.query("SELECT entries, fetched_at FROM related WHERE video_id = ?", [.text(videoId)]) {
                ($0.text(0), $0.real(1))
            }.first
        }
        guard let row, let json = row.0, let at = row.1,
              let entries = try? JSONDecoder().decode([ListedEntry].self, from: Data(json.utf8)) else { return nil }
        return (entries, Date(timeIntervalSince1970: at))
    }

    /// Lists older than 90 days go at the same time: nothing reads them any more.
    public func saveRelated(_ entries: [ListedEntry], videoId: String, at date: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        try db.withLock { db in
            try db.transaction {
                try db.execute("INSERT OR REPLACE INTO related(video_id, fetched_at, entries) VALUES (?, ?, ?)",
                               [.text(videoId), .real(date.timeIntervalSince1970), .text(json)])
                try db.execute("DELETE FROM related WHERE fetched_at < ?", [.real(date.timeIntervalSince1970 - 90 * 86400)])
            }
        }
    }

    // MARK: Title vectors (TitleSimilarity's, so a launch doesn't embed the same titles again)

    public func titleVectors(ids: [String]) throws -> [String: (script: String, vector: [Float])] {
        var out: [String: (script: String, vector: [Float])] = [:]
        try db.withLock { db in
            for id in ids {
                for row in try db.query("SELECT script, vector FROM title_vector WHERE video_id = ?", [.text(id)], row: { r in
                    (r.text(0), r.blob(1))
                }) {
                    guard let script = row.0, let data = row.1 else { continue }
                    out[id] = (script, data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
                }
            }
        }
        return out
    }

    /// Vectors not saved again for 90 days go at the same time.
    public func saveTitleVectors(_ vectors: [(id: String, script: String, vector: [Float])], at date: Date) throws {
        try db.withLock { db in
            try db.transaction {
                for v in vectors {
                    let data = v.vector.withUnsafeBufferPointer { Data(buffer: $0) }
                    try db.execute("INSERT OR REPLACE INTO title_vector(video_id, script, vector, at) VALUES (?, ?, ?, ?)",
                                   [.text(v.id), .text(v.script), .blob(data), .real(date.timeIntervalSince1970)])
                }
                try db.execute("DELETE FROM title_vector WHERE at < ?", [.real(date.timeIntervalSince1970 - 90 * 86400)])
            }
        }
    }

    // MARK: Descriptions and e5 vectors (local AI ranking)

    /// Cleaned descriptions by video; "" means fetched and empty.
    public func descriptions(ids: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        try db.withLock { db in
            for id in ids {
                for text in try db.query("SELECT description FROM video_text WHERE video_id = ?", [.text(id)], row: { $0.text(0) }) {
                    out[id] = text
                }
            }
        }
        return out
    }

    /// Descriptions not fetched again for 90 days go at the same time.
    public func saveDescriptions(_ d: [String: String], at date: Date) throws {
        try db.withLock { db in
            try db.transaction {
                for (id, text) in d {
                    try db.execute("INSERT OR REPLACE INTO video_text(video_id, description, fetched_at) VALUES (?, ?, ?)",
                                   [.text(id), .text(text), .real(date.timeIntervalSince1970)])
                }
                try db.execute("DELETE FROM video_text WHERE fetched_at < ?", [.real(date.timeIntervalSince1970 - 90 * 86400)])
            }
        }
    }

    /// `described`: the vector was made with the description known (possibly empty), not from the title alone.
    public func e5Vectors(ids: [String]) throws -> [String: (described: Bool, vector: [Float])] {
        var out: [String: (described: Bool, vector: [Float])] = [:]
        try db.withLock { db in
            for id in ids {
                for row in try db.query("SELECT described, vector FROM e5_vector WHERE video_id = ?", [.text(id)], row: { r in
                    (r.int(0), r.blob(1))
                }) {
                    guard let described = row.0, let data = row.1 else { continue }
                    out[id] = (described != 0, data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
                }
            }
        }
        return out
    }

    /// Vectors not saved again for 90 days go at the same time.
    public func saveE5Vectors(_ vectors: [(id: String, described: Bool, vector: [Float])], at date: Date) throws {
        try db.withLock { db in
            try db.transaction {
                for v in vectors {
                    let data = v.vector.withUnsafeBufferPointer { Data(buffer: $0) }
                    try db.execute("INSERT OR REPLACE INTO e5_vector(video_id, described, vector, at) VALUES (?, ?, ?, ?)",
                                   [.text(v.id), .int(v.described ? 1 : 0), .blob(data), .real(date.timeIntervalSince1970)])
                }
                try db.execute("DELETE FROM e5_vector WHERE at < ?", [.real(date.timeIntervalSince1970 - 90 * 86400)])
            }
        }
    }

    /// Changes whenever For You's inputs do: a watch (new or again), an import, a dismissal or its undo. Equal stamps
    /// mean For You's ranking would come out the same, so it needn't run again.
    public func profileStamp() throws -> [Double] {
        try db.withLock { db in
            try db.query("""
                SELECT (SELECT COUNT(*) FROM history), (SELECT COALESCE(MAX(watched_at), 0) FROM history),
                       (SELECT COUNT(*) FROM imported_watch), (SELECT COALESCE(MAX(watched_at), 0) FROM imported_watch),
                       (SELECT COUNT(*) FROM dismissal), (SELECT COALESCE(MAX(at), 0) FROM dismissal)
                """) { r in (0..<6).map { r.real($0) ?? Double(r.int($0) ?? 0) } }.first ?? []
        }
    }

    // MARK: Imported watches (Google Takeout): For You's profile, not History

    /// Adds the watches, keeping each video's latest time; returns how many videos are new.
    @discardableResult
    public func saveImportedWatches(_ watches: [HistoryEntry]) throws -> Int {
        try db.withLock { db in
            let sql = "SELECT COUNT(*) FROM imported_watch"
            let before = try db.query(sql) { $0.int(0) ?? 0 }.first ?? 0
            try db.transaction {
                for w in watches {
                    try db.execute("""
                        INSERT INTO imported_watch(video_id, title, channel_id, channel_name, watched_at) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(video_id) DO UPDATE SET watched_at = max(watched_at, excluded.watched_at)
                        """, [.text(w.videoId), .text(w.title), w.channelId.map(SQLValue.text) ?? .null,
                              .text(w.channelName), .real(w.watchedAt.timeIntervalSince1970)])
                }
            }
            return (try db.query(sql) { $0.int(0) ?? 0 }.first ?? 0) - before
        }
    }

    /// Newest first.
    public func importedWatches(limit: Int) throws -> [HistoryEntry] {
        try db.withLock { db in
            try db.query("""
                SELECT video_id, title, channel_id, channel_name, watched_at FROM imported_watch
                ORDER BY watched_at DESC LIMIT ?
                """, [.int(limit)]) { r in
                HistoryEntry(videoId: r.text(0)!, title: r.text(1)!, channelId: r.text(2), channelName: r.text(3)!,
                             lengthSeconds: nil, publishedAt: nil, watchedAt: Date(timeIntervalSince1970: r.real(4)!),
                             positionSeconds: 0)
            }
        }
    }

    // MARK: Dismissals ("Not interested")

    public func dismiss(_ d: Dismissal) throws {
        try db.withLock { db in
            try db.execute("INSERT OR REPLACE INTO dismissal(video_id, title, channel_id, hides_channel, at) VALUES (?, ?, ?, ?, ?)",
                           [.text(d.videoId), .text(d.title), d.channelId.map { .text($0) } ?? .null,
                            .int(d.hidesChannel ? 1 : 0), .real(d.at.timeIntervalSince1970)])
        }
    }

    /// Newest first.
    public func dismissals() throws -> [Dismissal] {
        try db.withLock { db in
            try db.query("SELECT video_id, title, channel_id, hides_channel, at FROM dismissal ORDER BY at DESC") { r in
                Dismissal(videoId: r.text(0)!, title: r.text(1)!, channelId: r.text(2), hidesChannel: r.int(3) == 1,
                          at: Date(timeIntervalSince1970: r.real(4)!))
            }
        }
    }

    public func undoDismissal(videoId: String) throws {
        try db.withLock { db in try db.execute("DELETE FROM dismissal WHERE video_id = ?", [.text(videoId)]) }
    }

    public func counts() throws -> (channels: Int, history: Int) {
        try db.withLock { db in
            let c = try db.query("SELECT count(*) FROM channel") { $0.int(0) ?? 0 }.first ?? 0
            let h = try db.query("SELECT count(*) FROM history") { $0.int(0) ?? 0 }.first ?? 0
            return (c, h)
        }
    }
}
