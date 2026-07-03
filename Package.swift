// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnthropicUsageBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AnthropicUsageBar",
            path: "Sources/AnthropicUsageBar"
        )
    ]
)
