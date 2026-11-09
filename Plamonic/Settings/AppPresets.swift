import Foundation

enum AppPresetKind: String, Sendable {
    case chat  // team chat (Slack, Discord)
    case aiAssistant  // AI chat / coding agent desktop apps
    case terminal  // terminal hosts for CLI agents
    case browser  // web browsers (any site: generic page rules, manual by default)
}

enum PresetVerification: String, Sendable {
    case verified  // rules written from measured AX trees (docs/AX_NOTES.md)
    case unverified  // generic rules; the app's AX tree has not been inspected yet
    case unsupported  // measured, and the app does not expose what Plamonic needs; the preset is off
}

/// A built-in profile for a known app plus the metadata the settings UI shows.
struct AppPreset: Identifiable, Sendable {
    var profile: AppProfile
    var kind: AppPresetKind
    var verification: PresetVerification
    /// Japanese description for the settings UI.
    var note: String
    /// Tools this preset covers, e.g. the CLI agents that run inside a terminal host.
    var coveredTools: [String]

    var id: String { profile.bundleID }
    var bundleID: String { profile.bundleID }
    var displayName: String { profile.displayName }
}

enum AppPresets {
    static let slackBundleID = "com.tinyspeck.slackmacgap"
    static let discordBundleID = "com.hnc.Discord"
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let codexBundleID = "com.openai.codex"
    static let openCodeBundleID = "ai.opencode.desktop"
    static let deepSeekHarnessBundleID = "com.deepseek.dsh"
    static let terminalBundleID = "com.apple.Terminal"
    static let ghosttyBundleID = "com.mitchellh.ghostty"
    static let iTerm2BundleID = "com.googlecode.iterm2"
    static let safariBundleID = "com.apple.Safari"
    static let chromeBundleID = "com.google.Chrome"
    static let edgeBundleID = "com.microsoft.edgemac"
    static let braveBundleID = "com.brave.Browser"

    static let all: [AppPreset] = [
        slack, discord, claude, codexDesktop, openCodeDesktop, deepSeekHarness, terminal, ghostty, iTerm2,
        safari, chrome, edge, brave,
    ]

