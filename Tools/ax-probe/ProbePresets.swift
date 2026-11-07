import Foundation

/// Rule sets validated with this probe. The app's real presets live in the Settings module;
/// these mirror what was measured against the live apps (see the report / docs/AX_NOTES.md).
enum ProbePresets {
    struct Preset {
        var name: String
        var bundleIDs: [String]
        var apply: (inout AppProfile) -> Void
    }

    static func m(
        roles: [String] = [], subroles: [String] = [], dom: [String] = [], ids: [String] = []
    ) -> ElementMatcher {
        ElementMatcher(roles: roles, subroles: subroles, domClassPrefixes: dom, identifierPrefixes: ids)
    }

    static let all: [Preset] = [
        Preset(name: "slack", bundleIDs: ["com.tinyspeck.slackmacgap"]) { p in
            p.scope = .rules
            p.granularity = .paragraph
            p.rules.items = [m(dom: ["p-rich_text_section", "p-rich_text_list", "p-rich_text_quote"])]
            p.rules.excludes = [
                m(dom: ["p-rich_text_preformatted", "c-message__sender_button", "c-timestamp", "c-message_actions__"]),
                // Pruned only to save time: sidebars, headers and the composer never hold message items.
                m(dom: [
                    "p-channel_sidebar", "p-tab_rail", "p-ia4_top_nav", "p-control_strip", "p-team_sidebar",
                    "p-view_header", "p-workspace__primary_view_footer", "p-ia4_sidebar_header",
                ]),
            ]
        },
        Preset(name: "discord", bundleIDs: ["com.hnc.Discord"]) { p in
            p.scope = .rules
            p.granularity = .paragraph
            p.rules.items = [m(dom: ["messageContent_", "embedDescription_"])]
            p.rules.excludes = [
                m(dom: ["repliedTextContent_", "timestamp_", "hiddenVisually_", "codeContainer_", "hljs"]),
                // Pruned only to save time: server/channel sidebar, member list, composer.
                m(dom: ["sidebar_", "membersWrap_", "form_"]),
                m(subroles: ["AXLandmarkNavigation"]),
            ]
        },
        Preset(name: "claude", bundleIDs: ["com.anthropic.claudefordesktop"]) { p in
            p.scope = .rules
            p.granularity = .paragraph
            p.rules.containers = [m(dom: ["epitaxy-chat-panel-body"])]
            p.rules.items = [m(dom: ["group/message-row"])]
            p.rules.excludes = [
                m(dom: ["group/status", "sr-only", "group/tool"]),
                m(subroles: ["AXLandmarkComplementary"]),
            ]
        },
        Preset(name: "opencode", bundleIDs: ["ai.opencode.desktop"]) { p in
            p.scope = .rules
            p.granularity = .paragraph
            p.rules.containers = [m(dom: ["scroll-view__viewport"])]
            p.rules.excludes = [m(dom: ["tool-collapsible", "sticky", "sr-only"])]
        },
        Preset(name: "terminal", bundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2"]) { p in
            // Only the screen text area (skips the title bar).
            p.scope = .rules
            p.rules.containers = [m(roles: ["AXTextArea"])]
            p.textAreaHandling = .terminal
            p.enableManualAccessibility = false
        },
        Preset(name: "ghostty", bundleIDs: ["com.mitchellh.ghostty"]) { p in
            p.scope = .rules
            p.rules.containers = [m(roles: ["AXTextArea"])]
            p.textAreaHandling = .terminal
            p.enableManualAccessibility = false
        },
        Preset(name: "webchat", bundleIDs: ["com.deepseek.dsh"]) { p in
            // Generic rules for Electron chat apps that were not measured.
            p.scope = .rules
            p.granularity = .paragraph
            p.rules.containers = [m(roles: ["AXWebArea"])]
            p.rules.excludes = [
                m(subroles: [
                    "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkComplementary", "AXLandmarkContentInfo",
                ]),
                m(dom: ["sr-only", "hljs", "code-block", "language-", "katex", "cm-editor", "monaco-editor"]),
                // Sidebar thread lists (DeepSeek Harness).
                m(roles: ["AXOutline"]),
            ]
        },
        Preset(name: "browser", bundleIDs: [
            "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        ]) { p in
            // Any web page (AppPresets.browserProfile).
            p.scope = .rules
            p.granularity = .paragraph
            p.rules.containers = [m(roles: ["AXWebArea"])]
            p.rules.excludes = [
                m(subroles: ["AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkSearch", "AXLandmarkContentInfo"]),
                m(subroles: ["AXPreformattedStyleGroup"]),
                m(roles: ["AXOutline"]),
                m(dom: ["hljs", "shiki", "language-", "cm-", "monaco-", "sr-only", "visually-hidden", "mw-editsection"]),
            ]
            // Chrome builds its web tree only for AXEnhancedUserInterface; Safari always has it.
            p.enableManualAccessibility = false
            p.enableEnhancedUserInterface = true
        },
        Preset(name: "none", bundleIDs: []) { p in
            p.scope = .window
        },
    ]

    static func named(_ name: String) -> Preset? { all.first { $0.name == name } }
    static func forBundle(_ bundleID: String) -> Preset? { all.first { $0.bundleIDs.contains(bundleID) } }
}
