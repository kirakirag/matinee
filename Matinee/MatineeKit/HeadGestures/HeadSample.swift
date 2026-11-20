/// One report of AirPods head motion.
public struct HeadSample: Sendable, Equatable {
    public var t: Double
    /// Angular speeds in °/s.
    public var pitchRate: Double, rollRate: Double, yawRate: Double
    /// Attitude in degrees. Pitch and roll are measured against gravity (roll is about 0 with the head upright,
    /// negative tilted left); yaw has no fixed zero.
    public var pitch: Double, roll: Double, yaw: Double
    /// The size of the head's own acceleration (gravity removed) in g.
    public var accel: Double

    public init(t: Double, pitchRate: Double = 0, rollRate: Double = 0, yawRate: Double = 0,
                pitch: Double = 0, roll: Double = 0, yaw: Double = 0, accel: Double = 0) {
        self.t = t
        self.pitchRate = pitchRate
        self.rollRate = rollRate
        self.yawRate = yawRate
        self.pitch = pitch
        self.roll = roll
        self.yaw = yaw
        self.accel = accel
    }

    /// The fastest of the three angular speeds.
    public var speed: Double { max(abs(pitchRate), abs(rollRate), abs(yawRate)) }
}

/// A head gesture the player acts on.
public enum HeadGesture: Equatable, Sendable {
    case nod
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

/// What a burst of head motion is an example of.
public enum GestureLabel: String, Codable, Sendable, CaseIterable {
    case nod, shake
    /// Any other movement: looking around, leaning, reaching for something.
    case none
}
