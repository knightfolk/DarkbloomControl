// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DarkbloomMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkbloomTelemetry", targets: ["DarkbloomTelemetry"]),
        .executable(name: "DarkbloomMonitor", targets: ["DarkbloomMonitor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "DarkbloomTelemetry",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "DarkbloomMonitor",
            dependencies: ["DarkbloomTelemetry", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources/DarkbloomLogo.svg", "Resources/darkbloom-mark.svg", "Resources/darkbloom-menubar.svg"],
            resources: [
                .copy("Resources/dc-mark.svg"),
                .copy("Resources/dc-menubar.svg"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/model-qwen.svg"),
                .copy("Resources/model-openai.svg"),
                .copy("Resources/model-google.svg"),
                .copy("Resources/model-nvidia.svg"),
                .copy("Resources/model-prismml.svg"),
                .copy("Resources/MODEL-ICONS-LICENSE.txt"),
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "DarkbloomTelemetryTests",
            dependencies: ["DarkbloomTelemetry", "DarkbloomMonitor"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
