// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stagehand",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Stagehand",
            path: "Sources/Stagehand",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
