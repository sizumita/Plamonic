import Foundation

/// Cheap checks that keep obviously untranslatable text away from the model.
/// Extraction applies its own rules first; this is the last line before a job is queued.
enum TranslationTextFilter {
    enum Rejection: String, Equatable, Sendable {
        case empty
        case tooShort
        case noLetters  // digits, punctuation, symbols, emoji only
        case url
        case filePath
        case codeLike
        case ignoredByPattern
    }

    /// `text` should already be normalized by `TextSanitizer.normalize`.
    static func rejection(
        for text: String, minLength: Int, ignorePatterns: [NSRegularExpression] = []
    ) -> Rejection? {
        let visible = text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        if visible == 0 { return .empty }
        if visible < max(1, minLength) { return .tooShort }
        if !text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { return .noLetters }

        // CJK prose has no spaces, so a whole sentence would read as one token ("foo()を呼びます").
        if !text.contains(where: { $0.isWhitespace }) && !isMostlyCJK(text) {
            if matches(urlRegex, text) || matches(emailRegex, text) { return .url }
            if matches(pathRegex, text) || matches(relativeFileRegex, text) { return .filePath }
            if looksLikeCodeToken(text) { return .codeLike }
        } else if looksLikeCodeBlock(text, visibleCount: visible) {
            return .codeLike
        }

        if !ignorePatterns.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            if ignorePatterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
                return .ignoredByPattern
            }
        }
        return nil
    }

    /// Compiles user patterns, skipping invalid ones.
    static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { pattern in
            guard !pattern.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: pattern)
        }
    }

    // MARK: - Heuristics

    private static let urlRegex = regex(#"^(?:[a-z][a-z0-9+.-]*://|www\.)\S+$"#, caseInsensitive: true)
    private static let emailRegex = regex(#"^[^@\s]+@[^@\s]+\.[a-z]{2,}$"#, caseInsensitive: true)
    private static let pathRegex = regex(#"^(?:~|\.{1,2})?/\S*/\S*$|^[A-Za-z]:\\\S*$"#)
    private static let relativeFileRegex = regex(#"^[\w.@-]+(?:/[\w.@-]+)+\.[A-Za-z0-9]{1,8}$"#)
    private static let hexRegex = regex(#"^[0-9a-f]{7,64}$"#, caseInsensitive: true)
    private static let dottedIdentifierRegex = regex(#"^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+(?:\(\))?$"#)
    private static let snakeCaseRegex = regex(#"^[A-Za-z0-9]+(?:_[A-Za-z0-9]+)+$"#)
    private static let camelCaseRegex = regex(#"^[a-z]+[A-Z][A-Za-z0-9]*$"#)
    private static let codePunctuation: Set<Character> = ["{", "}", "[", "]", "<", ">", ";", "=", "|", "\\", "`"]

    /// A single token that reads like an identifier, hash or expression.
    private static func looksLikeCodeToken(_ token: String) -> Bool {
        if matches(hexRegex, token) && token.contains(where: { $0.isNumber }) { return true }
        if matches(snakeCaseRegex, token) || matches(camelCaseRegex, token) { return true }
        if matches(dottedIdentifierRegex, token) { return true }
        for marker in ["::", "->", "=>", "()", "==", "!=", "&&", "||", "</", "/>"] where token.contains(marker) {
            return true
        }
        return false
    }

    /// At least 30 % of the letters are kana, han or hangul (the rule Extraction's `isCodeLine` uses).
    private static func isMostlyCJK(_ text: String) -> Bool {
        let profile = LanguageDetector.ScriptProfile(text)
        return profile.letters > 0 && (profile.kana + profile.han + profile.hangul) * 10 >= profile.letters * 3
    }

    /// Text where code punctuation is dense or most lines end like statements.
    private static func looksLikeCodeBlock(_ text: String, visibleCount: Int) -> Bool {
        let codeCharacters = text.reduce(0) { codePunctuation.contains($1) ? $0 + 1 : $0 }
        if visibleCount >= 8 && Double(codeCharacters) / Double(visibleCount) >= 0.2 { return true }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 3 else { return false }
        let statementLines = lines.filter { line in
            guard let last = line.last else { return false }
            return last == ";" || last == "{" || last == "}"
        }
        return Double(statementLines.count) / Double(lines.count) >= 0.5
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
