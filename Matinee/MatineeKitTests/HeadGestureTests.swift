import CryptoKit
import Foundation
import Testing
@testable import MatineeKit

struct MotionSegmenterTests {
    private func bursts(_ samples: [HeadSample]) -> [MotionBurst] {
        var s = MotionSegmenter()
        return samples.compactMap { s.feed($0) }
    }

    @Test func oneMovementBetweenTwoRestsIsOneBurst() throws {
        var head = Head()
        let b = bursts(head.rest() + head.nod())
        #expect(b.count == 1)
        let burst = try #require(b.first)
        #expect(abs(burst.duration - 0.5) < 0.1)
        #expect(burst.calmBefore > 0.9)
        #expect(burst.accelBefore < 0.01)
    }

    @Test func aShortPauseInsideAMovementDoesNotSplitIt() {
        var head = Head()
        var all = head.rest() + head.move(0.25) { _ in (-80, 0, 0) }
        all += head.rest(0.15) + head.move(0.25) { _ in (80, 0, 0) } + head.rest()
        #expect(bursts(all).count == 1)
    }

    @Test func movementThatGoesOnAndOnIsDropped() {
        var head = Head()
        let b = bursts(head.rest() + head.move(5) { (60 * sin(2 * .pi * $0), 0, 30) } + head.rest() + head.nod())
        #expect(b.count == 1)   // only the nod after it
    }

    @Test func jitterIsNoBurst() {
        var head = Head()
        #expect(bursts(head.rest() + head.move(0.06) { _ in (40, 0, 0) } + head.rest()).isEmpty)
        #expect(bursts(head.rest() + head.move(0.5) { _ in (14, 0, 0) } + head.rest()).isEmpty)
    }

    @Test func aTwitchDoesNotEndTheStillness() throws {
        var head = Head()
        // Still for 2 s, a twitch of 14 °/s, still for 0.3 s, then a nod: the head counts as still all along.
        let burst = try #require(bursts(head.rest(2) + head.move(0.1) { _ in (0, 0, 14) } + head.rest(0.3) + head.nod()).first)
        #expect(burst.calmBefore > 2)
    }

    @Test func walkingShowsInTheAccelerationBefore() throws {
        var head = Head()
        head.accel = 0.15
        let burst = try #require(bursts(head.rest(2) + head.nod()).first)
        #expect(burst.accelBefore > 0.1)
    }
}

struct CalibrationSessionTests {
    @Test func walksThroughTheStepsAndEndsWithAProfile() {
        var head = Head()
        var session = CalibrationSession()
        func feed(_ samples: [HeadSample]) { for s in samples { session.feed(s) } }
        #expect(session.step == .still)
        feed(head.rest(1))
        #expect(session.step == .still && session.progress > 0.3 && session.progress < 0.5)
        feed(head.rest(2))
        #expect(session.step == .nod)
        feed(head.nod())
        #expect(session.repetitions == 1 && abs(session.progress - 0.2) < 0.01)
        feed(head.shake())   // not a nod: not counted
        #expect(session.repetitions == 1)
        for _ in 0..<4 { feed(head.nod()) }
        #expect(session.step == .shake)
        for _ in 0..<5 { feed(head.shake()) }
        #expect(session.step == .tiltLeft)
        feed(head.tilt(by: 20) + head.rest(1.5))   // the wrong side
        #expect(session.step == .tiltLeft && session.progress == 0)
        feed(head.tilt(by: -40) + head.rest(1.5))
        #expect(session.step == .tiltRight)
        feed(head.tilt(by: 42) + head.rest(1.5))
        #expect(session.step == .natural && session.profile == nil)
        feed(head.tilt(by: -22) + head.rest(21))
        #expect(session.step == .done)
    }

