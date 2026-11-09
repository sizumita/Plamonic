import Foundation

/// A website's settings for the browser extensions (DESIGN §9.4): whether its pages are translated by themselves,
/// where on the page, and translation overrides. Kept in settings.json next to the app profiles, so every site is
/// set up in Plamonic, not in each browser.
struct SiteProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String { pattern }
    /// Which pages: a host ("www.youtube.com"), all of a domain ("*.wikipedia.org": the domain and its subdomains),
    /// optionally with a path prefix ("github.com/apple"). See `SitePattern`.
    var pattern: String
    var displayName: String
    /// automatic: translate a page when it opens. manual: when chosen in the extension's menu. off: never.
    var mode: TranslationMode = .manual
    /// CSS selectors of the parts to translate; empty = the whole page.
    var includeSelectors: [String] = []
    /// CSS selectors of parts never translated (inside the included ones too).
    var excludeSelectors: [String] = []
    var targetLanguageOverride: String? = nil
    var formOverride: JapaneseFormSetting? = nil
    /// Passed to PLaMo as PFML3 `context`, before the page's title.
    var context: String = ""

    init(pattern: String, displayName: String) {
        self.pattern = pattern
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decode(String.self, forKey: .pattern)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? pattern
        let d = SiteProfile(pattern: pattern, displayName: displayName)
        mode = try c.decodeIfPresent(TranslationMode.self, forKey: .mode) ?? d.mode
        includeSelectors = try c.decodeIfPresent([String].self, forKey: .includeSelectors) ?? d.includeSelectors
        excludeSelectors = try c.decodeIfPresent([String].self, forKey: .excludeSelectors) ?? d.excludeSelectors
        targetLanguageOverride = try c.decodeIfPresent(String.self, forKey: .targetLanguageOverride)
        formOverride = try c.decodeIfPresent(JapaneseFormSetting.self, forKey: .formOverride)
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? d.context
    }

    private enum CodingKeys: String, CodingKey {
        case pattern, displayName, mode, includeSelectors, excludeSelectors, targetLanguageOverride, formOverride
        case context
    }
}

/// Site patterns: `host[/path]`, where the host may start with `*.` to take in its subdomains (and the domain
/// itself) and the path is a prefix. A scheme is ignored; matching ignores case.
enum SitePattern {
    struct Parts: Equatable {
        var host: String
        var wildcard: Bool
        var path: String
    }

    static func parse(_ pattern: String) -> Parts? {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        let slash = text.firstIndex(of: "/")
        var host = slash.map { String(text[..<$0]) } ?? text
        let path = slash.map { String(text[$0...]) } ?? ""
        let wildcard = host.hasPrefix("*.")
        if wildcard { host.removeFirst(2) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        guard !host.isEmpty, !host.contains("*"), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return nil }
        return Parts(host: host, wildcard: wildcard, path: path == "/" ? "" : path)
    }

    /// How specifically `pattern` matches `url` (higher wins), or nil when it does not.
    static func specificity(_ pattern: String, url: URL) -> Int? {
        guard let parts = parse(pattern), let host = url.host()?.lowercased() else { return nil }
        let hostMatches =
            parts.wildcard ? (host == parts.host || host.hasSuffix("." + parts.host)) : host == parts.host
        guard hostMatches else { return nil }
        let path = url.path().lowercased()
        guard parts.path.isEmpty || path.hasPrefix(parts.path) else { return nil }
        return (parts.wildcard ? 0 : 10_000) + parts.host.count * 10 + parts.path.count * 100
    }

    /// The pattern for a page's site, for a new profile: its host without "www.".
    static func suggested(for url: URL) -> String? {
        guard var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
