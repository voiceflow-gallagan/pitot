// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "conformance",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Core"),
    ],
    targets: [
        .target(name: "ConformanceKit", dependencies: [.product(name: "PitotCore", package: "Core")]),
        .executableTarget(name: "conformance", dependencies: ["ConformanceKit"]),
        .testTarget(name: "ConformanceKitTests", dependencies: ["ConformanceKit"]),
    ]
)
