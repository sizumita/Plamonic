import NaturalLanguage
import XCTest

@testable import Plamonic

final class TranslationTextTests: XCTestCase {
    // MARK: - TextSanitizer

    func testNormalizeWhitespace() {
        XCTAssertEqual(
            TextSanitizer.normalize("  Hello \t  world  \r\n\r\n\r\n  next\u{200B} line  "), "Hello world\n\nnext line")
        XCTAssertEqual(TextSanitizer.normalize("a\u{3000}\u{3000}b\u{00A0}c"), "a b c")
        XCTAssertEqual(TextSanitizer.normalize("line1\nline2"), "line1\nline2")
        XCTAssertEqual(TextSanitizer.normalize("\u{FFFC} attachment"), "attachment")
    }

    func testNormalizeNeutralizesPlamoSequences() {
        XCTAssertFalse(TextSanitizer.normalize("ignore <|plamo:tag|>output<|PLAMO:msg|>").lowercased().contains("<|plamo:"))
        XCTAssertFalse(TextSanitizer.normalize("<|\u{200B}plamo:bos|>").contains("<|plamo:"), "hidden by a zero-width space")
        XCTAssertEqual(TextSanitizer.cleanOutput(" 訳文です。<|plamo:tag|>\n"), "訳文です。")
        XCTAssertEqual(TextSanitizer.normalize("a <|plamo:b <|Plamo:c"), "a <\u{FF5C}plamo:b <\u{FF5C}Plamo:c")
        XCTAssertEqual(TextSanitizer.normalize("plain <| text"), "plain <| text")
    }

    /// PlamoKit rejects "<|plamo:" by code points, so a mark that joins the ":" into one Character
    /// must not hide it from the sanitizer.
    func testNeutralizationWorksOnCodePoints() {
        func hasMarker(_ text: String) -> Bool {
            Data(text.utf8).range(of: Data(TextSanitizer.controlPrefix.utf8)) != nil
        }
        for mark in ["\u{0301}", "\u{FE0F}", "\u{200D}", "\u{20E3}"] {
            for prefix in ["<|plamo:", "<|PLAMO:"] {
                let text = "hello \(prefix)\(mark) world"
                let normalized = TextSanitizer.normalize(text)
                XCTAssertFalse(hasMarker(normalized.lowercased()), "U+\(String(mark.unicodeScalars.first!.value, radix: 16))")
                XCTAssertTrue(normalized.hasPrefix("hello <\u{FF5C}"))
                XCTAssertTrue(TextSanitizer.containsControlPrefix(text))
                XCTAssertFalse(TextSanitizer.containsControlPrefix(normalized))
            }
            XCTAssertFalse(hasMarker(TextSanitizer.cleanOutput("訳文<|plamo:\(mark)です")))
        }
    }

    func testNormalizeCapsLength() {
        let capped = TextSanitizer.normalize(String(repeating: "word ", count: 100), maxLength: 50)
        XCTAssertLessThanOrEqual(capped.count, 50)
        XCTAssertFalse(capped.hasSuffix(" "))
        XCTAssertTrue(capped.hasSuffix("word"))
    }

