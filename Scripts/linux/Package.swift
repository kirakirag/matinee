// swift-tools-version:6.0
// Linux-only harness: builds MatineeKit and runs MatineeKitTests with shims for Apple-only modules.
import PackageDescription
let package = Package(
    name: "MatineeLinux",
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")],
    targets: [
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
        .target(name: "os", path: "Sources/os"),
        .target(name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")], path: "Sources/CryptoKit"),
        .target(name: "MatineeKit", dependencies: ["SQLite3", "os", "CryptoKit"], path: "Sources/MatineeKit",
                swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .testTarget(name: "MatineeKitTests", dependencies: ["MatineeKit", "SQLite3", "CryptoKit"], path: "Tests/MatineeKitTests",
                    exclude: ["Fixtures"], swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
    ])
