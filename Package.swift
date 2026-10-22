// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Tsuzuri",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tsuzuri", targets: ["Tsuzuri"]),
        .executable(name: "tsuzuri-cli", targets: ["tsuzuri-cli"]),
    ],
    dependencies: [
        // Pinned: mlx-audio-swift moves fast. Bump deliberately and re-test recognition.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "244458d7b61e54ff135073ddc9ed76782bb20758"),
        // Already pulled in by mlx-audio-swift; listed so TsuzuriCore can use the LLM runtime for polish.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMajor(from: "1.1.6")),
    ],
    targets: [
        .target(
            name: "TsuzuriCore",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "tsuzuri-cli",
            dependencies: ["TsuzuriCore"]
        ),
        .executableTarget(
            name: "Tsuzuri",
            dependencies: ["TsuzuriCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
