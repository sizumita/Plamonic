import XCTest

@testable import Plamonic

final class SettingsPresetsTests: XCTestCase {
    func testRequestedAppsHavePresets() {
        let ids = Set(AppPresets.all.map(\.bundleID))
        XCTAssertEqual(ids.count, AppPresets.all.count, "bundle IDs are unique")
        for id in [
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.anthropic.claudefordesktop", "com.openai.codex",
            "ai.opencode.desktop", "com.deepseek.dsh", "com.apple.Terminal", "com.mitchellh.ghostty",
            "com.googlecode.iterm2", "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
            "com.brave.Browser",
        ] {
            XCTAssertTrue(ids.contains(id), "missing preset for \(id)")
        }
    }

    func testPresetsAreWellFormed() {
        for preset in AppPresets.all {
            // An app that cannot be translated is off, so it is not scanned for nothing. Browsers wait for the
            // hotkey: their rules are not written for any one site.
            let expectedMode: TranslationMode =
                preset.verification == .unsupported ? .off : preset.kind == .browser ? .manual : .automatic
            XCTAssertEqual(preset.profile.mode, expectedMode, preset.bundleID)
            XCTAssertFalse(preset.profile.context.isEmpty, preset.bundleID)
            XCTAssertFalse(preset.note.isEmpty, preset.bundleID)
            XCTAssertFalse(preset.profile.context.contains("<|plamo:"), preset.bundleID)
            let rules = preset.profile.rules
            for matcher in rules.containers + rules.items + rules.excludes {
                XCTAssertFalse(matcher.isEmpty, "\(preset.bundleID) has an empty matcher")
            }
            if preset.kind == .terminal {
                XCTAssertEqual(preset.profile.textAreaHandling, .terminal, preset.bundleID)
                XCTAssertFalse(preset.profile.ignorePatterns.isEmpty, preset.bundleID)
                XCTAssertFalse(preset.coveredTools.isEmpty, preset.bundleID)
            }
        }
    }

    func testGhosttyIsUnsupported() {
        // Ghostty has no AXBoundsForRange (docs/AX_NOTES.md), matching README's 非対応.
        let ghostty = AppPresets.preset(for: AppPresets.ghosttyBundleID)
        XCTAssertEqual(ghostty?.verification, .unsupported)
        XCTAssertEqual(ghostty?.profile.mode, .off)
        XCTAssertEqual(
            AppPresets.all.filter { $0.verification == .unsupported }.map(\.bundleID), [AppPresets.ghosttyBundleID])
    }

    func testPresetRegexesCompile() {
        for preset in AppPresets.all {
            XCTAssertEqual(RuleSuggestions.invalidPatterns(preset.profile.ignorePatterns), [], preset.bundleID)
        }
    }

    func testMeasuredRules() {
        let slack = AppPresets.slack.profile.rules
        XCTAssertEqual(
            Set(slack.items.flatMap(\.domClassPrefixes)),
            ["p-rich_text_section", "p-rich_text_list", "p-rich_text_quote"])
        XCTAssertTrue(slack.excludes.contains { $0.domClassPrefixes.contains("p-rich_text_preformatted") })

        let discord = AppPresets.discord.profile.rules
        XCTAssertEqual(discord.items.flatMap(\.domClassPrefixes), ["messageContent_", "embedDescription_"])
        XCTAssertTrue(discord.items.allSatisfy { $0.roleDescriptions.isEmpty }, "roleDescription is localized")

        let claude = AppPresets.claude.profile.rules
        XCTAssertTrue(claude.items.contains { $0.domClassPrefixes.contains("group/message-row") })
        // The chat panel and the side chat's transcript.
        XCTAssertEqual(
            claude.containers.flatMap(\.domClassPrefixes),
            ["epitaxy-chat-panel-body", "[scrollbar-gutter:stable_both-edges]"])
        XCTAssertEqual(Set(claude.excludes.flatMap(\.domClassPrefixes)), ["group/status", "group/tool", "sr-only"])

        let openCode = AppPresets.openCodeDesktop.profile.rules
        XCTAssertEqual(openCode.containers.flatMap(\.domClassPrefixes), ["scroll-view__viewport"])
        XCTAssertEqual(Set(openCode.excludes.flatMap(\.domClassPrefixes)), ["sticky", "sr-only"])
        XCTAssertFalse(slack.excludes.contains { $0.domClassPrefixes.contains("sr-only") }, "Slack's list is sr-only")
        XCTAssertTrue(discord.excludes.contains { $0.domClassPrefixes.contains("repliedTextContent_") })

        // DeepSeek Harness lists its threads in an AXOutline that is not a navigation landmark.
        let deepSeek = AppPresets.deepSeekHarness.profile.rules
        XCTAssertTrue(deepSeek.excludes.contains { $0.roles == ["AXOutline"] })
    }

