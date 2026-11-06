import Foundation

/// Synthetic terminal screens shaped like the Claude Code / Codex CLIs (no real user content).
enum ExtractionFixtures {
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
}
