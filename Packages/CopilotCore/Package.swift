// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CopilotCore", targets: ["CopilotCore"]),
               .executable(name: "CopilotCoreBenchmarks", targets: ["CopilotCoreBenchmarks"])],
    targets: [
        .target(name: "CopilotCore"),
        .executableTarget(name: "CopilotCoreBenchmarks", dependencies: ["CopilotCore"]),
        .testTarget(name: "CopilotCoreTests", dependencies: ["CopilotCore"])
    ],
    swiftLanguageModes: [.v6]
)
