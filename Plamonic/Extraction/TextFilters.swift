import Foundation

/// Why a piece of text is not worth translating.
enum TextRejection: String, Sendable, CaseIterable {
    case empty
    case tooShort
    case tooLong
    case noLetters  // whitespace, digits, symbols or emoji only
    case numeric  // numbers, timestamps, dates, counters
    case emojiShortcode  // ":thumbsup:"
    case url
    case filePath
    case codeLike
    case ignoredPattern
}

/// Heuristics that decide whether on-screen text is natural language worth translating.
enum TextFilters {
    /// nil = translate it. `text` should already be normalized (`normalize`).
    /// `detectCode: false` skips the code heuristic (for text whose lines were already checked one by one).
    static func rejection(
        for text: String, minLength: Int, maxLength: Int = .max, ignore: IgnorePatterns? = nil,
        detectCode: Bool = true
    ) -> TextRejection? {
        if text.isEmpty { return .empty }
        if text.count < max(1, minLength) { return .tooShort }
        if text.count > maxLength { return .tooLong }
        if !text.contains(where: { $0.isLetter }) { return .noLetters }
        if let ignore, ignore.matches(text) { return .ignoredPattern }
        if isNumericOrTimestamp(text) { return .numeric }
        if isEmojiShortcodeOnly(text) { return .emojiShortcode }
        if isURLOnly(text) { return .url }
        if isFilePath(text) { return .filePath }
        if detectCode, isCodeLike(text) { return .codeLike }
        return nil
    }

    static func shouldTranslate(_ text: String, minLength: Int, maxLength: Int = .max, ignore: IgnorePatterns? = nil)
        -> Bool
    {
        rejection(for: text, minLength: minLength, maxLength: maxLength, ignore: ignore) == nil
    }

    // MARK: Normalization

