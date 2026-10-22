import Foundation
import TsuzuriCore

/// The modifier key used as the push-to-talk trigger. Only keys that are
/// rarely used on their own are offered.
enum TriggerKey: String, CaseIterable {
    case rightOption, rightCommand, fn

    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        }
    }

    var title: String {
        switch self {
        case .rightOption: String(localized: "Right Option ⌥")
        case .rightCommand: String(localized: "Right Command ⌘")
        case .fn: "Fn / 🌐"
        }
    }
}

enum RecognitionLanguage: String, CaseIterable {
    case auto, chinese = "Chinese", english = "English", japanese = "Japanese"

    /// Language names are shown in their own language, like the system language list.
    var title: String {
        switch self {
        case .auto: String(localized: "Auto (Mixed Languages)")
        case .chinese: "中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    var modelValue: String? { self == .auto ? nil : rawValue }
}

extension ASRModel {
    /// Model name plus a localized speed / accuracy hint.
    var menuTitle: String {
        switch self {
        case .qwen3_1_7b_4bit: displayName + " — " + String(localized: "Accurate")
        case .qwen3_0_6b_8bit: displayName + " — " + String(localized: "Fast")
        case .qwen3_1_7b_8bit, .qwen3_0_6b_4bit: displayName
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var model: ASRModel {
        get { defaults.string(forKey: "model").flatMap(ASRModel.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: "model") }
    }

    static var trigger: TriggerKey {
        get { defaults.string(forKey: "trigger").flatMap(TriggerKey.init(rawValue:)) ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: "trigger") }
    }

    static var language: RecognitionLanguage {
        get { defaults.string(forKey: "language").flatMap(RecognitionLanguage.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "language") }
    }

    /// Free-form context / hot words handed to Qwen3-ASR. Empty by default:
    /// in testing a generic context made the 1.7B model translate instead of transcribe.
    static var context: String {
        get { defaults.string(forKey: "context") ?? "" }
        set { defaults.set(newValue, forKey: "context") }
    }

    /// Clean up transcripts with the local LLM (cleanup-1) before inserting them. Off by default
    /// until it has been checked against real recordings.
    static var polish: Bool {
        get { defaults.bool(forKey: "polish") }
        set { defaults.set(newValue, forKey: "polish") }
    }
}

/// Apps where polish is skipped: in a terminal the dictated text is usually a
/// command, and punctuation or digit rewriting would break it.
enum PolishPolicy {
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.mitchellh.ghostty",
        "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
        "dev.commandline.waveterm",
    ]

    static func shouldPolish(bundleID: String?) -> Bool {
        guard Settings.polish else { return false }
        guard let bundleID else { return true }
        return !terminalBundleIDs.contains(bundleID)
    }
}
