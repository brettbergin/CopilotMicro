// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotMicroKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CopilotMicroCore", targets: ["CopilotMicroCore"]),
        .library(name: "CopilotMicroBridge", targets: ["CopilotMicroBridge"]),
        .library(name: "CopilotMicroStorage", targets: ["CopilotMicroStorage"]),
    ],
    dependencies: [
        // Keep the verified CLT-compatible runtime pinned and confined to the test target.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4")
    ],
    targets: [
        .target(name: "CopilotMicroCore"),
        .target(
            name: "CopilotMicroBridge",
            dependencies: ["CopilotMicroCore"]
        ),
        .target(
            name: "CopilotMicroStorage",
            dependencies: ["CopilotMicroCore"]
        ),
        .testTarget(
            name: "CopilotMicroCoreTests",
            dependencies: [
                "CopilotMicroCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "CopilotMicroBridgeTests",
            dependencies: [
                "CopilotMicroBridge",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "CopilotMicroStorageTests",
            dependencies: [
                "CopilotMicroStorage",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
