import Foundation
import Testing
@testable import MatineeKit

private extension HeadGesture {
    /// The gesture without how long a tilt was held.
    var name: String {
        switch self {
        case .nod: "nod"
        case .shake: "shake"
        case .tiltLeft: "left"
        case .tiltRight: "right"
        }
    }
}

/// Feeds `seconds` of motion at `hz`: `rates(t)` gives (pitch, roll, yaw) speeds in °/s; attitude is their integral.
private func gestures(hz: Double = 25, seconds: Double, start: Double = 100,
                      _ rates: (Double) -> (Double, Double, Double)) -> [(t: Double, g: HeadGesture)] {
    var d = HeadGestureDetector()
    var pitch = 0.0, roll = 0.0, out: [(Double, HeadGesture)] = []
    let n = Int(seconds * hz)
    for i in 0...n {
        let t = Double(i) / hz
        let (p, r, y) = rates(t)
        pitch += p / hz
        roll += r / hz
        if let g = d.feed(.init(t: start + t, pitchRate: p, rollRate: r, yawRate: y, pitch: pitch, roll: roll)) {
            out.append((t, g))
        }
    }
    return out
}

/// `halves` half-cycles of a 2 Hz swing peaking at `peak` °/s from t = 0.5 s (each half ≈ peak/2π degrees),
/// then rest.
private func swing(_ t: Double, halves: Int, peak: Double = 100, hz: Double = 2) -> Double {
    let u = t - 0.5
    guard u >= 0, u < Double(halves) / (2 * hz) else { return 0 }
    return peak * sin(2 * .pi * hz * u)
}

/// Rolls to `degrees` over 0.5 s from t = 1.5 s (after the warm-up), then holds.
private func tiltTo(_ degrees: Double, _ t: Double) -> Double {
    (1.5..<2.0).contains(t) ? degrees / 0.5 : 0
}

struct HeadGestureTests {
    @Test func nodTwiceIsANod() {
        let g = gestures(seconds: 3) { (swing($0, halves: 2), 0, 0) }
        #expect(g.map(\.g) == [.nod])
    }

    @Test func nodIsSeenAtAHundredHertzToo() {
        let g = gestures(hz: 100, seconds: 3) { (swing($0, halves: 2), 0, 0) }
        #expect(g.map(\.g) == [.nod])
    }

    @Test func aLongNodIsStillOneGesture() {
        let g = gestures(seconds: 4) { (swing($0, halves: 4), 0, 0) }
        #expect(g.map(\.g) == [.nod])
    }

    @Test func shakeNeedsThreeSwings() {
        #expect(gestures(seconds: 3) { (0, 0, swing($0, halves: 3)) }.map(\.g) == [.shake])
        #expect(gestures(seconds: 3) { (0, 0, swing($0, halves: 2)) }.isEmpty)
    }

    @Test func lookingDownOnceIsNothing() {
        #expect(gestures(seconds: 3) { (swing($0, halves: 1), 0, 0) }.isEmpty)
    }

    @Test func smallTwitchesAreNothing() {
        // 20 °/s never reaches the lobe speed.
        #expect(gestures(seconds: 3) { (swing($0, halves: 4, peak: 20), 0, 0) }.isEmpty)
    }

    @Test func turningAroundAndBackIsNotAShake() {
        // Two 90° turns (left then back) and another: large swings, not a "no".
        let g = gestures(seconds: 5) { (0, 0, swing($0, halves: 3, peak: 300, hz: 0.8)) }
        #expect(g.isEmpty)
    }

    @Test func diagonalNodWithAsMuchRollIsNothing() {
        let g = gestures(seconds: 3) { t in (swing(t, halves: 2), swing(t, halves: 2), 0) }
        #expect(!g.contains { $0.g == .nod })
    }

    @Test func heldTiltSeeksAndRepeats() throws {
        let g = gestures(seconds: 4.4) { (0, tiltTo(20, $0), 0) }
        #expect(g.map(\.g.name) == ["right", "right", "right"])
        let first = try #require(g.first?.t)
        #expect(first >= 1.95 && first <= 2.4)
    }

    @Test func tiltLeftIsNegativeRoll() {
        #expect(gestures(seconds: 2.6) { (0, tiltTo(-20, $0), 0) }.map(\.g.name) == ["left"])
    }

    @Test func smallTiltIsNothing() {
        #expect(gestures(seconds: 4) { (0, tiltTo(10, $0), 0) }.isEmpty)
    }

