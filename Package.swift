// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StageLeft",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StageLeft",
            path: "Sources/StageLeft",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
