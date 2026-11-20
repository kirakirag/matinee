/// One movement of the head, from the moment it left stillness to the moment it came back to it.
public struct MotionBurst: Sendable {
    public let samples: [HeadSample]
    /// How long the head was still before it, in seconds.
    public let calmBefore: Double
    /// The RMS of the head's acceleration in the 1.5 s before it, in g: high while walking.
    public let accelBefore: Double

    public var duration: Double { samples[samples.count - 1].t - samples[0].t }
}

/// Cuts the motion stream into bursts: a burst starts when the head leaves stillness and ends once it has been still
/// again for a moment. These constants only say what "still" is; which bursts are gestures is learnt (`GestureModel`).
public struct MotionSegmenter {
    /// Under this many °/s on every axis the head is still.
    static let calmSpeed = 10.0
    /// A burst ends after this long still, so the pause at the bottom of a nod doesn't split it.
    static let endQuiet = 0.25
    /// Movement that goes on longer than this (walking about, stretching) is no gesture: dropped whole.
    static let maxBurst = 3.0
    /// Shorter or slower than this is sensor jitter.
    static let minBurst = 0.12, minPeak = 20.0
    /// Longer without a report is a new start: nothing carries over a gap.
    static let maxGap = 0.5
    static let contextSeconds = 1.5

    private var lastT: Double?
    private var calmSince: Double?
    /// Since when the head had been still when the current burst began.
    private var calmBeforeBurst: Double?
    private var burst: [HeadSample] = []
    private var inBurst = false
    private var overlong = false
    private var quietSince: Double?
    private var calmBefore = 0.0, accelBefore = 0.0
    private var recent: [(t: Double, accel: Double)] = []

    public init() {}

    /// The head is moving (inside a burst).
    public var isMoving: Bool { inBurst }

    public mutating func feed(_ s: HeadSample) -> MotionBurst? {
        guard let prev = lastT, s.t > prev, s.t - prev <= Self.maxGap else {
            if let prev = lastT, s.t <= prev { return nil }
            self = MotionSegmenter()
            lastT = s.t
            return nil
        }
        lastT = s.t
        let calm = s.speed < Self.calmSpeed
        defer {
            recent.append((s.t, s.accel))
            recent.removeAll { $0.t < s.t - Self.contextSeconds }
        }
        if !inBurst {
            if calm {
                if calmSince == nil { calmSince = s.t }
                return nil
            }
            inBurst = true
            overlong = false
            quietSince = nil
            calmBefore = calmSince.map { s.t - $0 } ?? 0
            accelBefore = recent.isEmpty ? 0 : (recent.reduce(0) { $0 + $1.accel * $1.accel } / Double(recent.count)).squareRoot()
            calmBeforeBurst = calmSince
            calmSince = nil
            burst = [s]
            return nil
        }
        if !overlong { burst.append(s) }
        if !calm {
            quietSince = nil
            if !overlong, s.t - burst[0].t > Self.maxBurst {
                overlong = true
                burst = [burst[0]]
            }
            return nil
        }
        if quietSince == nil { quietSince = s.t }
        guard let quiet = quietSince, s.t - quiet >= Self.endQuiet else { return nil }
        inBurst = false
        quietSince = nil
        let samples = burst.filter { $0.t < quiet }
        burst = []
        let jitter = !overlong && (samples.count < 2 || samples[samples.count - 1].t - samples[0].t < Self.minBurst
                                   || !samples.contains { $0.speed >= Self.minPeak })
        // A twitch doesn't end the stillness it happened in.
        calmSince = jitter ? calmBeforeBurst ?? quiet : quiet
        guard !overlong, !jitter else { return nil }
        return MotionBurst(samples: samples, calmBefore: calmBefore, accelBefore: accelBefore)
    }
}
