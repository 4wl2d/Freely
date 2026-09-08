// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Freely",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Freely", targets: ["Freely"])],
    dependencies: [
        .package(path: "Packages/FreelyCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "Freely",
            dependencies: [
                .product(name: "FreelyCore", package: "FreelyCore"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Freely",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "FreelyTests", dependencies: ["Freely"], path: "Tests", exclude: ["Fixtures"])
    ],
    swiftLanguageModes: [.v6]
)
