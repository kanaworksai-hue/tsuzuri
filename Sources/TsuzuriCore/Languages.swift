import Foundation

/// Languages Qwen3-ASR recognises. `name` is the model's own language name (what it
/// returns as the detected language and accepts as a forced language).
public struct SpokenLanguage: Hashable, Sendable {
    public var name: String
    /// The language's name in that language, as in the system language list.
    public var nativeName: String

    /// The 30 languages of Qwen3-ASR, in the model's own order.
    public static let all: [SpokenLanguage] = [
        .init(name: "Chinese", nativeName: "中文"),
        .init(name: "English", nativeName: "English"),
        .init(name: "Cantonese", nativeName: "粵語"),
        .init(name: "Arabic", nativeName: "العربية"),
        .init(name: "German", nativeName: "Deutsch"),
        .init(name: "French", nativeName: "Français"),
        .init(name: "Spanish", nativeName: "Español"),
        .init(name: "Portuguese", nativeName: "Português"),
        .init(name: "Indonesian", nativeName: "Bahasa Indonesia"),
        .init(name: "Italian", nativeName: "Italiano"),
        .init(name: "Korean", nativeName: "한국어"),
        .init(name: "Russian", nativeName: "Русский"),
        .init(name: "Thai", nativeName: "ไทย"),
        .init(name: "Vietnamese", nativeName: "Tiếng Việt"),
        .init(name: "Japanese", nativeName: "日本語"),
        .init(name: "Turkish", nativeName: "Türkçe"),
        .init(name: "Hindi", nativeName: "हिन्दी"),
        .init(name: "Malay", nativeName: "Bahasa Melayu"),
        .init(name: "Dutch", nativeName: "Nederlands"),
        .init(name: "Swedish", nativeName: "Svenska"),
        .init(name: "Danish", nativeName: "Dansk"),
        .init(name: "Finnish", nativeName: "Suomi"),
        .init(name: "Polish", nativeName: "Polski"),
        .init(name: "Czech", nativeName: "Čeština"),
        .init(name: "Filipino", nativeName: "Filipino"),
        .init(name: "Persian", nativeName: "فارسی"),
        .init(name: "Greek", nativeName: "Ελληνικά"),
        .init(name: "Romanian", nativeName: "Română"),
        .init(name: "Hungarian", nativeName: "Magyar"),
        .init(name: "Macedonian", nativeName: "Македонски"),
    ]

    /// Chinese dialects Qwen3-ASR recognises as Chinese (no separate setting needed).
    public static let chineseDialects = [
        "Anhui", "Dongbei", "Fujian", "Gansu", "Guizhou", "Hebei", "Henan", "Hubei", "Hunan", "Jiangxi",
        "Ningxia", "Shandong", "Shaanxi", "Shanxi", "Sichuan", "Tianjin", "Yunnan", "Zhejiang",
        "Cantonese (Hong Kong)", "Cantonese (Guangdong)", "Wu", "Minnan",
    ]

    public static func named(_ name: String) -> SpokenLanguage? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Languages spokenly/cleanup-1 was trained on. Polish is skipped for anything else:
/// on untrained languages a 0.6B model rewrites or translates rather than cleans up.
public enum PolishLanguages {
    public static let supported = ["English", "German", "Spanish", "French", "Chinese", "Russian", "Japanese"]

    /// Why a transcript in `detected` (Qwen3-ASR's language, comma-separated when the
    /// audio was split into chunks) must not be polished, or nil when it may be.
    public static func skipReason(for detected: String?) -> String? {
        let languages = (detected ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !languages.isEmpty else { return "language unknown" }
        if let other = languages.first(where: { name in
            !supported.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }) {
            return "language \(other) not supported"
        }
        return nil
    }
}
