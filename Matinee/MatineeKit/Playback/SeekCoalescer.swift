/// Merges seeks asked for while one is still in flight: they only move the target, and when mpv restarts
/// playback the last target is sought once. Relative seeks build on the pending target, not the stale position.
public struct SeekCoalescer {
    public struct Seek: Equatable {
        public let seconds: Double
        public let exact: Bool
    }

    public private(set) var target: Double?
    public private(set) var isSeeking = false
    private var exact = false
    private var pending = false

    public init() {}

    /// Returns the seek to issue now, or nil when it was queued behind the one in flight.
    public mutating func request(by delta: Double, from position: Double, duration: Double?, exact: Bool) -> Seek? {
        request(to: (target ?? position) + delta, duration: duration, exact: exact)
    }

    public mutating func request(to seconds: Double, duration: Double?, exact: Bool) -> Seek? {
        let clamped = max(0, min(seconds, duration ?? .infinity))
        target = clamped
        self.exact = exact
        if isSeeking { pending = true; return nil }
        isSeeking = true
        return Seek(seconds: clamped, exact: exact)
    }

    /// Call on mpv's playback restart; returns the queued seek to issue next, if any.
    public mutating func restarted() -> Seek? {
        guard pending, let target else { reset(); return nil }
        pending = false
        return Seek(seconds: target, exact: exact)
    }

    public mutating func reset() {
        target = nil
        isSeeking = false
        pending = false
    }
}
