// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dictate",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "dictate",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
