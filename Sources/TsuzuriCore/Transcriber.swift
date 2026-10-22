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

    /// Picks up the silence detector when it was downloaded after the model loaded.
    public func loadVADIfNeeded() {
        if vad == nil, ModelStore.isInstalled(ModelStore.vadDirectory) {
            vad = try? SileroVAD.fromModelDirectory(ModelStore.vadDirectory)
        }
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

        // Speech ranges (sample indices) from the VAD; without it, the whole input.
        var ranges = [0..<samples.count]
        if trimSilence, let vad, samples.count > Self.sampleRate / 2 {  // VAD is unreliable on very short clips
            ranges = try speechRanges(samples, vad: vad)
            guard !ranges.isEmpty else {
                return Transcription(text: "", language: nil, audioSeconds: 0, inputSeconds: inputSeconds,
                                     elapsed: Date().timeIntervalSince(start))
            }
        }
        let speech = ranges.first!.lowerBound..<ranges.last!.upperBound

        // Long dictations are recognised in pieces cut at pauses: in one pass over minutes of
        // speech the model can drift into translating or into a repetition loop.
        var texts: [String] = []
        var languages: [String] = []
        let pieces = Self.pieces(speech, pauses: ranges)
        for piece in pieces {
            let seconds = Double(piece.count) / Double(Self.sampleRate)
            // Fast Chinese / Japanese is ~6–8 tokens/s; a loop runs until the budget is used up.
            let output = asr.generate(
                audio: MLXArray(Array(samples[piece])),
                maxTokens: max(pieces.count > 1 ? 256 : 1024, Int(seconds * 10)),
                context: context,
                language: language,
                repetitionPenalty: 1.05
            )
            Memory.clearCache()
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
            for l in (Self.cleanLanguage(output.language) ?? "").split(separator: ",").map(String.init)
            where !languages.contains(l) {
                languages.append(l)
            }
        }
        return Transcription(
            text: Self.join(texts),
            language: languages.isEmpty ? nil : languages.joined(separator: ","),
            audioSeconds: Double(speech.count) / Double(Self.sampleRate),
            inputSeconds: inputSeconds,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    /// Up to this much speech is recognised in one pass; longer input is split into pieces
    /// of at most `pieceSeconds`, at the pauses between the VAD's speech ranges.
    static let singlePassSeconds = 45.0
    static let pieceSeconds = 30.0

    static func pieces(_ speech: Range<Int>, pauses ranges: [Range<Int>]) -> [Range<Int>] {
        let single = Int(singlePassSeconds * Double(sampleRate))
        let limit = Int(pieceSeconds * Double(sampleRate))
        guard speech.count > single else { return [speech] }
        // Ranges longer than a piece (no pause for 30 s) are cut into equal parts, so no
        // tiny leftover piece is recognised on its own.
        var parts: [Range<Int>] = []
        for r in ranges {
            let n = (r.count + limit - 1) / limit
            for k in 0..<n {
                parts.append(r.lowerBound + r.count * k / n..<r.lowerBound + r.count * (k + 1) / n)
            }
        }
        // Join neighbouring ranges (including the pause between them) while they fit.
        var out: [Range<Int>] = []
        for part in parts {
            if let last = out.last, part.upperBound - last.lowerBound <= limit {
                out[out.count - 1] = last.lowerBound..<part.upperBound
            } else {
                out.append(part)
            }
        }
        return out
    }

    /// Joins piece transcripts: no space next to Chinese / Japanese text, a space otherwise.
    static func join(_ texts: [String]) -> String {
        var out = ""
        for text in texts {
            if let a = out.last, let b = text.first, !isCJK(a), !isCJK(b), !".,;:!?)".contains(b) { out += " " }
            out += text
        }
        return out
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            switch s.value {
            case 0x3000...0x30FF, 0x3100...0x312F, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF: true
            default: false
            }
        }
    }

    /// Qwen3-ASR reports "None" for segments without a language (e.g. a click or breath),
    /// also inside multi-segment results such as "Chinese,None".
    static func cleanLanguage(_ language: String?) -> String? {
        let parts = (language ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "None" }
            // Rarely the model writes the native name ("中文"); report the English one.
            .map { part in SpokenLanguage.all.first { $0.nativeName == part }?.name ?? part }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// Speech ranges in sample indices (padded by 200 ms, overlaps merged); empty when there is no speech.
    private func speechRanges(_ samples: [Float], vad: SileroVAD) throws -> [Range<Int>] {
        let stamps = try vad.getSpeechTimestamps(MLXArray(samples), sampleRate: Self.sampleRate, speechPadMs: 200)
        var out: [Range<Int>] = []
        for stamp in stamps {
            let lo = max(0, stamp.start), hi = min(samples.count, stamp.end)
            guard hi > lo else { continue }
            if let last = out.last, lo <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, hi)
            } else {
                out.append(lo..<hi)
            }
        }
        return out
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
