import Foundation
@testable import MatineeKit

/// A made-up person's head, sampled at 50 Hz: each call appends some movement and returns its samples. The same
/// seed always moves the same way.
struct Head {
    private(set) var t = 100.0
    private(set) var pitch = -20.0, roll = 1.0, yaw = 0.0
    /// The body's acceleration in g: about 0.005 sitting, 0.15 walking.
    var accel = 0.005
    private var seed: UInt64

    init(seed: UInt64 = 1) { self.seed = seed }

    /// A number in -1...1.
    private mutating func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 30) - 1
    }

    /// `seconds` of movement at the speeds `rates` gives (pitch, roll, yaw in °/s) for the time since it began.
    mutating func move(_ seconds: Double, _ rates: (Double) -> (Double, Double, Double) = { _ in (0, 0, 0) }) -> [HeadSample] {
        var out: [HeadSample] = []
        for i in 0..<Int((seconds * 50).rounded()) {
            let (p, r, y) = rates(Double(i) / 50)
            let s = HeadSample(t: t, pitchRate: p + 1.5 * noise(), rollRate: r + 1.5 * noise(), yawRate: y + 1.5 * noise(),
                               pitch: pitch, roll: roll, yaw: yaw, accel: accel * (1 + 0.3 * noise()))
            pitch += p / 50
            roll += r / 50
            yaw += y / 50
            t += 0.02
            out.append(s)
        }
        return out
    }

    mutating func rest(_ seconds: Double = 1) -> [HeadSample] { move(seconds) }

    /// Down and up `times`, each swing peaking at `peak` °/s, then a second of rest.
    mutating func nod(peak: Double = 100, hz: Double = 2, times: Int = 1) -> [HeadSample] {
        move(Double(times) / hz) { (-peak * sin(2 * .pi * hz * $0), 0, 0) } + rest()
    }

    /// Left, right, left (three swings), then a second of rest.
    mutating func shake(peak: Double = 120, hz: Double = 2) -> [HeadSample] {
        move(1.5 / hz) { (0, 0, peak * sin(2 * .pi * hz * $0)) } + rest()
    }

    /// Rolls by `degrees` (negative is left) over half a second, without resting after.
    mutating func tilt(by degrees: Double) -> [HeadSample] { move(0.5) { _ in (0, degrees / 0.5, 0) } }

    /// Pitches by `degrees` over `seconds`, without resting after.
    mutating func pitch(by degrees: Double, over seconds: Double = 0.5) -> [HeadSample] {
        move(seconds) { _ in (degrees / seconds, 0, 0) }
    }

    /// Turns by `degrees` over `seconds`, then rests.
    mutating func turn(by degrees: Double, over seconds: Double = 0.6) -> [HeadSample] {
        move(seconds) { _ in (0, 0, degrees / seconds) } + rest()
    }

    /// The whole calibration: still, five nods and shakes (each a little different), a tilt to each side, then
    /// twenty seconds of looking around and leaning.
    mutating func calibrate() -> GestureProfile {
        var session = CalibrationSession()
        var all = rest(3)
        for i in 0..<5 { all += nod(peak: 85 + 10 * Double(i), hz: 1.8 + 0.1 * Double(i)) }
        for i in 0..<5 { all += shake(peak: 100 + 10 * Double(i), hz: 1.8 + 0.1 * Double(i)) }
        all += tilt(by: -21) + rest(1.5) + tilt(by: 21) + rest(0.5)
        all += tilt(by: 20) + rest(1.5) + tilt(by: -20) + rest(1)
        // Natural movement: looking aside and back, leaning in and out, glancing down.
        all += turn(by: 35) + turn(by: -35) + pitch(by: -25) + rest() + pitch(by: 25) + rest()
        all += turn(by: -50, over: 0.8) + turn(by: 50, over: 0.8) + pitch(by: 15, over: 0.4) + rest() + pitch(by: -15, over: 0.4)
        all += rest(12)
        for s in all { session.feed(s) }
        return session.profile!
    }
}

extension HeadGestureRecognizer {
    /// Everything the recogniser reports for `samples`.
    mutating func outputs(_ samples: [HeadSample]) -> [Output] { samples.compactMap { feed($0) } }

    /// The gestures acted on, by name ("left" and "right" for tilts).
    mutating func gestures(_ samples: [HeadSample]) -> [String] {
        outputs(samples).compactMap {
            guard case .gesture(let g, _) = $0 else { return nil }
            switch g {
            case .nod: return "nod"
            case .shake: return "shake"
            case .tiltLeft: return "left"
            case .tiltRight: return "right"
            }
        }
    }
}
