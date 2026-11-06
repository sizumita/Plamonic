import CoreGraphics
import Foundation

/// One row of a terminal screen as read from the AX text area.
struct TerminalLine: Equatable, Sendable {
    var row: Int
    var text: String
    /// UTF-16 offset of the line's first character in the string the AX ranges refer to.
    var utf16Offset: Int
}

/// A kept piece of one row (absolute UTF-16 range, for AXBoundsForRange).
struct TerminalSpan: Equatable, Sendable {
    var row: Int
    var location: Int
    var length: Int
}

/// Rejoined paragraph of terminal text.
struct TerminalParagraph: Equatable, Sendable {
    var text: String
    var spans: [TerminalSpan]
    /// UTF-16 offset in `text` where each span's text starts (parallel to `spans`).
    var pieceOffsets: [Int] = []
}

enum TerminalLineKind: Equatable, Sendable {
    case blank
    case border  // box-drawing rules and frames
    case chrome  // spinners, status bars, key hints
    case prompt  // shell / TUI input prompts and echoed user input
    case toolHeader  // "⏺ Bash(ls)", "• Ran git status"
    case toolOutput  // "⎿ ...", "└ ..." and their indented continuation
    case code
    case ignored  // matched a user ignore pattern
    case content

    /// Kinds decided from one row's text alone. Such a row still continues a paragraph when the previous row
    /// was filled to the wrap width (it is a wrapped piece of prose, not a line of its own).
    var isSoftBreak: Bool { self == .chrome || self == .code || self == .ignored }
}

