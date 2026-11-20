import Foundation

/// Turns the motion stream into gestures for one person's `GestureProfile`: nods and shakes by comparing each burst
/// of movement with the remembered examples, tilts by the calibrated angles.
public struct HeadGestureRecognizer {
    public enum Output: Equatable, Sendable {
        /// A gesture to act on. A nod or shake comes with its features, to learn from what happens next.
        case gesture(HeadGesture, features: [Double]?)
        /// A movement close to a gesture but not acted on, with its features.
        case nearMiss(GestureLabel, features: [Double])
        /// The head held most of the way to a tilt, not acted on.
        case tiltNearMiss(left: Bool)
    }

    public private(set) var profile: GestureProfile
    /// For debugging: what the last burst was taken for, and how far it was from each kind of example.
    public private(set) var lastBurst: String?
    private var model: GestureModel
    private var segmenter = MotionSegmenter()
    private var tilt: TiltTracker

    public init(profile: GestureProfile) {
        self.profile = profile
        model = GestureModel(profile.examples)
        tilt = TiltTracker(settings: .init(profile))
    }

    /// Changes what was learnt without interrupting the stream.
    public mutating func update(_ change: (inout GestureProfile) -> Void) {
        change(&profile)
        model = GestureModel(profile.examples)
        tilt.settings = .init(profile)
    }

    public mutating func feed(_ s: HeadSample) -> Output? {
        let burst = segmenter.feed(s)
        let tilted = tilt.feed(s)
        if let burst {
            // How the head was held is measured from the calibrated pose; how far from it this person gestures is
            // learnt with their gestures, so nothing here follows the head around.
            let features = GestureFeatures.vector(burst, viewPitch: profile.viewPitch, neutralRoll: profile.neutralRoll)
            let verdict = model.classify(features)
            lastBurst = { m in
                let d = [GestureLabel.nod, .shake, .none].map { String(format: "%.2f", m.distance(features, to: $0)) }
                return "\(verdict) nod=\(d[0]) (r \(String(format: "%.2f", m.radius[.nod] ?? 0))) shake=\(d[1]) (r \(String(format: "%.2f", m.radius[.shake] ?? 0))) other=\(d[2])"
            }(model)
            switch verdict {
            case .gesture(.nod): return .gesture(.nod, features: features)
            case .gesture(.shake): return .gesture(.shake, features: features)
            case .nearMiss(let label): return .nearMiss(label, features: features)
            case .gesture(.none), .nothing: break
            }
        }
        switch tilted {
        case .tilt(let gesture): return .gesture(gesture, features: nil)
        case .nearMiss(let left): return .tiltNearMiss(left: left)
        case nil: return nil
        }
    }
}
