import Foundation
import NaturalLanguage

/// Language identification for the "skip text already in the target language" filter.
/// NLLanguageRecognizer does the heavy lifting; script counts decide the cases it handles badly
/// (short text, Japanese written only in kanji, mixed-language text).
enum LanguageDetector {
    /// The 53 PLaMo 3 Translate language codes ("ja(easy)" is a target-only variant of "ja").
    static let supportedLanguageCodes: Set<String> = [
        "ja", "en", "zh-hans", "zh-hant", "ko", "ar", "az", "be", "bg", "bn", "ca", "ceb", "de", "es", "et", "eu",
        "fa", "fr", "gu", "he", "hi", "hr", "hu", "hy", "id", "it", "jv", "ka", "kk", "km", "lt", "lv", "ml", "mr",
        "ms", "my", "ne", "nl", "pa", "pl", "ru", "si", "sk", "sl", "sr", "sw", "ta", "te", "th", "tl", "ur", "uz",
        "vi",
    ]

    /// Maps a NaturalLanguage language to its PLaMo code, or nil when PLaMo does not support it
    /// (e.g. Norwegian "nb"/"no", Portuguese, Turkish).
    static func plamoCode(for language: NLLanguage) -> String? {
        let code = baseCode(language.rawValue)
        return supportedLanguageCodes.contains(code) ? code : nil
    }

    /// Normalizes a language code for comparison: lowercased, "ja(easy)" -> "ja",
    /// "zh"/"zh-cn" -> "zh-hans", "zh-tw"/"zh-hk" -> "zh-hant", region subtags dropped ("en-US" -> "en").
    static func baseCode(_ code: String) -> String {
        let lower = code.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
        if lower.hasPrefix("ja(") || lower.hasPrefix("ja-") { return "ja" }
        if lower == "zh" || lower.hasPrefix("zh-hans") || lower == "zh-cn" || lower == "zh-sg" { return "zh-hans" }
        if lower.hasPrefix("zh-hant") || lower == "zh-tw" || lower == "zh-hk" || lower == "zh-mo" { return "zh-hant" }
        if lower == "fil" { return "tl" }
        if let dash = lower.firstIndex(of: "-") { return String(lower[..<dash]) }
        return lower
    }

    /// True when the text should not be translated because it is already in `target`
    /// and the policy says to skip such text.
    static func shouldSkip(
        _ text: String, target: String, policy: SameLanguagePolicy, kanaNearby: Bool = false
    ) -> Bool {
        guard policy == .skip else { return false }
        return isInLanguage(text, target: target, kanaNearby: kanaNearby)
    }

    /// True only when the text is confidently written in `target` ("ja(easy)" counts as "ja").
    /// Short, mixed or ambiguous text returns false so it still gets translated.
    /// `kanaNearby`: neighbouring text in the same window contains kana, which makes
    /// kanji-only text more likely Japanese than Chinese.
    static func isInLanguage(_ text: String, target: String, kanaNearby: Bool = false) -> Bool {
        let base = baseCode(target)
        let prose = stripNonProse(text)
        let profile = ScriptProfile(prose)
        guard profile.letters > 0 else { return false }

        switch base {
        case "ja":
            return isJapanese(prose, profile: profile, kanaNearby: kanaNearby)
        case "zh-hans", "zh-hant":
            return chineseVariant(prose, profile: profile, kanaNearby: kanaNearby) == base
        default:
            return isInScriptLanguage(prose, profile: profile, base: base)
        }
    }

    /// Best guess of the PLaMo code of the text's main language, or nil when unknown / unsupported.
    static func dominantLanguage(of text: String, kanaNearby: Bool = false) -> String? {
        let prose = stripNonProse(text)
        let profile = ScriptProfile(prose)
        guard profile.letters > 0 else { return nil }
        if isJapanese(prose, profile: profile, kanaNearby: kanaNearby) { return "ja" }
        if let zh = chineseVariant(prose, profile: profile, kanaNearby: kanaNearby) { return zh }
        if Double(profile.hangul) / Double(profile.letters) >= 0.5 { return "ko" }
        guard let top = hypotheses(prose, constraints: nil).first else { return nil }
        return plamoCode(for: top.key)
    }

