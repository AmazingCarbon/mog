// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mog",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: lock state machine, embedding math, alignment, profile storage.
        .target(name: "MogCore"),
        // Camera, Vision landmarks, ArcFace (Core ML), screen lock. Reused by CLI and menu bar.
        .target(
            name: "MogEngine",
            dependencies: ["MogCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI: enroll / test (dry run) / watch / lock-test / status / forget.
        .executableTarget(
            name: "mog",
            dependencies: ["MogCore", "MogEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu-bar app. Same engine; packaged into Mog.app by Scripts/build-app.sh.
        .executableTarget(
            name: "MogBar",
            dependencies: ["MogCore", "MogEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dependency-free checks (this toolchain ships neither XCTest nor swift-testing).
        .executableTarget(name: "MogChecks", dependencies: ["MogCore"], path: "Checks"),
    ]
)
