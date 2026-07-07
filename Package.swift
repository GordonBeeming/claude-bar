// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "ClaudeBarCore"
        ),
        .executableTarget(
            name: "ClaudeBar",
            dependencies: ["ClaudeBarCore"]
        ),
        .testTarget(
            name: "ClaudeBarCoreTests",
            dependencies: ["ClaudeBarCore"]
        )
    ]
)
