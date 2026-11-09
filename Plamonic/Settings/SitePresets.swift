import Foundation

/// Built-in website profiles: where the text worth translating is on sites people often read in another
/// language. Like app presets, a preset stays as it is until the user edits it; the edited copy is stored instead.
enum SitePresets {
    static let all: [SiteProfile] = [
        make("www.youtube.com", "YouTube", include: [
            // Titles, the description, comments and replies; not the player, buttons or the sidebar's chips.
            "ytd-watch-metadata #title", "#description-inline-expander", "ytd-comment-view-model #content-text",
            "#video-title", "yt-lockup-metadata-view-model h3",
        ], exclude: ["#masthead-container", "ytd-mini-guide-renderer", "#chips"],
        context: "YouTube"),
        make("x.com", "X", include: ["[data-testid=\"tweetText\"]", "[data-testid=\"UserDescription\"]"],
             context: "Posts on X (formerly Twitter)"),
        make("*.reddit.com", "Reddit", include: [
            "shreddit-post h1", "shreddit-post [slot=\"text-body\"]", "shreddit-comment [slot=\"comment\"]",
            "a[slot=\"title\"]",
        ], context: "Reddit posts and comments"),
        make("github.com", "GitHub", include: [
            ".markdown-body", ".comment-body", ".js-issue-title", "[data-testid=\"issue-title\"]", ".f4.my-3",
        ], exclude: [".blob-code", ".highlight", ".commit-tease"], context: "GitHub"),
        make("*.wikipedia.org", "Wikipedia", include: ["#firstHeading", "#mw-content-text"],
             exclude: [".mw-editsection", ".reference", ".reflist", ".navbox", ".infobox .mergedrow"],
             context: "Wikipedia article"),
        make("news.ycombinator.com", "Hacker News", include: [".titleline", ".commtext", ".toptext"],
             context: "Hacker News"),
    ]

    static func preset(for pattern: String) -> SiteProfile? {
        all.first { $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame }
    }

    private static func make(
        _ pattern: String, _ name: String, include: [String] = [], exclude: [String] = [], context: String = ""
    ) -> SiteProfile {
        var profile = SiteProfile(pattern: pattern, displayName: name)
        profile.includeSelectors = include
        profile.excludeSelectors = exclude
        profile.context = context
        return profile
    }
}
