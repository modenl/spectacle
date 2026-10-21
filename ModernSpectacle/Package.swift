// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ModernSpectacle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ModernSpectacle", targets: ["ModernSpectacleApp"]),
        .executable(name: "spectacle-cli", targets: ["ModernSpectacleCLI"]),
        .library(name: "ModernSpectacleCore", targets: ["ModernSpectacleCore"])
    ],
    targets: [
        .target(name: "ModernSpectacleCore"),
        .target(
            name: "ModernSpectacleServices",
            dependencies: ["ModernSpectacleCore"]
        ),
        .executableTarget(
            name: "ModernSpectacleApp",
            dependencies: [
                "ModernSpectacleCore",
                "ModernSpectacleServices"
            ]
        ),
        .executableTarget(
            name: "ModernSpectacleCLI",
            dependencies: [
                "ModernSpectacleCore",
                "ModernSpectacleServices"
            ]
        ),
        .testTarget(
            name: "ModernSpectacleCoreTests",
            dependencies: ["ModernSpectacleCore"]
        )
    ]
)