    @Test func profileHoldsThePoseTheTiltsAndTheExamples() {
        var head = Head()
        let p = head.calibrate()
        #expect(abs(p.viewPitch - -20) < 1 && abs(p.neutralRoll - 1) < 1)
        #expect(abs(p.tiltLeft - 21) < 1.5 && abs(p.tiltRight - 20) < 1.5)
        #expect(p.stillAccel > 0.003 && p.stillAccel < 0.008)
        #expect(p.examples.count { $0.label == .nod } == 5)
        #expect(p.examples.count { $0.label == .shake } == 5)
        #expect(p.examples.count { $0.label == .none } >= 8)
        #expect(p.examples.allSatisfy { $0.source == .calibration && $0.features.count == GestureFeatures.count })
    }

    @Test func uprightIsTheStillStepsRoll() {
        // The fixture's head rests at a roll of 1° (AirPods sit at an angle): that is upright, not a tilt.
        var head = Head()
        var session = CalibrationSession()
        for s in head.rest(1) { session.feed(s) }
        #expect(session.upright == nil)
        for s in head.rest(2) { session.feed(s) }
        #expect(session.step == .nod)
        #expect(abs((session.upright ?? 0) - head.roll) < 0.5)
    }

    @Test func movingDuringTheStillStepStartsItOver() {
        var head = Head()
        var session = CalibrationSession()
        for s in head.rest(2) + head.nod() + head.rest(1) { session.feed(s) }
        #expect(session.step == .still)
        for s in head.rest(1) { session.feed(s) }
        #expect(session.step == .nod)
    }

    @Test func everyCalibrationTakeIsRecognisedFromTheOthers() {
        var head = Head()
        let check = GestureModel(head.calibrate().examples).selfCheck()
        #expect(check[.nod]?.recognised == 5 && check[.nod]?.of == 5)
        #expect(check[.shake]?.recognised == 5 && check[.shake]?.of == 5)
    }
}

struct HeadGestureRecognizerTests {
    /// A calibrated person, sitting still for a second with the recogniser running.
    private func calibrated(seed: UInt64 = 1) -> (Head, HeadGestureRecognizer) {
        var head = Head(seed: seed)
        var r = HeadGestureRecognizer(profile: head.calibrate())
        _ = r.outputs(head.rest())
        return (head, r)
    }

    @Test func aGestureOutOfNowhereIsNothing() {
        // The stream has only just started: nothing says the head was still before.
        var head = Head()
        var r = HeadGestureRecognizer(profile: head.calibrate())
        #expect(r.gestures(head.nod()).isEmpty)
    }

    @Test func nodsAndShakesLikeTheCalibratedOnesAreRecognised() {
        var (head, r) = calibrated()
        #expect(r.gestures(head.nod(peak: 95, hz: 2.1)) == ["nod"])
        #expect(r.gestures(head.shake(peak: 115, hz: 1.9)) == ["shake"])
        #expect(r.gestures(head.nod(peak: 110, hz: 1.9) + head.nod(peak: 90)) == ["nod", "nod"])
    }

