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

    enum Script: String, CaseIterable { case han, kana, latin, cyrillic, greek }

    static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005: .han
        case 0x3040...0x30FF, 0x31F0...0x31FF: .kana
        // ASCII letters plus accented ones (é, ü, ñ, ß, ő, ș, ế…); not × ÷.
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF: .latin
        case 0x400...0x4FF: .cyrillic
        case 0x370...0x3FF, 0x1F00...0x1FFF: .greek
        default: nil
        }
    }

    /// Letters that make up words separated by spaces: Latin (with accents), Cyrillic, Greek.
    static func isWordLetter(_ c: Character) -> Bool {
        guard c.isLetter else { return false }
        return c.unicodeScalars.allSatisfy { scalar in
            switch script(of: scalar) {
            case .latin, .cyrillic, .greek: true
            default: scalar.properties.generalCategory == .nonspacingMark
            }
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

    /// Space-separated words (Latin, Cyrillic, Greek): "können" stays one word.
    static func latinWords(_ s: String) -> [String] {
        s.split(whereSeparator: { !isWordLetter($0) }).map(String.init)
    }

    // MARK: - New words

    /// cleanup-1 keeps the speaker's wording, so every word it writes must come
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
        known.formUnion(EuropeanNumbers.candidates(in: input))
        let hasMyriad = input.contains { "万萬亿億".contains($0) }
        for n in outNumbers {
            if hasMyriad, n.value.count >= 5, !n.followedByMyriad { return "number: \(n.value) instead of 万/亿" }
            if !known.contains(n.value) { return "number: \(n.value) not in input" }
        }
        return nil
    }

    struct DigitRun { var value: String; var followedByMyriad: Bool }

    // 2,500 / 2.500 / 2 500 (also no-break and narrow no-break spaces, as French writes it).
    private static let thousandsSeparator = try! NSRegularExpression(
        pattern: "(?<=[0-9])[,. \u{00A0}\u{202F}](?=[0-9]{3}(?![0-9]))")
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
            if PolishGuard.isWordLetter(ch) {
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
        candidates(ofValues: group.compactMap { words[$0] })
    }

    /// Values a run of number words may stand for, given each word's value in order.
    static func candidates(ofValues values: [Int]) -> Set<String> {
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

/// Values that spoken German, French, Spanish and Russian numbers may stand for
/// (the other languages cleanup-1 writes digits for). Each word must split completely
/// into number parts: "dreiundzwanzig" → 3 und 20, "doscientos" → 200, "vingt-cinq" → 20 5.
enum EuropeanNumbers {
    /// Joins units and tens the other way round: German "drei und zwanzig" = 23.
    private static let und = -1

    static let parts: [String: Int] = {
        var p: [String: Int] = [:]
        func add(_ values: [Int], _ words: String) {
            for (v, w) in zip(values, words.split(separator: " ")) { p[String(w)] = v }
        }
        let units = Array(0...19)
        let tens = [20, 30, 40, 50, 60, 70, 80, 90]
        let hundreds = [200, 300, 400, 500, 600, 700, 800, 900]
        // German (compounds are split below: "zweihundertfünfzig" → zwei hundert fünfzig)
        add(units, "null eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn fünfzehn sechzehn siebzehn achtzehn neunzehn")
        add(tens, "zwanzig dreißig vierzig fünfzig sechzig siebzig achtzig neunzig")
        add([1, 1, 2, 6, 7, 30], "ein eine zwo sech sieb dreissig")
        p["und"] = und
        add([100, 1000, 1_000_000, 1_000_000, 1_000_000_000, 1_000_000_000], "hundert tausend million millionen milliarde milliarden")
        // French ("quatre-vingt" = 80 is handled when composing)
        add(units, "zéro un deux trois quatre cinq six sept huit neuf dix onze douze treize quatorze quinze seize")
        add([1, 20, 30, 40, 50, 60, 100, 100, 1000, 1_000_000, 1_000_000, 1_000_000_000, 1_000_000_000],
            "une vingt trente quarante cinquante soixante cent cents mille million millions milliard milliards")
        p["vingts"] = 20
        // Spanish ("veinti" + unit: veintitrés)
        add(units, "cero uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciséis diecisiete dieciocho diecinueve")
        add([1, 1, 20, 20, 16, 22, 23, 26], "un una veinte veinti dieciseis veintidós veintitrés veintiséis")
        add(tens.dropFirst().map { $0 }, "treinta cuarenta cincuenta sesenta setenta ochenta noventa")
        add([100, 100] + hundreds, "cien ciento doscientos trescientos cuatrocientos quinientos seiscientos setecientos ochocientos novecientos")
        add([200, 300, 400, 500, 600, 700, 800, 900], "doscientas trescientas cuatrocientas quinientas seiscientas setecientas ochocientas novecientas")
        add([1000, 1_000_000, 1_000_000], "mil millón millones")
        // Russian
        add(units, "ноль один два три четыре пять шесть семь восемь девять десять одиннадцать двенадцать тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать")
        add([1, 1, 2], "одна одно две")
        add(tens, "двадцать тридцать сорок пятьдесят шестьдесят семьдесят восемьдесят девяносто")
        add([100] + hundreds, "сто двести триста четыреста пятьсот шестьсот семьсот восемьсот девятьсот")
        add([1000, 1000, 1000, 1_000_000, 1_000_000, 1_000_000],
            "тысяча тысячи тысяч миллион миллиона миллионов")
        return p
    }()
    private static let longestPart = parts.keys.map(\.count).max() ?? 0

    /// Splits `word` into number parts (longest first), or nil if any part is not a number.
    static func split(_ word: String) -> [Int]? {
        let chars = Array(word)
        var values: [Int] = []
        var i = 0
        outer: while i < chars.count {
            for n in stride(from: min(longestPart, chars.count - i), through: 2, by: -1) {
                if let v = parts[String(chars[i..<(i + n)])] {
                    values.append(v)
                    i += n
                    continue outer
                }
            }
            return nil
        }
        return values
    }

    /// Word values in spoken order → values for `EnglishNumbers.candidates(ofValues:)`.
    static func normalize(_ values: [Int]) -> [Int] {
        var out: [Int] = []
        var k = 0
        while k < values.count {
            let v = values[k]
            if v == und {
                // drei und zwanzig → 23
                if let unit = out.popLast(), k + 1 < values.count { out.append(values[k + 1] + unit); k += 2 } else { k += 1 }
            } else if v == 20, out.last == 4 {
                out[out.count - 1] = 80 // quatre-vingt(s)
                k += 1
            } else if v == 20, k + 1 < values.count, (1...9).contains(values[k + 1]),
                      out.last.map({ $0 >= 20 && $0 < 100 }) != true {
                out.append(20 + values[k + 1]) // veinti + tres
                k += 2
            } else {
                out.append(v)
                k += 1
            }
        }
        return out
    }

    static func candidates(in s: String) -> Set<String> {
        var out = Set<String>()
        var group: [Int] = []
        func flush() {
            if !group.isEmpty { out.formUnion(EnglishNumbers.candidates(ofValues: normalize(group))) }
            group = []
        }
        // Hyphens join (vingt-cinq); other non-letters end a number phrase.
        var word = ""
        func endWord() {
            defer { word = "" }
            guard !word.isEmpty else { return }
            if let values = split(word) {
                group += values
            } else if ["y", "et", "и"].contains(word), !group.isEmpty {
                return // treinta y cinco, vingt et un
            } else {
                flush()
            }
        }
        for ch in s.lowercased() {
            if PolishGuard.isWordLetter(ch) {
                word.append(ch)
            } else {
                endWord()
                if !ch.isWhitespace, ch != "-" { flush() }
            }
        }
        endWord()
        flush()
        return out
    }
}
