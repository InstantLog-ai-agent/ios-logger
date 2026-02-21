// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "InstantLogiOS",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "InstantLogiOS",
            targets: ["InstantLogiOS"]
        ),
    ],
    targets: [
        .target(
            name: "InstantLogiOS",
            dependencies: [],
            path: "Sources/InstantLogiOS"
        ),
        .testTarget(
            name: "InstantLogiOSTests",
            dependencies: ["InstantLogiOS"],
            path: "Tests/InstantLogiOSTests"
        ),
    ]
)
