// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PitotCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PitotCore", targets: ["PitotCore"]),
    ],
    targets: [
        .target(name: "PitotCore"),
        .testTarget(name: "PitotCoreTests", dependencies: ["PitotCore"]),
    ]
)
