import AppKit
import CMpv

/// `-mpvselftest YES`: creates and initialises an mpv handle with the player's options inside the app's
/// sandbox, prints `MPVSELFTEST ok version=<mpv-version>`, then quits.
enum MPVSelfTest {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "mpvselftest") }

    static func run() {
        guard let handle = mpv_create() else { return finish("MPVSELFTEST failed mpv_create") }
        defer { mpv_terminate_destroy(handle) }
        for (name, value) in MPVPlayer.options {
            let rc = mpv_set_option_string(handle, name, value)
            if rc < 0 { return finish("MPVSELFTEST failed option \(name)=\(value) rc=\(rc)") }
        }
        let rc = mpv_initialize(handle)
        if rc < 0 { return finish("MPVSELFTEST failed mpv_initialize rc=\(rc)") }
        guard let version = mpv_get_property_string(handle, "mpv-version") else { return finish("MPVSELFTEST failed mpv-version") }
        defer { mpv_free(version) }
        finish("MPVSELFTEST ok version=\(String(cString: version))")
    }

    private static func finish(_ line: String) {
        print(line)
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