    private static let byBundleID: [String: AppPreset] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.bundleID.lowercased(), $0) })

    /// Bundle IDs are matched case-insensitively.
    static func preset(for bundleID: String) -> AppPreset? { byBundleID[bundleID.lowercased()] }

    static func profile(for bundleID: String) -> AppProfile? { preset(for: bundleID)?.profile }

    // MARK: - Chat apps

    static let slack: AppPreset = {
        var p = AppProfile(bundleID: slackBundleID, displayName: "Slack")
        p.mode = .automatic
        p.scope = .rules
        p.granularity = .paragraph
        p.rules = ExtractionRules(
            containers: [],
            items: [classes("p-rich_text_section", "p-rich_text_list", "p-rich_text_quote")],
            excludes: [
                classes("p-rich_text_preformatted", "c-message__sender_button", "c-timestamp", "c-message_actions__"),
                // Message composer (unmeasured, harmless if absent).
                classes("ql-editor", "c-texty_input"),
                // Pruned only to save time: sidebars, headers and the footer never hold message items.
                // Never exclude "sr-only" here: Slack's message list itself carries that class.
                classes(
                    "p-channel_sidebar", "p-tab_rail", "p-ia4_top_nav", "p-control_strip", "p-team_sidebar",
                    "p-view_header", "p-workspace__primary_view_footer", "p-ia4_sidebar_header"),
            ])
        p.context = "Messages in a Slack workspace between software engineers."
        p.enableManualAccessibility = true
        return AppPreset(
            profile: p, kind: .chat, verification: .verified,
            note: "メッセージ本文（p-rich_text_section / list / quote）だけを訳します。コードブロック（p-rich_text_preformatted）は訳しません。",
            coveredTools: [])
    }()

    static let discord: AppPreset = {
        var p = AppProfile(bundleID: discordBundleID, displayName: "Discord")
        p.mode = .automatic
        p.scope = .rules
        p.granularity = .paragraph
        // Class names end in a build hash, so match by prefix. roleDescription is localized; never use it here.
        p.rules = ExtractionRules(
            containers: [],
            items: [classes("messageContent_", "embedDescription_")],
            excludes: [
                // Reply previews also carry messageContent_; timestamp_ is the "(edited)" marker.
                classes("repliedTextContent_", "timestamp_", "hiddenVisually_", "codeContainer_", "hljs"),
                // Pruned only to save time: server/channel sidebar, member list, composer.
                classes("sidebar_", "membersWrap_", "form_"),
                ElementMatcher(subroles: ["AXLandmarkNavigation"]),
            ])
        p.context = "Chat messages in a Discord server or direct messages."
        p.enableManualAccessibility = true
        return AppPreset(
            profile: p, kind: .chat, verification: .verified,
            note: "メッセージ本文（messageContent_）と埋め込みの説明文（embedDescription_）を訳します。",
            coveredTools: [])
    }()

    // MARK: - AI assistant desktop apps

    static let claude: AppPreset = {
        var p = AppProfile(bundleID: claudeBundleID, displayName: "Claude")
        p.mode = .automatic
        p.scope = .rules
        p.granularity = .paragraph
        p.rules = ExtractionRules(
            // The Claude Code chat panel, and the side chat's transcript scroller (it has no named class; of the
            // window's elements only the two transcript scrollers carry this one, and the chat panel's is inside
            // its panel, which is matched first). Each scrolls on its own (WindowSnapshot.scrollRegions).
            // The chat tab has none; TextExtractor then searches the whole window for the items (a rule set with
            // items falls back to the window when no container is found).
            containers: [classes("epitaxy-chat-panel-body"), classes("[scrollbar-gutter:stable_both-edges]")],
            // group/message-row is measured (Claude Code tab); the font-* classes are for the chat tab (unverified).
            items: [classes("group/message-row", "font-user-message", "font-claude-response")],
            excludes: [
                classes("group/status", "group/tool", "sr-only"),
                ElementMatcher(subroles: ["AXLandmarkComplementary"]),
            ])
        p.context =
            "A conversation between a software engineer and Claude, an AI coding assistant, in the Claude desktop app (Claude Code)."
        p.enableManualAccessibility = true
        return AppPreset(
            profile: p, kind: .aiAssistant, verification: .verified,
            note: "Claude Code タブのメッセージ行（group/message-row）を、サイドチャットのものも含めて訳します。ツール実行の状態行（group/status, group/tool）と読み上げ専用の重複テキスト（sr-only）は訳しません。チャットタブ向けの規則は未検証です。",
            coveredTools: ["Claude Code"])
    }()

    static let codexDesktop: AppPreset = {
        var p = genericWebChatProfile(bundleID: codexBundleID, displayName: "Codex")
        p.context = "A conversation between a software engineer and Codex, an AI coding agent by OpenAI."
        return AppPreset(
            profile: p, kind: .aiAssistant, verification: .unverified,
            note: "デスクトップ版は未検証です。汎用の Web チャット規則（AXWebArea 内の段落、コードブロック・ナビゲーションは除外）を使います。CLI 版の Codex はターミナルのプリセットで訳します。",
            coveredTools: ["Codex"])
    }()

    static let openCodeDesktop: AppPreset = {
        var p = AppProfile(bundleID: openCodeBundleID, displayName: "OpenCode")
        p.mode = .automatic
        p.scope = .rules
        p.granularity = .paragraph
        p.rules = ExtractionRules(
            containers: [classes("scroll-view__viewport")],
            items: [],
            // Expanded thinking uses tool-collapsible too; its button is skipped by includeControls.
            excludes: [classes("sticky"), classes("sr-only")])
        p.context = "A conversation between a software engineer and an AI coding agent in OpenCode."
        p.enableManualAccessibility = true
        return AppPreset(
            profile: p, kind: .aiAssistant, verification: .verified,
            note: "デスクトップ版の本文領域（scroll-view__viewport）を、展開した思考の本文も含めて段落ごとに訳します。開いたツールの説明文も対象です。操作ボタンと固定ヘッダ（sticky）は訳しません。CLI 版はターミナルのプリセットで訳します。",
            coveredTools: ["OpenCode"])
    }()

    static let deepSeekHarness: AppPreset = {
        var p = genericWebChatProfile(bundleID: deepSeekHarnessBundleID, displayName: "DeepSeek Harness")
        p.context = "A conversation between a user and an AI assistant in DeepSeek Harness."
        return AppPreset(
            profile: p, kind: .aiAssistant, verification: .unverified,
            note: "未検証です。汎用の Web チャット規則（AXWebArea 内の段落、コードブロック・ナビゲーション・サイドバーのスレッド一覧は除外）を使います。うまく訳せない場合は「要素を調べる」でルールを調整してください。",
            coveredTools: ["DeepSeek Harness"])
    }()

    // MARK: - Terminal hosts (Claude Code / Codex / OpenCode CLIs)

    static let terminal: AppPreset = terminalPreset(
        bundleID: terminalBundleID, displayName: "ターミナル", verification: .verified,
        note: "画面に見えている行だけを訳します。TUI の罫線・スピナー・ショートカット表示・トークン数などの行は無視します。")

    /// Ghostty exposes the screen text but not AXBoundsForRange (docs/AX_NOTES.md), so no line can be placed.
    static let ghostty: AppPreset = {
        var preset = terminalPreset(
            bundleID: ghosttyBundleID, displayName: "Ghostty", verification: .unsupported,
            note: "文字の位置（AXBoundsForRange）を公開していないため、今は訳せません。そのため「オフ」にしています。")
        preset.profile.mode = .off
        return preset
    }()

    static let iTerm2: AppPreset = terminalPreset(
        bundleID: iTerm2BundleID, displayName: "iTerm2", verification: .unverified,
        note: "未検証です。ターミナルと同じ方式（AXTextArea の可視行）で訳します。")

    static let terminalCoveredTools = ["Claude Code（CLI）", "Codex（CLI）", "OpenCode（CLI）"]

    /// Lines of TUI chrome that should never be translated. Applied per line in terminal mode.
    static let terminalIgnorePatterns: [String] = [
        // Lines made only of box-drawing characters, rules and bars.
        #"^[\s│┃┆┇┊┋╎╏║╭╮╰╯─━┄┅┈┉╌╍═┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬▏▕▔▁▌▐|+=_~\-]+$"#,
        // Spinner + verb ("✻ Thinking…", "· Compacting conversation…").
        #"^\s*[·✢✳✶✻✽✺✹✸✷⋆∗◐◓◑◒◴◷◶◵\x{2800}-\x{28FF}]\s*\S.{0,60}?(…|\.\.\.)"#,
        // Braille spinners used by many TUIs.
        #"^\s*[\x{2800}-\x{28FF}]\s"#,
        #"(?i)\besc to (interrupt|cancel)\b"#,
        #"\? for shortcuts"#,
        // Token counters and context meters.
        #"(?i)[↑↓]\s*[\d.,]+\s*[km]?\s*tokens?\b"#,
        #"(?i)^\s*[\d.,]+\s*[km]?\s*tokens?\b[^\p{L}]*$"#,
        #"(?i)\btoken usage:"#,
        #"(?i)\b\d{1,3}%\s+context( window)?\s+(left|used)\b"#,
        #"(?i)context left until auto-compact"#,
        // Key hints in footers ("ctrl+t to show todos", "shift+tab to cycle", "⏎ send"): a hint that starts the
        // line or follows a "·" separator and ends there, so prose such as "hit Cmd+K and then type" is kept.
        #"(?i)(^|[·|])\W*((ctrl|alt|cmd|shift)\+)+\w+\s+(to\s+\p{L}+(\s+\p{L}+){0,2}|\p{L}+)\W*?([·|]|$)"#,
        #"⏎\s+\p{L}+"#,
        #"(?i)press ctrl-?c again to exit"#,
        // Mode banners ("⏵⏵ accept edits on", "plan mode on").
        #"^\s*⏵⏵"#,
        #"(?i)\b(accept edits|bypass permissions|plan mode) on\b"#,
        // Tool invocations and their output ("⏺ Bash(ls)", "⎿ Read 42 lines", "└ src/main.rs").
        #"^\s*[⏺●]\s*[A-Za-z]+\("#,
        #"^\s*[⎿└]\s"#,
        #"^\s*[•◦]\s+(Ran|Running|Explored|Exploring|Edited|Editing|Searched|Searching|Listed|Called|Calling|Updated Plan)\b"#,
        // Shell prompts and empty input prompts.
        #"^[\w.-]+@[\w.-]+[^\n]*?[%$#]\s"#,
        #"^\s*[❯›>$%#]\s*$"#,
        // Progress bars.
        #"[█▉▊▋▌▍▎░▒▓]{3,}"#,
    ]

    // MARK: - Browsers

    static let safari: AppPreset = browserPreset(
        bundleID: safariBundleID, displayName: "Safari", chromium: false, verification: .verified,
        note: "ページの本文を段落ごとに訳します。ヘッダ・ナビゲーション・検索欄・フッタ・コードブロックは訳しません。どのサイトでも同じ規則なので、はじめは手動（⌃⌥R）にしています。")

    static let chrome: AppPreset = browserPreset(
        bundleID: chromeBundleID, displayName: "Google Chrome", chromium: true, verification: .verified,
        note: "Safari と同じ規則でページの本文を訳します。Chrome は AXEnhancedUserInterface をオンにしたときだけページの中身を公開するので、最初に訳すときに数秒かかります。この設定はウインドウのアニメーションを止めることがあり、訳すのをオフにするか Plamonic を終了すると元に戻します。")

    static let edge: AppPreset = browserPreset(
        bundleID: edgeBundleID, displayName: "Microsoft Edge", chromium: true, verification: .unverified,
        note: "未検証です。Chrome と同じ方式（AXEnhancedUserInterface、ページ本文の汎用規則）で訳します。")

    static let brave: AppPreset = browserPreset(
        bundleID: braveBundleID, displayName: "Brave", chromium: true, verification: .unverified,
        note: "未検証です。Chrome と同じ方式（AXEnhancedUserInterface、ページ本文の汎用規則）で訳します。")

    // MARK: - Builders

    private static func classes(_ prefixes: String...) -> ElementMatcher {
        ElementMatcher(domClassPrefixes: prefixes)
    }

    /// Paragraphs inside the web area; code blocks, navigation, tree views and screen-reader-only text are skipped.
    static func genericWebChatProfile(bundleID: String, displayName: String) -> AppProfile {
        var p = AppProfile(bundleID: bundleID, displayName: displayName)
        p.mode = .automatic
        p.scope = .rules
        p.granularity = .paragraph
        p.rules = ExtractionRules(
            containers: [ElementMatcher(roles: ["AXWebArea"])],
            items: [],
            excludes: [
                classes(
                    "hljs", "shiki", "language-", "code-block", "md-code-block", "sr-only", "visually-hidden", "cm-",
                    "monaco-"),
                ElementMatcher(subroles: ["AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkComplementary"]),
                // Sidebar thread / session lists are tree views and not marked as navigation (DeepSeek Harness).
                ElementMatcher(roles: ["AXOutline"]),
            ])
        p.enableManualAccessibility = true
        return p
    }

    /// Any web page: paragraphs of the web area; site chrome (header, navigation, search, footer), code blocks,
    /// tree views and screen-reader-only text are skipped. Sidebars (complementary) are kept: articles put prose
    /// there. Manual by default, since the rules are not written for any one site.
    static func browserProfile(bundleID: String, displayName: String, chromium: Bool) -> AppProfile {
        var p = AppProfile(bundleID: bundleID, displayName: displayName)
        p.mode = .manual
        p.scope = .rules
        p.granularity = .paragraph
        p.rules = ExtractionRules(
            containers: [ElementMatcher(roles: ["AXWebArea"])],
            items: [],
            excludes: [
                ElementMatcher(subroles: [
                    "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkSearch", "AXLandmarkContentInfo",
                ]),
                // Safari's <pre>. Chrome exposes <pre> as a plain group; the code filter and the highlighter
                // classes below catch its code. Never exclude AXCodeStyleGroup: inline <code> is part of sentences.
                ElementMatcher(subroles: ["AXPreformattedStyleGroup"]),
                ElementMatcher(roles: ["AXOutline"]),
                classes(
                    "hljs", "shiki", "language-", "cm-", "monaco-", "sr-only", "visually-hidden", "mw-editsection"),
            ])
        p.context = "A web page the user is reading in a web browser."
        // Chrome builds its web tree only for AXEnhancedUserInterface (AXManualAccessibility is Electron's);
        // Safari always exposes it.
        p.enableManualAccessibility = false
        p.enableEnhancedUserInterface = chromium
        return p
    }

    private static func browserPreset(
        bundleID: String, displayName: String, chromium: Bool, verification: PresetVerification, note: String
    ) -> AppPreset {
        AppPreset(
            profile: browserProfile(bundleID: bundleID, displayName: displayName, chromium: chromium),
            kind: .browser, verification: verification, note: note, coveredTools: [])
    }

    private static func terminalPreset(
        bundleID: String, displayName: String, verification: PresetVerification, note: String
    ) -> AppPreset {
        var p = AppProfile(bundleID: bundleID, displayName: displayName)
        p.mode = .automatic
        p.scope = .rules
        p.granularity = .paragraph
        p.textAreaHandling = .terminal
        p.rules = ExtractionRules(containers: [], items: [ElementMatcher(roles: ["AXTextArea"])], excludes: [])
        p.ignorePatterns = terminalIgnorePatterns
        // The terminal screen may report itself as editable; it is the text we want.
        p.includeEditableText = true
        p.context =
            "Terminal output of AI coding agents (Claude Code, Codex, OpenCode) and command-line tools used by a software engineer."
        // Native AppKit apps: the Chromium switch is not needed.
        p.enableManualAccessibility = false
        return AppPreset(
            profile: p, kind: .terminal, verification: verification, note: note, coveredTools: terminalCoveredTools)
    }
}
