import AppKit
import CryptoKit
import MatineeKit
import Observation

/// Head gestures for the app: owns the learnt profile (sealed on disk), runs calibration, and turns the AirPods'
/// motion into gestures for the player while one is open.
@MainActor @Observable final class HeadGestureService {
    /// A profile exists: the feature can be switched on.
    private(set) var isCalibrated = false
    /// The calibration under way, while its sheet is open.
    private(set) var calibration: CalibrationSession?
    /// During calibration: how the head is turned from where it rests (degrees), for the on-screen head.
    private(set) var pose = (pitch: 0.0, yaw: 0.0, roll: 0.0)
    /// During calibration: motion is arriving (AirPods in and connected).
    private(set) var isReceiving = false
    /// During calibration: Motion & Fitness access was refused.
    private(set) var accessDenied = false
    /// Why the finished calibration couldn't be saved.
    private(set) var saveError: String?
    /// How many of each gesture's calibration takes the others recognise, for the sheet's last page.
    private(set) var selfCheck: [GestureLabel: (recognised: Int, of: Int)] = [:]

    /// Set by the player: what to do with a recognised gesture or a near miss.
    @ObservationIgnored var onOutput: ((HeadGestureRecognizer.Output) -> Void)?
    @ObservationIgnored private let tracker = HeadTracker()
    @ObservationIgnored private let store: GestureProfileStore
    @ObservationIgnored private var recognizer: HeadGestureRecognizer?
    @ObservationIgnored private var playerOpen = false
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastSample = ContinuousClock.now - .seconds(60)
    #if DEBUG
    @ObservationIgnored private var lastReport: String?
    #endif
    /// The finished calibration was handed to `finish` (once).
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var base: (pitch: Double, yaw: Double)?
    @ObservationIgnored private var lastT = 0.0

    /// Settings' "Head gestures with AirPods".
    static var isSwitchedOn: Bool { UserDefaults.standard.bool(forKey: "headGestures") }
    static var isDenied: Bool { HeadTracker.isDenied }
    /// Starting and stopping the AirPods' motion stream switches what they send over Bluetooth, and doing it often
    /// can drop their audio in every app. So it keeps running this long after it's last needed.
    private static let linger = Duration.seconds(30)

