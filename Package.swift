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
        .target(
            name: "DarkbloomTelemetry",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "DarkbloomMonitor",
            dependencies: ["DarkbloomTelemetry"],
            resources: [
                .copy("Resources/darkbloom-mark.svg"),
                .copy("Resources/darkbloom-menubar.svg"),
            ]
        ),
        .testTarget(
            name: "DarkbloomTelemetryTests",
            dependencies: ["DarkbloomTelemetry", "DarkbloomMonitor"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
