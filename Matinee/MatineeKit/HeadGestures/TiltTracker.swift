// The hold-and-latch rules are ported from MousePods' gestures.py (Apache-2.0, Copyright 2026 Matteo Gaudioso,
// https://github.com/starman-tech/mousepods); see THIRD_PARTY_NOTICES.md. The angles come from calibration.

import Foundation

/// Reports a tilt while the head is held towards a shoulder: once after a moment, then again and again, faster and
/// faster, until it comes back upright. How deep a tilt must be, and where upright is, come from the person's
/// calibration. Nothing counts while they're bent over something or walking.
public struct TiltTracker {
    public struct Settings: Equatable, Sendable {
        /// The roll with the head upright, and the tilt (degrees from it) that counts on each side.
        public var neutralRoll: Double, left: Double, right: Double
        /// The pitch the head watches at, and how far from it a tilt still counts.
        public var viewPitch: Double, pitchGate: Double
        /// The smoothed acceleration above which the person is walking.
        public var accelGate: Double

        public init(neutralRoll: Double, left: Double, right: Double, viewPitch: Double, pitchGate: Double, accelGate: Double) {
            self.neutralRoll = neutralRoll
            self.left = left
            self.right = right
            self.viewPitch = viewPitch
            self.pitchGate = pitchGate
            self.accelGate = accelGate
        }

        /// A tilt is the learnt share of the calibrated one (never under 6°). The pitch may be three times as far
        /// from the calibrated one as it usually is when this person gestures, which is learnt with their gestures
        /// (`GestureModel.scale`). Walking is four times the still head's acceleration (at least 0.04 g).
        public init(_ p: GestureProfile) {
            let usualPitch = 10 * GestureModel(p.examples).scale[GestureFeatures.pitchOffset]
            self.init(neutralRoll: p.neutralRoll,
                      left: max(p.tiltFactorLeft * p.tiltLeft, 6), right: max(p.tiltFactorRight * p.tiltRight, 6),
                      viewPitch: p.viewPitch, pitchGate: 3 * usualPitch, accelGate: max(4 * p.stillAccel, 0.04))
        }
    }

    public enum Event: Equatable, Sendable {
        case tilt(HeadGesture)
        /// The head was held tilted, still, most of the way to a tilt: learnt if the arrow key that way follows.
        case nearMiss(left: Bool)
    }

    public var settings: Settings

    static let hold = 0.25
    /// A near miss is this share of the needed tilt, held this long.
    static let nearMissShare = 0.6, nearMissHold = 0.6
    /// The first repeat comes after 1 s, each next one sooner, down to 4 a second.
    static let repeatAfter = 1.0, repeatFactor = 0.8, repeatMin = 0.25
    /// The head must be this still (°/s) to begin a tilt, and this still to keep holding it.
    static let stillSpeed = 15.0, holdMaxSpeed = 30.0
    /// Upright drifts a little with posture: it follows the head while it's still and near upright, this far at most.
    static let driftTau = 1.0, driftLimit = 6.0
    /// A tilt held this long (lying on a side) stops seeking until the head comes back upright.
    static let maxHold = 20.0
    static let accelTau = 0.5

    private var lastT: Double?
    private var drift = 0.0
    /// False until the head has been upright once, so starting with it tilted seeks nothing.
    private var armed = false
    private var holdSince: Double?
    private var holdSign = 0
    private var lastRepeat: Double?
    private var repeats = 0
    private var accelAvg = 0.0
    private var almostSince: Double?
    /// The near miss of this lean was reported (once, until the head is upright again).
    private var almostReported = false

    public init(settings: Settings) { self.settings = settings }

    public mutating func feed(_ s: HeadSample) -> Event? {
        guard let prev = lastT, s.t > prev, s.t - prev <= MotionSegmenter.maxGap else {
            if let prev = lastT, s.t <= prev { return nil }
            self = TiltTracker(settings: settings)
            lastT = s.t
            return nil
        }
        let dt = s.t - prev
        lastT = s.t
        accelAvg += (s.accel - accelAvg) * min(dt / Self.accelTau, 1)
        let rel = s.roll - settings.neutralRoll - drift
        let sign = rel > 0 ? 1 : -1
        let need = sign > 0 ? settings.right : settings.left
        let near = abs(rel) < 0.5 * min(settings.left, settings.right)
        if near { armed = true }
        let attending = armed && abs(s.pitch - settings.viewPitch) <= settings.pitchGate && accelAvg <= settings.accelGate
        // A tilt begins with the head held properly still; once it is seeking, a little movement doesn't end it.
        let held = attending && abs(rel) >= need && s.speed < (lastRepeat == nil ? Self.stillSpeed : Self.holdMaxSpeed)
        var event: Event?
        if attending, holdSince == nil, abs(rel) >= Self.nearMissShare * need, abs(rel) < need, s.speed < Self.stillSpeed {
            let since = almostSince ?? s.t
            almostSince = since
            if !almostReported, s.t - since >= Self.nearMissHold {
                almostReported = true
                event = .nearMiss(left: sign < 0)
            }
        } else {
            almostSince = nil
            if near { almostReported = false }
        }
        if held, holdSince == nil || sign == holdSign {
            if holdSince == nil { holdSince = s.t; holdSign = sign }
            let since = holdSince!
            let interval = max(Self.repeatAfter * pow(Self.repeatFactor, Double(repeats)), Self.repeatMin)
            let due = lastRepeat.map { s.t - $0 >= interval } ?? (s.t - since >= Self.hold)
            if due, s.t - since < Self.maxHold {
                if lastRepeat != nil { repeats += 1 }
                lastRepeat = s.t
                event = .tilt(sign > 0 ? .tiltRight(held: s.t - since) : .tiltLeft(held: s.t - since))
            }
        } else if abs(rel) < 0.5 * need || sign != holdSign {
            holdSince = nil
            lastRepeat = nil
            repeats = 0
        }
        if near, holdSince == nil, s.speed < Self.stillSpeed {
            drift = min(max(drift + rel * min(dt / Self.driftTau, 1), -Self.driftLimit), Self.driftLimit)
        }
        return event
    }
}