    /// Removes zero-width characters, collapses runs of spaces, trims each line and drops extra blank lines.
    static func normalize(_ raw: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        let cleaned = raw.replacingOccurrences(of: "\r\n", with: "\n").filter {
            $0 != "\u{200B}" && $0 != "\u{FEFF}" && $0 != "\u{00AD}" && $0 != "\u{2060}"
        }
        for line in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = collapseSpaces(line)
            if collapsed.isEmpty {
                blankRun += 1
                if blankRun == 1, !lines.isEmpty { lines.append("") }
            } else {
                blankRun = 0
                lines.append(collapsed)
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// `normalize`, and where each UTF-16 unit of the result came from in `raw` (to move link ranges along).
    /// The text is the same as `normalize(raw)` except in odd cases (a zero-width character inside "\r\n");
    /// callers compare and drop the links when it differs.
    static func normalizeMapped(_ raw: String) -> (text: String, map: TextOffsetMap) {
        struct Line {
            var chars: [(Character, Int)] = []
            /// Offset of the line break that ends it.
            var end: Int?
        }
        var lines: [Line] = []
        var current = Line()
        var offset = 0
        for ch in raw {
            let at = offset
            offset += ch.utf16.count
            if ch == "\n" || ch == "\r\n" {
                current.end = at
                lines.append(current)
                current = Line()
            } else if ch != "\u{200B}" && ch != "\u{FEFF}" && ch != "\u{00AD}" && ch != "\u{2060}" {
                current.chars.append((ch, at))
            }
        }
        lines.append(current)

        var kept: [(chars: [(Character, Int)], end: Int?)] = []
        var blankRun = 0
        for line in lines {
            var out: [(Character, Int)] = []
            var pendingSpace: Int?
            for (ch, at) in line.chars {
                if ch == " " || ch == "\t" || ch == "\u{00A0}" {
                    if pendingSpace == nil { pendingSpace = at }
                } else {
                    if let space = pendingSpace, !out.isEmpty { out.append((" ", space)) }
                    pendingSpace = nil
                    out.append((ch, at))
                }
            }
            if out.isEmpty {
                blankRun += 1
                if blankRun == 1, !kept.isEmpty { kept.append(([], line.end)) }
            } else {
                blankRun = 0
                kept.append((out, line.end))
            }
        }
        while let last = kept.last, last.chars.isEmpty { kept.removeLast() }

        var text = ""
        var sources: [Int] = []
        for (i, line) in kept.enumerated() {
            if i > 0 {
                text.append("\n")
                sources.append(kept[i - 1].end ?? sources.last ?? 0)
            }
            for (ch, at) in line.chars {
                text.append(ch)
                for _ in 0..<ch.utf16.count { sources.append(at) }
            }
        }
        return (text, TextOffsetMap(sources: sources))
    }

    private static func collapseSpaces(_ line: Substring) -> String {
        var out = ""
        out.reserveCapacity(line.count)
        var pendingSpace = false
        for ch in line {
            if ch == " " || ch == "\t" || ch == "\u{00A0}" {
                pendingSpace = true
            } else {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            }
        }
        return out
    }

    // MARK: Classifiers

    private static let timeWords: Set<String> = [
        "am", "pm", "a.m.", "p.m.", "午前", "午後", "今日", "昨日", "edited", "(edited)", "（編集済）", "(編集済)",
    ]
    private static let numericToken = try! NSRegularExpression(
        pattern:
            #"^[#+\-±~≈<>@(（\[]*[0-9０-９][0-9０-９.,:/\-_'’]*(%|[kKmMbBgGtT]|ms|[smhdwy]|px|pt|x|kb|mb|gb|時間|時|分|秒|日|月|年|件|個|人|回|歳|週間|週|か月|ヶ月)?[)）\]]*[.,:;!]?$"#
    )
    private static let cjkDate = try! NSRegularExpression(
        pattern: #"^([0-9０-９]+[年月日時分秒])+([0-9０-９]+)?([(（][^)）]{1,3}[)）])?$"#)

    /// Numbers, times, dates, counters ("12:30", "10:00 AM", "2025/11/05", "3h", "+12 -4", "2025年11月5日").
    static func isNumericOrTimestamp(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty, tokens.count <= 8 else { return false }
        var sawDigit = false
        for token in tokens {
            let t = String(token)
            if timeWords.contains(t.lowercased()) { continue }
            if matches(numericToken, t) || matches(cjkDate, t) {
                sawDigit = true
                continue
            }
            return false
        }
        return sawDigit
    }

    private static let shortcode = try! NSRegularExpression(pattern: #"^(:[\w+\-']+:\s*)+$"#)

    static func isEmojiShortcodeOnly(_ text: String) -> Bool { matches(shortcode, text) }

    private static let urlToken = try! NSRegularExpression(
        pattern:
            #"^(?:[a-zA-Z][a-zA-Z0-9+.\-]*://\S+|www\.\S+|mailto:\S+|[^\s@/]+@[^\s@/]+\.[A-Za-z]{2,}|[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.(?:com|net|org|io|dev|app|ai|co|jp|me|so|sh|gg|ly|tv|us|uk|de|fr|info|xyz|tech|edu|gov)(?::\d+)?(?:/\S*)?)$"#
    )

    /// One or more URLs / e-mail addresses and nothing else.
    static func isURLOnly(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]（）「」\"'.,;"))
            return !t.isEmpty && matches(urlToken, t)
        }
    }

