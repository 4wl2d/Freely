// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "STTGate",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "EndpointVAD", path: "EndpointVAD", publicHeadersPath: "include"),
        .executableTarget(name: "stt-gate", dependencies: [
            "EndpointVAD",
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "WhisperKit", package: "WhisperKit")
        ], path: "Sources")
    ],
    swiftLanguageModes: [.v6]
)
