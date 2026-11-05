import Foundation

/// Resolves playable streams with a visionos-first policy, a per-ID-and-quality cache and a bounded prefetch queue.
/// At most one prefetch runs and one more waits (the newest), so with two worker slots an open never waits behind one.
public actor PlaybackResolver {
    /// (video ID, player clients, max height); nil height means the highest available.
    public typealias Resolve = @Sendable (String, [String]?, Int?) async throws -> Resolved

    /// A video at a quality cap: cached and shared separately per cap.
    private struct Key: Hashable { var id: String; var maxHeight: Int? }

    private let resolveStreams: Resolve
    private let now: @Sendable () -> Date
    private var cache: [Key: Resolved] = [:]
    private var inFlight: [Key: Task<Resolved, any Error>] = [:]
    private var prefetching: Key?
    private var queued: Key?
    /// Called with each prefetch's result (not an open's), e.g. to fetch the stream's first bytes ahead too.
    private let onPrefetched: (@Sendable (Resolved) async -> Void)?
    /// Keeps results across launches, so resuming a video after a relaunch doesn't wait for yt-dlp.
    private let store: Store?
    /// The last visionos resolve was below what's wanted (or failed).
    private var visionosFellShort = false

    public init(resolve: @escaping Resolve, now: @escaping @Sendable () -> Date = Date.init,
                onPrefetched: (@Sendable (Resolved) async -> Void)? = nil, store: Store? = nil) {
        self.resolveStreams = resolve
        self.now = now
        self.onPrefetched = onPrefetched
        self.store = store
    }

    /// Forgets a video's results, e.g. after its streams answered 403: the URLs carry the IP they were resolved from,
    /// so they break when the network changes.
    public func invalidate(_ id: String) {
        for key in cache.keys where key.id == id { cache[key] = nil }
        try? store?.deleteResolved(videoId: id)
    }

    public func resolve(_ id: String, maxHeight: Int? = nil) async throws -> Resolved {
        let key = Key(id: id, maxHeight: maxHeight)
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return try await task.value }
        if queued == key { queued = nil }
        return try await start(key).value
    }

    public func prefetch(_ id: String, maxHeight: Int? = nil) {
        let key = Key(id: id, maxHeight: maxHeight)
        if cached(key) != nil || inFlight[key] != nil || queued == key { return }
        if prefetching == nil {
            prefetching = key
            start(key, race: false)
        } else {
            queued = key
        }
    }

    private func cached(_ key: Key) -> Resolved? {
        if let hit = cache[key], usable(hit) { return hit }
        guard let stored = try? store?.resolved(videoId: key.id, maxHeight: key.maxHeight), usable(stored) else { return nil }
        cache[key] = stored
        return stored
    }

    /// Not within 30 minutes of expiring.
    private func usable(_ r: Resolved) -> Bool { now() < r.expire.addingTimeInterval(-1800) }

    @discardableResult
    /// `race`: whether this resolve may start the fallback early (opens may; prefetches use one worker slot).
    private func start(_ key: Key, race: Bool = true) -> Task<Resolved, any Error> {
        let task = Task { try await self.run(key, race: race) }
        inFlight[key] = task
        return task
    }

    private func run(_ key: Key, race: Bool) async throws -> Resolved {
        do {
            let result = try await fetch(key, race: race)
            cache[key] = result
            try? store?.saveResolved(result, videoId: key.id, maxHeight: key.maxHeight, now: now())
            if prefetching == key, let onPrefetched { Task { await onPrefetched(result) } }
            finish(key)
            return result
        } catch {
            finish(key)
            throw error
        }
    }

    private func finish(_ key: Key) {
        inFlight[key] = nil
        guard prefetching == key else { return }
        prefetching = nil
        if let next = queued {
            queued = nil
            prefetching = next
            start(next, race: false)
        }
    }

    /// visionos first; the default clients when it fails or is below 720p (or below the cap, when that is lower).
    /// After visionos fell short, the next resolve starts both at once (the fallback would likely be needed again),
    /// until visionos is enough again; a fallback that turns out not to be needed finishes unawaited.
    private func fetch(_ key: Key, race: Bool) async throws -> Resolved {
        let enough = min(720, key.maxHeight ?? 720)
        let resolveStreams = resolveStreams
        let early = race && visionosFellShort ? Task { try await resolveStreams(key.id, nil, key.maxHeight) } : nil
        let first: Resolved?
        do { first = try await resolveStreams(key.id, ["visionos"], key.maxHeight) } catch { first = nil }
        visionosFellShort = (first?.height ?? 0) < enough
        if let first, first.height >= enough { return first }
        let fallback: Resolved
        if let early { fallback = try await early.value } else { fallback = try await resolveStreams(key.id, nil, key.maxHeight) }
        if let first, first.height > fallback.height { return first }
        return fallback
    }
}
