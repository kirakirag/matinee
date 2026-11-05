import Foundation

/// Pure state for "which video is current", so results of an earlier `open` that arrive late can be dropped.
public struct PlaybackSession: Sendable {
    public private(set) var token = 0

    public init() {}

    public mutating func begin() -> Int {
        token += 1
        return token
    }

    public func isCurrent(_ t: Int) -> Bool { t == token }
}

public enum StartDelay {
    /// Whole seconds (rounded up) until `availableAt`; nil when there is nothing left to wait for.
    public static func seconds(until availableAt: Date?, now: Date) -> Int? {
        guard let availableAt else { return nil }
        let s = Int(availableAt.timeIntervalSince(now).rounded(.up))
        return s > 0 ? s : nil
    }
}
