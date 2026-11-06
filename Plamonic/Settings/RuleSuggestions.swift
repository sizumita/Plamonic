import Foundation

/// Turns inspected AX elements into rule matchers for the rule editor.
enum RuleSuggestions {
    /// Strips a trailing build hash from a CSS-module class ("messageContent_c19a55" -> "messageContent_").
    /// Classes without a hash-like suffix are returned unchanged.
    static func suggestedPrefix(forClass cls: String) -> String {
        guard let range = cls.range(of: #"(_{1,2}|-)[A-Za-z0-9]{5,8}$"#, options: .regularExpression) else {
            return cls
        }
        let tail = cls[range]
        let separator = tail.prefix { $0 == "_" || $0 == "-" }
        let hash = tail.dropFirst(separator.count)
        guard hash.contains(where: \.isNumber) else { return cls }
        return String(cls[..<range.lowerBound]) + separator
    }

    /// The matcher pre-selected for an element: its DOM class prefixes when it has any, else role + subrole.
    static func defaultMatcher(for element: ElementDescriptor) -> ElementMatcher {
        if let first = element.domClasses.first(where: { !$0.isEmpty }) {
            return ElementMatcher(domClassPrefixes: [suggestedPrefix(forClass: first)])
        }
        var matcher = ElementMatcher(roles: [element.role])
        if let subrole = element.subrole, !subrole.isEmpty { matcher.subroles = [subrole] }
        return matcher
    }

    /// One-line description of a matcher for lists ("role=AXGroup class^=p-rich_text_section").
    static func summary(of matcher: ElementMatcher) -> String {
        var parts: [String] = []
        if !matcher.roles.isEmpty { parts.append("role=" + matcher.roles.joined(separator: "|")) }
        if !matcher.subroles.isEmpty { parts.append("subrole=" + matcher.subroles.joined(separator: "|")) }
        if !matcher.roleDescriptions.isEmpty {
            parts.append("description=" + matcher.roleDescriptions.joined(separator: "|"))
        }
        if !matcher.domClassPrefixes.isEmpty { parts.append("class^=" + matcher.domClassPrefixes.joined(separator: "|")) }
        if !matcher.identifierPrefixes.isEmpty {
            parts.append("id^=" + matcher.identifierPrefixes.joined(separator: "|"))
        }
        return parts.joined(separator: " ")
    }

    /// Patterns that NSRegularExpression cannot compile.
    static func invalidPatterns(_ patterns: [String]) -> [String] {
        patterns.filter { (try? NSRegularExpression(pattern: $0)) == nil }
    }
}
