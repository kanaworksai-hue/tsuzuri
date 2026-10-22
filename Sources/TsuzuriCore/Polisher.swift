import Foundation
@preconcurrency import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The dictation clean-up model: spokenly/cleanup-1 (Apache-2.0, a Qwen3-0.6B-Base
/// fine-tune), converted locally to MLX 4-bit: by the app after downloading the original
/// (`ModelPackage.polish`, `PolishModelConverter`), or with mlx_lm as in the README.
public enum PolishModel {
    public static let directoryName = "cleanup-1-4bit"
    public static let sourceRepo = "spokenly/cleanup-1"
    public static var localDirectory: URL { ModelStore.root.appendingPathComponent(directoryName) }
    public static var isInstalled: Bool { ModelStore.isInstalled(localDirectory) }
}

/// The result of one polish pass. `text` is what should be inserted: the model
/// output when it passed the guard, otherwise the raw transcript.
public struct Polish: Sendable {
    public var raw: String
    /// What the model wrote ("" when it did not run).
    public var candidate: String
    /// Why the candidate was not used; nil when it was.
    public var rejection: String?
    public var elapsed: Double
    public var promptTokens = 0
    public var generatedTokens = 0

    /// Polish that did not run (unsupported language, terminal…): the raw text is used.
    public static func skipped(_ raw: String, reason: String) -> Polish {
        Polish(raw: raw, candidate: "", rejection: "skipped: \(reason)", elapsed: 0)
    }

    public var accepted: Bool { rejection == nil }
    public var text: String { accepted ? candidate : raw }
}

/// Owns the cleanup-1 weights. Not thread-safe: only `Transcriber` holds one and
/// calls it, so MLX stays on the actor's serial executor.
final class Polisher {
    private let context: ModelContext
    private let stopTokens: Set<Int>

    private init(context: ModelContext) {
        self.context = context
        let tokenizer = context.tokenizer
        stopTokens = Set(["<|endoftext|>", "<|im_end|>"].compactMap { tokenizer.convertTokenToId($0) })
            .union(tokenizer.eosTokenId.map { [$0] } ?? [])
    }

    static func load(_ directory: URL) async throws -> Polisher {
        let context = try await LLMModelFactory.shared.load(from: directory, using: TokenizerBridgeLoader())
        let polisher = Polisher(context: context)
        // Compile the Metal kernels now so the first dictation is not slower than the rest.
        _ = try polisher.generate("text: hello there\n", maxTokens: 4, deadline: .distantFuture)
        return polisher
    }

    /// Runs the model on `text`. Generation stops at `timeout`; the caller's guard
    /// then rejects the partial output.
    func run(_ text: String, app: String?, timeout: Double) -> Polish {
        let start = Date()
        var prompt = ""
        if let app, !app.isEmpty {
            prompt += "app: \(app.replacingOccurrences(of: "\n", with: " "))\n"
        }
        prompt += "text: \(text)"
        do {
            let maxTokens = context.tokenizer.encode(text: text, addSpecialTokens: false).count * 2 + 24
            let out = try generate(prompt, maxTokens: maxTokens, deadline: start.addingTimeInterval(timeout))
            let elapsed = Date().timeIntervalSince(start)
            var result = Polish(raw: text, candidate: out.text, rejection: nil, elapsed: elapsed,
                                promptTokens: out.promptTokens, generatedTokens: out.generatedTokens)
            if out.timedOut {
                result.rejection = String(format: "timeout (%.2fs)", elapsed)
            } else {
                result.rejection = PolishGuard.rejection(raw: text, output: out.text)
            }
            return result
        } catch {
            return Polish(raw: text, candidate: "", rejection: "error: \(error)",
                          elapsed: Date().timeIntervalSince(start))
        }
    }

    private func generate(_ prompt: String, maxTokens: Int, deadline: Date) throws
        -> (text: String, promptTokens: Int, generatedTokens: Int, timedOut: Bool)
    {
        // The chat template turns this into "<prompt>\nout:" and the model answers after it.
        let tokens = try context.tokenizer.applyChatTemplate(messages: [["role": "user", "content": prompt]])
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: context.model,
                                         parameters: parameters)
        var output: [Int] = []
        var timedOut = false
        while let token = iterator.next() {
            if stopTokens.contains(token) { break }
            output.append(token)
            if Date() > deadline {
                timedOut = true
                break
            }
        }
        let text = context.tokenizer.decode(tokenIds: output, skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, tokens.count, output.count, timedOut)
    }
}

/// Loads swift-transformers tokenizers for MLXLMCommon (what MLXHuggingFace's
/// `#huggingFaceTokenizerLoader` macro expands to, without the macro dependency).
private struct TokenizerBridgeLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Turns the original spokenly/cleanup-1 weights (bfloat16) into the 4-bit MLX model Tsuzuri
/// loads, the same way `mlx_lm.convert -q --q-bits 4` does: every matrix whose rows divide
/// into groups of 64 (the linear layers and the tied embedding) is quantized, everything else
/// is kept. Done on the Mac after download, so no converted copy has to be hosted anywhere.
public enum PolishModelConverter {
    public static let groupSize = 64
    public static let bits = 4
    /// Copied as they are; config.json is rewritten with the quantization settings.
    static let passthroughFiles = ["chat_template.jinja", "generation_config.json", "tokenizer.json",
                                   "tokenizer_config.json", "LICENSE", "NOTICE", "README.md"]

    public static func convert(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let configData = try Data(contentsOf: source.appendingPathComponent("config.json"))
        guard var config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tied = config["tie_word_embeddings"] as? Bool ?? false

        var output: [String: MLXArray] = [:]
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        for file in files {
            // One tensor at a time (loading is lazy), so memory peaks at one bf16 tensor plus the
            // 4-bit result rather than the whole original model.
            var weights = try loadArrays(url: file)
            for key in weights.keys.sorted() {
                try Task.checkCancellation()
                guard let weight = weights.removeValue(forKey: key) else { continue }
                if tied, key == "lm_head.weight" { continue }  // the embedding doubles as the output layer
                if key.hasSuffix(".weight"), weight.ndim == 2, weight.dim(-1) % groupSize == 0 {
                    let (wq, scales, biases) = quantized(weight, groupSize: groupSize, bits: bits)
                    let base = String(key.dropLast(".weight".count))
                    output[key] = wq
                    output[base + ".scales"] = scales
                    output[base + ".biases"] = biases
                    eval(wq, scales, biases ?? wq)
                } else {
                    output[key] = weight
                    eval(weight)
                }
            }
            Memory.clearCache()
        }
        try save(arrays: output, metadata: ["format": "mlx"],
                 url: destination.appendingPathComponent("model.safetensors"))

        let quantization: [String: Any] = ["group_size": groupSize, "bits": bits, "mode": "affine"]
        config["quantization"] = quantization
        config["quantization_config"] = quantization
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("config.json"))
        for name in passthroughFiles where fm.fileExists(atPath: source.appendingPathComponent(name).path) {
            let target = destination.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source.appendingPathComponent(name), to: target)
        }
    }
}
