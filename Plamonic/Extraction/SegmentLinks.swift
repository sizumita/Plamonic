import CoreGraphics
import Foundation

// Links inside segments (DESIGN §6.1 「リンクを取る」): found by the walk, carried through every later change of
// the segment's text, and finished (frames, look, URL) only for the segments that are kept.

/// The clickable element a piece of text belongs to.
struct LinkMark: Hashable, Sendable {
    var element: AXElement
    var kind: SegmentLinkKind
}

/// One visible run (leaf element) of a link, with the visible runs next to it in the paragraph. Its frame covers
/// several lines when the text wraps; a neighbour on the same line tells where the link starts or ends there.
struct LinkRun: Equatable, Sendable {
    var frame: CGRect
    var before: CGRect?
    var after: CGRect?
}

/// A link of a segment that is not final yet. `range` is in UTF-16 offsets of `RawSegment.text`.
struct RawLink: Equatable, Sendable {
    var range: Range<Int>
    var kind: SegmentLinkKind
    var element: AXElement?
    var url: URL? = nil
    /// Final rectangles when the walk knows them (terminal cells). Otherwise derived from `runs`.
    var frames: [CGRect] = []
    var runs: [LinkRun] = []
    /// The link's text as the segment's style source holds it: its color and underline are read from that run.
    /// nil = the style source does not cover this link.
    var styleText: String? = nil
    /// Where `styleText` starts in the style source's text as the walk read it (UTF-16). The same words may come
    /// earlier as plain text, so the link is looked up there first. nil = unknown.
    var styleOffset: Int? = nil

    /// What the style reader looks up for this link.
    var styleProbe: LinkStyleProbe { LinkStyleProbe(text: styleText ?? "", offset: styleOffset) }

    /// Moves the link by `offset` UTF-16 units (its segment's text was put after other text).
    func shifted(by offset: Int) -> RawLink {
        var l = self
        l.range = (range.lowerBound + offset)..<(range.upperBound + offset)
        return l
    }
}

/// Where text went when it was rewritten: for each UTF-16 unit of the new text, the offset of the unit it came
/// from in the old text (non-decreasing).
struct TextOffsetMap: Equatable, Sendable {
    var sources: [Int]

