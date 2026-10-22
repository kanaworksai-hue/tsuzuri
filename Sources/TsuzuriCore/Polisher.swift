import Foundation
@preconcurrency import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The dictation clean-up model: spokenly/cleanup-1 (Apache-2.0, a Qwen3-0.6B-Base
/// fine-tune), converted locally to MLX 4-bit. See README for the conversion command.
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
