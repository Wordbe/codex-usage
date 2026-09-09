// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "codexusage", targets: ["CodexUsage"])
    ],
    targets: [
        .executableTarget(
            name: "CodexUsage",
            path: "Sources/CodexUsage"
        ),
        .testTarget(name: "CodexUsageTests", dependencies: ["CodexUsage"])
    ]
)
