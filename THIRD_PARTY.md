# Third-party software and models

Tsuzuri's own code is under the [MIT license](LICENSE). It is built on the projects below.
The app bundle includes the full license texts of all Swift packages in
`Tsuzuri.app/Contents/Resources/Licenses.txt`.

## Swift packages

| Package | License | Used for |
| --- | --- | --- |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) (includes [MLX](https://github.com/ml-explore/mlx)) | MIT | GPU array runtime on Apple Silicon, `mlx.metallib` |
| [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) | MIT | Qwen3-ASR and Silero VAD model code, audio loading |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT | LLM runtime for Polish |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 | Tokenizers |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache-2.0 | Dependency |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache-2.0 | Chat templates |
| [swift-collections](https://github.com/apple/swift-collections) | Apache-2.0 | Dependency |
| [swift-numerics](https://github.com/apple/swift-numerics) | Apache-2.0 | Dependency |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 | Dependency |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 | Dependency |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | Apache-2.0 | Build-time dependency (Swift macros) |
| [EventSource](https://github.com/mattt/EventSource) | MIT | Dependency |
| [yyjson](https://github.com/ibireme/yyjson) | MIT | Dependency |

Exact versions are pinned in `Package.resolved`.

## Models (downloaded separately, not included in this repository or the app)

| Model | License | Used for |
| --- | --- | --- |
| [Qwen3-ASR 1.7B / 0.6B](https://github.com/QwenLM/Qwen3-ASR) by the Qwen team, Alibaba Cloud; MLX conversions by [mlx-community](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit) | Apache-2.0 | Speech recognition |
| [Silero VAD](https://github.com/snakers4/silero-vad); MLX conversion by [mlx-community](https://huggingface.co/mlx-community/silero-vad) | MIT | Trimming silence |
| [spokenly/cleanup-1](https://huggingface.co/spokenly/cleanup-1), fine-tuned from [Qwen3-0.6B-Base](https://huggingface.co/Qwen/Qwen3-0.6B-Base) | Apache-2.0 | Optional Polish (converted to 4-bit MLX on your Mac) |

## Ideas

Some ideas come from [Parrot](https://github.com/banyudu/parrot) and [Koe](https://github.com/imshire/koe)
(both MIT). No code was copied from them.

## Brand

The KanaWorks_AI name, logo and the Kana character (in `docs/brand/`, `docs/assets/` and the app icon)
are © KanaWorks_AI and are not covered by the MIT license. See [docs/brand](docs/brand/README.md).
