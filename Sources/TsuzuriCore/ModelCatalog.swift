import Foundation

/// ASR models Tsuzuri knows about. Weights live outside the repo in
/// `~/Library/Application Support/Tsuzuri/Models/<directoryName>`.
public enum ASRModel: String, CaseIterable, Sendable {
    case qwen3_1_7b_4bit = "Qwen3-ASR-1.7B-4bit"
    case qwen3_1_7b_8bit = "Qwen3-ASR-1.7B-8bit"
    case qwen3_0_6b_8bit = "Qwen3-ASR-0.6B-8bit"
    case qwen3_0_6b_4bit = "Qwen3-ASR-0.6B-4bit"

    public static let `default`: ASRModel = .qwen3_1_7b_4bit
    public static let fast: ASRModel = .qwen3_0_6b_8bit

    public var directoryName: String { rawValue }
    public var huggingFaceRepo: String { "mlx-community/\(rawValue)" }

    public var displayName: String {
        switch self {
        case .qwen3_1_7b_4bit: "Qwen3-ASR 1.7B (4bit)"
        case .qwen3_1_7b_8bit: "Qwen3-ASR 1.7B (8bit)"
        case .qwen3_0_6b_8bit: "Qwen3-ASR 0.6B (8bit)"
        case .qwen3_0_6b_4bit: "Qwen3-ASR 0.6B (4bit)"
        }
    }

    public var localDirectory: URL { ModelStore.root.appendingPathComponent(directoryName) }
    public var isInstalled: Bool { ModelStore.isInstalled(localDirectory) }
}

public enum ModelStore {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["TSUZURI_MODELS_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tsuzuri/Models")
    }

    public static var vadDirectory: URL { root.appendingPathComponent("silero-vad") }

    static func isInstalled(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }
}
