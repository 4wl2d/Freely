// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreelyCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FreelyCore", targets: ["FreelyCore"]),
               .executable(name: "FreelyCoreBenchmarks", targets: ["FreelyCoreBenchmarks"])],
    targets: [
        .target(name: "FreelyCore"),
        .executableTarget(name: "FreelyCoreBenchmarks", dependencies: ["FreelyCore"]),
        .testTarget(name: "FreelyCoreTests", dependencies: ["FreelyCore"])
    ],
    swiftLanguageModes: [.v6]
)
