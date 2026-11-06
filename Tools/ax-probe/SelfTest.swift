import CoreGraphics
import Foundation

/// Pure-logic checks (no AX access). Mirrors PlamonicTests/Extraction*Tests.swift.
enum SelfTest {
    static let claudeCodeScreen = [
        "╭───────────────────────────────────────────────────╮",
        "│ ✻ Welcome to Claude Code!                         │",
        "│                                                   │",
        "│   /help for help, /status for your current setup  │",
        "│                                                   │",
        "│   cwd: /Users/demo/project                        │",
        "╰───────────────────────────────────────────────────╯",
        "",
        "> explain the overlay module",
        "",
        "⏺ I'll start by reading the overlay sources to understand how",
        "  translations are drawn on top of other windows.",
        "",
        "⏺ Read(Plamonic/Overlay/OverlayWindow.swift)",
        "  ⎿  Read 120 lines (ctrl+r to expand)",
        "",
        "⏺ Bash(ls -la Plamonic/Overlay)",
        "  ⎿  total 24",
        "     drwxr-xr-x  5 demo  staff  160 Nov  5 14:41 .",
        "     -rw-r--r--  1 demo  staff  812 Nov  5 14:41 OverlayWindow.swift",
        "",
        "⏺ The overlay is a borderless panel that ignores mouse events. Each",
        "  segment gets a text layer whose font size shrinks until the",
        "  translation fits inside the original frame.",
        "",
        "  - Panels are reused per window",
        "  - Fonts shrink down to the minimum size",
        "",
        "⏺ オーバーレイはマウスイベントを無視するパネルで、各セグメントの位置に訳文",
        "  を描画します。",
        "",
        "✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)",
        "",
        "╭───────────────────────────────────────────────────╮",
        "│ >                                                 │",
        "╰───────────────────────────────────────────────────╯",
        "  ? for shortcuts                       ◯ IDE disconnected",
    ].joined(separator: "\n")

    static let claudeCodeExpected = [
        "✻ Welcome to Claude Code!",
        "/help for help, /status for your current setup",
        "I'll start by reading the overlay sources to understand how translations are drawn on top of other windows.",
        "The overlay is a borderless panel that ignores mouse events. Each segment gets a text layer whose font size shrinks until the translation fits inside the original frame.",
        "- Panels are reused per window",
        "- Fonts shrink down to the minimum size",
        "オーバーレイはマウスイベントを無視するパネルで、各セグメントの位置に訳文を描画します。",
    ]

    static let codexScreen = [
        ">_ OpenAI Codex (v0.46.0)",
        "",
        "model:     gpt-5-codex   /model to change",
        "directory: ~/Workspace/plamonic",
        "",
        "› Summarize the extraction pipeline",
        "",
        "• I'll look at the extraction sources first.",
        "",
        "• Explored",
        "  └ Read TextExtractor.swift",
        "    List Extraction",
        "",
        "• The extractor walks the accessibility tree once per scan, merges inline",
        "  runs into paragraphs, and filters out timestamps, URLs and code before",
        "  anything is sent to the translator.",
        "",
        "• Ran swift test",
        "  └ Test Suite 'All tests' passed",
        "",
        "─ Worked for 18s ──────────────────────────────────────────────",
        "",
        "• Working (3s • esc to interrupt)",
        "",
        "› Implement {feature}",
        "",
        "  ⏎ send   ⇧⏎ newline   ⌃T transcript   ⌃C quit   100% context left",
    ].joined(separator: "\n")

    static let codexExpected = [
        "I'll look at the extraction sources first.",
        "The extractor walks the accessibility tree once per scan, merges inline runs into paragraphs, and filters out timestamps, URLs and code before anything is sent to the translator.",
    ]

    static let paneScreen = [
        " Main text that wraps across two rows of  │ Sidebar title",
        " the left pane.                           │ Session info",
        "                                          │",
        "sizumita@mac Plamonic % ls -la",
        "Short line one.",
        "Short line two.",
    ].joined(separator: "\n")

    static let paneExpected = [
        "Main text that wraps across two rows of the left pane.",
        "Sidebar title",
        "Session info",
        "Short line one.",
        "Short line two.",
    ]

