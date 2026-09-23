// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinnowLightningChainWatch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "chain-watch", targets: ["ChainWatch"])],
    dependencies: [.package(path: "../.deps/winnow")],
    targets: [
        .target(name: "ChainWatchCore", dependencies: [.product(name: "WalletCore", package: "winnow")]),
        .executableTarget(name: "ChainWatch", dependencies: ["ChainWatchCore", .product(name: "WalletCore", package: "winnow")]),
        .testTarget(name: "ChainWatchTests", dependencies: ["ChainWatchCore", .product(name: "WalletCore", package: "winnow")]),
    ]
)
