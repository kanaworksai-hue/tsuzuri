import Foundation

/// Decides whether a polished transcript is safe to use instead of the raw one.
/// Rejections fall back to the raw text, so the checks err on the side of
/// rejecting: a missed cleanup costs little, a changed meaning costs a lot.
public enum PolishGuard {
    /// Returns why `output` must not replace `raw`, or nil when it is fine.
    public static func rejection(raw: String, output: String) -> String? {
        // NFKC: full-width digits and letters → ASCII.
        let input = raw.precomposedStringWithCompatibilityMapping
        let out = output.precomposedStringWithCompatibilityMapping
        let inLength = input.filter { !$0.isWhitespace }.count
        let outLength = out.filter { !$0.isWhitespace }.count
        if outLength == 0 { return "empty" }
        // Answers, expansions and run-on generations are much longer than the input.
        // The small constant lets very short inputs gain punctuation.
        if outLength > inLength * 3 / 2 + 2 { return "longer (\(inLength) → \(outLength) chars)" }
        if let reason = scriptChange(input: input, output: out) { return reason }
        if let reason = newWords(input: input, output: out) { return reason }
        if let reason = numberMismatch(input: input, output: out) { return reason }
        return nil
    }

    // MARK: - Script mix (translation)

    enum Script: String, CaseIterable { case han, kana, latin }