    @Test func aGestureComesWithItsFeaturesAndATiltWithout() throws {
        var (head, r) = calibrated()
        guard case .gesture(.nod, let features) = try #require(r.outputs(head.nod()).first) else {
            Issue.record("not a nod")
            return
        }
        #expect(features?.count == GestureFeatures.count)
        guard case .gesture(.tiltLeft, let none) = try #require(r.outputs(head.tilt(by: -20) + head.rest(0.5)).first) else {
            Issue.record("not a tilt")
            return
        }
        #expect(none == nil)
    }

    @Test func everydayMovementIsNothing() {
        var (head, r) = calibrated()
        // Bending down to pick something up and coming back.
        #expect(r.gestures(head.pitch(by: -50, over: 0.7) + head.rest(0.3) + head.pitch(by: 50, over: 0.7) + head.rest()).isEmpty)
        // Looking aside and back.
        #expect(r.gestures(head.turn(by: 40) + head.turn(by: -40)).isEmpty)
        // Looking down at a phone for a while.
        #expect(r.gestures(head.pitch(by: -30) + head.rest(3) + head.pitch(by: 30) + head.rest()).isEmpty)
        // A long wobble of everything at once.
        #expect(r.gestures(head.move(2.5) { (40 * sin(5 * $0), 30 * sin(3 * $0), 50 * sin(4 * $0)) } + head.rest()).isEmpty)
    }

    @Test func aNodWhileWalkingAboutIsNothing() {
        var (head, r) = calibrated()
        head.accel = 0.15
        #expect(r.gestures(head.rest(2) + head.nod() + head.nod()).isEmpty)
        head.accel = 0.005
        #expect(r.gestures(head.rest(2) + head.nod()) == ["nod"])
    }

    @Test func aNodFromABentOverHeadIsNothing() {
        var (head, r) = calibrated()
        #expect(r.gestures(head.pitch(by: -40) + head.rest(1) + head.nod()).isEmpty)
    }

    @Test func aMuchSmallerNodIsANearMissUntilItsKeyTeachesIt() throws {
        var (head, r) = calibrated()
        let small = { (h: inout Head) in h.nod(peak: 52, hz: 2.4) }
        guard case .nearMiss(.nod, let features) = try #require(r.outputs(small(&head)).first) else {
            Issue.record("not a near miss")
            return
        }
        r.update { $0.learn(features, as: .nod, source: .corrected) }
        #expect(r.gestures(small(&head)) == ["nod"])
        #expect(r.gestures(head.nod()) == ["nod"])   // the calibrated nod still is one
    }

    @Test func anUndoneGestureIsNotActedOnAgain() throws {
        var (head, r) = calibrated()
        // A fast, shallow nod that passes as one.
        let quick = { (h: inout Head) in h.nod(peak: 75, hz: 2.3) }
        guard case .gesture(.nod, let features?) = try #require(r.outputs(quick(&head)).first) else {
            Issue.record("not a nod")
            return
        }
        r.update { $0.learn(features, as: .none, source: .undone) }
        #expect(r.gestures(quick(&head)).isEmpty)
        #expect(r.gestures(head.nod(peak: 105, hz: 1.9)) == ["nod"])
    }

    @Test func aCorrectionOverrulesAnUndoThatLooksLikeIt() throws {
        var (head, r) = calibrated()
        guard case .gesture(.nod, let features?) = try #require(r.outputs(head.nod()).first) else {
            Issue.record("not a nod")
            return
        }
        r.update { $0.learn(features, as: .none, source: .undone) }   // a mistaken ⌘Z
        // That very movement is now a near miss; one undo of an ordinary nod doesn't end nodding, though.
        #expect(GestureModel(r.profile.examples).classify(features) == .nearMiss(.nod))
        #expect(r.gestures(head.nod(peak: 120, hz: 2.2)) == ["nod"])
        r.update { $0.learn(features, as: .nod, source: .corrected) }
        #expect(GestureModel(r.profile.examples).classify(features) == .gesture(.nod))
        #expect(!r.profile.examples.contains { $0.source == .undone })
        // And the other way: an undo drops the learnt gestures that look like it, never the calibrated ones.
        r.update { $0.learn(features, as: .none, source: .undone) }
        #expect(!r.profile.examples.contains { $0.source == .corrected })
        #expect(r.profile.examples.count { $0.label == .nod && $0.source == .calibration } == 5)
    }

    @Test func learningFromEverySuccessNeverMakesItStricter() throws {
        var (head, r) = calibrated()
        // The slowest and the fastest calibrated nods, before and after forty identical confirmed ones.
        guard case .gesture(.nod, let features?) = try #require(r.outputs(head.nod()).first) else {
            Issue.record("not a nod")
            return
        }
        for _ in 0..<60 { r.update { $0.learn(features, as: .nod, source: .confirmed) } }
        #expect(r.profile.examples.count { $0.label == .nod && $0.source == .confirmed } == 40)
        #expect(r.profile.examples.count { $0.label == .nod && $0.source == .calibration } == 5)
        #expect(r.gestures(head.nod(peak: 85, hz: 1.8)) == ["nod"])
        #expect(r.gestures(head.nod(peak: 125, hz: 2.2)) == ["nod"])
    }

    @Test func anotherPersonCalibratesToTheirOwnGestures() {
        // Someone whose nod is slow and deep: recognised by their profile, not by the first person's.
        var slow = Head(seed: 7)
        var session = CalibrationSession()
        var all = slow.rest(3)
        for i in 0..<5 { all += slow.nod(peak: 45 + 3 * Double(i), hz: 0.9 + 0.05 * Double(i)) }
        for i in 0..<5 { all += slow.shake(peak: 60 + 4 * Double(i), hz: 1.0 + 0.05 * Double(i)) }
        all += slow.tilt(by: -12) + slow.rest(1.5) + slow.tilt(by: 24) + slow.rest(1.5) + slow.tilt(by: -12) + slow.rest(22)
        for s in all { session.feed(s) }
        var theirs = HeadGestureRecognizer(profile: session.profile!)
        var first = Head()
        var mine = HeadGestureRecognizer(profile: first.calibrate())
        _ = slow.rest(60)   // past the first person's clock, so both recognisers can watch this head
        let still = slow.rest()
        _ = theirs.outputs(still)
        _ = mine.outputs(still)
        let nod = slow.nod(peak: 50, hz: 1.0)
        #expect(theirs.gestures(nod) == ["nod"])
        #expect(mine.gestures(nod).isEmpty)
        // Their tilt is shallower too.
        let tilt = slow.tilt(by: -10) + slow.rest(0.5)
        #expect(theirs.gestures(tilt) == ["left"])
        #expect(mine.gestures(tilt).isEmpty)
    }
}