    /// True when the text contains hiragana, katakana or Japanese iteration marks.
    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { Script.of($0) == .kana }
    }

    // MARK: - Japanese / Chinese

    private static func isJapanese(_ prose: String, profile: ScriptProfile, kanaNearby: Bool) -> Bool {
        let cjk = profile.kana + profile.han
        let cjkShare = Double(cjk) / Double(profile.letters)
        if profile.kana > 0 {
            if cjkShare >= 0.5 { return true }
            if cjkShare >= 0.3, topLanguage(prose, constraints: nil) == "ja" { return true }
            return false  // mostly foreign text with a few Japanese words
        }
        guard profile.han > 0, Double(profile.han) / Double(profile.letters) >= 0.7 else { return false }
        // Kanji only: Japanese or Chinese.
        if ChineseMarkers.count(in: prose).total > 0 { return false }
        if kanaNearby { return true }
        return topLanguage(prose, constraints: [.japanese, .simplifiedChinese, .traditionalChinese]) == "ja"
    }

    /// "zh-hans" / "zh-hant" when the text is Chinese, nil otherwise.
    private static func chineseVariant(_ prose: String, profile: ScriptProfile, kanaNearby: Bool) -> String? {
        let cjk = profile.kana + profile.han
        guard profile.han > 0, Double(cjk) / Double(profile.letters) >= 0.6 else { return nil }
        if profile.kana >= 2 || Double(profile.kana) / Double(cjk) >= 0.1 { return nil }  // Japanese
        let markers = ChineseMarkers.count(in: prose)
        if markers.total == 0 && (kanaNearby || profile.kana > 0) { return nil }
        if markers.simplified > markers.traditional { return "zh-hans" }
        if markers.traditional > markers.simplified { return "zh-hant" }
        let constraints: [NLLanguage] =
            markers.total > 0
            ? [.simplifiedChinese, .traditionalChinese]
            : [.simplifiedChinese, .traditionalChinese, .japanese]
        switch topLanguage(prose, constraints: constraints) {
        case "zh-hans": return "zh-hans"
        case "zh-hant": return "zh-hant"
        default: return nil
        }
    }

    // MARK: - Other languages

    private static func isInScriptLanguage(_ prose: String, profile: ScriptProfile, base: String) -> Bool {
        guard let scripts = expectedScripts[base] else {
            return isConfidentNL(prose, profile: profile, base: base)
        }
        let inScript = scripts.reduce(0) { $0 + profile.count(of: $1) }
        guard Double(inScript) / Double(profile.letters) >= 0.7 else { return false }
        // Scripts used by a single PLaMo language decide on their own.
        if scripts.allSatisfy({ uniqueScripts.contains($0) }) { return inScript >= 2 }
        return isConfidentNL(prose, profile: profile, base: base)
    }

    private static func isConfidentNL(_ prose: String, profile: ScriptProfile, base: String) -> Bool {
        // Shared scripts (Latin, Cyrillic, Arabic, Devanagari) need enough text for NL to be reliable.
        guard profile.letters >= 12 else { return false }
        guard let top = hypotheses(prose, constraints: nil).first else { return false }
        return plamoCode(for: top.key) == base && top.value >= 0.6
    }

    private static let expectedScripts: [String: [Script]] = {
        var map: [String: [Script]] = [:]
        for code in [
            "en", "de", "es", "fr", "it", "nl", "pl", "ca", "ceb", "et", "eu", "hr", "hu", "id", "jv", "lt", "lv",
            "ms", "sk", "sl", "sw", "tl", "vi", "az", "uz",
        ] {
            map[code] = [.latin]
        }
        for code in ["ru", "bg", "be", "kk"] { map[code] = [.cyrillic] }
        map["sr"] = [.cyrillic, .latin]
        for code in ["ar", "fa", "ur"] { map[code] = [.arabic] }
        for code in ["hi", "mr", "ne"] { map[code] = [.devanagari] }
        map["ko"] = [.hangul]
        map["he"] = [.hebrew]
        map["th"] = [.thai]
        map["bn"] = [.bengali]
        map["gu"] = [.gujarati]
        map["pa"] = [.gurmukhi]
        map["ta"] = [.tamil]
        map["te"] = [.telugu]
        map["ml"] = [.malayalam]
        map["si"] = [.sinhala]
        map["my"] = [.myanmar]
        map["km"] = [.khmer]
        map["ka"] = [.georgian]
        map["hy"] = [.armenian]
        return map
    }()

    private static let uniqueScripts: Set<Script> = [
        .hangul, .hebrew, .thai, .bengali, .gujarati, .gurmukhi, .tamil, .telugu, .malayalam, .sinhala, .myanmar,
        .khmer, .georgian, .armenian,
    ]

    // MARK: - NaturalLanguage

    private static func hypotheses(_ text: String, constraints: [NLLanguage]?) -> [(key: NLLanguage, value: Double)] {
        let recognizer = NLLanguageRecognizer()
        if let constraints { recognizer.languageConstraints = constraints }
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
    }

    private static func topLanguage(_ text: String, constraints: [NLLanguage]?) -> String? {
        guard let top = hypotheses(text, constraints: constraints).first else { return nil }
        return plamoCode(for: top.key)
    }

    // MARK: - Pre-processing

    private static let nonProseRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:https?://|www\.)\S+|[\w.+-]+@[\w-]+\.[\w.-]+|`[^`\n]*`|<[@#!][^>\s]*>|(?<!\w)[@#][\w.-]+"#,
        options: [.caseInsensitive])

    /// Removes URLs, e-mail addresses, inline code and @mentions / #channels, which say nothing
    /// about the language of the surrounding text.
    static func stripNonProse(_ text: String) -> String {
        guard let regex = nonProseRegex,
            text.contains(where: { $0 == ":" || $0 == "@" || $0 == "`" || $0 == "#" || $0 == "." })
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }
}

