import Foundation

/// One remembered movement: what it was, and its `GestureFeatures`. Never the raw motion.
public struct GestureExample: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Recorded in calibration: kept for good.
        case calibration
        /// A gesture that was acted on and left standing.
        case confirmed
        /// A movement that wasn't recognised, followed at once by the key for the same action.
        case corrected
        /// A gesture that was acted on and taken back (⌘Z).
        case undone
    }

    public var label: GestureLabel
    public var features: [Double]
    public var source: Source

    public init(label: GestureLabel, features: [Double], source: Source) {
        self.label = label
        self.features = features
        self.source = source
    }
}

/// Everything learnt about one person's head gestures. Behavioural data: it is stored only sealed
/// (`GestureProfileStore`) and never leaves the Mac.
public struct GestureProfile: Codable, Equatable, Sendable {
    /// Where the head rests while watching, in degrees, and how much its acceleration reads when it is still, in g.
    public var viewPitch: Double, neutralRoll: Double, stillAccel: Double
    /// How far the head was tilted to each side in calibration, in degrees from `neutralRoll`.
    public var tiltLeft: Double, tiltRight: Double
    /// The share of the calibrated tilt that counts as a tilt. It starts at `tiltFactor` and is learnt from there:
    /// up when a tilt's seek is undone, down when a tilt that fell short is followed by the arrow key.
    public var tiltFactorLeft = GestureProfile.tiltFactor, tiltFactorRight = GestureProfile.tiltFactor
    public var examples: [GestureExample]

    static let tiltFactor = 0.6, tiltFactorStep = 1.1, tiltFactorMin = 0.35, tiltFactorMax = 0.9
    /// How many learnt (not calibration) examples are kept, newest last.
    static let learntGestures = 40, learntOthers = 150

    public init(viewPitch: Double, neutralRoll: Double, stillAccel: Double, tiltLeft: Double, tiltRight: Double,
                examples: [GestureExample]) {
        self.viewPitch = viewPitch
        self.neutralRoll = neutralRoll
        self.stillAccel = stillAccel
        self.tiltLeft = tiltLeft
        self.tiltRight = tiltRight
        self.examples = examples
    }

    /// Remembers a movement. A new gesture example overrules the take-backs that look like it, and a take-back
    /// overrules the learnt gestures that look like it, so one mistake either way can be corrected.
    public mutating func learn(_ features: [Double], as label: GestureLabel, source: GestureExample.Source) {
        let model = GestureModel(examples)
        func close(_ e: GestureExample, to gesture: GestureLabel) -> Bool {
            guard let r = model.radius[gesture] else { return false }
            return GestureFeatures.distance(e.features, features, scale: model.scale) < 0.5 * r
        }
        if label == .none {
            examples.removeAll { ($0.source == .confirmed || $0.source == .corrected) && close($0, to: $0.label) }
        } else {
            examples.removeAll { $0.source == .undone && close($0, to: label) }
        }
        examples.append(GestureExample(label: label, features: features, source: source))
        let limit = label == .none ? Self.learntOthers : Self.learntGestures
        var extra = examples.count { $0.label == label && $0.source != .calibration } - limit
        if extra > 0 {
            examples.removeAll { e in
                guard extra > 0, e.label == label, e.source != .calibration else { return false }
                extra -= 1
                return true
            }
        }
    }

    /// A tilt's seek was taken back: that side needs a deeper tilt from now on.
    public mutating func tiltUndone(left: Bool) {
        if left {
            tiltFactorLeft = min(tiltFactorLeft * Self.tiltFactorStep, Self.tiltFactorMax)
        } else {
            tiltFactorRight = min(tiltFactorRight * Self.tiltFactorStep, Self.tiltFactorMax)
        }
    }

    /// A tilt that fell short was followed by the arrow key the same way: that side needs less of a tilt from now on.
    public mutating func tiltCorrected(left: Bool) {
        if left {
            tiltFactorLeft = max(tiltFactorLeft / Self.tiltFactorStep, Self.tiltFactorMin)
        } else {
            tiltFactorRight = max(tiltFactorRight / Self.tiltFactorStep, Self.tiltFactorMin)
        }
    }
}

public enum GestureVerdict: Equatable, Sendable {
    case gesture(GestureLabel)
    /// Close to a gesture but not close enough to act on: learnt if the same action's key follows.
    case nearMiss(GestureLabel)
    case nothing
}

/// Recognises a burst by the remembered examples nearest to it. A burst is a gesture only when it is as close to
/// that gesture's examples as they are to each other, and closer to them than to anything remembered as "not a
/// gesture"; a movement unlike everything remembered is nothing.
public struct GestureModel: Sendable {
    /// How much each feature varies between this person's own takes of a gesture.
    public let scale: [Double]
    /// Per gesture, how far a burst may be from its examples.
    public let radius: [GestureLabel: Double]
    private let examples: [GestureExample]