    init(store: GestureProfileStore = GestureProfileStore(
        file: URL.applicationSupportDirectory.appending(path: "Matinee/head-gestures"),
        keys: KeychainGestureKey(service: (Bundle.main.bundleIdentifier ?? "Matinee") + ".head-gestures"))) {
        self.store = store
        if let profile = store.load() {
            recognizer = HeadGestureRecognizer(profile: profile)
            isCalibrated = true
        }
        tracker.onSample = { [weak self] in self?.handle($0) }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Gestures are being listened for right now.
    var isListening: Bool { tracker.isRunning && calibration == nil && Self.isSwitchedOn && recognizer != nil }

    /// The player opened or closed (full or mini).
    func playerChanged(open: Bool) {
        playerOpen = open
        sync()
    }

    private func sync() {
        if calibration != nil || (Self.isSwitchedOn && isCalibrated && playerOpen) {
            stopTask?.cancel()
            stopTask = nil
            tracker.start()
        } else if tracker.isRunning, stopTask == nil {
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: Self.linger)
                guard !Task.isCancelled else { return }
                self?.stopTask = nil
                self?.tracker.stop()
            }
        }
    }

    private func handle(_ s: HeadSample) {
        lastSample = .now
        guard calibration != nil else {
            guard Self.isSwitchedOn, playerOpen else { return }
            let output = recognizer?.feed(s)
            #if DEBUG
            // What each movement was taken for and how far it was from the examples (no motion data), on stderr.
            if let report = recognizer?.lastBurst, report != lastReport {
                lastReport = report
                FileHandle.standardError.write(Data("HEAD \(report)\n".utf8))
            }
            if case .gesture(let g, nil)? = output { FileHandle.standardError.write(Data("HEAD \(g)\n".utf8)) }
            if case .tiltNearMiss(let left)? = output { FileHandle.standardError.write(Data("HEAD tilt fell short, left=\(left)\n".utf8)) }
            #endif
            if let output { onOutput?(output) }
            return
        }
        // The on-screen head: pitch and yaw are shown against where the head has been lately, so it faces forward
        // whenever the person does. Roll is against their upright, which the first step learns (tilts are held, so it
        // can't follow); during that step, which is holding still, the head is shown level.
        let dt = min(max(s.t - lastT, 0), 0.1)
        lastT = s.t
        var b = base ?? (s.pitch, s.yaw)
        let turn = (s.yaw - b.yaw + 540).truncatingRemainder(dividingBy: 360) - 180
        b.pitch += (s.pitch - b.pitch) * dt / 4
        b.yaw += turn * dt / 3
        base = b
        pose = (s.pitch - b.pitch, turn, calibration?.upright.map { s.roll - $0 } ?? 0)
        isReceiving = true
        calibration?.feed(s)
        if !finished, let profile = calibration?.profile { finish(profile) }
    }

    // MARK: Calibration

    func beginCalibration() {
        calibration = CalibrationSession()
        finished = false
        saveError = nil
        selfCheck = [:]
        base = nil
        pose = (0, 0, 0)
        isReceiving = false
        accessDenied = Self.isDenied
        sync()
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            // AirPods taken out mid-way: the stream just stops.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let receiving = ContinuousClock.now - self.lastSample < .seconds(1)
                if receiving != self.isReceiving { self.isReceiving = receiving }
                if Self.isDenied != self.accessDenied { self.accessDenied = Self.isDenied }
                if !receiving { self.tracker.start() }   // access granted, or AirPods back in, since the last try
            }
        }
    }

    /// Closes the calibration, finished or not. An unfinished one changes nothing.
    func endCalibration() {
        calibration = nil
        watchTask?.cancel()
        watchTask = nil
        sync()
    }

    private func finish(_ profile: GestureProfile) {
        finished = true
        do {
            try store.save(profile)
            recognizer = HeadGestureRecognizer(profile: profile)
            selfCheck = GestureModel(profile.examples).selfCheck()
            #if DEBUG
            let model = GestureModel(profile.examples)
            let counts = GestureLabel.allCases.map { l in "\(l)=\(profile.examples.count { $0.label == l })" }
            FileHandle.standardError.write(Data("HEAD calibrated \(counts) radius=\(model.radius) selfCheck=\(selfCheck) tilt=\(profile.tiltLeft),\(profile.tiltRight) pitch=\(profile.viewPitch) roll=\(profile.neutralRoll) accel=\(profile.stillAccel)\n".utf8))
            #endif
            isCalibrated = true
            UserDefaults.standard.set(true, forKey: "headGestures")
        } catch {
            saveError = "\(error)"
        }
    }

    /// Forgets everything learnt (the sealed file and its key) and switches head gestures off.
    func reset() {
        saveTask?.cancel()
        try? store.reset()
        recognizer = nil
        isCalibrated = false
        UserDefaults.standard.set(false, forKey: "headGestures")
        sync()
    }

    // MARK: Learning

    /// Changes what was learnt (an example from a gesture that stood, was undone or was corrected) and saves it a
    /// moment later.
    func learn(_ change: (inout GestureProfile) -> Void) {
        guard recognizer != nil else { return }
        recognizer?.update(change)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let profile = self.recognizer?.profile else { return }
            self.saveTask = nil
            try? self.store.save(profile)
        }
    }

    #if DEBUG
    /// For previews: a calibration fed `samples`, with the head turned as `pose`. Nothing is tracked or saved.
    static func preview(samples: [HeadSample], pose: (pitch: Double, yaw: Double, roll: Double) = (0, 0, 0)) -> HeadGestureService {
        let dir = URL.temporaryDirectory.appending(path: "matinee-preview-\(UUID().uuidString)")
        let service = HeadGestureService(store: GestureProfileStore(file: dir.appending(path: "p"), keys: PreviewKey()))
        service.calibration = CalibrationSession()
        for s in samples { service.calibration?.feed(s) }
        service.pose = pose
        service.isReceiving = true
        return service
    }

    private struct PreviewKey: GestureKeyStore {
        func key(create: Bool) throws -> SymmetricKey? { nil }
        func delete() throws {}
    }
    #endif

    /// Saves anything learnt but not yet written (the app is quitting).
    func flush() {
        guard saveTask != nil, let profile = recognizer?.profile else { return }
        saveTask?.cancel()
        saveTask = nil
        try? store.save(profile)
    }
}