    /// The new offset for an old one: the number of new units that come from before it.
    func map(_ old: Int) -> Int {
        var lo = 0
        var hi = sources.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sources[mid] < old { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The old range in the new text, without the spaces and line breaks the rewrite left at its ends.
    /// nil when nothing of it is left.
    func map(_ range: Range<Int>, in text: String) -> Range<Int>? {
        LinkText.trimmed(map(range.lowerBound)..<map(range.upperBound), in: text)
    }
}

enum LinkText {
    /// `range` without the white space at its ends; nil when nothing else is in it.
    static func trimmed(_ range: Range<Int>, in text: String) -> Range<Int>? {
        let ns = text as NSString
        var lo = max(0, range.lowerBound)
        var hi = min(ns.length, range.upperBound)
        while lo < hi, isSpace(ns.character(at: lo)) { lo += 1 }
        while hi > lo, isSpace(ns.character(at: hi - 1)) { hi -= 1 }
        return lo < hi ? lo..<hi : nil
    }

    static func substring(_ text: String, _ range: Range<Int>) -> String {
        (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    private static func isSpace(_ u: unichar) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0xA0 || u == 0x2028 || u == 0x2029 || u == 0x3000
    }

    /// Links of `links` rewritten into a new text; links left empty are dropped.
    static func remap(_ links: [RawLink], with map: TextOffsetMap, in text: String) -> [RawLink] {
        links.compactMap { l in
            guard let r = map.map(l.range, in: text) else { return nil }
            var m = l
            m.range = r
            return m
        }
    }
}

// MARK: Paragraphs of the walk

extension ExtractionWalk {
    /// The links of a paragraph made of `parts` (joined into `text`, part i starting at `offsets[i]`).
    /// Adjacent parts of the same link are one link.
    static func links(of parts: [Part], text: String, offsets: [Int]) -> [RawLink] {
        guard parts.contains(where: { $0.link != nil }) else { return [] }
        var result: [RawLink] = []
        var i = 0
        while i < parts.count {
            guard let mark = parts[i].link else {
                i += 1
                continue
            }
            var j = i
            while j + 1 < parts.count, parts[j + 1].link == mark { j += 1 }
            let range = offsets[i]..<(offsets[j] + parts[j].text.utf16.count)
            if let r = LinkText.trimmed(range, in: text) {
                var link = RawLink(range: r, kind: mark.kind, element: mark.element)
                for k in i...j {
                    guard parts[k].visible, let f = parts[k].frame else { continue }
                    let before = neighbourFrame(parts, k, step: -1)
                    let after = neighbourFrame(parts, k, step: 1)
                    link.runs.append(LinkRun(frame: f, before: before, after: after))
                }
                result.append(link)
            }
            i = j + 1
        }
        return result
    }

    private static func neighbourFrame(_ parts: [Part], _ k: Int, step: Int) -> CGRect? {
        var i = k + step
        while i >= 0, i < parts.count {
            if parts[i].visible, let f = parts[i].frame, parts[i].role != "AXListMarker" { return f }
            i += step
        }
        return nil
    }

    /// One rectangle per line of a link. A run over several lines starts on its first line where the run before
    /// it ends and stops on its last line where the run after it starts (when those hold one line), so the
    /// rectangles never cover the text around the link. `textHeight`: the height of one line; `pitch`: the
    /// distance between lines, when known.
    static func linkFrames(_ runs: [LinkRun], textHeight: CGFloat?, singleLineLimit: CGFloat?, pitch: CGFloat?)
        -> [CGRect]
    {
        var lines: [CGRect] = []
        for run in runs {
            let f = run.frame.standardized
            guard f.width > 0, f.height > 0 else { continue }
            guard let th = textHeight, th > 0, let limit = singleLineLimit, f.height > limit, f.height >= th * 1.5
            else {
                lines.append(f)
                continue
            }
            let first = CGRect(x: f.minX, y: f.minY, width: f.width, height: th)
            let last = CGRect(x: f.minX, y: f.maxY - th, width: f.width, height: th)
            func oneLine(_ r: CGRect?) -> CGRect? {
                guard let r, r.height <= limit else { return nil }
                return r
            }
            var start = f.minX
            if let b = oneLine(run.before), LineGeometry.sameLine(b, first), b.maxX > f.minX, b.maxX < f.maxX {
                start = b.maxX
            }
            var end = f.maxX
            if let a = oneLine(run.after), LineGeometry.sameLine(a, last), a.minX > f.minX, a.minX < f.maxX {
                end = a.minX
            }
            lines.append(CGRect(x: start, y: first.minY, width: f.maxX - start, height: th))
            let middleTop = first.maxY
            let middleBottom = last.minY
            if let p = pitch, p >= th * 0.9 {
                let count = Int(((f.height - th) / p).rounded()) + 1
                if count > 2 {
                    for k in 1..<(count - 1) {
                        let y = f.minY + CGFloat(k) * p
                        guard y + th <= middleBottom + 1 else { break }
                        lines.append(CGRect(x: f.minX, y: y, width: f.width, height: th))
                    }
                }
            } else if middleBottom - middleTop >= th * 0.5 {
                // Lines in between are the link's whole width; their pitch is unknown.
                lines.append(CGRect(x: f.minX, y: middleTop, width: f.width, height: middleBottom - middleTop))
            }
            lines.append(CGRect(x: f.minX, y: last.minY, width: end - f.minX, height: th))
        }
        // Runs of one line (a link of several elements) become one rectangle per line.
        var rows: [CGRect] = []
        for r in lines.sorted(by: { $0.minY < $1.minY }) where r.width > 0 {
            if let i = rows.lastIndex(where: { LineGeometry.sameLine($0, r) }) {
                rows[i] = rows[i].union(r)
            } else {
                rows.append(r)
            }
        }
        return rows
    }
}

// MARK: Terminals

extension TerminalSegmenter {
    /// A URL in a terminal paragraph: its UTF-16 range in the paragraph's text and its cells on screen.
    struct DetectedLink: Equatable, Sendable {
        var range: Range<Int>
        var url: URL
        /// Per piece of the paragraph the URL lies in: the logical line and its cell columns.
        var cells: [(row: Int, startCol: Int, endCol: Int)]

        static func == (a: DetectedLink, b: DetectedLink) -> Bool {
            a.range == b.range && a.url == b.url
                && a.cells.elementsEqual(b.cells) {
                    $0.row == $1.row && $0.startCol == $1.startCol && $0.endCol == $1.endCol
                }
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// http / https URLs and bare "www." addresses in `text` (mail addresses and bare domains are left alone).
    static func urls(in text: String) -> [(range: Range<Int>, url: URL)] {
        guard let detector, text.contains(where: { $0 == "." || $0 == ":" }) else { return [] }
        let ns = text as NSString
        var found: [(Range<Int>, URL)] = []
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let url = match.url, let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return }
            let written = ns.substring(with: match.range).lowercased()
            guard written.hasPrefix("http://") || written.hasPrefix("https://") || written.hasPrefix("www.") else {
                return
            }
            found.append((match.range.location..<(match.range.location + match.range.length), url))
        }
        return found
    }

    /// The URLs of a paragraph, with the cells they take on each row.
    static func detectLinks(in paragraph: TerminalParagraph, lines: [Int: TerminalLine]) -> [DetectedLink] {
        let found = urls(in: paragraph.text)
        guard !found.isEmpty, paragraph.pieceOffsets.count == paragraph.spans.count else { return [] }
        var result: [DetectedLink] = []
        for (range, url) in found {
            var cells: [(row: Int, startCol: Int, endCol: Int)] = []
            for (i, span) in paragraph.spans.enumerated() {
                let start = paragraph.pieceOffsets[i]
                let end = start + span.length
                let lo = max(start, range.lowerBound)
                let hi = min(end, range.upperBound)
                guard lo < hi, let line = lines[span.row],
                    let cols = Grid.columns(of: line, location: span.location + (lo - start), length: hi - lo)
                else { continue }
                cells.append((span.row, cols.start, cols.end))
            }
            result.append(DetectedLink(range: range, url: url, cells: cells))
        }
        return result
    }

    /// The previous row ends in a URL cut at the wrap width and this row goes on with it: join them without a space.
    /// A URL that happens to end at the wrap width is followed by a word ("today.", "below:", "(v2.0)"): the next
    /// row's first token, without the punctuation that ends a sentence, must hold a URL separator, or be all of
    /// the row with no such punctuation.
    static func continuesURL(_ previous: String, previousRight: Int, wrapRight: Int, next: String) -> Bool {
        guard previousRight + 1 >= wrapRight, let first = next.first, isURLCharacter(first),
            !"([{<'\"".contains(first)
        else { return false }
        let lastToken = previous.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let lower = lastToken.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") else {
            return false
        }
        let firstToken = next.prefix(while: { !$0.isWhitespace })
        guard firstToken.allSatisfy(isURLCharacter) else { return false }
        var core = Substring(firstToken)
        while let last = core.last, ".,:;!?)]'\"".contains(last) { core.removeLast() }
        guard !core.isEmpty else { return false }
        if core.contains(where: { "/?=&%#~_".contains($0) }) { return true }
        return core.count == firstToken.count && firstToken.count == next.count
    }

    private static func isURLCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let s = c.unicodeScalars.first else { return false }
        if c.isLetter || c.isNumber { return true }
        return "-._~:/?#[]@!$&'()*+,;=%".unicodeScalars.contains(s)
    }
}
