// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/gordonbeeming/mac-reactions", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "ClaudeBarCore"
        ),
        .executableTarget(
            name: "ClaudeBar",
            dependencies: ["ClaudeBarCore", .product(name: "MacReactions", package: "mac-reactions")]
        ),
        .testTarget(
            name: "ClaudeBarCoreTests",
            dependencies: ["ClaudeBarCore"]
        )
    ]
)