    struct FilterCase {
        var text: String
        var expected: TextRejection?
    }

    static let filterCases: [FilterCase] = [
        FilterCase(text: "", expected: .empty),
        FilterCase(text: "a", expected: .tooShort),
        FilterCase(text: "12:30", expected: .noLetters),
        FilterCase(text: "+12 -4", expected: .noLetters),
        FilterCase(text: "🎉🎉", expected: .noLetters),
        FilterCase(text: "10:30 AM", expected: .numeric),
        FilterCase(text: "2025年11月5日", expected: .numeric),
        FilterCase(text: "3h", expected: .numeric),
        FilterCase(text: "1.2k", expected: .numeric),
        FilterCase(text: ":thumbsup: :tada:", expected: .emojiShortcode),
        FilterCase(text: "https://example.com/a?b=c", expected: .url),
        FilterCase(text: "example.com", expected: .url),
        FilterCase(text: "foo@bar.com", expected: .url),
        FilterCase(text: "/usr/local/bin", expected: .filePath),
        FilterCase(text: "~/Workspace/x", expected: .filePath),
        FilterCase(text: "src/main.swift", expected: .filePath),
        FilterCase(text: "README.md", expected: .filePath),
        FilterCase(text: "let x = foo(bar);", expected: .codeLike),
        FilterCase(text: "git commit -m \"fix\"", expected: .codeLike),
        FilterCase(text: "snake_case_name", expected: .codeLike),
        FilterCase(text: "camelCaseName", expected: .codeLike),
        FilterCase(text: "if (a == b) {", expected: .codeLike),
        FilterCase(text: "ls -la", expected: .codeLike),
        FilterCase(text: "go test ./...", expected: .codeLike),
        FilterCase(text: "find . -name '*.swift'", expected: .codeLike),
        FilterCase(text: "make sense?", expected: nil),
        FilterCase(text: "claude is great", expected: nil),
        FilterCase(text: "go ahead - it's fine with me", expected: nil),
        FilterCase(text: "make sure you update the config/settings first", expected: nil),
        FilterCase(text: "find the bug in the auth/login flow please", expected: nil),
        FilterCase(text: "Hello world", expected: nil),
        FilterCase(text: "こんにちは", expected: nil),
        FilterCase(text: "OK", expected: nil),
        FilterCase(text: "Use the foo() function to start.", expected: nil),
        FilterCase(text: "Today at 10:30", expected: nil),
        FilterCase(text: "I moved it to src/main.swift yesterday.", expected: nil),
        FilterCase(text: "We shipped v2.0 today!", expected: nil),
        FilterCase(text: "Thanks 🙏", expected: nil),
        FilterCase(text: "設定画面で `scope` を変更してください。", expected: nil),
    ]

