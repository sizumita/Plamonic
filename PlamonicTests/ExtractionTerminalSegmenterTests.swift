import XCTest

@testable import Plamonic

final class ExtractionTerminalSegmenterTests: XCTestCase {
    private func paragraphs(_ screen: String, columns: Int? = nil) -> [String] {
        TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: screen), columns: columns).map(\.text)
    }

    func testClaudeCodeScreen() {
        XCTAssertEqual(paragraphs(ExtractionFixtures.claudeCodeScreen), ExtractionFixtures.claudeCodeExpected)
    }

    func testCodexScreen() {
        XCTAssertEqual(paragraphs(ExtractionFixtures.codexScreen), ExtractionFixtures.codexExpected)
    }

    func testPanesPromptsAndShortLines() {
        XCTAssertEqual(paragraphs(ExtractionFixtures.paneScreen, columns: 70), ExtractionFixtures.paneExpected)
    }

    func testSpansPointAtKeptTextInUTF16() throws {
        let base = 1000
        let screen = ExtractionFixtures.claudeCodeScreen
        let result = TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: screen, baseOffset: base))
        let ns = screen as NSString

        let latin = try XCTUnwrap(result.first { $0.text.hasPrefix("I'll start") })
        XCTAssertEqual(latin.spans.count, 2)
        XCTAssertEqual(
            ns.substring(with: NSRange(location: latin.spans[0].location - base, length: latin.spans[0].length)),
            "I'll start by reading the overlay sources to understand how")

        let cjk = try XCTUnwrap(result.first { $0.text.hasPrefix("オーバーレイ") })
        XCTAssertEqual(
            ns.substring(with: NSRange(location: cjk.spans[1].location - base, length: cjk.spans[1].length)),
            "を描画します。")
    }

    func testLineClassification() {
        XCTAssertEqual(TerminalSegmenter.classify("╰──────╯"), .border)
        XCTAssertEqual(TerminalSegmenter.classify("─ Worked for 1m 05s ─────────"), .border)
        XCTAssertEqual(TerminalSegmenter.classify("✶ Pondering… (esc to interrupt)"), .chrome)
        XCTAssertEqual(TerminalSegmenter.classify("· Combobulating…"), .chrome)
        XCTAssertEqual(TerminalSegmenter.classify("⏵⏵ accept edits on (shift+tab to cycle)"), .chrome)
        XCTAssertEqual(TerminalSegmenter.classify("> fix the bug"), .prompt)
        XCTAssertEqual(TerminalSegmenter.classify("user@host ~/src % make"), .prompt)
        XCTAssertEqual(TerminalSegmenter.classify("~/src/app main ✗"), .prompt)
        XCTAssertEqual(TerminalSegmenter.classify("⏺ Bash(git status)"), .toolHeader)
        XCTAssertEqual(TerminalSegmenter.classify("⎿  Read 12 lines"), .toolOutput)
        XCTAssertEqual(TerminalSegmenter.classify("• Ran npm test"), .toolHeader)
        XCTAssertEqual(TerminalSegmenter.classify("const x = 1;"), .code)
        XCTAssertEqual(TerminalSegmenter.classify("This is prose."), .content)
        XCTAssertEqual(TerminalSegmenter.classify("/help for help"), .content)
        XCTAssertEqual(
            TerminalSegmenter.classify("[bot] deployed", ignore: IgnorePatterns(["^\\[bot\\]"])), .ignored)
    }

    func testFooterPhrasesCountOnlyWhereFootersPutThem() {
        // Footer hints: separated, at the start of the row, or in parentheses.
        XCTAssertEqual(TerminalSegmenter.classify("⇧⏎ newline   ⌃T transcript   ⌃C quit"), .chrome)
        XCTAssertEqual(TerminalSegmenter.classify("Showing detailed transcript · ctrl+o to toggle"), .chrome)
        XCTAssertEqual(TerminalSegmenter.classify("2 background tasks"), .chrome)
        XCTAssertEqual(TerminalSegmenter.classify("Read 3 files (ctrl+o to expand)"), .chrome)
        XCTAssertEqual(TerminalSegmenter.classify("Context left until auto-compact: 12%"), .chrome)
        // The same words in prose.
        XCTAssertEqual(TerminalSegmenter.classify("to end with a newline, so a missing final newline drops the"), .content)
        XCTAssertEqual(TerminalSegmenter.classify("last record. Open the transcript view to see what was sent"), .content)
        XCTAssertEqual(TerminalSegmenter.classify("for agents that run in the background, then retry the job."), .content)
        XCTAssertEqual(TerminalSegmenter.classify("Press Esc to cancel the dialog first."), .content)
    }

    func testWrappedProseStaysOneParagraph() {
        let screen = [
            "⏺ The parser reads one record per line and expects every entry",
            "  to end with a newline, so a missing final newline drops the",
            "  last record. Open the transcript view to see what was sent",
            "  for agents that run in the background, then retry the job.",
            "",
            // Rows 2 and 4 look like code on their own ("let ... (", a trailing ";").
            "⏺ I could not reproduce the crash on this machine, so please",
            "  let me know (with the full log) whether it still happens",
            "  after the cache is rebuilt, which can take a minute because",
            "  the indexer reads every file of the project before it starts;",
            "  you can keep working in the meantime and nothing is lost.",
            "",
            // Row 2 matches a per-line ignore pattern for context meters.
            "⏺ Most of the slowdown comes from the model itself, and about",
            "  50% context dependent work happens before the first token is",
            "  produced, so shorter prompts help more than a faster disk.",
            "",
            "⏺ Done. The overlay now redraws only the panels that changed.",
            "✻ Thinking… (3s · esc to interrupt)",
        ].joined(separator: "\n")
        let ignore = IgnorePatterns([#"(?i)\b\d{1,3}%\s+context( window)?( left| used)?\b"#])
        let result = TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: screen), ignore: ignore)
        XCTAssertEqual(
            result.map(\.text),
            [
                "The parser reads one record per line and expects every entry to end with a newline, so a missing final newline drops the last record. Open the transcript view to see what was sent for agents that run in the background, then retry the job.",
                "I could not reproduce the crash on this machine, so please let me know (with the full log) whether it still happens after the cache is rebuilt, which can take a minute because the indexer reads every file of the project before it starts; you can keep working in the meantime and nothing is lost.",
                "Most of the slowdown comes from the model itself, and about 50% context dependent work happens before the first token is produced, so shorter prompts help more than a faster disk.",
                "Done. The overlay now redraws only the panels that changed.",
            ])
        XCTAssertEqual(result.map(\.spans.count), [4, 5, 3, 1])
    }

    func testPresetIgnorePatternsKeepProse() {
        // The terminal presets' per-line patterns must not cut prose that mentions keys or context.
        let ignore = IgnorePatterns(AppPresets.terminalIgnorePatterns)
        let screen = [
            "⏺ The command palette lists every action of the current window.",
            "  You can hit Cmd+K and then type the command name to run it, or",
            "  pick it from the list with the arrow keys and press Return.",
        ].joined(separator: "\n")
        let result = TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: screen), ignore: ignore)
        XCTAssertEqual(
            result.map(\.text),
            [
                "The command palette lists every action of the current window. You can hit Cmd+K and then type the command name to run it, or pick it from the list with the arrow keys and press Return."
            ])
        XCTAssertEqual(
            TerminalSegmenter.classify("• Read the config loader first; it decides which profile wins.", ignore: ignore),
            .content)
        XCTAssertEqual(
            TerminalSegmenter.classify("The new build now uses 80% context and finishes sooner.", ignore: ignore),
            .content)
        // Footers are still dropped (as chrome or by the patterns).
        XCTAssertNotEqual(TerminalSegmenter.classify("42% context left · ? for shortcuts", ignore: ignore), .content)
        XCTAssertNotEqual(TerminalSegmenter.classify("ctrl+t to show todos", ignore: ignore), .content)
    }

    func testMaxParagraphsKeepsTheBottom() {
        let screen = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let result = TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: screen), maxParagraphs: 2)
        XCTAssertEqual(result.map(\.text), ["Second paragraph.", "Third paragraph."])
    }

    func testFragmentsSplitAtVerticalBorders() {
        let line = TerminalLine(row: 0, text: "│ left │ right", utf16Offset: 0)
        let fragments = TerminalSegmenter.fragments(of: line).filter { !$0.text.isEmpty }
        XCTAssertEqual(fragments.map(\.text), ["left", "right"])
        XCTAssertEqual(fragments.map(\.key), [1, 8])
        XCTAssertEqual(fragments[0].paneRight, 7)
    }
}
