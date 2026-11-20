/// Walks a person through calibration, fed with the motion stream: holding still, nodding and shaking a few times,
/// tilting to each side, then moving about naturally (what gestures must not be confused with). Ends with their
/// `GestureProfile`.
public struct CalibrationSession {
    public enum Step: Int, CaseIterable, Sendable { case still, nod, shake, tiltLeft, tiltRight, natural, done }

    public private(set) var step = Step.still
    /// How far through the current step, 0 to 1.
    public private(set) var progress = 0.0
    /// Nods or shakes recorded in the current step.
    public private(set) var repetitions = 0
    /// Set once `step` is `.done`.
    public private(set) var profile: GestureProfile?

    /// The roll (degrees against gravity) with this person's head upright, learnt by the first step; nil before. The
    /// AirPods sit at an angle in the ears, so it is seldom 0.
    public var upright: Double? { step == .still ? nil : neutralRoll }

    public static let repetitionsNeeded = 5
    static let stillSeconds = 2.5, tiltSeconds = 1.2, naturalSeconds = 20.0
    /// Under this many °/s the head is being held (still, or in a tilt).
    static let heldSpeed = 15.0
    /// The least lean, in degrees, that is a tilt to a side at all.
    static let leastTilt = 6.0
    /// A nod is mostly pitch and a shake mostly yaw: a take that is mostly something else isn't recorded.
    static let leastShare = 0.5

    private var segmenter = MotionSegmenter()
    private var since: Double?
    private var pitches: [Double] = [], rolls: [Double] = [], accels: [Double] = []
    private var viewPitch = 0.0, neutralRoll = 0.0, stillAccel = 0.0
    private var tiltLeft = 0.0, tiltRight = 0.0
    private var examples: [GestureExample] = []

    public init() {}

    public mutating func feed(_ s: HeadSample) {
        let burst = segmenter.feed(s)
        switch step {
        case .still:
            guard hold(s, while: s.speed < Self.heldSpeed, for: Self.stillSeconds) else { return }
            viewPitch = pitches.reduce(0, +) / Double(pitches.count)
            neutralRoll = rolls.reduce(0, +) / Double(rolls.count)
            stillAccel = (accels.reduce(0) { $0 + $1 * $1 } / Double(accels.count)).squareRoot()
            advance()
        case .nod, .shake:
            guard let burst else { return }
            let features = GestureFeatures.vector(burst, viewPitch: viewPitch, neutralRoll: neutralRoll)
            let share = features[step == .nod ? GestureFeatures.pitchShare : GestureFeatures.yawShare]
            guard share >= Self.leastShare else { return }
            examples.append(GestureExample(label: step == .nod ? .nod : .shake, features: features, source: .calibration))
            repetitions += 1
            progress = Double(repetitions) / Double(Self.repetitionsNeeded)
            if repetitions == Self.repetitionsNeeded { advance() }
        case .tiltLeft, .tiltRight:
            let lean = (s.roll - neutralRoll) * (step == .tiltLeft ? -1 : 1)
            guard hold(s, while: lean >= Self.leastTilt && s.speed < Self.heldSpeed, for: Self.tiltSeconds) else { return }
            let leans = rolls.map { abs($0 - neutralRoll) }.sorted()
            if step == .tiltLeft { tiltLeft = leans[leans.count / 2] } else { tiltRight = leans[leans.count / 2] }
            advance()
        case .natural:
            if let burst {
                let features = GestureFeatures.vector(burst, viewPitch: viewPitch, neutralRoll: neutralRoll)
                examples.append(GestureExample(label: .none, features: features, source: .calibration))
            }
            let start = since ?? s.t
            since = start
            progress = min((s.t - start) / Self.naturalSeconds, 1)
            guard progress >= 1 else { return }
            profile = GestureProfile(viewPitch: viewPitch, neutralRoll: neutralRoll, stillAccel: stillAccel,
                                     tiltLeft: tiltLeft, tiltRight: tiltRight,
                                     examples: examples)
            advance()
        case .done: break
        }
    }

    /// Collects the samples while `condition` holds without a break; true once it has held for `seconds`.
    private mutating func hold(_ s: HeadSample, while condition: Bool, for seconds: Double) -> Bool {
        guard condition else {
            since = nil
            progress = 0
            return false
        }
        if since == nil {
            since = s.t
            pitches = []
            rolls = []
            accels = []
        }
        pitches.append(s.pitch)
        rolls.append(s.roll)
        accels.append(s.accel)
        progress = min((s.t - since!) / seconds, 1)
        return progress >= 1
    }

    private mutating func advance() {
        step = Step(rawValue: step.rawValue + 1) ?? .done
        progress = step == .done ? 1 : 0
        repetitions = 0
        since = nil
    }
}
