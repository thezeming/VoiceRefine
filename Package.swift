// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceRefine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceRefine", targets: ["VoiceRefine"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceRefine",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/VoiceRefine",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "VoiceRefineTests",
            dependencies: ["VoiceRefine"],
            path: "Tests/VoiceRefineTests"
        )
    ]
)