struct TiltTrackerTests {
    private func calibrated() -> (Head, HeadGestureRecognizer) {
        var head = Head()
        var r = HeadGestureRecognizer(profile: head.calibrate())
        _ = r.outputs(head.rest())
        return (head, r)
    }

    private func tilts(_ r: inout HeadGestureRecognizer, _ samples: [HeadSample]) -> [(t: Double, held: Double, seek: Double)] {
        var out: [(Double, Double, Double)] = []
        for s in samples {
            guard case .gesture(let g, _)? = r.feed(s) else { continue }
            switch g {
            case .tiltLeft(let held), .tiltRight(let held): out.append((s.t, held, g.seekSeconds ?? 0))
            default: break
            }
        }
        return out
    }

    @Test func aHeldTiltSeeksThenRepeatsFasterAndFurther() throws {
        var (head, r) = calibrated()
        let start = head.t
        let e = tilts(&r, head.tilt(by: -20) + head.rest(12))
        let first = try #require(e.first)
        #expect(first.t - start >= 0.5 && first.t - start <= 1.0)
        let gaps = zip(e.dropFirst(), e).map { $0.t - $1.t }
        #expect(abs(gaps[0] - 1.0) < 0.05)
        #expect(zip(gaps.dropFirst(), gaps).allSatisfy { $0 <= $1 + 0.03 })
        #expect(abs(try #require(gaps.last) - 0.25) < 0.05)
        #expect(e.first?.seek == -10 && e.last?.seek == -30)
        #expect(HeadGesture.tiltRight(held: 4).seekSeconds == 20)
    }

    @Test func aTiltShallowerThanMostOfTheCalibratedOneIsNothing() {
        var (head, r) = calibrated()
        #expect(tilts(&r, head.tilt(by: -9) + head.rest(3)).isEmpty)   // calibrated at 21°, so 12.6° is needed
        #expect(!tilts(&r, head.tilt(by: -5) + head.rest(1)).isEmpty)
    }

