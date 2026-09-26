// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotMicro",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "CopilotMicro", targets: ["CopilotMicro"])
    ],
    dependencies: [
        .package(path: "Packages/CopilotMicroKit")
    ],
    targets: [
        .executableTarget(
            name: "CopilotMicro",
            dependencies: [
                .product(name: "CopilotMicroBridge", package: "CopilotMicroKit"),
                .product(name: "CopilotMicroCore", package: "CopilotMicroKit"),
                .product(name: "CopilotMicroDevice", package: "CopilotMicroKit"),
                .product(name: "CopilotMicroTerminal", package: "CopilotMicroKit"),
            ],
            path: "App/Sources"
        )
    ],
    swiftLanguageModes: [.v6]
)