    @Test func returningFromATiltIsNotAnotherTilt() {
        // Right for a while, then back to the middle: no left tilt on the way back.
        let g = gestures(seconds: 5) { t in (0, tiltTo(20, t) + ((3.0..<3.5).contains(t) ? -40 : 0), 0) }
        #expect(!g.contains { $0.g.name == "left" })
        #expect(g.contains { $0.g.name == "right" })
    }

    @Test func attitudeSettlingAtStartIsNotATilt() {
        // CoreMotion's first reports can be far from where the head is; the attitude then swings there and stays.
        #expect(gestures(seconds: 20) { (0, $0 < 0.6 ? -40 : 0, 0) }.isEmpty)
    }

    @Test func aTiltHeldForeverStopsRepeating() {
        // Lying on a side: after 20 s still there, that's where the head rests.
        let g = gestures(seconds: 40) { (0, tiltTo(-20, $0), 0) }
        #expect(g.count >= 20)
        #expect(g.allSatisfy { $0.g.name == "left" && $0.t < 23 })
    }

    @Test func aHeldTiltSeeksFasterAndFurther() throws {
        let g = gestures(hz: 50, seconds: 12) { (0, tiltTo(20, $0), 0) }
        let times = g.map(\.t)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(abs(gaps[0] - 1.0) < 0.05)
        #expect(zip(gaps.dropFirst(), gaps).allSatisfy { $0 <= $1 + 0.03 })
        #expect(abs(try #require(gaps.last) - 0.25) < 0.05)
        let steps = g.compactMap(\.g.seekSeconds)
        #expect(steps.first == 10 && steps.last == 30)
        #expect(zip(steps.dropFirst(), steps).allSatisfy { $0 >= $1 })
        #expect(HeadGesture.tiltLeft(held: 7).seekSeconds == -30)
    }

    @Test func noddingAgainRightAwayIsAnotherNod() {
        // Two nods with a 0.3 s pause between them: two gestures.
        let n = gestures(seconds: 4) { t in (swing(t, halves: 2) + swing(t - 0.8, halves: 2), 0, 0) }
        #expect(n.map(\.g.name) == ["nod", "nod"])
    }

    @Test func seekingWithATiltDoesNotMoveTheRest() {
        // Left for 8 s, back upright, then left again: no right tilt on the way back, and the second left tilt
        // needs no more than the first.
        let g = gestures(seconds: 16) { t in
            if (1.5..<2.0).contains(t) || (12.0..<12.5).contains(t) { return (0, -40, 0) }
            if (10.0..<10.5).contains(t) { return (0, 40, 0) }
            return (0, 0, 0)
        }
        #expect(!g.contains { $0.g.name == "right" })
        #expect(g.contains { $0.g.name == "left" && $0.t > 12 })
    }

    @Test func aGentleNodIsANod() {
        // 35 °/s peaks, under 6° each way.
        #expect(gestures(seconds: 3) { (swing($0, halves: 2, peak: 35), 0, 0) }.map(\.g) == [.nod])
    }

    @Test func aGentleShakeIsNothing() {
        #expect(gestures(seconds: 3) { (0, 0, swing($0, halves: 3, peak: 35)) }.isEmpty)
    }

    @Test func aNewRestingPositionIsNotATilt() {
        // Slumping 20° over ten seconds is followed, never held long enough against the rest.
        #expect(gestures(seconds: 12) { (0, $0 < 10 ? 2 : 0, 0) }.isEmpty)
    }

    @Test func aGapStartsAfresh() {
        var d = HeadGestureDetector()
        var out: [HeadGesture] = []
        // First lobe, then the reports stop for a second, then the second lobe: not a nod.
        for i in 0...60 {
            let t = Double(i) / 100
            let rate = t < 0.25 ? 100 * sin(4 * .pi * t) : 0
            if let g = d.feed(.init(t: t, pitchRate: rate, rollRate: 0, yawRate: 0, pitch: 0, roll: 0)) { out.append(g) }
        }
        for i in 0...60 {
            let t = 1.6 + Double(i) / 100
            let rate = t < 1.85 ? -100 * sin(4 * .pi * (t - 1.6)) : 0
            if let g = d.feed(.init(t: t, pitchRate: rate, rollRate: 0, yawRate: 0, pitch: 0, roll: 0)) { out.append(g) }
        }
        #expect(out.isEmpty)
    }
}
