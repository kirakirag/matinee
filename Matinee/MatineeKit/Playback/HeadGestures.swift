// Nod/shake and tilt rules ported from MousePods' gestures.py (Apache-2.0, Copyright 2026 Matteo Gaudioso,
// https://github.com/starman-tech/mousepods); see THIRD_PARTY_NOTICES.md.

import Foundation

/// A head gesture recognised from AirPods motion.
public enum HeadGesture: Equatable, Sendable {
    /// Up–down, twice or more.
    case nod
    /// Left–right, three swings or more.
    case shake
    /// The head held tilted towards a shoulder; repeated, faster and faster, while it stays there. `held` is how
    /// long it has been held, in seconds.
    case tiltLeft(held: Double), tiltRight(held: Double)

    /// How far a tilt seeks: 10 s, then 20 s after 3 s held and 30 s after 6 s, backwards for a left tilt.
    public var seekSeconds: Double? {
        switch self {
        case .nod, .shake: nil
        case .tiltLeft(let held): -Self.seekStep(held)
        case .tiltRight(let held): Self.seekStep(held)
        }
    }

    private static func seekStep(_ held: Double) -> Double { held < 3 ? 10 : held < 6 ? 20 : 30 }
}

/// Turns head motion into gestures with fixed thresholds (no learning). A nod or shake is a run of alternating
/// "lobes" of angular speed on one axis, each a few degrees, close together and clearly stronger than the other axes.
/// A tilt is the roll held away from where the head usually rests, which follows slow drift.
public struct HeadGestureDetector {
    /// One motion report: angular speeds in °/s and attitude in degrees.
    public struct Sample {
        public var t: Double
        public var pitchRate: Double, rollRate: Double, yawRate: Double
        public var pitch: Double, roll: Double

        public init(t: Double, pitchRate: Double, rollRate: Double, yawRate: Double, pitch: Double, roll: Double) {
            self.t = t
            self.pitchRate = pitchRate
            self.rollRate = rollRate
            self.yawRate = yawRate
            self.pitch = pitch
            self.roll = roll
        }
    }

    // MousePods' defaults, calibrated on AirPods 3 and Pro 2, with nods made easier: through CoreMotion a firm nod
    // took too much effort.
    /// °/s a lobe must peak at, per axis (pitch, yaw); it lasts while above a quarter of that.
    static let lobeSpeed = [25.0, 40.0]
    static let nodDegrees = 5.0, nodLobes = 2
    static let shakeDegrees = 10.0, shakeLobes = 3
    static let maxGestureSeconds = 2.0, maxLobeGap = 0.4
    /// Swings right after a gesture belong to it only when they carry straight on, for at most this long after it,
    /// so nodding again (even impatiently) is a new gesture.
    static let continuationGap = 0.2, continuationMax = 1.5
    static let dominance = 2.0           // the gesture's axis carries this many times the energy of either other axis
    static let refractory = 0.4
    /// A swing this large is turning to look at something, not a gesture.
    static let maxLobeDegrees = 60.0
    static let tiltDegrees = 15.0, tiltHold = 0.25
    /// The first repeat comes after 1 s, each next one sooner, down to 4 a second.
    static let tiltRepeat = 1.0, tiltRepeatFactor = 0.8, tiltRepeatMin = 0.25
    static let holdMaxSpeed = 30.0, stillSpeed = 15.0
    /// The rest follows the head while it's still and near it, so slumping a little isn't a tilt.
    static let restTau = 1.0
    /// CoreMotion's attitude settles for a moment after updates start: the rest is taken after it.
    static let warmUp = 1.0
    /// Kept this long still away from the rest (lying on a side), the head rests there now: a tilt stops repeating.
    /// Never sooner, so seeking with a held tilt doesn't move the rest.
    static let adoptAfter = 20.0
    static let crossAxisRatio = 1.3
    /// Longer without a report is a new segment: nothing carries over a gap.
    static let maxGap = 0.5