    /// A near miss teaches only when the same action's key follows it, so its band can be wide: twice the radius
    /// takes in a nod half the size of the calibrated ones.
    static let radiusFactor = 1.3, radiusFloor = 0.6, nearMissFactor = 2.0

    public init(_ examples: [GestureExample]) {
        self.examples = examples
        // Each feature's scale is how much it varies in this person's gestures: in calibration, or across everything
        // learnt since (other days, other ways of sitting) when that is more. The floors stand in until there is
        // enough to go by. Like the radius, it only ever widens.
        let gestures = examples.filter { $0.label != .none }
        let calibrated = Self.variation(gestures.filter { $0.source == .calibration })
        let all = Self.variation(gestures)
        let scale = (0..<GestureFeatures.count).map { max(GestureFeatures.floors[$0], calibrated[$0], all[$0]) }
        self.scale = scale
        var radius: [GestureLabel: Double] = [:]
        for label in [GestureLabel.nod, .shake] {
            let all = examples.filter { $0.label == label }
            guard !all.isEmpty else { continue }
            // Never tighter than calibration made it: learning adds reach, it can't take it away.
            radius[label] = max(Self.spread(all.filter { $0.source == .calibration }, scale), Self.spread(all, scale))
        }
        self.radius = radius
    }

    /// Per feature, the standard deviation of `group` around each gesture's own mean (0 for an empty group).
    private static func variation(_ group: [GestureExample]) -> [Double] {
        var squares = [Double](repeating: 0, count: GestureFeatures.count)
        guard !group.isEmpty else { return squares }
        for label in [GestureLabel.nod, .shake] {
            let same = group.filter { $0.label == label }
            guard !same.isEmpty else { continue }
            for i in 0..<GestureFeatures.count {
                let mean = same.reduce(0) { $0 + $1.features[i] } / Double(same.count)
                squares[i] += same.reduce(0) { $0 + ($1.features[i] - mean) * ($1.features[i] - mean) }
            }
        }
        return squares.map { ($0 / Double(group.count)).squareRoot() }
    }

    /// How far apart a gesture's examples are: each one's distance to its two nearest fellows, the 80th percentile.
    private static func spread(_ group: [GestureExample], _ scale: [Double]) -> Double {
        guard group.count >= 2 else { return radiusFloor }
        let each = group.indices.map { i in
            nearest(group[i].features, in: group.indices.filter { $0 != i }.map { group[$0] }, scale, count: 2)
        }.sorted()
        return max(radiusFactor * each[min(Int(0.8 * Double(each.count)), each.count - 1)], radiusFloor)
    }

    /// The mean distance from `x` to its `count` nearest examples in `group`.
    private static func nearest(_ x: [Double], in group: [GestureExample], _ scale: [Double], count: Int) -> Double {
        let d = group.map { GestureFeatures.distance(x, $0.features, scale: scale) }.sorted().prefix(count)
        return d.isEmpty ? .infinity : d.reduce(0, +) / Double(d.count)
    }

    /// How far `x` is from the nearest example of `label`; infinity when there is none. A single example, so one
    /// correction is enough to teach a new way of making a gesture.
    public func distance(_ x: [Double], to label: GestureLabel) -> Double {
        Self.nearest(x, in: examples.filter { $0.label == label }, scale, count: 1)
    }

    public func classify(_ x: [Double]) -> GestureVerdict {
        var best: (label: GestureLabel, distance: Double)?
        for label in [GestureLabel.nod, .shake] {
            let d = distance(x, to: label)
            if d < (best?.distance ?? .infinity) { best = (label, d) }
        }
        guard let best, let r = radius[best.label] else { return .nothing }
        if best.distance <= r, best.distance < distance(x, to: .none) { return .gesture(best.label) }
        return best.distance <= Self.nearMissFactor * r ? .nearMiss(best.label) : .nothing
    }

    /// How many of each gesture's calibration takes are recognised from the others alone.
    public func selfCheck() -> [GestureLabel: (recognised: Int, of: Int)] {
        var result: [GestureLabel: (recognised: Int, of: Int)] = [:]
        for (i, e) in examples.enumerated() where e.source == .calibration && e.label != .none {
            var rest = examples
            rest.remove(at: i)
            let ok = GestureModel(rest).classify(e.features) == .gesture(e.label)
            let old = result[e.label] ?? (0, 0)
            result[e.label] = (old.recognised + (ok ? 1 : 0), old.of + 1)
        }
        return result
    }
}
