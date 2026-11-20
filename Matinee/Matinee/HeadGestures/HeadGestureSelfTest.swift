import AppKit
import MatineeKit

/// `-headgestureselftest YES`: inside the app's sandbox, seals a profile with a key made in the keychain, reads it
/// back, and resets both, under names of its own (the real calibration is untouched). Prints
/// `HEADGESTURESELFTEST ok`, or what failed, then quits.
enum HeadGestureSelfTest {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "headgestureselftest") }

    static func run() {
        let file = URL.applicationSupportDirectory.appending(path: "Matinee/head-gestures-selftest")
        let keys = KeychainGestureKey(service: (Bundle.main.bundleIdentifier ?? "Matinee") + ".head-gestures-selftest")
        let store = GestureProfileStore(file: file, keys: keys)
        let profile = GestureProfile(viewPitch: -20, neutralRoll: 1, stillAccel: 0.005, tiltLeft: 21, tiltRight: 20,
                                     examples: [])
        do {
            try store.save(profile)
            guard store.load() == profile else { return finish("HEADGESTURESELFTEST failed load after save") }
            guard let raw = try? Data(contentsOf: file), raw.range(of: Data("viewPitch".utf8)) == nil else {
                return finish("HEADGESTURESELFTEST failed file is readable")
            }
            // A second store (the next launch) finds the same key.
            guard GestureProfileStore(file: file, keys: keys).load() == profile else {
                return finish("HEADGESTURESELFTEST failed key not found again")
            }
            try store.reset()
            guard store.load() == nil, try keys.key(create: false) == nil else {
                return finish("HEADGESTURESELFTEST failed reset left something")
            }
            finish("HEADGESTURESELFTEST ok")
        } catch {
            try? store.reset()
            finish("HEADGESTURESELFTEST failed \(error)")
        }
    }

    private static func finish(_ line: String) {
        print(line)
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
