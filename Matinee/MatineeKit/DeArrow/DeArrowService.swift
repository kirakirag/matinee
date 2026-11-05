import Foundation

/// Looks up DeArrow branding, one request per hash prefix, cached in the store.
public actor DeArrowService {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private struct BadStatus: Error {}

    private static let maxConcurrent = 8

    private let store: Store
    private let fetch: Fetch
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    public init(store: Store, fetch: @escaping Fetch = DeArrowService.urlSession, ttl: TimeInterval = 86_400,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.fetch = fetch
        self.ttl = ttl
        self.now = now
    }

    public static let urlSession: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await PrivateHTTP.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BadStatus() }
        return data
    }

    /// Cached branding first, then one request per prefix for the rest. Never throws.
    public func branding(for videoIds: [String]) async -> [String: Branding] {
        let ids = Set(videoIds.filter(VideoID.isValid))
        let cached = (try? store.branding(videoIds: Array(ids))) ?? [:]
        let current = now()
        var result: [String: Branding] = [:]
        var stale: [String: [String]] = [:]
        for id in ids {
            if let c = cached[id] {
                if c.title != nil || c.thumbnailTime != nil { result[id] = Branding(title: c.title, thumbnailTime: c.thumbnailTime) }
                // Expired rows stay in the result as a fallback if the refetch fails.
                if c.fetchedAt.addingTimeInterval(ttl) > current { continue }
            }
            stale[DeArrow.hashPrefix(id), default: []].append(id)
        }
        let fetch = self.fetch
        await withTaskGroup(of: (String, Data?).self) { tasks in
            var pending = stale.keys.makeIterator()
            func addNext() -> Bool {
                // A cancelled caller (e.g. superseded by a newer reload) starts no more requests.
                guard !Task.isCancelled, let prefix = pending.next() else { return false }
                tasks.addTask { (prefix, try? await fetch(DeArrow.brandingURL(prefix: prefix))) }
                return true
            }
            var inFlight = 0
            while inFlight < Self.maxConcurrent, addNext() { inFlight += 1 }
            for await (prefix, data) in tasks {
                _ = addNext()
                guard let data, let parsed = try? DeArrow.parse(data) else { continue }
                var rows: [String: CachedBranding] = [:]
                for id in stale[prefix] ?? [] {
                    let b = parsed[id]
                    rows[id] = CachedBranding(title: b?.title, thumbnailTime: b?.thumbnailTime, fetchedAt: current)
                    result[id] = b
                }
                try? store.saveBranding(rows)
            }
        }
        return result
    }
}
