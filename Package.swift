// swift-tools-version: 5.9
// Open Dictation — native macOS custom dictation app.
// SwiftPM is the reproducible build system (works with Xcode or CLT-only hosts).
import PackageDescription

let package = Package(
    name: "OpenDictation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenDictationCore", targets: ["OpenDictationCore"]),
        .executable(name: "OpenDictation", targets: ["OpenDictationApp"])
    ],
    targets: [
        .target(
            name: "OpenDictationCore",
            path: "Sources/OpenDictationCore"
        ),
        .executableTarget(
            name: "OpenDictationApp",
            dependencies: ["OpenDictationCore"],
            path: "Sources/OpenDictationApp"
        ),
        // Shared fakes/stubs (no XCTest): used by the XCTest suite AND by the
        // dependency-free self-test executable that runs on CLT-only hosts.
        .target(
            name: "OpenDictationTestSupport",
            dependencies: ["OpenDictationCore"],
            path: "Sources/OpenDictationTestSupport"
        ),
        .executableTarget(
            name: "OpenDictationSelfTest",
            dependencies: ["OpenDictationCore", "OpenDictationTestSupport"],
            path: "Sources/OpenDictationSelfTest"
        ),
        .testTarget(
            name: "OpenDictationCoreTests",
            dependencies: ["OpenDictationCore", "OpenDictationTestSupport"],
            path: "Tests/OpenDictationCoreTests"
        )
    ]
)
