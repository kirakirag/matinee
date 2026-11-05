// swift-tools-version: 6.2
// Throwaway prototype: in-window libmpv playback timing. Not part of the app.
import PackageDescription

let package = Package(
    name: "PlaybackSpike",
    platforms: [.macOS("27.0")],
    targets: [
        .systemLibrary(name: "CMpv", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .executableTarget(name: "PlaybackSpike", dependencies: ["CMpv"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
