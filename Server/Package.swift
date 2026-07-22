// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RemoteASRServer",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "remote-asr-server", targets: ["RemoteASRServer"]),
        .executable(name: "remote-asr-smoke", targets: ["RemoteASRSmoke"]),
        .executable(name: "remote-asr-benchmark", targets: ["RemoteASRBenchmark"]),
        .executable(name: "remote-asr-turn-benchmark", targets: ["RemoteASRTurnBenchmark"]),
    ],
    dependencies: [
        .package(path: "../Vendor/speech-swift"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", "2.5.0"..<"2.17.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", "2.6.0"..<"2.7.0"),
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", "1.5.0"..<"1.6.0"),
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            exact: "1.24.2"
        ),
    ],
    targets: [
        .target(
            name: "RemoteASRCore",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "WSCore", package: "swift-websocket"),
            ],
            resources: [
                .copy("Resources/smart-turn-v3.2-cpu.onnx"),
                .copy("Resources/SMART_TURN_LICENSE.txt"),
            ]
        ),
        .executableTarget(
            name: "RemoteASRServer",
            dependencies: ["RemoteASRCore"]
        ),
        .executableTarget(
            name: "RemoteASRSmoke",
            dependencies: []
        ),
        .executableTarget(
            name: "RemoteASRBenchmark",
            dependencies: [
                "RemoteASRCore",
                .product(name: "AudioCommon", package: "speech-swift"),
            ]
        ),
        .executableTarget(
            name: "RemoteASRTurnBenchmark",
            dependencies: [
                "RemoteASRCore",
                .product(name: "AudioCommon", package: "speech-swift"),
            ]
        ),
        .testTarget(
            name: "RemoteASRCoreTests",
            dependencies: ["RemoteASRCore"]
        ),
    ]
)
