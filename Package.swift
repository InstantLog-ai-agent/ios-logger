// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SensorCoreiOS",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SensorCoreiOS",
            targets: ["SensorCoreiOS"]
        ),
    ],
    targets: [
        .target(
            name: "SensorCoreiOS",
            dependencies: [],
            path: "Sources/SensorCoreiOS"
        ),
        .testTarget(
            name: "SensorCoreiOSTests",
            dependencies: ["SensorCoreiOS"],
            path: "Tests/SensorCoreiOSTests"
        ),
    ]
)
