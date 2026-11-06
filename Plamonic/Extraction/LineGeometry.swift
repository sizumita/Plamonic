import CoreGraphics
import Foundation

/// Line metrics of a paragraph derived from the frames of its text runs (no AX calls).
/// Chromium reports one frame per text node: the bounding box of its lines. A run that holds one line is as tall
/// as the font's text box; a run over n lines is (n - 1) line pitches plus one text box.
enum LineGeometry {
    /// Runs up to this many font sizes tall hold one line (Chromium: 12–16 pt text gives 13–21 pt runs).
    static let singleLineEm: CGFloat = 1.7
    /// Without a font size: runs up to this tall can be one line.
    static let maxSingleLineHeight: CGFloat = 34

    /// Height limit of a one-line run.
    static func singleLineLimit(runs: [CGRect], fontSize: Double?) -> CGFloat? {
        if let fs = fontSize, fs > 0 { return CGFloat(fs) * singleLineEm }
        guard let minH = runs.map(\.height).filter({ $0 > 0 }).min() else { return nil }
        return min(minH * 1.5, maxSingleLineHeight)
    }

    /// Height of one line of text: the median height of the runs that hold one line.
    static func textHeight(runs: [CGRect], fontSize: Double?) -> CGFloat? {
        guard let limit = singleLineLimit(runs: runs, fontSize: fontSize) else { return nil }
        let heights = runs.map(\.height).filter { $0 > 0 && $0 <= limit }.sorted()
        guard !heights.isEmpty else { return nil }
        return heights[heights.count / 2]
    }

    /// Gaps between the tops of a paragraph's known lines: the first line of each run, and the last line of
    /// runs spanning several. A gap may span several lines.
    struct Gaps {
        var gaps: [CGFloat]
        var textHeight: CGFloat
        /// Lines may not be closer than this (they would overlap) ...
        var minPitch: CGFloat
        /// ... nor further apart than this (no usual line height is that loose).
        var maxPitch: CGFloat

        /// Gaps too short to span two lines: exact pitches.
        var direct: [CGFloat] { gaps.filter { $0 >= minPitch && $0 < 2 * minPitch && $0 <= maxPitch } }
    }

    /// `textHeight`: the height of one line measured elsewhere in the window, for a paragraph whose runs all
    /// span several lines (one long text node).
    static func gaps(runs: [CGRect], fontSize: Double?, textHeight known: CGFloat? = nil) -> Gaps? {
        guard let th = textHeight(runs: runs, fontSize: fontSize) ?? known, th > 0,
            let limit = singleLineLimit(runs: runs, fontSize: fontSize)
        else { return nil }
        var tops: [CGFloat] = []
        for r in runs where r.height > 0 {
            tops.append(r.minY)
            if r.height > limit { tops.append(r.maxY - th) }
        }
        let rows = cluster(tops.sorted(), tolerance: max(2, th * 0.25))
        guard rows.count >= 2 else { return nil }
        return Gaps(
            gaps: zip(rows, rows.dropFirst()).map { $1 - $0 }, textHeight: th, minPitch: th * 0.9,
            maxPitch: fontSize.map { CGFloat($0) * 2.2 } ?? th * 2)
    }

    /// Distance between the tops of consecutive lines. Exact gaps decide; a gap over several lines is divided
    /// by the line count that gives the window's pitch (`windowPitch`), else the most usual line height.
    /// nil for a one-line paragraph.
    static func linePitch(_ g: Gaps, fontSize: Double?, windowPitch: CGFloat? = nil) -> CGFloat? {
        var pitches = g.direct
        if pitches.isEmpty {
            let usual = max(fontSize.map { CGFloat($0) * 1.4 } ?? g.textHeight * 1.25, g.textHeight)
            let target = windowPitch ?? usual
            for gap in g.gaps where gap >= g.minPitch {
                var best: CGFloat?
                for k in 1...40 {
                    let p = gap / CGFloat(k)
                    if p < g.minPitch { break }
                    if p <= g.maxPitch, best.map({ abs(p - target) < abs($0 - target) }) ?? true { best = p }
                }
                if let best { pitches.append(best) }
            }
        }
        guard !pitches.isEmpty else { return nil }
        return half(median(pitches))
    }

