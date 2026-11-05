import Foundation

public struct FeedRefreshResult: Sendable, Equatable {
    public var updated: Int
    /// Channel ids that could not be refreshed, sorted.
    public var failed: [String]

    public init(updated: Int, failed: [String]) {
        self.updated = updated
        self.failed = failed
    }
}

/// Refreshes the cached feed from each channel's public RSS feed.
public struct FeedService: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// HTTP cache validators from a feed's last response, sent back so an unchanged feed answers 304.
    public struct Validators: Sendable, Equatable {
        public var etag: String?
        public var lastModified: String?
        public init(etag: String?, lastModified: String?) {
            self.etag = etag
            self.lastModified = lastModified
        }
    }

    public enum FetchResult: Sendable {
        case fresh(Data, Validators?)
        case unchanged
    }

    /// Fetches with the validators stored for the channel, if any.
    public typealias ConditionalFetch = @Sendable (URL, Validators?) async throws -> FetchResult

    private struct BadStatus: Error {}

    let store: Store
    let fetch: ConditionalFetch
    let maxConcurrent: Int
    let now: @Sendable () -> Date

    /// Plain fetches (tests, the offline bench): no validators.
    public init(store: Store, fetch: @escaping Fetch, maxConcurrent: Int = 8, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(store: store, conditionalFetch: { url, _ in .fresh(try await fetch(url), nil) },
                  maxConcurrent: maxConcurrent, now: now)
    }

    public init(store: Store, conditionalFetch: @escaping ConditionalFetch = FeedService.conditionalSession,
                maxConcurrent: Int = 8, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.fetch = conditionalFetch
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
    }

    /// A refresh of many channels mostly finds nothing new; when the server supports validators, those feeds answer
    /// 304 with no body to download, parse or store.
    public static let conditionalSession: ConditionalFetch = { url, validators in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData   // the 304 must reach here, not be answered by a cache
        if let etag = validators?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = validators?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await PrivateHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BadStatus() }
        if http.statusCode == 304 { return .unchanged }
        guard http.statusCode == 200 else { throw BadStatus() }
        let etag = http.value(forHTTPHeaderField: "ETag"), modified = http.value(forHTTPHeaderField: "Last-Modified")
        return .fresh(data, etag == nil && modified == nil ? nil : Validators(etag: etag, lastModified: modified))
    }

    /// A plain fetch (the channel page): without validators the server can't answer 304.
    public static let urlSession: Fetch = { url in
        guard case .fresh(let data, _) = try await conditionalSession(url, nil) else { throw BadStatus() }
        return data
    }

    public static func feedURL(channelId: String) -> URL? {
        guard ChannelID.isValid(channelId) else { return nil }
        return URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)")
    }

    public func refresh(channels: [Channel]) async -> FeedRefreshResult {
        var updated = 0
        var failed: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var pending = channels.makeIterator()
            var inFlight = 0
            func addNext() -> Bool {
                guard let channel = pending.next() else { return false }
                group.addTask { (channel.id, await refreshOne(channel.id)) }
                return true
            }
            while inFlight < maxConcurrent, addNext() { inFlight += 1 }
            for await (id, ok) in group {
                if ok { updated += 1 } else { failed.append(id) }
                _ = addNext()
            }
        }
        return FeedRefreshResult(updated: updated, failed: failed.sorted())
    }

    private func refreshOne(_ id: String) async -> Bool {
        guard let url = Self.feedURL(channelId: id) else { return false }
        do {
            switch try await fetch(url, try? store.feedValidators(channelId: id)) {
            case .unchanged:
                return true
            case .fresh(let data, let validators):
                let videos = try RSSParser.parse(data)
                try store.replaceFeed(channelId: id, videos: videos, fetchedAt: now())
                try? store.saveFeedValidators(validators, channelId: id)
                return true
            }
        } catch {
            return false
        }
    }
}