/// Turns a terminal screen (Claude Code / Codex / OpenCode CLIs, shells) into translatable paragraphs:
/// drops TUI chrome, splits side-by-side panes at vertical borders, and rejoins hard-wrapped lines.
enum TerminalSegmenter {
    /// Splits the visible screen text into rows. `baseOffset` is the UTF-16 location of `text` in the element.
    static func lines(fromScreen text: String, baseOffset: Int = 0) -> [TerminalLine] {
        var result: [TerminalLine] = []
        var offset = baseOffset
        var row = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = String(line)
            if s.hasSuffix("\r") { s.removeLast() }
            result.append(TerminalLine(row: row, text: s, utf16Offset: offset))
            offset += line.utf16.count + 1
            row += 1
        }
        return result
    }

    /// - columns: terminal width in cells when known; helps tell short deliberate lines from wrapped ones.
    static func segment(
        _ lines: [TerminalLine], columns: Int? = nil, ignore: IgnorePatterns? = nil, maxParagraphs: Int = .max
    ) -> [TerminalParagraph] {
        // Fragments per row, split at vertical borders.
        let rows = lines.map { fragments(of: $0) }

        // Classify, with one row of lookahead for tool headers ("⏺ Bash(...)" followed by "⎿ ...").
        var kinds: [[TerminalLineKind]] = []
        for (r, frags) in rows.enumerated() {
            var rowKinds: [TerminalLineKind] = []
            for f in frags {
                var kind = classify(f.text, ignore: ignore)
                if kind == .content || kind == .code {
                    let next = r + 1 < rows.count ? rows[r + 1].first(where: { $0.key == f.key }) : nil
                    if let next, startsWithToolTree(next.text), next.indent >= f.indent {
                        kind = .toolHeader
                    }
                }
                rowKinds.append(kind)
            }
            kinds.append(rowKinds)
        }

        // Tool blocks: everything indented deeper than a tool header / tree line belongs to the tool output.
        var toolIndent: [Int: Int] = [:]
        for r in rows.indices {
            for i in rows[r].indices {
                let f = rows[r][i]
                let kind = kinds[r][i]
                if kind == .blank {
                    toolIndent[f.key] = nil
                    continue
                }
                if let ti = toolIndent[f.key] {
                    if f.indent > ti {
                        kinds[r][i] = .toolOutput
                        continue
                    }
                    toolIndent[f.key] = nil
                }
                if kind == .toolHeader {
                    toolIndent[f.key] = f.indent
                } else if kind == .toolOutput {
                    toolIndent[f.key] = max(0, f.indent - 1)
                }
            }
        }

        // Wrap width per pane, used to tell wrapped lines from deliberate line breaks: the widest content line,
        // unless the pane only has short lines, then its border (or the terminal width).
        var observed: [Int: Int] = [:]
        var bound: [Int: Int] = [:]
        for r in rows.indices {
            for i in rows[r].indices {
                let f = rows[r][i]
                if let p = f.paneRight { bound[f.key] = max(bound[f.key] ?? 0, p) }
                if kinds[r][i] == .content { observed[f.key] = max(observed[f.key] ?? 0, f.rightCol) }
            }
        }
        var wrapRight: [Int: Int] = [:]
        for (key, right) in observed {
            if let b = bound[key] ?? columns, b > key, Double(right - key) < Double(b - key) * 0.6 {
                wrapRight[key] = b
            } else {
                wrapRight[key] = right
            }
        }

        var paragraphs: [TerminalParagraph] = []
        var open: [Int: Builder] = [:]
        func close(_ key: Int) {
            guard let b = open.removeValue(forKey: key) else { return }
            if let p = b.paragraph() { paragraphs.append(p) }
        }

        for r in rows.indices {
            var seen = Set<Int>()
            for i in rows[r].indices {
                let f = rows[r][i]
                seen.insert(f.key)
                let kind = kinds[r][i]
                guard kind == .content || kind.isSoftBreak else {
                    close(f.key)
                    continue
                }
                let item = ContentLine(f)
                let wrap = wrapRight[f.key] ?? 0
                if let b = open[f.key],
                    kind == .content
                        ? b.canAppend(item, paneLeft: f.key, wrapRight: wrap)
                        // A wrapped row of prose that only looks like chrome or code on its own
                        // ("let me know (with the log) ...", "... the cache;"): keep the paragraph whole.
                        : b.continuesWrapped(item, paneLeft: f.key, wrapRight: wrap)
                {
                    b.append(item, wrapRight: wrap)
                } else {
                    close(f.key)
                    if kind == .content { open[f.key] = Builder(item) }
                }
            }
            for key in Array(open.keys) where !seen.contains(key) { close(key) }
        }
        for key in open.keys.sorted() { close(key) }

        paragraphs.sort {
            ($0.spans.first?.row ?? 0, $0.spans.first?.location ?? 0)
                < ($1.spans.first?.row ?? 0, $1.spans.first?.location ?? 0)
        }
        // The newest output is at the bottom of a terminal: keep the last paragraphs.
        if paragraphs.count > maxParagraphs { paragraphs.removeFirst(paragraphs.count - maxParagraphs) }
        return paragraphs
    }

    // MARK: Classification

    static func classify(_ rawText: String, ignore: IgnorePatterns? = nil) -> TerminalLineKind {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .blank }
        if isBorder(text) { return .border }
        if startsWithToolTree(text) { return .toolOutput }
        if isChrome(text) { return .chrome }
        if isPrompt(text) { return .prompt }
        if isToolHeader(text) { return .toolHeader }
        if let ignore, ignore.matches(text) { return .ignored }
        if TextFilters.isCodeLine(stripDecorativeBullet(text).text) { return .code }
        return .content
    }

    static let verticalBorders: Set<Character> = ["│", "┃", "║", "╎", "╏", "┆", "┇", "┊", "┋", "▌", "▐", "▏", "▕"]

    static func isBoxCharacter(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x2500...0x259F).contains(s.value) || (0x1FB00...0x1FBFF).contains(s.value)
    }

    static func isBorder(_ text: String) -> Bool {
        var box = 0
        var other = 0
        for c in text where !c.isWhitespace {
            if isBoxCharacter(c) { box += 1 } else { other += 1 }
        }
        if box == 0 { return false }
        if other == 0 { return true }
        // A rule with a label: "─ Worked for 12s ──────────".
        if let first = text.first, let last = text.last, isBoxCharacter(first), isBoxCharacter(last), box >= 3 {
            return true
        }
        return box >= 6 && box >= other * 2
    }

    private static let spinnerGlyphs: Set<Character> = [
        "·", "✢", "✳", "✶", "✻", "✽", "✺", "✹", "✸", "✷", "∗", "*", "◐", "◓", "◑", "◒", "◴", "◷", "◶", "◵",
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷", "◦", "•",
        "⏺", "●",
    ]

    /// Key hints and status texts of TUI footers. Prose can contain them too ("press ctrl+c to stop the
    /// server"), so they count only where a footer puts them (see `isFooterHint`).
    private static let chromePhrases: [String] = [
        "esc to interrupt", "esc to cancel", "esc to go back", "esc to exit", "ctrl+c to", "ctrl-c to",
        "? for shortcuts", "shift+tab to", "accept edits", "bypass permissions", "plan mode on", "auto-accept",
        "context left", "until auto-compact", "ctrl+r to expand", "ctrl+o to expand", "ctrl+t to", "ctrl+b to",
        "ctrl+e to", "ctrl+g to", "ctrl+x ", "press enter", "enter to confirm", "enter to send", "⏎ send",
        "⌃c quit", "ctrl+c quit", "/model to change", "tab to switch", "esc interrupt", "ide disconnected",
        "◯ ide", "⧉ in ", "tokens used", "token usage", "↑↓ to", "↑/↓", "press up to edit", "background tasks",
        "· ↑", "· ↓", "last login:",
    ]
    /// Footer words that are ordinary in prose ("ends with a newline"): only in a row of separated hints.
    private static let chromeWords: [String] = [
        "newline", "transcript", "to quit", "for agents", "queued messages", "tab switch",
    ]

    static func isChrome(_ text: String) -> Bool {
        let lower = text.lowercased()
        let separated = hasHintSeparators(lower)
        if chromePhrases.contains(where: { isFooterHint($0, in: lower, separated: separated) }) { return true }
        if separated, chromeWords.contains(where: { lower.contains($0) }) { return true }
        if let first = text.first, spinnerGlyphs.contains(first) {
            let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
            // "✻ Thinking…", "· Pondering... (3s)", "✻ Worked for 1m 5s"
            if let firstWordEnd = rest.firstIndex(where: { $0.isWhitespace || $0 == "(" }) {
                let word = rest[..<firstWordEnd]
                if word.hasSuffix("…") || word.hasSuffix("...") { return true }
                let after = rest[firstWordEnd...].trimmingCharacters(in: .whitespaces)
                if after.hasPrefix("for "), after.dropFirst(4).first?.isNumber == true { return true }
            } else if rest.hasSuffix("…") || rest.hasSuffix("...") {
                return true
            }
        }
        if labelValue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        if versionBanner.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        return false
    }

    /// `phrase` sits where footers put hints: in a row of separated hints, at the start of the row (after
    /// symbols or a count: "? for shortcuts", "⏵⏵ accept edits on", "2 background tasks"), or in parentheses
    /// ("(shift+tab to cycle)", "+12 lines (ctrl+r to expand)").
    private static func isFooterHint(_ phrase: String, in lower: String, separated: Bool) -> Bool {
        guard let range = lower.range(of: phrase) else { return false }
        if separated { return true }
        let before = lower[..<range.lowerBound]
        if !containsWord(before) { return true }
        if let open = before.lastIndex(of: "("), !before[open...].contains(")") { return true }
        return false
    }

    /// Footers separate their hints with "·" / "•" / "|" or align them in columns; prose does neither.
    private static func hasHintSeparators(_ text: String) -> Bool {
        text.contains(" · ") || text.contains(" • ") || text.contains(" | ") || text.contains("  ")
    }

    /// Two letters in a row (a word, not a unit like the "k" of "1.2k").
    private static func containsWord(_ text: Substring) -> Bool {
        var previousIsLetter = false
        for c in text {
            if c.isLetter {
                if previousIsLetter { return true }
                previousIsLetter = true
            } else {
                previousIsLetter = false
            }
        }
        return false
    }

    // "model: gpt-5-codex", "directory: ~/src/app", "cwd: /Users/me/x"
    private static let labelValue = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z ]{0,20}:\s+[\w.\-/~@:+]*[/.\-~@0-9][\w.\-/~@:+]*$"#)
    // ">_ OpenAI Codex (v0.46.0)", "opencode v0.15.3"
    private static let versionBanner = try! NSRegularExpression(
        pattern: #"^(>_\s+)?[\w .\-]{1,30}\s\(?v\d+\.\d+(\.\d+)?[\w.\-]*\)?$"#)

    private static let promptPrefixes: [String] = [">", "›", "❯", "$", "%", "➜", "λ", "»", "▶"]
    private static let shellPrompt = try! NSRegularExpression(
        pattern: #"^(\([\w.\-]+\)\s+)?[\w.\-]+@[\w.\-]+[^\n]{0,80}?[$%#❯>]\s"#)

    static func isPrompt(_ text: String) -> Bool {
        for p in promptPrefixes where text.hasPrefix(p) {
            let rest = text.dropFirst(p.count)
            if rest.isEmpty || rest.first?.isWhitespace == true { return true }
        }
        let range = NSRange(text.startIndex..., in: text)
        return shellPrompt.firstMatch(in: text, range: range) != nil
            || pathPrompt.firstMatch(in: text, range: range) != nil
    }

    // Prompts that start with the working directory: "~/src/app main ✗", "~ git status".
    private static let pathPrompt = try! NSRegularExpression(pattern: #"^~(/[^\s]*)?(\s|$)|^/[^\s/]+/[^\s]*\s+\S"#)

    private static let toolVerbs = try! NSRegularExpression(
        pattern:
            #"^[•●⏺◦]\s+(Ran|Running|Explored|Exploring|Edited|Editing|Searched|Searching|Listed|Called|Calling|Waited|Waiting|Updated Plan|Applied patch|Wrote|Deleted|Added)\b"#
    )
    private static let toolCall = try! NSRegularExpression(pattern: #"^[⏺●]\s*[A-Z][\w\- ]{0,30}\("#)

    static func isToolHeader(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return toolCall.firstMatch(in: text, range: range) != nil
            || toolVerbs.firstMatch(in: text, range: range) != nil
    }

    static func startsWithToolTree(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return false }
        return first == "⎿" || first == "└" || first == "├" || first == "╰"
    }

    private static let decorativeBullets: Set<Character> = ["⏺", "●", "•", "◦", "▪"]

    /// Removes a leading message bullet ("⏺ ", "• "). Returns the remaining text and how many characters were removed.
    static func stripDecorativeBullet(_ text: String) -> (text: String, removed: Int) {
        guard let first = text.first, decorativeBullets.contains(first) else { return (text, 0) }
        let rest = text.dropFirst()
        let trimmed = rest.drop(while: { $0 == " " })
        return (String(trimmed), 1 + (rest.count - trimmed.count))
    }

    private static let listMarker = try! NSRegularExpression(
        pattern: #"^([-*+]|\d{1,3}[.)]|[a-z][.)]|☐|☒|✓|✔|✗|✘|\[[ xX]\]|→|▸|▹|►|➤|※)\s"#)

    static func startsWithListMarker(_ text: String) -> Bool {
        listMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Fragments

    struct Fragment {
        var row: Int
        /// Pane key: cell column right after the vertical border that starts this fragment (0 = line start).
        var key: Int
        /// Trimmed text.
        var text: String
        /// Cell column of the first non-space character.
        var indent: Int
        /// Cell column just after the last non-space character.
        var rightCol: Int
        var utf16Start: Int
        var utf16Length: Int
        /// Cell column of the vertical border that ends this fragment, if any.
        var paneRight: Int? = nil
    }

    static func fragments(of line: TerminalLine) -> [Fragment] {
        var result: [Fragment] = []
        var key = 0
        var col = 0
        var utf16 = line.utf16Offset
        // Current fragment accumulation.
        var chars: [(Character, Int, Int)] = []  // char, cell column, utf16 offset

        func flush(endBorder: Int?) {
            let trimmedStart = chars.firstIndex(where: { !$0.0.isWhitespace })
            let trimmedEnd = chars.lastIndex(where: { !$0.0.isWhitespace })
            if let s = trimmedStart, let e = trimmedEnd {
                let slice = chars[s...e]
                let text = String(slice.map { $0.0 })
                let last = chars[e]
                result.append(
                    Fragment(
                        row: line.row, key: key, text: text, indent: chars[s].1,
                        rightCol: last.1 + TextMetrics.cellWidth(last.0), utf16Start: chars[s].2,
                        utf16Length: last.2 + last.0.utf16.count - chars[s].2, paneRight: endBorder))
            } else {
                result.append(
                    Fragment(
                        row: line.row, key: key, text: "", indent: col, rightCol: col, utf16Start: utf16,
                        utf16Length: 0, paneRight: endBorder))
            }
            chars.removeAll(keepingCapacity: true)
        }

        for ch in line.text {
            if verticalBorders.contains(ch) {
                flush(endBorder: col)
                col += TextMetrics.cellWidth(ch)
                utf16 += ch.utf16.count
                key = col
                continue
            }
            chars.append((ch, col, utf16))
            col += TextMetrics.cellWidth(ch)
            utf16 += ch.utf16.count
        }
        flush(endBorder: nil)
        // Drop empty fragments after a closing border ("│ text │" leaves an empty tail).
        if result.count > 1 { result.removeAll { $0.text.isEmpty && $0.key > 0 && $0.key >= col } }
        return result
    }

    // MARK: Screen geometry

    /// The monospaced grid of a terminal screen (untransformed AX coordinates). A logical line longer than the
    /// terminal is soft-wrapped onto several rows, but AX reports it as one line: rows are counted here.
    struct Grid: Equatable {
        var cell: CGSize
        /// x of the first column.
        var left: CGFloat
        /// Top of the first row of the logical line `anchorRow`.
        var anchorTop: CGFloat
        var anchorRow: Int
        /// Wrap width in cells when a line is seen wrapping; nil = every line fits on one row.
        var wrapColumns: Int?
        /// First screen row of each logical line.
        var screenRow: [Int: Int]

        init(cell: CGSize, left: CGFloat, anchorTop: CGFloat, anchorRow: Int, wrapColumns: Int?, lines: [TerminalLine]) {
            self.cell = cell
            self.left = left
            self.anchorTop = anchorTop
            self.anchorRow = anchorRow
            self.wrapColumns = wrapColumns
            var rows: [Int: Int] = [:]
            var next = 0
            for line in lines {
                rows[line.row] = next
                next += Self.rowCount(TextMetrics.cellWidth(line.text), wrapColumns: wrapColumns)
            }
            screenRow = rows
        }

        static func rowCount(_ cells: Int, wrapColumns: Int?) -> Int {
            guard let columns = wrapColumns, columns > 0 else { return 1 }
            return max(1, (cells + columns - 1) / columns)
        }

        func top(ofScreenRow row: Int) -> CGFloat {
            anchorTop + CGFloat(row - (screenRow[anchorRow] ?? 0)) * cell.height
        }

        /// One rectangle per screen row for the cells `startCol..<endCol` of a logical line.
        func rects(line: Int, startCol: Int, endCol: Int) -> [(screenRow: Int, rect: CGRect)] {
            guard let first = screenRow[line], endCol > startCol else { return [] }
            let columns = wrapColumns ?? Int.max
            var result: [(Int, CGRect)] = []
            var col = startCol
            while col < endCol {
                let wrap = columns == Int.max ? 0 : col / columns
                let rowStart = columns == Int.max ? 0 : wrap * columns
                let end = columns == Int.max ? endCol : min(endCol, rowStart + columns)
                let rect = CGRect(
                    x: left + CGFloat(col - rowStart) * cell.width, y: top(ofScreenRow: first + wrap),
                    width: CGFloat(end - col) * cell.width, height: cell.height)
                result.append((first + wrap, rect))
                col = end
            }
            return result
        }

        /// Cell columns of a UTF-16 range of `line`.
        static func columns(of line: TerminalLine, location: Int, length: Int) -> (start: Int, end: Int)? {
            let ns = line.text as NSString
            let start = location - line.utf16Offset
            guard start >= 0, length >= 0, start + length <= ns.length else { return nil }
            let before = TextMetrics.cellWidth(ns.substring(to: start))
            return (before, before + TextMetrics.cellWidth(ns.substring(with: NSRange(location: start, length: length))))
        }
    }

    // MARK: Uncovered content

    /// Cells of one row holding visible characters that no paragraph covers.
    struct CellRun: Equatable, Sendable {
        var row: Int
        var startCol: Int
        var endCol: Int
    }

    /// Visible characters outside every paragraph span: borders, prompts, spinners, tool output, code.
    /// The overlay keeps translations off them (a translation that needs more lines must not cover the
    /// frame of a box or the prompt below it). Characters closer than `gap` cells join one run.
    static func uncoveredRuns(_ lines: [TerminalLine], paragraphs: [TerminalParagraph], gap: Int = 2) -> [CellRun] {
        var covered: [Int: [Range<Int>]] = [:]
        for p in paragraphs {
            for span in p.spans where span.length > 0 {
                covered[span.row, default: []].append(span.location..<(span.location + span.length))
            }
        }
        var runs: [CellRun] = []
        for line in lines {
            let spans = covered[line.row] ?? []
            var col = 0
            var utf16 = line.utf16Offset
            var open: CellRun?
            for ch in line.text {
                let width = TextMetrics.cellWidth(ch)
                let inSpan = spans.contains { $0.contains(utf16) }
                if !ch.isWhitespace && !inSpan {
                    if var run = open, col - run.endCol <= gap {
                        run.endCol = col + width
                        open = run
                    } else {
                        if let run = open { runs.append(run) }
                        open = CellRun(row: line.row, startCol: col, endCol: col + width)
                    }
                } else if inSpan, let run = open {
                    // Text that belongs to a paragraph ends the run, however close.
                    runs.append(run)
                    open = nil
                }
                col += width
                utf16 += ch.utf16.count
            }
            if let run = open { runs.append(run) }
        }
        return runs
    }

    /// Content line after bullet handling.
    private struct ContentLine {
        var row: Int
        var text: String
        var indent: Int  // column of the first kept character
        var rightCol: Int
        var span: TerminalSpan
        var startsParagraph: Bool  // had a bullet or list marker

        init(_ f: Fragment) {
            row = f.row
            rightCol = f.rightCol
            let stripped = TerminalSegmenter.stripDecorativeBullet(f.text)
            if stripped.removed > 0 {
                let removedPrefix = f.text.prefix(stripped.removed)
                text = stripped.text
                indent = f.indent + TextMetrics.cellWidth(removedPrefix)
                let removedUTF16 = removedPrefix.utf16.count
                span = TerminalSpan(
                    row: f.row, location: f.utf16Start + removedUTF16, length: f.utf16Length - removedUTF16)
                startsParagraph = true
            } else {
                text = f.text
                indent = f.indent
                span = TerminalSpan(row: f.row, location: f.utf16Start, length: f.utf16Length)
                startsParagraph = TerminalSegmenter.startsWithListMarker(f.text)
            }
        }
    }

    private final class Builder {
        var text: String
        var spans: [TerminalSpan]
        var pieceOffsets: [Int] = [0]
        var lastRow: Int
        var lastRight: Int
        var lastText: String
        /// Continuation lines are expected at this column (text column of the first line).
        var contentIndent: Int

        init(_ line: ContentLine) {
            text = line.text
            spans = [line.span]
            lastRow = line.row
            lastRight = line.rightCol
            lastText = line.text
            var indent = line.indent
            // For list items ("- foo") continuation aligns with the text after the marker.
            if line.startsParagraph, let m = TerminalSegmenter.listMarkerWidth(line.text) { indent += m }
            contentIndent = indent
        }

        func canAppend(_ line: ContentLine, paneLeft: Int, wrapRight: Int) -> Bool {
            guard line.row == lastRow + 1, !line.startsParagraph else { return false }
            if line.indent < contentIndent - 1 { return false }
            let lastFull = lastRight + 4 >= wrapRight
            if line.indent > contentIndent + 1 && !lastFull { return false }
            // Greedy wrapping would have put the next word on this line if it fitted: the break was deliberate.
            let lastIsCJK = lastText.last.map { TextMetrics.isCJK($0) } ?? false
            let nextIsCJK = line.text.first.map { TextMetrics.isCJK($0) } ?? false
            let needsSpace = !lastIsCJK && !nextIsCJK
            let firstWordWidth =
                nextIsCJK
                ? TextMetrics.cellWidth(line.text.first!)
                : TextMetrics.cellWidth(line.text.prefix(while: { !$0.isWhitespace }))
            let fits = lastRight + (needsSpace ? 1 : 0) + firstWordWidth <= wrapRight
            if fits {
                let endsSentence = lastText.last.map { ".!?:;。！？：；」』)".contains($0) } ?? false
                let short = Double(lastRight - paneLeft) < Double(wrapRight - paneLeft) * 0.75
                if endsSentence || short { return false }
            }
            return true
        }

        /// `canAppend`, and the previous row reached the wrap width: the terminal broke the line, not the author.
        func continuesWrapped(_ line: ContentLine, paneLeft: Int, wrapRight: Int) -> Bool {
            lastRight + 4 >= wrapRight && canAppend(line, paneLeft: paneLeft, wrapRight: wrapRight)
        }

        func append(_ line: ContentLine, wrapRight: Int) {
            // A URL cut at the wrap width goes on without a space, so it stays one URL.
            if TerminalSegmenter.continuesURL(text, previousRight: lastRight, wrapRight: wrapRight, next: line.text) {
                text += line.text
            } else {
                text = TextMetrics.joinWrapped(text, line.text)
            }
            pieceOffsets.append(text.utf16.count - line.text.utf16.count)
            spans.append(line.span)
            lastRow = line.row
            lastRight = line.rightCol
            lastText = line.text
        }

        func paragraph() -> TerminalParagraph? {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            // Offsets move with the spaces trimmed at the start.
            let lead = text.unicodeScalars.prefix { CharacterSet.whitespaces.contains($0) }
                .reduce(0) { $0 + $1.utf16.count }
            return TerminalParagraph(text: t, spans: spans, pieceOffsets: pieceOffsets.map { max(0, $0 - lead) })
        }
    }

    fileprivate static func listMarkerWidth(_ text: String) -> Int? {
        guard let m = listMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let r = Range(m.range, in: text)
        else { return nil }
        return TextMetrics.cellWidth(text[r])
    }
}
