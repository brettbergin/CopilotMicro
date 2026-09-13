// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotMicroKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CopilotMicroCore", targets: ["CopilotMicroCore"]),
        .library(name: "CopilotMicroBridge", targets: ["CopilotMicroBridge"]),
        .library(name: "CopilotMicroDevice", targets: ["CopilotMicroDevice"]),
        .library(name: "CopilotMicroStorage", targets: ["CopilotMicroStorage"]),
        .library(name: "CopilotMicroTerminal", targets: ["CopilotMicroTerminal"]),
        .executable(name: "CopilotMicroHardwareProbe", targets: ["CopilotMicroHardwareProbe"]),
        .executable(name: "CopilotMicroDeviceSetup", targets: ["CopilotMicroDeviceSetup"]),
        .executable(name: "CopilotMicroInputObserver", targets: ["CopilotMicroInputObserver"]),
        .executable(name: "CopilotMicroLightingProbe", targets: ["CopilotMicroLightingProbe"]),
        .executable(name: "CopilotMicroTerminalProbe", targets: ["CopilotMicroTerminalProbe"]),
        .executable(name: "CopilotMicroGhosttyProbe", targets: ["CopilotMicroGhosttyProbe"]),
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
            dependencies: [
                "CopilotMicroCore",
                "CopilotMicroTerminal",
            ]
        ),
        .target(
            name: "CopilotMicroTerminal",
            dependencies: ["CopilotMicroCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(
            name: "CopilotMicroDevice",
            dependencies: ["CopilotMicroCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "CopilotMicroHardwareProbe",
            dependencies: ["CopilotMicroDevice"]
        ),
        .executableTarget(
            name: "CopilotMicroDeviceSetup",
            dependencies: [
                "CopilotMicroDevice",
                "CopilotMicroStorage",
            ]
        ),
        .executableTarget(
            name: "CopilotMicroInputObserver",
            dependencies: ["CopilotMicroDevice"]
        ),
        .executableTarget(
            name: "CopilotMicroLightingProbe",
            dependencies: [
                "CopilotMicroCore",
                "CopilotMicroDevice",
            ]
        ),
        .executableTarget(
            name: "CopilotMicroTerminalProbe",
            dependencies: ["CopilotMicroTerminal"]
        ),
        .executableTarget(
            name: "CopilotMicroGhosttyProbe",
            dependencies: ["CopilotMicroTerminal"]
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
        .testTarget(
            name: "CopilotMicroTerminalTests",
            dependencies: [
                "CopilotMicroTerminal",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "CopilotMicroDeviceTests",
            dependencies: [
                "CopilotMicroDevice",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
