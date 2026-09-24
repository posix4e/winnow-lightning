// swift-tools-version: 6.0
import PackageDescription

// Build the pinned native core with scripts/build-lightning.sh first.
// This optional package leaves Winnow's ordinary SwiftPM build independent
// of Rust and of generated binary artifacts.
let package = Package(
    name: "WinnowLightning",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LightningCore", targets: ["LightningCore"])],
    dependencies: [.package(name: "Winnow", path: "..")],
    targets: [
        .binaryTarget(name: "CLightningBridge", path: "Artifacts/CLightningBridge.xcframework"),
        .target(name: "LightningCore", dependencies: ["CLightningBridge", .product(name: "WalletCore", package: "Winnow")],
                linkerSettings: [.linkedFramework("Security"), .linkedLibrary("resolv")]),
        .testTarget(name: "LightningCoreTests", dependencies: ["LightningCore", .product(name: "TestSupport", package: "Winnow")]),
    ])