    static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005: .han
        case 0x3040...0x30FF, 0x31F0...0x31FF: .kana
        case 0x41...0x5A, 0x61...0x7A: .latin
        default: nil
        }
    }

    /// Fillers the model is expected to delete; removed from the input before
    /// comparing script ratios. English number words are removed too (they become digits).
    private static let cjkFillers = [
        "就是说", "那个", "这个", "嗯", "呃", "额", "啊",
        "えーっと", "えーと", "えっと", "あのー", "あの", "えー", "まあ", "なんか",
    ]
    private static let latinFillers: Set<String> = ["um", "umm", "uh", "er", "erm", "hmm", "ah", "eh", "like"]

    private static func counts(_ s: String) -> [Script: Int] {
        var c: [Script: Int] = [:]
        for scalar in s.unicodeScalars {
            if let k = script(of: scalar) { c[k, default: 0] += 1 }
        }
        return c
    }

    static func scriptChange(input: String, output: String) -> String? {
        var stripped = input
        for word in cjkFillers { stripped = stripped.replacingOccurrences(of: word, with: "") }
        stripped = latinWords(stripped).reduce(stripped) { text, word in
            let w = word.lowercased()
            guard latinFillers.contains(w) || EnglishNumbers.words[w] != nil else { return text }
            return text.replacingOccurrences(of: word, with: "")
        }
        let a = counts(stripped), b = counts(output)
        let na = Double(max(1, a.values.reduce(0, +))), nb = Double(max(1, b.values.reduce(0, +)))
        for s in Script.allCases {
            let inN = a[s, default: 0], outN = b[s, default: 0]
            let inF = Double(inN) / na, outF = Double(outN) / nb
            if inN >= 3, inF >= 0.2, outF < inF * 0.35 { return "script: \(s.rawValue) dropped" }
            if outN >= 3, outF >= 0.2, outF > inF * 2.5 + 0.1 { return "script: \(s.rawValue) added" }
        }
        return nil
    }

    static func latinWords(_ s: String) -> [String] {
        s.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).map(String.init)
    }

    // MARK: - New words

    /// cleanup-1 keeps the speaker's wording, so every latin word it writes must come
    /// from the input (ignoring case; adjacent words may be joined: "git hub" → GitHub,
    /// "A S A P" → ASAP), and it must not introduce new Han characters. This catches
    /// translations (memory → 内存), garbled terms (ASAPで → SAS也で) and hallucinated
    /// spellings of katakana (アンリアルエンジン → Annamalai Engine). It also rejects
    /// correct katakana → English (スイフト → Swift); that is the safe direction.
    static func newWords(input: String, output: String) -> String? {
        let inWords = latinWords(input).map { $0.lowercased() }
        var known = Set(inWords)
        for a in inWords.indices {
            for b in (a + 2)..<min(inWords.count, a + 6) + 1 where b <= inWords.count {
                known.insert(inWords[a..<b].joined())
            }
        }
        if let word = latinWords(output).first(where: { !known.contains($0.lowercased()) }) {
            return "new word: \(word)"
        }
        let inHan = Set(input.unicodeScalars.filter { script(of: $0) == .han })
        if let han = output.unicodeScalars.first(where: { script(of: $0) == .han && !inHan.contains($0) }) {
            return "new character: \(han)"
        }
        return nil
    }

    // MARK: - Numbers

    /// Every number in the output must be explained by the input: a digit string
    /// already there, or the value of spoken numerals (三百四十, twenty eight,
    /// one twenty eight → 128). Also keeps Chinese/Japanese 万/亿 instead of long
    /// digit strings (三百四十万 → 340万, not 3400000).
    static func numberMismatch(input: String, output: String) -> String? {
        let outNumbers = digitRuns(output)
        guard !outNumbers.isEmpty else { return nil }
        let inRuns = digitRuns(input).map(\.value)
        var known = Set(inRuns)
        // "1 2 8" or "1,28" in the raw transcript: adjacent runs may be one number.
        for i in inRuns.indices {
            var joined = inRuns[i]
            for j in (i + 1)..<min(inRuns.count, i + 4) {
                joined += inRuns[j]
                known.insert(stripZeros(joined))
            }
        }
        known.formUnion(CJKNumbers.candidates(in: input))
        known.formUnion(EnglishNumbers.candidates(in: input))
        let hasMyriad = input.contains { "万萬亿億".contains($0) }
        for n in outNumbers {
            if hasMyriad, n.value.count >= 5, !n.followedByMyriad { return "number: \(n.value) instead of 万/亿" }
            if !known.contains(n.value) { return "number: \(n.value) not in input" }
        }
        return nil
    }

    struct DigitRun { var value: String; var followedByMyriad: Bool }

    private static let thousandsSeparator = try! NSRegularExpression(pattern: "(?<=[0-9]),(?=[0-9]{3}(?![0-9]))")
    private static let digitRun = try! NSRegularExpression(pattern: "[0-9]+")

    /// Digit runs, thousands separators removed (2,500 → 2500), leading zeros stripped.
    static func digitRuns(_ s: String) -> [DigitRun] {
        let text = thousandsSeparator.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        return digitRun.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            let range = Range(m.range, in: text)!
            let next = text[range.upperBound...].first { !$0.isWhitespace }
            return DigitRun(value: stripZeros(String(text[range])), followedByMyriad: next.map { "万萬亿億".contains($0) } ?? false)
        }
    }

    static func stripZeros(_ s: String) -> String {
        let t = s.drop { $0 == "0" }
        return t.isEmpty ? "0" : String(t)
    }
}

