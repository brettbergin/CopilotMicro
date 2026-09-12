// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotMicroKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CopilotMicroCore", targets: ["CopilotMicroCore"])
    ],
    dependencies: [
        // Keep the verified CLT-compatible runtime pinned and confined to the test target.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4")
    ],
    targets: [
        .target(name: "CopilotMicroCore"),
        .testTarget(
            name: "CopilotMicroCoreTests",
            dependencies: [
                "CopilotMicroCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