    static func linePitch(
        runs: [CGRect], fontSize: Double?, textHeight: CGFloat? = nil, windowPitch: CGFloat? = nil
    ) -> CGFloat? {
        gaps(runs: runs, fontSize: fontSize, textHeight: textHeight).flatMap {
            linePitch($0, fontSize: fontSize, windowPitch: windowPitch)
        }
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func half(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

    /// One rectangle per line, when every run holds a single line (otherwise the line ends are unknown).
    /// `markers` (list bullets) join the line they sit on.
    static func lineFrames(runs: [CGRect], markers: [CGRect] = [], fontSize: Double?) -> [CGRect] {
        guard !runs.isEmpty, let limit = singleLineLimit(runs: runs, fontSize: fontSize),
            runs.allSatisfy({ $0.height <= limit })
        else { return [] }
        var rows: [CGRect] = []
        for r in runs.sorted(by: { $0.minY < $1.minY }) {
            if let i = rows.firstIndex(where: { sameLine($0, r) }) {
                rows[i] = rows[i].union(r)
            } else {
                rows.append(r)
            }
        }
        for m in markers {
            if let i = rows.firstIndex(where: { verticalOverlap($0, m) > 0.5 * min($0.height, m.height) }) {
                rows[i] = rows[i].union(m)
            }
        }
        return rows.sorted { $0.minY < $1.minY }
    }

    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }

    static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = verticalOverlap(a, b)
        return overlap > 0 && overlap >= 0.5 * min(a.height, b.height)
    }

    /// Means of runs of sorted values closer than `tolerance` to their neighbour.
    static func cluster(_ sorted: [CGFloat], tolerance: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        var group: [CGFloat] = []
        for v in sorted {
            if let last = group.last, v - last > tolerance {
                result.append(group.reduce(0, +) / CGFloat(group.count))
                group.removeAll()
            }
            group.append(v)
        }
        if !group.isEmpty { result.append(group.reduce(0, +) / CGFloat(group.count)) }
        return result
    }
}

/// Font metrics of a terminal grid.
enum TerminalMetrics {
    /// Point size of a monospaced font from its cell: the advance of the usual terminal fonts (Menlo, SF Mono,
    /// Monaco, JetBrains Mono, ...) is 0.6 em, and a row is 1.15–1.25 em at line spacing 1.
    static func fontSize(cellWidth: CGFloat, rowHeight: CGFloat) -> Double? {
        guard cellWidth > 0 || rowHeight > 0 else { return nil }
        let fromHeight = rowHeight / 1.2
        guard cellWidth > 0 else { return round(fromHeight) }
        let fromWidth = cellWidth / 0.6
        // Wide cells or tall rows that no 0.6 em font gives (unusual font, big line spacing): trust the row.
        if rowHeight > 0, fromWidth < rowHeight / 1.7 || fromWidth > rowHeight / 0.95 { return round(fromHeight) }
        return round(fromWidth)
    }

    private static func round(_ v: CGFloat) -> Double { (Double(v) * 2).rounded() / 2 }
}

/// Chromium reports font sizes in CSS pixels without the page zoom (Electron apps' zoom setting, CSS zoom), while
/// frames are on-screen points. CJK glyphs are 1 em wide in every common font, so one whole line of CJK text
/// tells the zoom: its width per glyph over the reported size. Kept per process (zoom is per app).
struct ZoomEstimator {
    private var samples: [pid_t: [Double]] = [:]
    static let maxSamples = 40

    mutating func add(pid: pid_t, reportedSize: Double, measuredEm: Double, runHeight: Double) {
        guard reportedSize > 0, measuredEm > 0 else { return }
        // A run taller than this is two lines at any usual zoom, and its width per glyph means nothing.
        guard runHeight <= reportedSize * 2.6 else { return }
        let ratio = measuredEm / reportedSize
        // Far outside any zoom: a run cut short with an ellipsis, or not the reported run.
        guard (0.5...3).contains(ratio) else { return }
        var list = samples[pid] ?? []
        list.append(ratio)
        if list.count > Self.maxSamples { list.removeFirst(list.count - Self.maxSamples) }
        samples[pid] = list
    }