/// Values that Chinese / Japanese numerals in a text may stand for.
enum CJKNumbers {
    static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    static let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    static let myriads: [Character: Int] = ["万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000]

    static func isNumeral(_ c: Character) -> Bool { digits[c] != nil || units[c] != nil || myriads[c] != nil }

    static func candidates(in s: String) -> Set<String> {
        var out = Set<String>()
        if s.contains("半") { out.insert("30") } // 三点半 → 3:30
        if s.contains("刻") { out.formUnion(["15", "45"]) }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            guard isNumeral(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count, isNumeral(chars[j]) { j += 1 }
            let run = Array(chars[i..<j])
            // Every contiguous piece: 三百四十万 → 340 (before 万), 3400000, 40, …
            for a in 0..<run.count {
                for b in (a + 1)...min(run.count, a + 16) {
                    let piece = Array(run[a..<b])
                    if let v = value(piece) { out.insert(String(v)) }
                    if piece.allSatisfy({ digits[$0] != nil }) {
                        out.insert(PolishGuard.stripZeros(piece.map { String(digits[$0]!) }.joined()))
                    }
                }
            }
            i = j
        }
        return out
    }

    /// Standard reading: 三百四十万 = 3400000, 十二 = 12, 二十 = 20.
    static func value(_ chars: [Character]) -> Int? {
        var total = 0, section = 0, number = 0
        var sawDigit = false
        for c in chars {
            if let d = digits[c] {
                number = d
                sawDigit = true
            } else if let u = units[c] {
                section += (number == 0 ? 1 : number) * u
                number = 0
            } else if let m = myriads[c] {
                guard section + number > 0 else { return nil }
                total += (section + number) * m
                section = 0
                number = 0
            }
        }
        let v = total + section + number
        return (sawDigit || v > 0) ? v : nil
    }
}

/// Values that spoken English numbers in a text may stand for.
enum EnglishNumbers {
    static let words: [String: Int] = {
        var w: [String: Int] = [:]
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                    "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                    "nineteen"]
        for (i, s) in ones.enumerated() { w[s] = i }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        for (i, s) in tens.enumerated() { w[s] = (i + 2) * 10 }
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
                        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
                        "fifteenth": 15, "twentieth": 20, "thirtieth": 30]
        w.merge(ordinals) { a, _ in a }
        w["hundred"] = 100
        w["thousand"] = 1000
        w["million"] = 1_000_000
        w["billion"] = 1_000_000_000
        w["half"] = 30 // "three and a half" is rarely a time, but "half past three" → 3:30
        w["quarter"] = 15
        return w
    }()

    private static func isScale(_ v: Int) -> Bool { v == 100 || v >= 1000 }

    static func candidates(in s: String) -> Set<String> {
        // Letters-only tokens; anything else ("," "." digits) separates number phrases.
        var tokens: [String] = []
        var word = ""
        for ch in s.lowercased() {
            if ch.isASCII, ch.isLetter {
                word.append(ch)
            } else {
                if !word.isEmpty { tokens.append(word) }
                word = ""
                if !ch.isWhitespace, ch != "-" { tokens.append("|") }
            }
        }
        if !word.isEmpty { tokens.append(word) }

        var out = Set<String>()
        var group: [String] = []
        func flush() {
            if !group.isEmpty { out.formUnion(candidates(of: group)) }
            group = []
        }
        for (k, t) in tokens.enumerated() {
            if words[t] != nil {
                group.append(t)
            } else if t == "a" || t == "an", k + 1 < tokens.count, let v = words[tokens[k + 1]], isScale(v) {
                group.append("one")
            } else if t == "and", !group.isEmpty {
                continue
            } else if t == "oh" || t == "o", !group.isEmpty {
                group.append("zero") // "three oh five" → 305
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    private static func candidates(of group: [String]) -> Set<String> {
        let values = group.compactMap { words[$0] }
        var out = Set(values.map(String.init))
        // Standard reading of every contiguous piece: "two thousand five hundred" = 2500.
        for a in 0..<values.count {
            for b in (a + 1)...values.count {
                if let v = standard(Array(values[a..<b])) { out.insert(String(v)) }
            }
        }
        // Colloquial digit groups: "one twenty eight" = 1|28 → 128, "nineteen ninety eight" → 1998.
        var chunks: [Int] = []
        var k = 0
        while k < values.count {
            let v = values[k]
            if v >= 20, v < 100, v % 10 == 0, k + 1 < values.count, values[k + 1] < 10, values[k + 1] > 0 {
                chunks.append(v + values[k + 1])
                k += 2
            } else if !isScale(v) {
                chunks.append(v)
                k += 1
            } else {
                k += 1
            }
        }
        for a in 0..<chunks.count {
            var joined = ""
            for b in a..<min(chunks.count, a + 4) {
                joined += String(chunks[b])
                out.insert(PolishGuard.stripZeros(joined))
            }
        }
        return out
    }

    private static func standard(_ values: [Int]) -> Int? {
        var total = 0, current = 0
        for v in values {
            if v == 100 {
                current = max(current, 1) * 100
            } else if v >= 1000 {
                total += max(current, 1) * v
                current = 0
            } else {
                current += v
            }
        }
        return total + current
    }
}
