import XCTest

@testable import PlamoKit

final class PromptBuilderTests: XCTestCase {
    func testReferencePrompts() throws {
        let ref = try XCTUnwrap(ReferenceFile.load("reference"))
        XCTAssertFalse(ref.cases.isEmpty)
        for c in ref.cases {
            XCTAssertEqual(try PlamoPromptBuilder.prompt(for: c.request), c.prompt)
        }
    }

    func testLeadingBOSText() throws {
        let p = try PlamoPromptBuilder.prompt(for: PlamoTranslationRequest(text: "Hi", targetLanguage: "en"))
        XCTAssertTrue(p.hasPrefix("<|plamo:bos|><|plamo:tag|>dataset<|plamo:msg|>translation"))
        XCTAssertTrue(p.hasSuffix("<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>"))
    }

    func testEmptyContextIsOmitted() throws {
        let p = try PlamoPromptBuilder.prompt(for: PlamoTranslationRequest(text: "Hi", targetLanguage: "ja", context: ""))
        XCTAssertFalse(p.contains("context"))
    }

    func testLanguageCodes() {
        for ok in ["ja", "en", "zh-hans", "zh-hant", "yue", "ja(easy)"] {
            XCTAssertTrue(PlamoPromptBuilder.isValidLanguageCode(ok), ok)
        }
        for bad in ["", "EN", "en-US", "zh-han", "e", "engl", "a-b-c", "ja (easy)", "pt_br"] {
            XCTAssertFalse(PlamoPromptBuilder.isValidLanguageCode(bad), bad)
        }
    }

    func testValidationErrors() {
        func rejects(_ r: PlamoTranslationRequest, line: UInt = #line) {
            XCTAssertThrowsError(try PlamoPromptBuilder.prompt(for: r), line: line)
        }
        rejects(PlamoTranslationRequest(text: "  \n", targetLanguage: "ja"))
        rejects(PlamoTranslationRequest(text: "hi", targetLanguage: "JA"))
        rejects(PlamoTranslationRequest(text: "hi", targetLanguage: "en", form: "polite"))
        rejects(PlamoTranslationRequest(text: "hi", targetLanguage: "ja", form: "casual"))
        rejects(PlamoTranslationRequest(text: "a <|plamo:tag|> b", targetLanguage: "ja"))
        rejects(PlamoTranslationRequest(text: "a <|plamo:\u{301}", targetLanguage: "ja"))
        rejects(PlamoTranslationRequest(text: "hi", targetLanguage: "ja", context: "<|plamo:x"))
        rejects(
            PlamoTranslationRequest(
                text: "hi", targetLanguage: "ja", glossary: [PlamoGlossaryEntry(source: "", target: "x")]))
        rejects(
            PlamoTranslationRequest(
                text: "hi", targetLanguage: "ja", history: [PlamoHistoryPair(source: "a", translation: " ")]))
        XCTAssertNoThrow(
            try PlamoPromptBuilder.prompt(for: PlamoTranslationRequest(text: "hi", targetLanguage: "ja", form: "plain")))
    }

    func testDefaultTokenBudget() {
        XCTAssertEqual(PlamoTranslationRequest(text: "abc", targetLanguage: "ja").effectiveMaxNewTokens, 73)
        XCTAssertEqual(
            PlamoTranslationRequest(text: String(repeating: "x", count: 1000), targetLanguage: "ja")
                .effectiveMaxNewTokens, 1024)
        XCTAssertEqual(PlamoTranslationRequest(text: "abc", targetLanguage: "ja", maxNewTokens: 5).effectiveMaxNewTokens, 5)
    }
}