    @Test func comingBackUprightIsNotATiltTheOtherWay() {
        var (head, r) = calibrated()
        let e = tilts(&r, head.tilt(by: -20) + head.rest(30) + head.tilt(by: 20) + head.rest(10))
        #expect(e.allSatisfy { $0.seek < 0 })
        #expect(e.allSatisfy { $0.held < 20 })   // lying on a side: it stops after 20 s
        #expect(!tilts(&r, head.tilt(by: -20) + head.rest(1)).isEmpty)   // and works again after
    }

    @Test func startingTiltedSeeksNothingUntilUprightOnce() {
        var head = Head()
        let profile = head.calibrate()
        var r = HeadGestureRecognizer(profile: profile)
        let tilted = head.tilt(by: -25)
        #expect(tilts(&r, head.rest(5)).isEmpty)
        _ = tilted
        #expect(tilts(&r, head.tilt(by: 25) + head.rest(2)).isEmpty)
        #expect(!tilts(&r, head.tilt(by: -20) + head.rest(1)).isEmpty)
    }

    @Test func aTiltWhileBentOverOrWalkingIsNothing() {
        var (head, r) = calibrated()
        #expect(tilts(&r, head.pitch(by: -45) + head.tilt(by: -20) + head.rest(3)).isEmpty)
        _ = r.outputs(head.tilt(by: 20) + head.pitch(by: 45) + head.rest(2))
        head.accel = 0.15
        #expect(tilts(&r, head.rest(2) + head.tilt(by: -20) + head.rest(3)).isEmpty)
    }

    @Test func leaningBackALittleIsStillWatching() {
        var (head, r) = calibrated()
        // Leaning back 25° and staying: inside the posture range a new profile starts with.
        _ = r.outputs(head.pitch(by: 25) + head.rest(6))
        #expect(!tilts(&r, head.tilt(by: -20) + head.rest(1)).isEmpty)
    }

    @Test func sittingDifferentlyThanInCalibrationStillCounts() {
        // Calibrated looking down at the sheet; watching, the head is 17° higher.
        var (head, r) = calibrated()
        _ = r.outputs(head.pitch(by: 17) + head.rest(8))
        #expect(!tilts(&r, head.tilt(by: -20) + head.rest(1)).isEmpty)
        #expect(r.gestures(head.tilt(by: 20) + head.rest(1) + head.nod()) == ["nod"])
    }

    @Test func anUndoneTiltNeedsADeeperTiltNextTime() {
        var (head, r) = calibrated()
        #expect(!tilts(&r, head.tilt(by: -13.5) + head.rest(1)).isEmpty)
        r.update { $0.tiltUndone(left: true) }
        #expect(tilts(&r, head.tilt(by: 13.5) + head.rest(1) + head.tilt(by: -13.5) + head.rest(1)).isEmpty)
        #expect(!tilts(&r, head.tilt(by: 13.5) + head.rest(1) + head.tilt(by: 13.5) + head.rest(1)).isEmpty)   // the right side is as it was
        var p = r.profile
        for _ in 0..<20 { p.tiltUndone(left: true) }
        #expect(p.tiltFactorLeft == 0.9)
    }

    @Test func aTiltThatFallsShortIsANearMissAndItsArrowKeyTeachesAShallowerTilt() {
        var (head, r) = calibrated()
        // 10° of the 12.6° needed, held: reported once, and not on the way into a full tilt.
        let short = head.tilt(by: -10) + head.rest(1.5)
        #expect(r.outputs(short) == [.tiltNearMiss(left: true)])
        #expect(!r.outputs(head.tilt(by: 10) + head.rest(1) + head.tilt(by: -20) + head.rest(0.5)).contains(.tiltNearMiss(left: true)))
        _ = r.outputs(head.tilt(by: 20) + head.rest(1))
        for _ in 0..<3 { r.update { $0.tiltCorrected(left: true) } }
        #expect(!tilts(&r, head.tilt(by: -10) + head.rest(1)).isEmpty)
        #expect(tilts(&r, head.tilt(by: 10) + head.rest(1) + head.tilt(by: 10) + head.rest(1)).isEmpty)   // the right side is as it was
        var p = r.profile
        for _ in 0..<20 { p.tiltCorrected(left: true) }
        #expect(p.tiltFactorLeft == 0.35)
    }