    private struct Lobe { var start: Double, end: Double, sign: Int, degrees: Double, peak: Double }

    private var lastT: Double?
    private var startT = 0.0
    /// Per axis: 0 pitch, 1 yaw.
    private var run: [Lobe?] = [nil, nil]
    private var lobes: [[Lobe]] = [[], []]
    /// When the last finished lobe on each axis (0 pitch, 1 yaw) ended, and its size.
    private var lastLobe = [(t: -1e9, degrees: 0.0), (t: -1e9, degrees: 0.0)]
    private var energy: [(t: Double, pitch: Double, roll: Double, yaw: Double)] = []
    private var lastEvent = -1e9
    /// Per axis: where the swings of the last gesture ended. Swings that carry straight on belong to it.
    private var consumedUntil: [Double?] = [nil, nil]
    /// Where the head rests, in degrees.
    private var rest: (pitch: Double, roll: Double)?
    private var holdSince: Double?
    /// Since when the head has been still and away from the rest.
    private var farSince: Double?
    private var holdSign = 0
    private var lastRepeat: Double?
    private var repeats = 0

    public init() {}

    public mutating func reset() { self = HeadGestureDetector() }

    public mutating func feed(_ s: Sample) -> HeadGesture? {
        guard let prev = lastT, s.t > prev, s.t - prev <= Self.maxGap else {
            if let prev = lastT, s.t <= prev { return nil }
            reset()
            lastT = s.t
            startT = s.t
            rest = (s.pitch, s.roll)
            return nil
        }
        let dt = s.t - prev
        lastT = s.t
        energy.append((s.t, s.pitchRate * s.pitchRate * dt, s.rollRate * s.rollRate * dt, s.yawRate * s.yawRate * dt))
        energy.removeAll { $0.t < s.t - Self.maxGestureSeconds - 0.5 }

        var gesture: HeadGesture?
        for (axis, rate) in [s.pitchRate, s.yawRate].enumerated() where lobeEnded(axis, s.t, dt, rate) {
            if let g = oscillation(axis, s.t) { gesture = g }
        }
        let tilt = self.tilt(s, dt)
        return gesture ?? tilt
    }

    /// Follows the lobe on `axis`; true when one big enough just ended.
    private mutating func lobeEnded(_ axis: Int, _ t: Double, _ dt: Double, _ rate: Double) -> Bool {
        let low = 0.25 * Self.lobeSpeed[axis]
        let sign = rate > 0 ? 1 : -1
        let moving = abs(rate) >= low
        guard var current = run[axis] else {
            if moving { run[axis] = Lobe(start: t, end: t, sign: sign, degrees: rate * dt, peak: abs(rate)) }
            return false
        }
        if moving, sign == current.sign {
            current.end = t
            current.degrees += rate * dt
            current.peak = max(current.peak, abs(rate))
            run[axis] = current
            return false
        }
        run[axis] = moving ? Lobe(start: t, end: t, sign: sign, degrees: rate * dt, peak: abs(rate)) : nil
        guard current.peak >= Self.lobeSpeed[axis] else { return false }
        let degrees = abs(current.degrees)
        lastLobe[axis] = (t, degrees)
        if degrees > Self.maxLobeDegrees {
            lobes[axis] = []
            return false
        }
        current.end = t
        if let until = consumedUntil[axis], current.start - until <= Self.continuationGap,
           current.start - lastEvent <= Self.continuationMax {
            consumedUntil[axis] = t
            return false
        }
        consumedUntil[axis] = nil
        lobes[axis].append(current)
        lobes[axis] = Array(lobes[axis].filter { $0.end > t - Self.maxGestureSeconds - 0.5 }.suffix(6))
        return true
    }

