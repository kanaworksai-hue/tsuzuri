import Cmlx
import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioVAD

public struct Transcription: Sendable {
    public var text: String
    public var language: String?
    /// Seconds of audio handed to the recogniser (after silence trimming).
    public var audioSeconds: Double
    /// Seconds of audio before trimming.
    public var inputSeconds: Double
    public var elapsed: Double
    public var rtf: Double { audioSeconds > 0 ? elapsed / audioSeconds : 0 }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case modelMissing(URL)
    /// A newer `load` call started before this one finished; its model was discarded.
    case superseded

    public var description: String {
        switch self {
        case .modelMissing(let url): "Model not found at \(url.path). See README for how to download it."
        case .superseded: "Model load superseded by a newer one"
        }
    }
}

/// Owns the MLX models. All inference goes through this actor so MLX is never
/// driven from two threads at once.
public actor Transcriber {
    public static let sampleRate = 16_000

    public private(set) var model: ASRModel?
    private var asr: Qwen3ASRModel?
    private var vad: SileroVAD?
    private var polisher: Polisher?
    private var loadGeneration = 0

    public init() {
        _ = Self.locateMetalLibrary
    }

    /// MLX only looks for mlx.metallib next to the executable, but in a signed app it
    /// must live in Contents/Resources (codesign treats everything in Contents/MacOS as
    /// code). Bundle lookup finds it in either place, so tell MLX where it is.
    private static let locateMetalLibrary: Void = {
        if let url = Bundle.main.url(forResource: "mlx", withExtension: "metallib") {
            mlx_metal_set_metallib_path(url.path)
        }
    }()

    /// Loads (or swaps to) `model`. Returns the load time in seconds.
    @discardableResult
    public func load(_ model: ASRModel, directory: URL? = nil) async throws -> Double {
        // Bump first: switching back to the loaded model must also supersede a load in flight,
        // otherwise that load would replace the model the user just went back to.
        loadGeneration += 1  // also cancels an older load when this one fails right away
        let generation = loadGeneration
        if self.model == model, asr != nil { return 0 }
        let dir = directory ?? model.localDirectory
        guard ModelStore.isInstalled(dir) else { throw TranscriberError.modelMissing(dir) }
        let start = Date()
        // Keep the current model until the new one is ready: transcribe() can run while
        // this call is suspended (actor reentrancy), and a dictation must not fail because
        // the user switched models. Only the newest of overlapping loads is kept.
        let loaded = try await Qwen3ASRModel.fromModelDirectory(dir)
        guard generation == loadGeneration else {
            Memory.clearCache()  // free the discarded model's buffers now
            throw TranscriberError.superseded
        }
        // Warm up kernels so the first real dictation is not slower than the rest.
        _ = loaded.generate(audio: MLXArray.zeros([Self.sampleRate]), maxTokens: 4)
        asr = loaded
        self.model = model
        Memory.clearCache()
        if vad == nil, ModelStore.isInstalled(ModelStore.vadDirectory) {
            vad = try? SileroVAD.fromModelDirectory(ModelStore.vadDirectory)
        }
        return Date().timeIntervalSince(start)
    }

    public func unload() {
        asr = nil
        model = nil
        Memory.clearCache()
    }

    // MARK: - Polish

    public var isPolisherLoaded: Bool { polisher != nil }

    /// Loads the clean-up model (independent of the ASR model). Returns the load time in seconds.
    @discardableResult
    public func loadPolisher(directory: URL? = nil) async throws -> Double {
        if polisher != nil { return 0 }
        let dir = directory ?? PolishModel.localDirectory
        guard ModelStore.isInstalled(dir) else { throw TranscriberError.modelMissing(dir) }
        let start = Date()
        let loaded = try await Polisher.load(dir)
        if polisher == nil { polisher = loaded }  // another call may have finished first
        return Date().timeIntervalSince(start)
    }

    public func unloadPolisher() {
        polisher = nil
        Memory.clearCache()
    }

    /// Cleans up a transcript (punctuation, fillers, self-corrections, digits).
    /// Falls back to `text` when the model is not loaded, times out, or its output
    /// fails `PolishGuard`; `Polish.rejection` says why.
    /// - Parameter app: name of the app receiving the text (cleanup-1's `app:` key), optional.
    public func polish(_ text: String, app: String? = nil, timeout: Double = 1.0) -> Polish {
        guard let polisher else {
            return Polish(raw: text, candidate: "", rejection: "not loaded", elapsed: 0)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Polish(raw: text, candidate: "", rejection: "empty input", elapsed: 0)
        }
        return polisher.run(text, app: app, timeout: timeout)
    }

    /// - Parameters:
    ///   - samples: mono Float32 PCM at 16 kHz.
    ///   - language: Qwen3-ASR language name ("Chinese", "English", "Japanese") or nil for auto-detect.
    ///   - context: free-form context / hot words passed as the system prompt.
    public func transcribe(
        _ samples: [Float],
        language: String? = nil,
        context: String = "",
        trimSilence: Bool = true
    ) throws -> Transcription {
        guard let asr else { throw TranscriberError.modelMissing(ModelStore.root) }
        let inputSeconds = Double(samples.count) / Double(Self.sampleRate)
        let start = Date()

        var speech = samples
        if trimSilence, let vad {
            guard let trimmed = try trimToSpeech(samples, vad: vad) else {
                return Transcription(text: "", language: nil, audioSeconds: 0, inputSeconds: inputSeconds,
                                     elapsed: Date().timeIntervalSince(start))
            }
            speech = trimmed
        }

        // Scale the token budget with the audio so long dictations (up to 3 min) are not cut
        // off; fast Chinese / Japanese speech is around 6–8 tokens per second. Not much more:
        // a repetition loop runs until the budget is used up, and the user waits for it.
        let seconds = Double(speech.count) / Double(Self.sampleRate)
        let output = asr.generate(
            audio: MLXArray(speech),
            maxTokens: max(1024, Int(seconds * 10)),
            context: context,
            language: language,
            repetitionPenalty: 1.05
        )
        Memory.clearCache()
        return Transcription(
            text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: Self.cleanLanguage(output.language),
            audioSeconds: Double(speech.count) / Double(Self.sampleRate),
            inputSeconds: inputSeconds,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    /// Qwen3-ASR reports "None" for segments without a language (e.g. a click or breath),
    /// also inside multi-segment results such as "Chinese,None".
    static func cleanLanguage(_ language: String?) -> String? {
        let parts = (language ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "None" }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// Cuts leading and trailing non-speech. Returns nil when no speech is found.
    private func trimToSpeech(_ samples: [Float], vad: SileroVAD) throws -> [Float]? {
        // Very short clips: VAD is unreliable, keep as-is.
        guard samples.count > Self.sampleRate / 2 else { return samples }
        let stamps = try vad.getSpeechTimestamps(MLXArray(samples), sampleRate: Self.sampleRate, speechPadMs: 200)
        guard let first = stamps.first, let last = stamps.last else { return nil }
        let lo = max(0, first.start)
        let hi = min(samples.count, last.end)
        guard hi > lo else { return nil }
        return Array(samples[lo..<hi])
    }

    public struct MemoryStats: Sendable {
        public var activeGB: Double
        public var peakGB: Double
        public var residentGB: Double
    }

    public func memoryStats() -> MemoryStats {
        MemoryStats(
            activeGB: Double(Memory.activeMemory) / 1e9,
            peakGB: Double(Memory.peakMemory) / 1e9,
            residentGB: Double(ProcessMemory.residentBytes()) / 1e9
        )
    }

    public func resetPeakMemory() { Memory.peakMemory = 0 }
}

public enum AudioFile {
    /// Loads any AVFoundation-readable file as mono 16 kHz Float32.
    public static func load16k(_ url: URL) throws -> [Float] {
        let (_, array) = try loadAudioArray(from: url, sampleRate: Transcriber.sampleRate)
        return array.asArray(Float.self)
    }
}

enum ProcessMemory {
    static func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