    func testOpenCodeExpandedThinkingIsNotExcluded() {
        // OpenCode 2.2.5: the expanded thinking body is inside a tool-collapsible group.
        let thinking = ElementTraits(role: "AXGroup", domClasses: ["tool-collapsible"])
        let excludes = CompiledMatcherSet(AppPresets.openCodeDesktop.profile.rules.excludes)
        XCTAssertFalse(excludes.matches(thinking))
    }

    func testBrowserRules() {
        let browsers = AppPresets.all.filter { $0.kind == .browser }
        XCTAssertEqual(
            Set(browsers.map(\.bundleID)),
            [AppPresets.safariBundleID, AppPresets.chromeBundleID, AppPresets.edgeBundleID, AppPresets.braveBundleID])
        for preset in browsers {
            let p = preset.profile
            XCTAssertEqual(p.scope, .rules, preset.bundleID)
            XCTAssertEqual(p.rules.containers, [ElementMatcher(roles: ["AXWebArea"])], preset.bundleID)
            // Inline <code> is part of sentences; only Safari's <pre> group is skipped.
            XCTAssertFalse(p.rules.excludes.contains { $0.subroles.contains("AXCodeStyleGroup") }, preset.bundleID)
            XCTAssertTrue(p.rules.excludes.contains { $0.subroles.contains("AXPreformattedStyleGroup") })
            XCTAssertTrue(p.rules.excludes.contains { $0.subroles.contains("AXLandmarkNavigation") })
            // Sidebars of articles hold prose.
            XCTAssertFalse(p.rules.excludes.contains { $0.subroles.contains("AXLandmarkComplementary") })
            // Chromium browsers ignore AXManualAccessibility (-25205) and need AXEnhancedUserInterface.
            XCTAssertFalse(p.enableManualAccessibility, preset.bundleID)
            XCTAssertEqual(p.enableEnhancedUserInterface, preset.bundleID != AppPresets.safariBundleID, preset.bundleID)
        }
        XCTAssertEqual(AppPresets.safari.verification, .verified)
        XCTAssertEqual(AppPresets.chrome.verification, .verified)
    }

    func testTerminalIgnorePatterns() {
        let regexes = AppPresets.terminalIgnorePatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        XCTAssertEqual(regexes.count, AppPresets.terminalIgnorePatterns.count)
        func ignored(_ line: String) -> Bool {
            regexes.contains { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        }
        let chrome = [
            "╭──────────────────────────╮", "│                          │", "────────────────",
            "✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)", "· Compacting conversation…",
            "⠋ Working", "  ? for shortcuts", "◦ Working (5s • Esc to interrupt)",
            "  ⏵⏵ accept edits on (shift+tab to cycle)", "⏎ send   ⇧⏎ newline", "100% context left",
            "Context left until auto-compact: 12%", "⏺ Bash(ls -la)", "  ⎿  Read 42 lines",
            "• Ran git status", "user@host ~/src % ls", "❯ ", "███████░░░░ 60%", "  1.2k tokens",
            "Token usage: total=1234", "ctrl+t to show todos", "  ctrl+o to expand", "(ctrl+r to expand)",
            "42% context left · ? for shortcuts", "Showing detailed transcript · ctrl+o to toggle", "ctrl+p commands",
        ]
        for line in chrome { XCTAssertTrue(ignored(line), "should ignore: \(line)") }
        let prose = [
            "I'll look at the configuration file and fix the bug.",
            "⏺ The build failed because the module was not found.",
            "• Implemented the new parser and added tests.",
            "これはテストの文章です。",
            "Welcome to Claude Code!",
            "We should use tokens in the request header.",
            // Prose that mentions shortcuts, Codex-style bullets and context sizes.
            "You can hit Cmd+K and then type the command name to run it.",
            "Press Ctrl+S and save the file before running the tests.",
            "Ctrl+C to stop the server, then restart it with the new flag.",
            "• Read the config loader first; it decides the order.",
            "The new prompt now uses 80% context and leaves room for the reply.",
        ]
        for line in prose { XCTAssertFalse(ignored(line), "should keep: \(line)") }
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(AppPresets.preset(for: "com.apple.terminal")?.bundleID, "com.apple.Terminal")
        XCTAssertNil(AppPresets.preset(for: "com.example.none"))
    }
}
