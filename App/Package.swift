// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VibeTyping",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "VibeTyping", targets: ["VibeTyping"]),
    ],
    targets: [
        .executableTarget(
            name: "VibeTyping",
            path: "Sources/VibeTyping",
            resources: [
                .copy("Resources/Pets"),
            ]
        ),
        .testTarget(
            name: "VibeTypingTests",
            dependencies: ["VibeTyping"]
        ),
    ]
)