    private mutating func oscillation(_ axis: Int, _ t: Double) -> HeadGesture? {
        let (gesture, need, minDegrees) = axis == 0
            ? (HeadGesture.nod, Self.nodLobes, Self.nodDegrees)
            : (HeadGesture.shake, Self.shakeLobes, Self.shakeDegrees)
        guard lobes[axis].count >= need, t - lastEvent >= Self.refractory else { return nil }
        let seq = Array(lobes[axis].suffix(need))
        for (a, b) in zip(seq, seq.dropFirst()) where a.sign == b.sign || b.start - a.end > Self.maxLobeGap {
            return nil
        }
        guard seq.allSatisfy({ abs($0.degrees) >= minDegrees }), seq.last!.end - seq[0].start <= Self.maxGestureSeconds
        else { return nil }
        let window = energy.filter { $0.t >= seq[0].start }
        let pitch = window.reduce(0) { $0 + $1.pitch }
        let roll = window.reduce(0) { $0 + $1.roll }
        let yaw = window.reduce(0) { $0 + $1.yaw }
        let (mine, others) = axis == 0 ? (pitch, max(roll, yaw)) : (yaw, max(roll, pitch))
        guard mine >= Self.dominance * others else { return nil }
        lobes = [[], []]
        consumedUntil[axis] = t
        lastEvent = t
        return gesture
    }

    private mutating func tilt(_ s: Sample, _ dt: Double) -> HeadGesture? {
        guard var rest else { return nil }
        if s.t - startT < Self.warmUp {
            self.rest = (s.pitch, s.roll)
            return nil
        }
        let relRoll = s.roll - rest.roll, relPitch = s.pitch - rest.pitch
        // A shake also rolls the head a little, and a nod drifts it: a recent big swing on another axis isn't a tilt.
        let coupled = lastLobe.contains { s.t - $0.t < 1.0 && $0.degrees > Self.crossAxisRatio * abs(relRoll) }
        let held = abs(relRoll) >= Self.tiltDegrees && abs(relRoll) > abs(relPitch) && !coupled
            && abs(s.rollRate) < Self.holdMaxSpeed
        let sign = relRoll > 0 ? 1 : -1
        var event: HeadGesture?
        let still = max(abs(s.pitchRate), abs(s.rollRate), abs(s.yawRate)) < Self.stillSpeed
        let near = abs(relRoll) < 0.5 * Self.tiltDegrees
        if near || !still {
            farSince = nil
        } else if farSince == nil {
            farSince = s.t
        } else if s.t - farSince! >= Self.adoptAfter {
            self.rest = (s.pitch, s.roll)
            farSince = nil
            holdSince = nil
            lastRepeat = nil
            repeats = 0
            return nil
        }
        if held, holdSince == nil || sign == holdSign {
            if holdSince == nil { holdSince = s.t; holdSign = sign }
            let interval = max(Self.tiltRepeat * pow(Self.tiltRepeatFactor, Double(repeats)), Self.tiltRepeatMin)
            let due = lastRepeat.map { s.t - $0 >= interval } ?? (s.t - holdSince! >= Self.tiltHold)
            if due, lastRepeat != nil || s.t - lastEvent >= Self.refractory {
                if lastRepeat != nil { repeats += 1 }
                lastRepeat = s.t
                lastEvent = s.t
                let held = s.t - holdSince!
                event = sign > 0 ? .tiltRight(held: held) : .tiltLeft(held: held)
            }
        } else if abs(relRoll) < 0.5 * Self.tiltDegrees || sign != holdSign || coupled {
            holdSince = nil
            lastRepeat = nil
            repeats = 0
        }
        // The rest's roll follows only near it, so tilting (and seeking with it) never moves the rest; its pitch
        // follows wherever the head looks, as pitch only decides which way a movement mostly goes.
        if still, holdSince == nil {
            let f = min(dt / Self.restTau, 1)
            if near { rest.roll += relRoll * f }
            rest.pitch += relPitch * f
            self.rest = rest
        }
        return event
    }
}