    static func run() -> Bool {
        var t = Checker()

        // Terminal segmentation
        let cc = TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: claudeCodeScreen)).map(\.text)
        t.equal(cc, claudeCodeExpected, "terminal: Claude Code screen")
        let cx = TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: codexScreen)).map(\.text)
        t.equal(cx, codexExpected, "terminal: Codex screen")
        let pane = TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: paneScreen), columns: 70).map(\.text)
        t.equal(pane, paneExpected, "terminal: panes, shell prompt, short lines")

        // Spans point at the kept text (UTF-16, absolute).
        let base = 1000
        let lines = TerminalSegmenter.lines(fromScreen: claudeCodeScreen, baseOffset: base)
        if let p = TerminalSegmenter.segment(lines).first(where: { $0.text.hasPrefix("I'll start") }) {
            let ns = claudeCodeScreen as NSString
            let first = ns.substring(with: NSRange(location: p.spans[0].location - base, length: p.spans[0].length))
            t.equal(first, "I'll start by reading the overlay sources to understand how", "terminal: span range")
            t.equal(p.spans.count, 2, "terminal: one span per row")
        } else {
            t.fail("terminal: span range", "paragraph missing")
        }
        let jp = TerminalSegmenter.segment(lines).first { $0.text.hasPrefix("オーバーレイ") }
        if let jp {
            let ns = claudeCodeScreen as NSString
            let second = ns.substring(with: NSRange(location: jp.spans[1].location - base, length: jp.spans[1].length))
            t.equal(second, "を描画します。", "terminal: CJK span")
        } else {
            t.fail("terminal: CJK span", "paragraph missing")
        }

        // Line classification
        t.equal(TerminalSegmenter.classify("╰──────╯"), .border, "classify: border")
        t.equal(TerminalSegmenter.classify("─ Worked for 1m 05s ─────────"), .border, "classify: labelled rule")
        t.equal(TerminalSegmenter.classify("✶ Pondering… (esc to interrupt)"), .chrome, "classify: spinner")
        t.equal(TerminalSegmenter.classify("· Combobulating…"), .chrome, "classify: spinner without hint")
        t.equal(TerminalSegmenter.classify("⏵⏵ accept edits on (shift+tab to cycle)"), .chrome, "classify: mode line")
        t.equal(TerminalSegmenter.classify("> fix the bug"), .prompt, "classify: prompt")
        t.equal(TerminalSegmenter.classify("user@host ~/src % make"), .prompt, "classify: shell prompt")
        t.equal(TerminalSegmenter.classify("⏺ Bash(git status)"), .toolHeader, "classify: tool call")
        t.equal(TerminalSegmenter.classify("⎿  Read 12 lines"), .toolOutput, "classify: tool output")
        t.equal(TerminalSegmenter.classify("• Ran npm test"), .toolHeader, "classify: codex tool")
        t.equal(TerminalSegmenter.classify("const x = 1;"), .code, "classify: code")
        t.equal(TerminalSegmenter.classify("This is prose."), .content, "classify: prose")
        t.equal(
            TerminalSegmenter.classify("[bot] deployed", ignore: IgnorePatterns(["^\\[bot\\]"])), .ignored,
            "classify: ignore pattern")
        t.equal(TerminalSegmenter.classify("⇧⏎ newline   ⌃T transcript   ⌃C quit"), .chrome, "classify: footer words")
        t.equal(
            TerminalSegmenter.classify("to end with a newline, so a missing final newline drops the"), .content,
            "classify: footer word in prose")

        // Wrapped rows that look like code on their own stay in their paragraph.
        let wrapped = [
            "⏺ I could not reproduce the crash on this machine, so please",
            "  let me know (with the full log) whether it still happens",
            "  after the cache is rebuilt, which can take a minute because",
            "  the indexer reads every file of the project before it starts;",
            "  you can keep working in the meantime and nothing is lost.",
        ].joined(separator: "\n")
        t.equal(
            TerminalSegmenter.segment(TerminalSegmenter.lines(fromScreen: wrapped)).map(\.spans.count), [5],
            "terminal: wrapped rows that look like code")

        // Filters
        for c in filterCases {
            t.equal(TextFilters.rejection(for: c.text, minLength: 2), c.expected, "filter: \"\(c.text)\"")
        }
        t.equal(
            TextFilters.rejection(for: "[bot] deployed v2", minLength: 2, ignore: IgnorePatterns(["^\\[bot\\]"])),
            .ignoredPattern, "filter: ignore pattern")
        t.equal(TextFilters.rejection(for: "abcdef", minLength: 2, maxLength: 5), .tooLong, "filter: too long")
        t.equal(TextFilters.normalize("  a \u{200B}b  \n\n\n  c\t d "), "a b\n\nc d", "normalize")
        t.equal(IgnorePatterns(["(", "ok"]).invalidPatterns, ["("], "ignore: invalid regex skipped")

        // Matchers
        let msg = ElementTraits(
            role: "AXGroup", subrole: "AXDocumentArticle", roleDescription: "message",
            domClasses: ["markup__75297", "messageContent_c19a55"], identifier: "chat-messages-123")
        t.check(!ElementMatcher().matches(msg), "matcher: empty matches nothing")
        t.check(!ElementMatcher(domClassPrefixes: ["", "  "]).matches(msg), "matcher: blank entries ignored")
        t.check(ElementMatcher(domClassPrefixes: ["messageContent_"]).matches(msg), "matcher: DOM class prefix")
        t.check(!ElementMatcher(domClassPrefixes: ["Content_"]).matches(msg), "matcher: prefix, not substring")
        t.check(
            ElementMatcher(roles: ["AXGroup"], domClassPrefixes: ["markup_"]).matches(msg), "matcher: AND across fields")
        t.check(
            !ElementMatcher(roles: ["AXLink"], domClassPrefixes: ["markup_"]).matches(msg), "matcher: AND fails")
        t.check(ElementMatcher(roles: ["AXLink", "AXGroup"]).matches(msg), "matcher: OR within a field")
        t.check(ElementMatcher(subroles: ["AXDocumentArticle"]).matches(msg), "matcher: subrole")
        t.check(
            !ElementMatcher(subroles: ["AXDocumentArticle"]).matches(ElementTraits(role: "AXGroup")),
            "matcher: missing subrole")
        t.check(ElementMatcher(roleDescriptions: ["Message"]).matches(msg), "matcher: roleDescription ignores case")
        t.check(ElementMatcher(identifierPrefixes: ["chat-"]).matches(msg), "matcher: identifier prefix")
        t.check(!ElementMatcher(identifierPrefixes: ["x"]).matches(msg), "matcher: identifier mismatch")
        let rules = ExtractionRules(containers: [ElementMatcher(roles: [" "])], items: [ElementMatcher(roles: ["AXGroup"])])
        t.check(!rules.hasContainers && rules.hasItems, "rules: usable matchers")

        // Inline joining
        func part(_ s: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> ExtractionWalk.Part {
            ExtractionWalk.Part(
                text: s, frame: CGRect(x: x, y: y, width: w, height: h), visible: true, role: "AXStaticText",
                treeIndex: 0)
        }
        t.equal(ExtractionWalk.join([part("Hello ", 0, 0, 40, 20), part("world", 40, 0, 40, 20)]), "Hello world", "join: DOM space")
        t.equal(ExtractionWalk.join([part("foo", 0, 0, 30, 20), part("bar", 40, 0, 30, 20)]), "foo bar", "join: gap")
        t.equal(ExtractionWalk.join([part("Title", 0, 0, 50, 18), part("Body", 0, 30, 40, 18)]), "Title\nBody", "join: new line")
        t.equal(ExtractionWalk.join([part("字字", 0, 0, 20, 20), part("字", 20, 0, 10, 20)]), "字字字", "join: CJK")
        t.equal(
            ExtractionWalk.join([part("see ", 0, 0, 300, 40), part("link", 10, 20, 30, 20), part(" now", 40, 20, 30, 20)]),
            "see link now", "join: wrapped inline")

        // Original look (§6): line pitch, line frames, terminal cells, inline buttons
        let item = [
            CGRect(x: 140, y: 262, width: 101, height: 16), CGRect(x: 241, y: 262, width: 229, height: 16),
            CGRect(x: 474, y: 263, width: 93, height: 17), CGRect(x: 140, y: 262, width: 660, height: 68),
        ]
        t.equal(LineGeometry.linePitch(runs: item, fontSize: 16), 26, "pitch: run over three lines")
        t.equal(
            LineGeometry.linePitch(
                runs: [CGRect(x: 0, y: 381, width: 304, height: 132)], fontSize: 16, textHeight: 22, windowPitch: 22),
            22, "pitch: window pitch divides a long gap")
        t.equal(LineGeometry.lineFrames(runs: item, fontSize: 16), [], "line frames: unknown for wrapped runs")
        t.equal(
            LineGeometry.lineFrames(runs: [CGRect(x: 0, y: 0, width: 50, height: 16)], fontSize: 16).count, 1,
            "line frames: one-line run")
        t.equal(TerminalMetrics.fontSize(cellWidth: 9, rowHeight: 17), 15, "terminal: font size from cells")
        t.check(
            ExtractionWalk.looksLikeInlineText("ExtractionWalk.swift", frame: CGRect(x: 0, y: 0, width: 167, height: 26)),
            "inline button: file link")
        t.check(
            !ExtractionWalk.looksLikeInlineText("Copy message to clipboard", frame: CGRect(x: 0, y: 0, width: 14, height: 24)),
            "inline button: icon")

        // Overlapping pieces of one paragraph merge; touching neighbours do not.
        func piece(_ text: String, _ frame: CGRect, emit: Int) -> (segment: RawSegment, text: String) {
            var s = RawSegment(text: text, frame: frame, role: "AXGroup", isEditable: false, treeIndex: emit)
            s.blockIndex = 1
            s.emitIndex = emit
            s.runFrames = [frame]
            s.runIsWhole = [true]
            return (s, text)
        }
        let split = SegmentMerger.merge(
            [
                piece("2. ファイル参照は", CGRect(x: 120, y: 351, width: 140, height: 26), emit: 0),
                piece("のように描画されます。", CGRect(x: 140, y: 356, width: 656, height: 68), emit: 1),
            ], maxCharacters: 2000)
        t.equal(split.items.map(\.text), ["2. ファイル参照はのように描画されます。"], "merge: split list item")
        let touching = SegmentMerger.merge(
            [
                piece("Status line", CGRect(x: 748, y: 615, width: 806, height: 32), emit: 0),
                piece("Answer paragraph", CGRect(x: 752, y: 641, width: 700, height: 46), emit: 1),
            ], maxCharacters: 2000)
        t.equal(touching.items.count, 2, "merge: touching neighbours stay apart")

        // Links (§6.1): ranges follow the text, wrapped links get one rectangle per line, terminal URLs.
        let raw = "  Read\u{200B}  the   setup guide \n\n\nnow"
        let mapped = TextFilters.normalizeMapped(raw)
        t.equal(mapped.text, TextFilters.normalize(raw), "links: mapped normalize is normalize")
        let guide = (raw as NSString).range(of: "setup guide")
        t.equal(
            mapped.map.map(guide.location..<(guide.location + guide.length), in: mapped.text).map {
                LinkText.substring(mapped.text, $0)
            }, "setup guide", "links: range after normalize")
        t.equal(
            ExtractionWalk.linkFrames(
                [
                    LinkRun(
                        frame: CGRect(x: 56, y: 405, width: 495, height: 40),
                        before: CGRect(x: 56, y: 405, width: 344, height: 18),
                        after: CGRect(x: 290, y: 427, width: 64, height: 18))
                ], textHeight: 18, singleLineLimit: 25.5, pitch: 22),
            [CGRect(x: 400, y: 405, width: 151, height: 18), CGRect(x: 56, y: 427, width: 234, height: 18)],
            "links: wrapped link frames")
        t.equal(
            TerminalSegmenter.urls(in: "see https://example.com/a?b=1, www.example.org or a@b.com").count, 2,
            "links: terminal URLs")
        let cut = TerminalSegmenter.segment(
            TerminalSegmenter.lines(
                fromScreen: "⏺ The fix is in https://github.com/exam\n  ple-org/example-repository/pull/12345\n  and it is ready for review today, ok."))
        t.equal(
            cut.map(\.text),
            ["The fix is in https://github.com/example-org/example-repository/pull/12345 and it is ready for review today, ok."],
            "links: URL cut at the wrap width")

        // Misc
        t.equal(TextMetrics.stableHash("hello"), "a430d84680aabd0b", "stable hash (FNV-1a)")
        t.equal(TextMetrics.cellWidth("aあ字"), 5, "cell width")
        t.equal(TextMetrics.joinWrapped("foo", "bar"), "foo bar", "join wrapped: Latin")
        t.equal(TextMetrics.joinWrapped("日本", "語"), "日本語", "join wrapped: CJK")

        print("selftest: \(t.passed) passed, \(t.failed) failed")
        return t.failed == 0
    }

    struct Checker {
        var passed = 0
        var failed = 0

        mutating func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1 } else { fail(name, "condition is false") }
        }

        mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
            if actual == expected {
                passed += 1
            } else {
                fail(name, "\n    expected: \(expected)\n    actual:   \(actual)")
            }
        }

        mutating func fail(_ name: String, _ detail: String) {
            failed += 1
            print("FAIL \(name): \(detail)")
        }
    }
}