    /// The median ratio when it clearly differs from 1, else 1. A few samples are needed before it counts.
    func factor(pid: pid_t) -> Double {
        guard var list = samples[pid], list.count >= 3 else { return 1 }
        list.sort()
        let median = list[list.count / 2]
        // Within a few percent is measurement noise (half-width punctuation, kerning).
        return abs(median - 1) < 0.04 ? 1 : (median * 100).rounded() / 100
    }

    mutating func forget(pid: pid_t?) {
        guard let pid else {
            samples.removeAll()
            return
        }
        samples[pid] = nil
    }
}

/// Merges segments that cover each other: a paragraph the walk split in two (something inside it looked like a
/// block) leaves two frames that share a line, and their overlays would hide each other's text.
enum SegmentMerger {
    /// How many neighbours back in reading order a segment is compared with.
    static let lookBack = 3

    /// `items` and the result are in reading order. Texts are joined in tree order.
    static func merge(
        _ items: [(segment: RawSegment, text: String)], maxCharacters: Int
    ) -> (items: [(segment: RawSegment, text: String)], merged: Int) {
        guard items.count > 1 else { return (items, 0) }
        var parent = Array(items.indices)
        var chars = items.map { $0.text.count }
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var merged = 0
        for j in items.indices {
            for i in stride(from: j - 1, through: max(0, j - lookBack), by: -1) {
                let (ri, rj) = (root(i), root(j))
                guard ri != rj, chars[ri] + chars[rj] + 1 <= maxCharacters,
                    shouldMerge(items[i].segment, items[j].segment)
                else { continue }
                parent[rj] = ri
                chars[ri] += chars[rj] + 1
                merged += 1
            }
        }
        guard merged > 0 else { return (items, 0) }

        var groups: [Int: [Int]] = [:]
        var firstOfGroup: [Int] = []
        for i in items.indices {
            let r = root(i)
            if groups[r] == nil { firstOfGroup.append(r) }
            groups[r, default: []].append(i)
        }
        var result: [(segment: RawSegment, text: String)] = []
        for r in firstOfGroup {
            let members = groups[r]!.sorted { items[$0].segment.emitIndex < items[$1].segment.emitIndex }
            if members.count == 1 {
                result.append(items[members[0]])
                continue
            }
            var segment = items[members[0]].segment
            var text = items[members[0]].text
            for m in members.dropFirst() {
                let other = items[m]
                text = TextMetrics.joinWrapped(text, other.text)
                // The other piece's text ends the joined text: its links move to where it starts.
                segment.absorb(
                    other.segment, otherIsLonger: other.text.count > items[members[0]].text.count,
                    linkOffset: text.utf16.count - other.text.utf16.count)
            }
            segment.text = text
            result.append((segment, text))
        }
        result.sort { TextExtractor.readingOrder($0.segment, $1.segment) }
        return (result, merged)
    }

    /// Same kind of text, from the same block or next to each other in the tree, and one covers at least half a
    /// line of the other (blocks that touch through negative margins overlap by a few points only).
    static func shouldMerge(_ a: RawSegment, _ b: RawSegment) -> Bool {
        guard a.isEditable == b.isEditable else { return false }
        let related = (a.blockIndex >= 0 && a.blockIndex == b.blockIndex) || abs(a.emitIndex - b.emitIndex) <= 2
        guard related else { return false }
        let i = a.frame.intersection(b.frame)
        guard !i.isNull else { return false }
        let line = min(lineHeight(of: a), lineHeight(of: b))
        return i.height >= max(4, 0.5 * line) && i.width >= max(4, line)
    }

    private static func lineHeight(of s: RawSegment) -> CGFloat {
        if let h = s.style.lineHeight { return CGFloat(h) }
        if let h = LineGeometry.textHeight(runs: s.wholeRunFrames, fontSize: s.style.fontSize) { return h }
        return min(s.frame.height, 24)
    }
}
