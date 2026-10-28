// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FastShot",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FastShot", targets: ["FastShot"]),
    ],
    targets: [
        // Platform-neutral model, drawing and export code; everything here is testable headless.
        .target(name: "FastShotCore"),
        .executableTarget(name: "FastShot", dependencies: ["FastShotCore"]),
        .testTarget(name: "FastShotCoreTests", dependencies: ["FastShotCore"]),
    ],
    swiftLanguageModes: [.v5]
)