    @Test func howMuchPostureVariesIsLearntFromTheGesturesThatStood() throws {
        var head = Head()
        var p = head.calibrate()
        let before = TiltTracker.Settings(p).pitchGate
        // Nods that stood with the head 30° higher and lower than usual: that much is normal for this person now.
        var high = try #require(p.examples.first { $0.label == .nod }).features, low = high
        high[GestureFeatures.pitchOffset] = 3
        low[GestureFeatures.pitchOffset] = -3
        p.learn(high, as: .nod, source: .confirmed)
        p.learn(low, as: .nod, source: .confirmed)
        let wider = TiltTracker.Settings(p).pitchGate
        #expect(wider > before)
        // Many more at the usual pitch don't narrow it again.
        let usual = try #require(p.examples.first { $0.label == .nod }).features
        for _ in 0..<38 { p.learn(usual, as: .nod, source: .confirmed) }
        #expect(TiltTracker.Settings(p).pitchGate >= before)
    }
}

private final class MemoryKey: GestureKeyStore, @unchecked Sendable {
    var stored: SymmetricKey?
    /// The keychain can't be read right now.
    var locked = false
    func key(create: Bool) throws -> SymmetricKey? {
        if locked { throw CocoaError(.fileReadNoPermission) }
        if stored == nil, create { stored = SymmetricKey(size: .bits256) }
        return stored
    }
    func delete() throws { stored = nil }
}

struct GestureProfileStoreTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "GestureProfileStoreTests-\(UUID().uuidString)/head-gestures")
    }

    private var profile: GestureProfile {
        GestureProfile(viewPitch: -20, neutralRoll: 1, stillAccel: 0.005, tiltLeft: 21, tiltRight: 20,
                       examples: [GestureExample(label: .nod, features: Array(repeating: 0.5, count: GestureFeatures.count),
                                                 source: .calibration)])
    }

    @Test func savesAndLoads() throws {
        let store = GestureProfileStore(file: file(), keys: MemoryKey())
        #expect(store.load() == nil)
        try store.save(profile)
        #expect(store.load() == profile)
    }

    @Test func theFileTellsNothingWithoutTheKey() throws {
        let url = file(), keys = MemoryKey()
        try GestureProfileStore(file: url, keys: keys).save(profile)
        let raw = try Data(contentsOf: url)
        for word in ["examples", "nod", "viewPitch", "calibration"] {
            #expect(raw.range(of: Data(word.utf8)) == nil)
        }
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Another key (or none) doesn't open it, and the useless file is removed.
        #expect(GestureProfileStore(file: url, keys: MemoryKey()).load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aLockedKeychainLosesNothing() throws {
        let url = file(), keys = MemoryKey()
        let store = GestureProfileStore(file: url, keys: keys)
        try store.save(profile)
        keys.locked = true
        #expect(store.load() == nil)
        keys.locked = false
        #expect(store.load() == profile)
    }

    @Test func aChangedFileDoesNotOpen() throws {
        let url = file(), keys = MemoryKey()
        let store = GestureProfileStore(file: url, keys: keys)
        try store.save(profile)
        var raw = try Data(contentsOf: url)
        raw[raw.count / 2] ^= 1
        try raw.write(to: url)
        #expect(store.load() == nil)
    }

    @Test func resetDeletesTheFileAndTheKey() throws {
        let url = file(), keys = MemoryKey()
        let store = GestureProfileStore(file: url, keys: keys)
        try store.save(profile)
        try store.reset()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(keys.stored == nil)
        #expect(store.load() == nil)
        try store.reset()   // nothing to delete is fine
    }
}
