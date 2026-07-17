// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnthropicUsageBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ccu", targets: ["ccu"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Pure-Foundation core: account index + credentials + usage fetching +
        // auto-prime logic. Shared by the menu-bar app and the `ccu` CLI.
        .target(
            name: "AnthropicUsageCore",
            path: "Sources/AnthropicUsageCore"
        ),
        // Menu-bar app (unchanged behaviour; now depends on Core).
        .executableTarget(
            name: "AnthropicUsageBar",
            dependencies: ["AnthropicUsageCore"],
            path: "Sources/AnthropicUsageBar"
        ),
        // CLI for headless / SSH workflows.
        .executableTarget(
            name: "ccu",
            dependencies: [
                "AnthropicUsageCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ccu"
        )
    ]
)
