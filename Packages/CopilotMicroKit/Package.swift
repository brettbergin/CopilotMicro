// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotMicroKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CopilotMicroCore", targets: ["CopilotMicroCore"])
    ],
    targets: [
        .target(name: "CopilotMicroCore")
    ],
    swiftLanguageModes: [.v6]
)
