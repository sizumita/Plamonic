import Foundation

/// One language PLaMo 3 Translate accepts as `lang`.
struct PlamoLanguage: Identifiable, Hashable, Sendable {
    /// PLaMo code ("ja", "zh-hans", "ja(easy)", ...).
    let code: String
    let japaneseName: String
    let englishName: String

    var id: String { code }
}

/// The languages PLaMo 3 Translate supports, with Japanese display names.
enum LanguageCatalog {
    static let easyJapaneseCode = "ja(easy)"

    /// 53 PLaMo languages plus やさしい日本語. Common languages first, the rest by code.
    static let all: [PlamoLanguage] = [
        PlamoLanguage(code: "ja", japaneseName: "日本語", englishName: "Japanese"),
        PlamoLanguage(code: "ja(easy)", japaneseName: "やさしい日本語", englishName: "Easy Japanese"),
        PlamoLanguage(code: "en", japaneseName: "英語", englishName: "English"),
        PlamoLanguage(code: "zh-hans", japaneseName: "中国語（簡体字）", englishName: "Chinese (Simplified)"),
        PlamoLanguage(code: "zh-hant", japaneseName: "中国語（繁体字）", englishName: "Chinese (Traditional)"),
        PlamoLanguage(code: "ko", japaneseName: "韓国語", englishName: "Korean"),
        PlamoLanguage(code: "ar", japaneseName: "アラビア語", englishName: "Arabic"),
        PlamoLanguage(code: "az", japaneseName: "アゼルバイジャン語", englishName: "Azerbaijani"),
        PlamoLanguage(code: "be", japaneseName: "ベラルーシ語", englishName: "Belarusian"),
        PlamoLanguage(code: "bg", japaneseName: "ブルガリア語", englishName: "Bulgarian"),
        PlamoLanguage(code: "bn", japaneseName: "ベンガル語", englishName: "Bengali"),
        PlamoLanguage(code: "ca", japaneseName: "カタルーニャ語", englishName: "Catalan"),
        PlamoLanguage(code: "ceb", japaneseName: "セブアノ語", englishName: "Cebuano"),
        PlamoLanguage(code: "de", japaneseName: "ドイツ語", englishName: "German"),
        PlamoLanguage(code: "es", japaneseName: "スペイン語", englishName: "Spanish"),
        PlamoLanguage(code: "et", japaneseName: "エストニア語", englishName: "Estonian"),
        PlamoLanguage(code: "eu", japaneseName: "バスク語", englishName: "Basque"),
        PlamoLanguage(code: "fa", japaneseName: "ペルシア語", englishName: "Persian"),
        PlamoLanguage(code: "fr", japaneseName: "フランス語", englishName: "French"),
        PlamoLanguage(code: "gu", japaneseName: "グジャラート語", englishName: "Gujarati"),
        PlamoLanguage(code: "he", japaneseName: "ヘブライ語", englishName: "Hebrew"),
        PlamoLanguage(code: "hi", japaneseName: "ヒンディー語", englishName: "Hindi"),
        PlamoLanguage(code: "hr", japaneseName: "クロアチア語", englishName: "Croatian"),
        PlamoLanguage(code: "hu", japaneseName: "ハンガリー語", englishName: "Hungarian"),
        PlamoLanguage(code: "hy", japaneseName: "アルメニア語", englishName: "Armenian"),
        PlamoLanguage(code: "id", japaneseName: "インドネシア語", englishName: "Indonesian"),
        PlamoLanguage(code: "it", japaneseName: "イタリア語", englishName: "Italian"),
        PlamoLanguage(code: "jv", japaneseName: "ジャワ語", englishName: "Javanese"),
        PlamoLanguage(code: "ka", japaneseName: "ジョージア語", englishName: "Georgian"),
        PlamoLanguage(code: "kk", japaneseName: "カザフ語", englishName: "Kazakh"),
        PlamoLanguage(code: "km", japaneseName: "クメール語", englishName: "Khmer"),
        PlamoLanguage(code: "lt", japaneseName: "リトアニア語", englishName: "Lithuanian"),
        PlamoLanguage(code: "lv", japaneseName: "ラトビア語", englishName: "Latvian"),
        PlamoLanguage(code: "ml", japaneseName: "マラヤーラム語", englishName: "Malayalam"),
        PlamoLanguage(code: "mr", japaneseName: "マラーティー語", englishName: "Marathi"),
        PlamoLanguage(code: "ms", japaneseName: "マレー語", englishName: "Malay"),
        PlamoLanguage(code: "my", japaneseName: "ミャンマー語", englishName: "Burmese"),
        PlamoLanguage(code: "ne", japaneseName: "ネパール語", englishName: "Nepali"),
        PlamoLanguage(code: "nl", japaneseName: "オランダ語", englishName: "Dutch"),
        PlamoLanguage(code: "pa", japaneseName: "パンジャブ語", englishName: "Punjabi"),
        PlamoLanguage(code: "pl", japaneseName: "ポーランド語", englishName: "Polish"),
        PlamoLanguage(code: "ru", japaneseName: "ロシア語", englishName: "Russian"),
        PlamoLanguage(code: "si", japaneseName: "シンハラ語", englishName: "Sinhala"),
        PlamoLanguage(code: "sk", japaneseName: "スロバキア語", englishName: "Slovak"),
        PlamoLanguage(code: "sl", japaneseName: "スロベニア語", englishName: "Slovenian"),
        PlamoLanguage(code: "sr", japaneseName: "セルビア語", englishName: "Serbian"),
        PlamoLanguage(code: "sw", japaneseName: "スワヒリ語", englishName: "Swahili"),
        PlamoLanguage(code: "ta", japaneseName: "タミル語", englishName: "Tamil"),
        PlamoLanguage(code: "te", japaneseName: "テルグ語", englishName: "Telugu"),
        PlamoLanguage(code: "th", japaneseName: "タイ語", englishName: "Thai"),
        PlamoLanguage(code: "tl", japaneseName: "タガログ語", englishName: "Tagalog"),
        PlamoLanguage(code: "ur", japaneseName: "ウルドゥー語", englishName: "Urdu"),
        PlamoLanguage(code: "uz", japaneseName: "ウズベク語", englishName: "Uzbek"),
        PlamoLanguage(code: "vi", japaneseName: "ベトナム語", englishName: "Vietnamese"),
    ]

