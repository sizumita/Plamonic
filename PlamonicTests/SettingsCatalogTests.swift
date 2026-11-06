import AppKit
import XCTest

@testable import Plamonic

final class SettingsCatalogTests: XCTestCase {
    func testLanguageCatalog() {
        XCTAssertEqual(LanguageCatalog.all.count, 54, "53 languages + ja(easy)")
        XCTAssertEqual(Set(LanguageCatalog.all.map(\.code)).count, 54)
        XCTAssertEqual(LanguageCatalog.displayName(for: "ja(easy)"), "やさしい日本語")
        XCTAssertEqual(LanguageCatalog.displayName(for: "zh-hant"), "中国語（繁体字）")
        XCTAssertFalse(LanguageCatalog.sourceLanguages.contains { $0.code == LanguageCatalog.easyJapaneseCode })
        XCTAssertTrue(LanguageCatalog.supportsForm("ja"))
        XCTAssertFalse(LanguageCatalog.supportsForm("ja(easy)"))
        XCTAssertEqual(LanguageCatalog.baseLanguage(of: "ja(easy)"), "ja")
    }

    func testLanguageIdentifierMapping() {
        XCTAssertEqual(LanguageCatalog.plamoCode(forLanguageIdentifier: "zh-Hant"), "zh-hant")
        XCTAssertEqual(LanguageCatalog.plamoCode(forLanguageIdentifier: "zh_TW"), "zh-hant")
        XCTAssertEqual(LanguageCatalog.plamoCode(forLanguageIdentifier: "zh-Hans"), "zh-hans")
        XCTAssertEqual(LanguageCatalog.plamoCode(forLanguageIdentifier: "en-US"), "en")
        XCTAssertEqual(LanguageCatalog.plamoCode(forLanguageIdentifier: "fil"), "tl")
        XCTAssertNil(LanguageCatalog.plamoCode(forLanguageIdentifier: "pt-BR"))
    }

    func testHotkeyFormatting() {
        let toggle = GlobalSettings().toggleHotkey!
        XCTAssertEqual(HotkeyKeyNames.fallbackName(for: toggle.keyCode), "T")
        XCTAssertEqual(toggle.modifierSymbols, "⌃⌥")
        XCTAssertTrue(toggle.displayString.hasPrefix("⌃⌥"))

        let all = HotkeySpec(keyCode: 0, modifierFlags: [.command, .shift, .option, .control])
        XCTAssertEqual(all.modifierSymbols, "⌃⌥⇧⌘")
        XCTAssertEqual(all.modifierFlags, [.command, .shift, .option, .control])
        XCTAssertFalse(HotkeySpec(keyCode: 0, modifierFlags: [.shift]).isValidGlobalHotkey)
        XCTAssertTrue(HotkeySpec(keyCode: 0x50, carbonModifiers: 0).isValidGlobalHotkey, "F19 alone")
        XCTAssertEqual(HotkeyKeyNames.fallbackName(for: 0x31), "Space")
    }

    @MainActor
    func testHotkeyCenterRegistration() throws {
        let center = HotkeyCenter()
        let spec = HotkeySpec(keyCode: 0x50, modifierFlags: [.command, .shift, .option, .control])  // ⌃⌥⇧⌘F19
        try center.register(id: "test", spec: spec) {}
        XCTAssertEqual(center.registeredIDs, ["test"])
        center.isSuspended = true
        center.isSuspended = false
        XCTAssertEqual(center.spec(for: "test"), spec)
        center.unregisterAll()
        XCTAssertTrue(center.registeredIDs.isEmpty)
    }

    @MainActor
    func testOnlyOneHotkeyRecorderRecords() throws {
        let center = HotkeyCenter.shared
        try XCTSkipIf(center.isSuspended, "another recorder is recording")
        let first = HotkeyRecorderModel()
        let second = HotkeyRecorderModel()
        first.start { _ in }
        XCTAssertTrue(center.isSuspended)
        second.start { _ in }
        XCTAssertFalse(first.isRecording, "starting a second recorder stops the first (and its key monitor)")
        XCTAssertTrue(second.isRecording)
        XCTAssertTrue(center.isSuspended, "the second recorder took over the suspension")
        second.stop()
        XCTAssertFalse(center.isSuspended, "global hotkeys come back when recording ends")
        first.stop()
        XCTAssertFalse(center.isSuspended)
    }

