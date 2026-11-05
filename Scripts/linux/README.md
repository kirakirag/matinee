# MatineeKit on Linux (cloud sessions)

Builds the Foundation-only `MatineeKit` and runs `MatineeKitTests` on Linux, so cloud sessions without Xcode can
check Kit changes. The app target (AppKit/SwiftUI/mpv) can't build here; it still needs the Mac.

    sudo Scripts/linux/setup_chroot.sh      # once per container: Ubuntu 26.04 chroot with Swift 6.1.3
    Scripts/linux/test.sh --filter 'WorkerClientTests|ListingTests'

Shims: `os.Logger` (no-op), `CryptoKit` (re-exports swift-crypto), `SQLite3` (system module), `LinuxCompat.swift`
(`URL.cachesDirectory`/`applicationSupportDirectory`, `CFGetTypeID` for JSON booleans). `sync.sh` copies the sources and
adds `import FoundationNetworking`/`FoundationXML` to each file.

Known Linux-only failures (also on main; Foundation/container differences, not Matinee bugs):
- `bundledWorkerMatchesSource`: `Runtime.bundle` isn't in git.
- `workerCrashFailsPendingAndRestarts`: the worker's exit isn't seen as EOF, so the request times out.
- `timeoutKillsWorkersChildren`: the killed `sleep` stays as an unreaped zombie in the container.
- `RangedStreamTests`: corelibs URLSession against the local test server; some tests fail or hang, so filter them out.
