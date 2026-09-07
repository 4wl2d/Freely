// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingCopilot",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MeetingCopilot", targets: ["MeetingCopilot"])],
    dependencies: [
        .package(path: "Packages/CopilotCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "MeetingCopilot",
            dependencies: [
                .product(name: "CopilotCore", package: "CopilotCore"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "MeetingCopilot",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "MeetingCopilotTests", dependencies: ["MeetingCopilot"], path: "Tests", exclude: ["Fixtures"])
    ],
    swiftLanguageModes: [.v6]
)
