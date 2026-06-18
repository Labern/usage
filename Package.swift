// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Usage",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .executableTarget(
            name: "Usage",
            dependencies: ["UsageCore"],
            path: "Sources/ClaudeUsageMonitor"
        ),
        .testTarget(
            name: "UsageTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageTests"
        ),
    ]
)