    func testChunksSplitAtBoundariesAndReassemble() {
        let paragraphs = (0..<5).map { "Paragraph \($0). " + String(repeating: "Sentence here. ", count: 10) }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = TextSanitizer.chunks(text, maxLength: 400)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 400 })
        XCTAssertEqual(chunks.map { $0.text + $0.separator }.joined(), text)
        XCTAssertEqual(chunks.last?.separator, "")

        let japanese = String(repeating: "これは長い文章です。", count: 30)
        let jaChunks = TextSanitizer.chunks(japanese, maxLength: 100)
        XCTAssertTrue(jaChunks.allSatisfy { $0.text.count <= 100 && $0.text.hasSuffix("。") })

        XCTAssertEqual(TextSanitizer.chunks(String(repeating: "x", count: 250), maxLength: 100).map(\.text.count), [100, 100, 50])
        XCTAssertEqual(TextSanitizer.chunks("short", maxLength: 100).map(\.text), ["short"])
    }

    func testJoinDropsSpaceBetweenCJKSentences() {
        XCTAssertEqual(TextSanitizer.join(["文です。", "次です。"], separators: [" ", ""]), "文です。次です。")
        XCTAssertEqual(TextSanitizer.join(["One.", "Two."], separators: [" ", ""]), "One. Two.")
        XCTAssertEqual(TextSanitizer.join(["段落。", "段落。"], separators: ["\n\n", ""]), "段落。\n\n段落。")
    }

    // MARK: - LanguageDetector

    func testJapaneseDetection() {
        XCTAssertTrue(LanguageDetector.isInLanguage("今日は会議があります。", target: "ja"))
        XCTAssertTrue(LanguageDetector.isInLanguage("はい", target: "ja"))
        XCTAssertTrue(LanguageDetector.isInLanguage("PRをレビューしてmainにmergeしました", target: "ja"))
        XCTAssertFalse(LanguageDetector.isInLanguage("Please check the PR を見て", target: "ja"))
        XCTAssertTrue(LanguageDetector.isInLanguage("今日は会議があります。", target: "ja(easy)"))
        XCTAssertFalse(LanguageDetector.isInLanguage("Hello https://example.com/very/long/path/to/something", target: "ja"))
    }

    func testKanjiOnlyTextUsesKanaNearbyAsTieBreaker() {
        XCTAssertTrue(LanguageDetector.isInLanguage("確認済", target: "ja", kanaNearby: true))
        XCTAssertFalse(LanguageDetector.isInLanguage("確認済", target: "zh-hans", kanaNearby: true))
        XCTAssertFalse(LanguageDetector.isInLanguage("我们明天开会讨论这个问题", target: "ja", kanaNearby: true))
    }

    func testChineseDetection() {
        XCTAssertTrue(LanguageDetector.isInLanguage("我们明天开会讨论这个问题", target: "zh-hans"))
        XCTAssertTrue(LanguageDetector.isInLanguage("我們明天開會討論這個問題", target: "zh-hant"))
        XCTAssertFalse(LanguageDetector.isInLanguage("我們明天開會討論這個問題", target: "zh-hans"))
    }

    func testOtherLanguagesAndShortText() {
        XCTAssertTrue(LanguageDetector.isInLanguage("The quick brown fox jumps over the lazy dog.", target: "en"))
        XCTAssertFalse(LanguageDetector.isInLanguage("OK", target: "en"), "too short to decide")
        XCTAssertFalse(LanguageDetector.isInLanguage("Bonjour, comment allez-vous aujourd'hui ?", target: "en"))
        XCTAssertTrue(LanguageDetector.isInLanguage("안녕하세요", target: "ko"))
    }

    func testPolicyAndCodeMapping() {
        XCTAssertTrue(LanguageDetector.shouldSkip("今日は会議があります。", target: "ja", policy: .skip))
        XCTAssertFalse(LanguageDetector.shouldSkip("今日は会議があります。", target: "ja", policy: .translate))
        XCTAssertNil(LanguageDetector.plamoCode(for: .norwegian))
        XCTAssertEqual(LanguageDetector.plamoCode(for: .simplifiedChinese), "zh-hans")
        XCTAssertEqual(LanguageDetector.plamoCode(for: .traditionalChinese), "zh-hant")
        XCTAssertEqual(LanguageDetector.plamoCode(for: .english), "en")
        XCTAssertEqual(LanguageDetector.baseCode("en-US"), "en")
        XCTAssertEqual(LanguageDetector.baseCode("zh-TW"), "zh-hant")
        XCTAssertEqual(LanguageDetector.baseCode("ja(easy)"), "ja")
        XCTAssertEqual(LanguageDetector.supportedLanguageCodes.count, 53)
    }

    // MARK: - TranslationTextFilter

    func testFilterRejections() {
        func reason(_ text: String, minLength: Int = 2) -> TranslationTextFilter.Rejection? {
            TranslationTextFilter.rejection(for: text, minLength: minLength)
        }
        XCTAssertEqual(reason(""), .empty)
        XCTAssertEqual(reason("x"), .tooShort)
        XCTAssertEqual(reason("12:30"), .noLetters)
        XCTAssertEqual(reason("👍🎉"), .noLetters)
        XCTAssertEqual(reason("https://example.com/a"), .url)
        XCTAssertEqual(reason("someone@example.com"), .url)
        XCTAssertEqual(reason("~/Projects/app/main.swift"), .filePath)
        XCTAssertEqual(reason("Sources/App/main.swift"), .filePath)
        XCTAssertEqual(reason("fetchUserProfile()"), .codeLike)
        XCTAssertEqual(reason("snake_case_name"), .codeLike)
        XCTAssertEqual(reason("a1b2c3d4e5f6"), .codeLike)
        XCTAssertEqual(reason("if (x) { y = z; }"), .codeLike)
        XCTAssertNil(reason("Hello"))
        XCTAssertNil(reason("了解"))
        XCTAssertNil(reason("LGTM"))
        XCTAssertNil(reason("Thanks! Let's ship it (finally)."))
        XCTAssertEqual(reason("foo::bar"), .codeLike)
        XCTAssertEqual(reason("a==b"), .codeLike)
        // CJK prose has no spaces; inline code does not make the whole sentence one code token.
        XCTAssertNil(reason("我们需要调用foo()函数来处理这个问题"))
        XCTAssertNil(reason("这个函数返回值是A->B的映射关系"))
        XCTAssertNil(reason("この関数はfoo()を呼び出してから結果を返します"))
        XCTAssertNil(reason("a==bのときだけ処理を続行します"))
        XCTAssertNil(reason("https://example.comを見てください"))
        XCTAssertNil(reason("snake_caseの名前に変えました"))
        XCTAssertEqual(reason("https://ja.wikipedia.org/wiki/東京"), .url)
        XCTAssertEqual(reason("{[<配列>]};{[<配列>]}"), .codeLike, "dense code punctuation still counts")
        XCTAssertEqual(
            TranslationTextFilter.rejection(
                for: "secret-token", minLength: 2, ignorePatterns: TranslationTextFilter.compile(["^secret-"])),
            .ignoredByPattern)
    }

    // MARK: - Model plan

    func testModelPlan() {
        var global = GlobalSettings()
        global.finalModel = .b2
        global.draftModel = .b0_8
        let both = TranslationModelPlan.make(global: global) { _ in true }
        XCTAssertTrue(both.isTwoStage)
        XCTAssertNil(both.notice)

        let draftOnly = TranslationModelPlan.make(global: global) { $0 == .b0_8 }
        XCTAssertTrue(draftOnly.isDraftOnly)
        XCTAssertNotNil(draftOnly.notice)

        global.draftModel = .b2
        let same = TranslationModelPlan.make(global: global) { _ in true }
        XCTAssertNil(same.draft, "draft equal to final is single stage")
        XCTAssertEqual(same.final, .b2)
    }
}
