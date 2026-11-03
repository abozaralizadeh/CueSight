// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CueSightKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShotEngine", targets: ["ShotEngine"]),
        .library(name: "TableVision", targets: ["TableVision"]),
        .library(name: "SceneSim", targets: ["SceneSim"]),
        .library(name: "SessionCore", targets: ["SessionCore"]),
    ],
    targets: [
        .target(name: "ShotEngine"),
        .target(name: "TableVision", dependencies: ["ShotEngine"]),
        .target(name: "SceneSim", dependencies: ["ShotEngine", "TableVision"]),
        .target(name: "SessionCore", dependencies: ["ShotEngine", "TableVision"]),
        .executableTarget(
            name: "cuesight-bench",
            dependencies: ["ShotEngine", "TableVision", "SceneSim", "SessionCore"]
        ),
        .testTarget(name: "ShotEngineTests", dependencies: ["ShotEngine", "SceneSim"]),
        .testTarget(name: "TableVisionTests", dependencies: ["ShotEngine", "TableVision", "SceneSim"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["ShotEngine", "TableVision", "SessionCore", "SceneSim"]),
    ]
)
