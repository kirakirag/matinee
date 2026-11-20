import Foundation

/// Describes a burst of head motion with a fixed list of numbers, so two bursts can be compared: how long it took,
/// how far and fast each axis swung, how the movement was shared between the axes, how many times it changed
/// direction, whether the head came back to where it started, and the setting it happened in (how still the head
/// and body were just before, and how far the head was from where it usually looks at the screen).
public enum GestureFeatures {
    public static let count = 19
    /// Index of the pitch and yaw shares of the movement's energy.
    public static let pitchShare = 7, yawShare = 8
    /// Index of how far the head was pitched from where it usually looks, in tens of degrees.
    public static let pitchOffset = 17

    /// The least spread each feature is given when distances are scaled by how much a person's own gestures vary:
    /// someone very consistent in calibration must not make every later gesture look foreign.
    static let floors: [Double] = [
        0.2,                    // log duration
        0.2, 0.2, 0.2,          // log swing in degrees: pitch, yaw, roll
        0.2, 0.2, 0.2,          // log peak speed
        0.1, 0.1,               // share of energy: pitch, yaw
        0.5, 0.5,               // changes of direction: pitch, yaw
        0.15, 0.15, 0.15,       // how one-way the movement was (0 came back, 1 never did)
        0.3, 0.3,               // log acceleration (centi-g) during and before
        0.2,                    // seconds still before (up to 1)
        1.0, 1.0,               // tens of degrees from the usual pitch and roll at the start: posture varies by 10°
    ]

    public static func vector(_ b: MotionBurst, viewPitch: Double, neutralRoll: Double) -> [Double] {
        let s = b.samples
        var angle = [0.0, 0.0, 0.0], lo = [0.0, 0.0, 0.0], hi = [0.0, 0.0, 0.0]
        var peak = [0.0, 0.0, 0.0], energy = [0.0, 0.0, 0.0]
        var steps: [[Double]] = [[], [], []]   // per axis, the angle moved in each sample
        var accelSquares = s[0].accel * s[0].accel
        for (a, c) in zip(s, s.dropFirst()) {
            let dt = c.t - a.t
            for (k, rate) in [c.pitchRate, c.yawRate, c.rollRate].enumerated() {
                let step = rate * dt
                angle[k] += step
                lo[k] = min(lo[k], angle[k])
                hi[k] = max(hi[k], angle[k])
                peak[k] = max(peak[k], abs(rate))
                energy[k] += rate * rate * dt
                steps[k].append(step)
            }
            accelSquares += c.accel * c.accel
        }
        let range = (0..<3).map { hi[$0] - lo[$0] }
        let total = max(energy.reduce(0, +), 1e-9)
        let accel = (accelSquares / Double(s.count)).squareRoot()
        return [
            log(max(b.duration, 0.01)),
            log(1 + range[0]), log(1 + range[1]), log(1 + range[2]),
            log(1 + peak[0]), log(1 + peak[1]), log(1 + peak[2]),
            energy[0] / total, energy[1] / total,
            turns(steps[0], range: range[0]), turns(steps[1], range: range[1]),
            abs(angle[0]) / (range[0] + 1), abs(angle[1]) / (range[1] + 1), abs(angle[2]) / (range[2] + 1),
            log(1 + 100 * accel), log(1 + 100 * b.accelBefore),
            min(b.calmBefore, 1),
            (s[0].pitch - viewPitch) / 10, (s[0].roll - neutralRoll) / 10,
        ]
    }

    /// How many swings one way then the other the axis made: runs of the same direction that cover at least a fifth
    /// of the whole swing (and a degree), at most 6.
    private static func turns(_ steps: [Double], range: Double) -> Double {
        let least = max(1, 0.2 * range)
        var count = 0, run = 0.0
        for step in steps {
            if run != 0, (step > 0) != (run > 0), step != 0 {
                if abs(run) >= least { count += 1 }
                run = 0
            }
            run += step
        }
        if abs(run) >= least { count += 1 }
        return Double(min(count, 6))
    }

    /// The distance between two feature lists, each feature divided by its `scale`: about 1 between two takes of
    /// the same gesture by the same person.
    public static func distance(_ a: [Double], _ b: [Double], scale: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<count {
            let d = (a[i] - b[i]) / scale[i]
            sum += d * d
        }
        return (sum / Double(count)).squareRoot()
    }
}
