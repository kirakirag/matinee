import Foundation

/// The videos a watch page suggests next, cached: Up next and For you read the same lists, and a list changes
/// slowly, so a video watched in the app costs For you nothing.
public struct RelatedService: Sendable {
    public typealias Fetch = @Sendable (String) async throws -> [ListedEntry]

    let store: Store
    let fetch: Fetch
    let ttl: TimeInterval
    let now: @Sendable () -> Date

    /// 14 days: each new watch fetches its own list, and an older watch's suggestions change slowly.
    public init(store: Store, fetch: @escaping Fetch, ttl: TimeInterval = 14 * 86400,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.fetch = fetch
        self.ttl = ttl
        self.now = now
    }

    /// Fresh from the cache, else fetched and cached. A failed fetch falls back to an expired list when there is one.
    public func related(_ videoId: String) async throws -> [ListedEntry] {
        let cached = try? store.related(videoId: videoId)
        let current = now()
        if let cached, current.timeIntervalSince(cached.fetchedAt) < ttl { return cached.entries }
        do {
            let entries = try await fetch(videoId)
            try? store.saveRelated(entries, videoId: videoId, at: current)
            return entries
        } catch {
            if let cached, !(error is CancellationError) { return cached.entries }
            throw error
        }
    }
}