    func testGlossaryFile() throws {
        let terms = [GlossaryTerm(source: "Slack", target: "スラック"), GlossaryTerm(source: "", target: "x")]
        let back = try GlossaryFile.importTerms(from: GlossaryFile.export(terms))
        XCTAssertEqual(back.map(\.source), ["Slack"])
        XCTAssertEqual(back.first?.target, "スラック")
        XCTAssertEqual(try GlossaryFile.importTerms(from: Data(#"{"PR": "プルリクエスト"}"#.utf8)).first?.target, "プルリクエスト")
        XCTAssertThrowsError(try GlossaryFile.importTerms(from: Data("[1,2]".utf8)))
        // One entry without the brackets is that entry, not the terms "source" and "target".
        let single = try GlossaryFile.importTerms(from: Data(#"{"source": " PR ", "target": "プルリクエスト"}"#.utf8))
        XCTAssertEqual(single.map(\.source), ["PR"])
        XCTAssertEqual(single.first?.target, "プルリクエスト")
        let copied = try GlossaryFile.importTerms(
            from: Data(#"{"id": "8C1F6E0A-6A43-4C38-9D57-3D0C2A3B9E11", "src": "LGTM", "tgt": "承認します"}"#.utf8))
        XCTAssertEqual(copied.map(\.source), ["LGTM"])
        XCTAssertEqual(
            try GlossaryFile.importTerms(from: Data(#"{"source": "ソース", "PR": "プルリクエスト"}"#.utf8)).map(\.source),
            ["PR", "source"], "a map that only shares one key with an entry stays a map")

        // Entries without a target are skipped (PLaMo rejects them) and counted for the message.
        let partial = try GlossaryFile.importGlossary(
            from: Data(#"[{"source": "deploy", "target": ""}, {"source": "PR", "target": "プルリクエスト"}]"#.utf8))
        XCTAssertEqual(partial.terms.map(\.source), ["PR"])
        XCTAssertEqual(partial.skippedWithoutTarget, 1)
        let map = try GlossaryFile.importGlossary(from: Data(#"{"deploy": " ", "PR": "プルリクエスト"}"#.utf8))
        XCTAssertEqual(map.terms.map(\.source), ["PR"])
        XCTAssertEqual(map.skippedWithoutTarget, 1)

        let merged = GlossaryFile.merge(
            terms, with: [GlossaryTerm(source: "Slack", target: "Slack"), GlossaryTerm(source: "A", target: "B")])
        XCTAssertEqual(merged.added, 1)
        XCTAssertEqual(merged.updated, 1)
    }

    func testRuleSuggestions() {
        XCTAssertEqual(RuleSuggestions.suggestedPrefix(forClass: "messageContent_c19a55"), "messageContent_")
        XCTAssertEqual(RuleSuggestions.suggestedPrefix(forClass: "embedDescription__a1b2c"), "embedDescription__")
        XCTAssertEqual(RuleSuggestions.suggestedPrefix(forClass: "p-rich_text_section"), "p-rich_text_section")
        XCTAssertEqual(RuleSuggestions.suggestedPrefix(forClass: "scroll-view__viewport"), "scroll-view__viewport")
        XCTAssertEqual(RuleSuggestions.suggestedPrefix(forClass: "group/message-row"), "group/message-row")

        let element = ElementDescriptor(
            role: "AXGroup", subrole: "AXDocument", roleDescription: nil,
            domClasses: ["markup_abc123", "messageContent_c19a55"], identifier: nil, axFrame: nil, textPreview: "")
        XCTAssertEqual(RuleSuggestions.defaultMatcher(for: element).domClassPrefixes, ["markup_"])
        var bare = element
        bare.domClasses = []
        XCTAssertEqual(RuleSuggestions.defaultMatcher(for: bare), ElementMatcher(roles: ["AXGroup"], subroles: ["AXDocument"]))
    }
}