// MARK: - Scripts

extension LanguageDetector {
enum Script: Hashable, Sendable {
    case latin, kana, han, hangul, cyrillic, arabic, hebrew, greek, thai, devanagari, bengali, gurmukhi, gujarati
    case tamil, telugu, malayalam, sinhala, myanmar, khmer, georgian, armenian, other, none

    static func of(_ scalar: Unicode.Scalar) -> Script {
        let v = scalar.value
        switch v {
        case 0x3041...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D, 0x3005, 0x3006:
            // 0x30FB (middle dot) is punctuation, not a letter.
            return v == 0x30FB || v == 0x30A0 ? .none : .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return .han
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
            return .hangul
        default:
            break
        }
        guard scalar.properties.isAlphabetic else { return .none }
        switch v {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F: return .cyrillic
        case 0x530...0x58F: return .armenian
        case 0x590...0x5FF: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x900...0x97F: return .devanagari
        case 0x980...0x9FF: return .bengali
        case 0xA00...0xA7F: return .gurmukhi
        case 0xA80...0xAFF: return .gujarati
        case 0xB80...0xBFF: return .tamil
        case 0xC00...0xC7F: return .telugu
        case 0xD00...0xD7F: return .malayalam
        case 0xD80...0xDFF: return .sinhala
        case 0xE00...0xE7F: return .thai
        case 0x1000...0x109F: return .myanmar
        case 0x10A0...0x10FF, 0x2D00...0x2D2F: return .georgian
        case 0x1780...0x17FF: return .khmer
        default: return .other
        }
    }
}

/// Letter counts per script (digits, punctuation, symbols and emoji are not counted).
struct ScriptProfile: Sendable {
    private(set) var counts: [Script: Int] = [:]
    private(set) var letters = 0

    init(_ text: String) {
        for scalar in text.unicodeScalars {
            let script = Script.of(scalar)
            guard script != .none else { continue }
            counts[script, default: 0] += 1
            letters += 1
        }
    }

    func count(of script: Script) -> Int { counts[script] ?? 0 }
    var kana: Int { count(of: .kana) }
    var han: Int { count(of: .han) }
    var hangul: Int { count(of: .hangul) }
    var latin: Int { count(of: .latin) }
}

/// Han characters that appear in Chinese but not in modern Japanese.
enum ChineseMarkers {
    struct Counts {
        var simplified = 0
        var traditional = 0
        var neutral = 0
        var total: Int { simplified + traditional + neutral }
    }

    // Simplified forms whose Japanese counterparts are written differently.
    static let simplifiedOnly: Set<Character> = Set(
        "们这么吗说给让对为时样个过问题见进经关头实电长门间开东车觉亲观视语话认读谁请谢该边远运连选红约级线终结统续书买卖钱错页听发变图应战层岁带归录恶欢热确种简紧务动业谈这还"
    )
    // Traditional forms whose Japanese counterparts are written differently.
    static let traditionalOnly: Set<Character> = Set(
        "們這麼嗎妳沒說讓對樣經關實覺觀讀邊續賣錢聽發變圖應戰歲帶歸錄惡歡會來國學體當與點從裡雙擊據傳處號寫灣兒臺歷卻爲"
    )
    // Pronouns and particles used in both Chinese scripts but not in Japanese.
    static let neutral: Set<Character> = Set("你她很啊嘛哦咱呢吧")

    static func count(in text: String) -> Counts {
        var counts = Counts()
        for character in text {
            if simplifiedOnly.contains(character) {
                counts.simplified += 1
            } else if traditionalOnly.contains(character) {
                counts.traditional += 1
            } else if neutral.contains(character) {
                counts.neutral += 1
            }
        }
        return counts
    }
}
}
