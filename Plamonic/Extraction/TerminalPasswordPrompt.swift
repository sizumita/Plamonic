import CoreFoundation
import Foundation

/// Tells whether a terminal screen waits for a password (`Password:`, `[sudo] password for …:`,
/// `Enter passphrase for key '…':`, `パスワード:`…). Only string checks on the screen the scan already read.
/// DESIGN §4.1.
enum TerminalPasswordPrompt {
    /// Longer lines are output, not prompts.
    static let maxLineLength = 200
    /// At most this many characters between the password word and the colon (`for key '/path/to/key'`).
    static let maxTailLength = 120

    /// Whether the screen waits for a password: the line with the insertion point (the text before it, when
    /// the rest of the line is blank) or the last non-empty line ends with a password prompt. Both are checked:
    /// terminals may report the mouse selection or a stale position instead of the cursor, and a status line
    /// (tmux, a TUI) can sit below the prompt.
    /// - insertionPoint: AXSelectedTextRange, in the UTF-16 space of the lines' offsets; nil = unknown.
    static func isWaiting(lines: [TerminalLine], insertionPoint: CFRange?) -> Bool {
        if let point = insertionPoint, let line = lineBefore(point, in: lines), matches(line) { return true }
        guard let last = lines.last(where: { !isBlank($0.text) }) else { return false }
        return matches(last.text)
    }

    /// Whether one line ends with a password prompt: a password word, then at most `maxTailLength` characters
    /// and a colon at the end (spaces, borders and typed `*` after it are allowed).
    static func matches(_ line: String) -> Bool {
        typedMarks(in: line) != nil
    }

    /// The line with the marks typed after a password prompt (`*`, `•`…: sudo's pwfeedback, masked inputs)
    /// turned into spaces; other lines come back unchanged. Each mark is one UTF-16 unit, so offsets stay valid.
    /// The marks then never reach a segment, a translation or the cache, and typing does not change the text.
    static func blankingInput(_ line: String) -> String {
        guard let marks = typedMarks(in: line), !marks.isEmpty else { return line }
        var result = line
        result.replaceSubrange(marks, with: String(repeating: " ", count: line[marks].utf16.count))
        return result
    }

    /// Where the typed marks of a prompt line are (an empty range when there are none); nil when the line is
    /// no password prompt.
    private static func typedMarks(in line: String) -> Range<String.Index>? {
        var s = Substring(line)
        trimTrailingBlank(&s)
        if s.lowercased().hasSuffix(hiddenNote) {
            // Inquirer-style prompts: "? Master password: [input is hidden]".
            s.removeLast(hiddenNote.count)
            trimTrailingBlank(&s)
        }
        // sudo's pwfeedback and masked inputs echo one mark per typed character.
        let marksEnd = s.endIndex
        while let c = s.last, maskCharacters.contains(c) { s.removeLast() }
        let marks = s.endIndex..<marksEnd
        trimTrailingBlank(&s)
        guard let colon = s.last, colon == ":" || colon == "：" else { return nil }
        s.removeLast()
        trimTrailingBlank(&s)  // "Mot de passe :"
        guard !s.isEmpty, s.count <= maxLineLength else { return nil }
        let text = String(s)
        let ns = text as NSString
        for match in passwordWord.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tail = ns.substring(from: match.range.upperBound)
            // A colon followed by a space is a label and its value ("Password: hunter2 …").
            if tail.count <= maxTailLength, !tail.contains(": "), !tail.contains("：") { return marks }
        }
        return nil
    }

    /// The text before the insertion point on its line, when it is an insertion point (no selection) on one of
    /// the lines and only blanks follow it in its pane (up to a vertical border or the end of the line).
    static func lineBefore(_ point: CFRange, in lines: [TerminalLine]) -> String? {
        guard point.length == 0 else { return nil }
        guard
            let line = lines.first(where: {
                point.location >= $0.utf16Offset && point.location <= $0.utf16Offset + $0.text.utf16.count
            })
        else { return nil }
        let ns = line.text as NSString
        let split = point.location - line.utf16Offset
        for c in ns.substring(from: split) {
            if TerminalSegmenter.verticalBorders.contains(c) { break }
            guard isBlankCharacter(c) else { return nil }
        }
        return ns.substring(to: split)
    }

    // MARK: Pieces

    /// Password words. ASCII and Cyrillic words must not be part of a longer word, a path or a URL.
    private static let passwordWord = try! NSRegularExpression(
        pattern: #"(?i)(?:(?<![\p{L}\p{N}_/.\-=?&#%+~@])"#
            + #"(?:password|passwort|kennwort|passphrase|pass phrase|passcode|pin|senha|contraseña|mot de passe|"#
            + #"wachtwoord|hasło|пароль)"#
            + #"(?![\p{L}\p{N}_/.\-=?&#%+~@])"#
            + #"|パスワード|パスフレーズ|パスコード|暗証番号|密码|密碼|口令|비밀번호|암호(?!화))"#)

    private static let hiddenNote = "[input is hidden]"
    private static let maskCharacters: Set<Character> = ["*", "•", "●", "∙", "·"]

    private static func isBlankCharacter(_ c: Character) -> Bool {
        c.isWhitespace || c == "\u{0}" || TerminalSegmenter.verticalBorders.contains(c)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(isBlankCharacter)
    }

    private static func trimTrailingBlank(_ s: inout Substring) {
        while let c = s.last, isBlankCharacter(c) { s.removeLast() }
    }
}
