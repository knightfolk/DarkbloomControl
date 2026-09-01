// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DarkbloomMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkbloomTelemetry", targets: ["DarkbloomTelemetry"]),
        .executable(name: "DarkbloomMonitor", targets: ["DarkbloomMonitor"]),
    ],
    targets: [
        .target(name: "DarkbloomTelemetry"),
        .executableTarget(
            name: "DarkbloomMonitor",
            dependencies: ["DarkbloomTelemetry"]
        ),
        .testTarget(
            name: "DarkbloomTelemetryTests",
            dependencies: ["DarkbloomTelemetry"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
