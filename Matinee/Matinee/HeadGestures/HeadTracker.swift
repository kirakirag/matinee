import CoreMotion
import MatineeKit

/// AirPods head motion (Pro, Max, 3rd generation and later) as `HeadSample`s on the main thread.
/// The first start asks for Motion & Fitness access.
@MainActor final class HeadTracker {
    private let manager = CMHeadphoneMotionManager()
    private(set) var isRunning = false
    var onSample: ((HeadSample) -> Void)?

    static var isDenied: Bool {
        let s = CMHeadphoneMotionManager.authorizationStatus()
        return s == .denied || s == .restricted
    }

    func start() {
        guard !isRunning, manager.isDeviceMotionAvailable, !Self.isDenied else { return }
        isRunning = true
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.handle(motion) }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
    }

    private func handle(_ m: CMDeviceMotion) {
        guard isRunning else { return }
        let deg = 180 / Double.pi, a = m.userAcceleration
        onSample?(HeadSample(
            t: m.timestamp,
            pitchRate: m.rotationRate.x * deg, rollRate: m.rotationRate.y * deg, yawRate: m.rotationRate.z * deg,
            pitch: m.attitude.pitch * deg, roll: m.attitude.roll * deg, yaw: m.attitude.yaw * deg,
            accel: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()))
    }
}
