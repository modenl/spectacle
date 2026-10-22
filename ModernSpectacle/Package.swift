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
    dependencies: [
        // Self-updates from the store's appcast; build-app.sh copies Sparkle.framework into the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
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
                "ModernSpectacleServices",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
