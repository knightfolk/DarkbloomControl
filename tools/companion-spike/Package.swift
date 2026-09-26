// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DarkbloomCompanionSpike",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SpikeCore", targets: ["SpikeCore"]),
        .executable(name: "TLSBridgeHarness", targets: ["TLSBridgeHarness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.1.0"),
    ],
    targets: [
        .target(name: "SpikeCore", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .executableTarget(name: "TLSBridgeHarness", dependencies: ["SpikeCore"]),
        .testTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore"]),
    ]
)