    /// Every language can be a target, including やさしい日本語.
    static var targetLanguages: [PlamoLanguage] { all }

    /// やさしい日本語 is output-only, so it cannot be fixed as the source language.
    static let sourceLanguages: [PlamoLanguage] = all.filter { $0.code != easyJapaneseCode }

    private static let byCode: [String: PlamoLanguage] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.code, $0) })

    static func language(for code: String) -> PlamoLanguage? { byCode[code] }

    static func isValidTarget(_ code: String) -> Bool { byCode[code] != nil }

    static func isValidSource(_ code: String) -> Bool { code != easyJapaneseCode && byCode[code] != nil }

    /// Japanese display name, or the code itself for unknown codes.
    static func displayName(for code: String) -> String { byCode[code]?.japaneseName ?? code }

    /// The `form` (plain / polite) option only exists for plain Japanese output.
    static func supportsForm(_ code: String) -> Bool { code == "ja" }

    /// The language a code is written in, for same-language checks ("ja(easy)" -> "ja").
    static func baseLanguage(of code: String) -> String { code == easyJapaneseCode ? "ja" : code }

    /// Maps a BCP 47 / NLLanguage identifier ("zh-Hant", "en-US", "fil", ...) to a PLaMo code, or nil if unsupported.
    static func plamoCode(forLanguageIdentifier identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = normalized.split(separator: "-").map(String.init)
        guard let primary = parts.first, !primary.isEmpty else { return nil }
        if primary == "zh" {
            let traditional = parts.dropFirst().contains { ["hant", "tw", "hk", "mo"].contains($0) }
            return traditional ? "zh-hant" : "zh-hans"
        }
        let aliases = ["iw": "he", "in": "id", "fil": "tl", "jw": "jv", "zsm": "ms", "pes": "fa"]
        let code = aliases[primary] ?? primary
        return byCode[code] != nil && code != easyJapaneseCode ? code : nil
    }
}
