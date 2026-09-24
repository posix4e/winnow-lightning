// swift-tools-version: 6.0
import PackageDescription

// Build the pinned native core with scripts/build-lightning.sh first.
// This optional package leaves Winnow's ordinary SwiftPM build independent
// of Rust and of generated binary artifacts.
let package = Package(
    name: "WinnowLightning",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LightningCore", targets: ["LightningCore"]),
               .library(name: "LightningLab", targets: ["LightningLab"]),
               .executable(name: "winnow-lightning-lab", targets: ["LightningLabCLI"])],
    dependencies: [.package(name: "Winnow", path: "..")],
    targets: [
        .binaryTarget(name: "CLightningBridge", path: "Artifacts/CLightningBridge.xcframework"),
        .target(name: "LightningCore", dependencies: ["CLightningBridge", .product(name: "WalletCore", package: "Winnow")],
                linkerSettings: [.linkedFramework("Security"), .linkedLibrary("resolv")]),
        .target(name: "LightningLab", dependencies: ["LightningCore", .product(name: "WalletCore", package: "Winnow"), .product(name: "TestSupport", package: "Winnow")]),
        .executableTarget(name: "LightningLabCLI", dependencies: ["LightningLab"]),
        .testTarget(name: "LightningCoreTests", dependencies: ["LightningCore", .product(name: "TestSupport", package: "Winnow")]),
    ])