    private static let absolutePath = try! NSRegularExpression(pattern: #"^(?:~|\.{1,2})?/[^\s]*$"#)
    private static let windowsPath = try! NSRegularExpression(pattern: #"^[A-Za-z]:\\[^\s]*$"#)
    private static let relativePath = try! NSRegularExpression(pattern: #"^[\w.@\-]+(?:/[\w.@\-]+)+/?(?::\d+(?::\d+)?)?$"#)
    private static let fileName = try! NSRegularExpression(
        pattern: #"^[\w\-]+(?:\.[\w\-]+)*\.[A-Za-z][A-Za-z0-9]{0,7}(?::\d+(?::\d+)?)?$"#)

    /// A single path or file name token ("/usr/bin", "~/x", "src/main.swift", "README.md", "C:\x").
    static func isFilePath(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()（）「」"))
        guard !t.contains(where: { $0.isWhitespace }), !t.isEmpty else { return false }
        guard t.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        return matches(absolutePath, t) || matches(windowsPath, t) || matches(relativePath, t) || matches(fileName, t)
    }

    /// Source code, shell commands, identifiers. Multi-line text is code-like when most lines are.
    static func isCodeLike(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let codeLines = lines.reduce(0) { $0 + (isCodeLine($1) ? 1 : 0) }
        return codeLines * 2 > lines.count
    }

    private static let codeKeywords: [String] = [
        "func ", "let ", "var ", "const ", "import ", "export ", "return ", "def ", "class ", "struct ", "enum ",
        "if (", "for (", "while (", "switch (", "fn ", "pub ", "#include", "#import", "#define", "package ",
        "public ", "private ", "static ", "async ", "await ", "try ", "catch ", "elif ", "else {", "} else",
        "@objc", "@available", "@property", "#!/",
    ]
    private static let strongCodeMarkers: [String] = [
        "=>", "->", "::", "==", "!=", "&&", "||", ":=", "+=", "-=", "</", "/>", "();", "){", ") {", "};", "[]",
    ]
    /// Command names that are not everyday words: with a few arguments, flags, paths or pipes it is a command.
    private static let shellCommands: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "brew", "pip", "pip3", "python3", "swiftc", "xcodebuild", "xcrun",
        "cargo", "docker", "kubectl", "curl", "wget", "sudo", "rm", "mv", "cp", "mkdir", "ssh", "grep", "rg", "sed",
        "awk", "chmod", "chown", "uv", "deno", "gh",
    ]
    /// Command names that are also words ("make sure", "go ahead", "find the bug", "claude is great"):
    /// a command only when what follows looks like arguments.
    private static let ambiguousCommands: Set<String> = [
        "go", "make", "find", "head", "tail", "source", "export", "cat", "cd", "ls", "echo", "python", "node",
        "swift", "bun", "claude", "codex", "opencode", "defaults",
    ]
    /// Subcommands that make an ambiguous name a command ("go test ./...", "swift build").
    private static let ambiguousSubcommands: [String: Set<String>] = [
        "go": ["build", "run", "test", "mod", "get", "install", "vet", "fmt", "generate", "env", "version", "work"],
        "swift": ["build", "run", "test", "package"],
        "bun": ["install", "run", "add", "remove", "test", "build", "x"],
    ]
    private static let identifier = try! NSRegularExpression(
        pattern:
            #"^(?:[A-Za-z_$][\w$]*(?:[_.:/#\-][\w$]+)+(?:\(\))?|[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*(?:\(\))?|[A-Za-z_$][\w$]*\(\)|[A-Z0-9_]{3,}=\S*|--?[a-z][\w\-]*)$"#
    )

    static func isCodeLine(_ line: String) -> Bool {
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let cjk = letters.filter { TextMetrics.isCJK($0) }.count
        // Mostly CJK prose is natural language even with some symbols.
        if !letters.isEmpty, cjk * 10 >= letters.count * 3 { return false }

        if line.hasSuffix(";") || line.hasSuffix("{") || line.hasPrefix("}") || line == ")" || line == "]" {
            return true
        }
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        if tokens.count == 1 {
            return matches(identifier, line)
        }
        if codeKeywords.contains(where: { line.hasPrefix($0) }) && line.contains(where: { "(){}=;:<>[]".contains($0) })
        {
            return true
        }
        if strongCodeMarkers.contains(where: { line.contains($0) }) {
            // Prose occasionally uses "->"; require code-ish density as well.
            if symbolRatio(line) >= 0.08 { return true }
        }
        if isShellCommand(line, tokens: tokens) { return true }
        if line.hasPrefix("$ ") || line.hasPrefix("% ") { return true }
        return symbolRatio(line) >= 0.25
    }

    /// "git push", "ls -la", "cd ~/src", "go test ./...", but not "make sense?" or "find the bug in auth/login".
    private static func isShellCommand(_ line: String, tokens: [Substring]) -> Bool {
        guard let first = tokens.first.map(String.init), line.unicodeScalars.allSatisfy({ $0.isASCII }),
            !hasProsePunctuation(line)
        else { return false }
        if shellCommands.contains(first) {
            return line.contains(" -") || line.contains("/") || line.contains("~") || line.contains("=")
                || line.contains("|") || line.contains("&&") || tokens.count <= 3
        }
        guard ambiguousCommands.contains(first), tokens.count >= 2 else { return false }
        if line.contains("|") || line.contains("&&") || tokens.dropFirst().contains(where: isFlag) { return true }
        if isArgument(tokens[1]) { return true }
        if let subcommands = ambiguousSubcommands[first], subcommands.contains(String(tokens[1])) {
            return tokens.count == 2 || isArgument(tokens[2])
        }
        return false
    }

    /// "-la", "--force", "-5".
    private static func isFlag(_ token: Substring) -> Bool {
        let body = token.drop(while: { $0 == "-" })
        let dashes = token.count - body.count
        guard dashes == 1 || dashes == 2, let c = body.first else { return false }
        return c.isLetter || c.isNumber
    }

    /// A path, file name, variable, assignment or quoted string: "./x", "~/src", "README.md", "$PATH", "A=1".
    private static func isArgument(_ token: Substring) -> Bool {
        if token.contains("/") || token.contains("=") { return true }
        if let c = token.first, ".~$\"".contains(c) { return true }
        return matches(fileName, String(token))
    }

    /// Sentence punctuation outside quotes: "?" / "!" after a word, an apostrophe inside a word ("it's"),
    /// ", " or a final "." after a word. Commands rarely have them unquoted.
    private static func hasProsePunctuation(_ line: String) -> Bool {
        let chars = Array(line)
        var quote: Character?
        for (i, c) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"":
                quote = c
            case "'":
                if prev?.isLetter == true && next?.isLetter == true { return true }
                if prev == nil || prev!.isWhitespace || prev == "=" { quote = c }
            case "?", "!":
                if prev.map({ $0.isLetter || $0.isNumber }) == true, next == nil || next!.isWhitespace { return true }
            case ",":
                if next?.isWhitespace == true { return true }
            case ".":
                if next == nil, prev?.isLetter == true { return true }
            default:
                break
            }
        }
        return false
    }

    private static func symbolRatio(_ line: String) -> Double {
        var symbols = 0
        var nonSpace = 0
        for ch in line where !ch.isWhitespace {
            nonSpace += 1
            if "{}[]()<>;=$#|&\\`^~*/+_@%".contains(ch) { symbols += 1 }
        }
        return nonSpace == 0 ? 0 : Double(symbols) / Double(nonSpace)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// User-provided regular expressions (AppProfile.ignorePatterns). Invalid ones are skipped.
final class IgnorePatterns: @unchecked Sendable {
    let patterns: [String]
    private(set) var invalidPatterns: [String] = []
    private let regexes: [NSRegularExpression]

    init(_ patterns: [String]) {
        self.patterns = patterns
        var compiled: [NSRegularExpression] = []
        var invalid: [String] = []
        for p in patterns where !p.trimmingCharacters(in: .whitespaces).isEmpty {
            if let re = try? NSRegularExpression(pattern: p, options: []) {
                compiled.append(re)
            } else {
                invalid.append(p)
            }
        }
        regexes = compiled
        invalidPatterns = invalid
    }

    var isEmpty: Bool { regexes.isEmpty }

    /// true when any pattern matches anywhere in `text` (use ^...$ in the pattern to match the whole text).
    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regexes.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}

/// Character classes and terminal display widths.
enum TextMetrics {
    /// Han, kana, CJK punctuation and fullwidth forms: scripts written without spaces between words.
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF,
            0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFF60, 0xFF61...0xFF9F, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return isCJK(s)
    }

    /// Terminal cell width: 2 for East Asian wide / fullwidth and most emoji, 0 for combining marks, else 1.
    static func cellWidth(_ c: Character) -> Int {
        guard let s = c.unicodeScalars.first else { return 0 }
        if c.unicodeScalars.count == 1, s.properties.generalCategory == .nonspacingMark { return 0 }
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
            0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
            0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    static func cellWidth(_ s: Substring) -> Int { s.reduce(0) { $0 + cellWidth($1) } }
    static func cellWidth(_ s: String) -> Int { s.reduce(0) { $0 + cellWidth($1) } }

    /// Joins two hard-wrapped pieces of the same paragraph: no space between CJK text, one space otherwise.
    static func joinWrapped(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        if last.isWhitespace || first.isWhitespace { return a + b }
        if isCJK(last) || isCJK(first) { return a + b }
        return a + " " + b
    }

    /// Stable 64-bit FNV-1a hash as 16 hex digits.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
