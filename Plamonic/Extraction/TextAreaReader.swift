import ApplicationServices
import CoreGraphics
import Foundation

extension ExtractionWalk {
    /// AXTextArea / AXTextField / AXComboBox: split per `TextAreaHandling`.
    func readTextInput(_ info: AXNodeInfo, index: Int, clip: CGRect, transform: FrameTransform? = nil) {
        if ExtractionRoles.isSecure(role: info.role, subrole: info.subrole) {
            noteObstacle(info.frame, clip: clip)
            return
        }
        guard visibility(info.frame, clip) != .invisible else { return }
        let el = info.element
        let editable = el.isSettable(AXAttr.value)
        if editable && !includeEditable {
            // An input field (a chat's composer) stays as it is; translations above it stop at it.
            noteObstacle(info.frame, clip: clip)
            return
        }

        let handling: TextAreaHandling = info.role == "AXTextArea" ? settings.profile.textAreaHandling : .whole
        switch handling {
        case .whole:
            guard let text = info.stringValue ?? el.string(AXAttr.value), !text.isEmpty,
                let frame = clipped(info.frame, clip)
            else { return }
            var segment = RawSegment(text: text, frame: frame, role: info.role, isEditable: editable, treeIndex: index)
            segment.styleSource = StyleSource(element: el, location: nil, length: text.utf16.count)
            emit(segment)
        case .paragraphs:
            readParagraphs(info, index: index, clip: clip, editable: editable, transform: transform)
        case .terminal:
            readTerminal(info, index: index, clip: clip, editable: editable, transform: transform)
        }
    }

    /// One segment per non-empty line of the value; only lines inside AXVisibleCharacterRange.
    private func readParagraphs(
        _ info: AXNodeInfo, index: Int, clip: CGRect, editable: Bool, transform: FrameTransform?
    ) {
        let el = info.element
        guard let value = info.stringValue ?? el.string(AXAttr.value), !value.isEmpty else { return }
        let ns = value as NSString
        var window = NSRange(location: 0, length: ns.length)
        if let vr = info.visibleCharacterRange ?? el.range(AXAttr.visibleCharacterRange), vr.length > 0,
            vr.location >= 0, vr.location + vr.length <= ns.length
        {
            window = ns.lineRange(for: NSRange(location: vr.location, length: vr.length))
        }
        var emitted = 0
        var location = window.location
        let end = window.location + window.length
        while location < end, emitted < limits.maxSegments * 2, checkBudget() {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            location = line.location + max(1, line.length)
            var content = line
            // Trim the trailing newline and surrounding spaces, keeping UTF-16 offsets.
            while content.length > 0, Self.isSpaceOrNewline(ns.character(at: content.location + content.length - 1)) {
                content.length -= 1
            }
            while content.length > 0, Self.isSpaceOrNewline(ns.character(at: content.location)) {
                content.location += 1
                content.length -= 1
            }
            guard content.length > 0 else { continue }
            let text = ns.substring(with: content)
            let bounds = el.bounds(forRange: CFRange(location: content.location, length: content.length))
                .map { transform?.apply($0) ?? $0 }
            guard let frame = clipped(bounds ?? (window.length == ns.length ? info.frame : nil), clip) else { continue }
            var segment = RawSegment(text: text, frame: frame, role: info.role, isEditable: editable, treeIndex: index)
            segment.styleSource = StyleSource(element: el, location: content.location, length: content.length)
            emit(segment)
            emitted += 1
        }
    }

    /// Visible screen only, TUI chrome removed, hard-wrapped lines rejoined; frame = union of line bounds.
    private func readTerminal(
        _ info: AXNodeInfo, index: Int, clip: CGRect, editable: Bool, transform: FrameTransform?
    ) {
        let el = info.element
        var base = 0
        var screen: String?
        // The insertion point comes in the same IPC as the visible range (it is only used for prompts).
        let ranges = info.visibleCharacterRange.map { TerminalRanges(visible: $0, selected: nil) }
            ?? Self.terminalRanges(el)
        if let vr = ranges.visible, vr.length > 0 {
            screen = el.string(forRange: vr)
            base = vr.location
        }
        if screen == nil {
            // No visible range: fall back to the tail of the value.
            guard let value = info.stringValue ?? el.string(AXAttr.value) else { return }
            screen = value
        }
        guard let screen, !screen.isEmpty else { return }
        let lines = Self.terminalLines(fromScreen: screen, baseOffset: base, maxLines: limits.maxTerminalLines)
        if TerminalPasswordPrompt.isWaiting(lines: lines, insertionPoint: ranges.selected) { passwordPrompt = true }
        let grid = Self.terminalGrid(el, lines: lines)
        let cell = grid?.cell
        let columns = grid?.wrapColumns ?? cell.flatMap { c -> Int? in
            guard let width = info.frame?.width, width > 0 else { return nil }
            return Int(width / c.width)
        }
        let paragraphs = TerminalSegmenter.segment(
            lines, columns: columns, ignore: ignore, maxParagraphs: limits.maxSegments)
        let lineByRow = Dictionary(lines.map { ($0.row, $0) }, uniquingKeysWith: { a, _ in a })
        let scale = transform?.scale ?? 1
        let fontSize = cell.flatMap {
            TerminalMetrics.fontSize(cellWidth: $0.width * scale, rowHeight: $0.height * scale)
        }
        for p in paragraphs {
            guard checkBudget() else { break }
            // One AXBoundsForRange per logical line: the union is the frame, the visible screen rows are the
            // line frames (a soft-wrapped line is split into its rows with the grid).
            var rows: [(row: Int, rect: CGRect)] = []
            for span in p.spans where span.length > 0 {
                guard let b = el.bounds(forRange: CFRange(location: span.location, length: span.length)),
                    b.width > 0, b.height > 0
                else { continue }
                for row in Self.screenRows(of: span, bounds: b, line: lineByRow[span.row], grid: grid) {
                    rows.append((row.row, transform?.apply(row.rect) ?? row.rect))
                }
            }
            let frame = rows.dropFirst().reduce(rows.first?.rect) { $0?.union($1.rect) }
            guard let f = clipped(frame, clip) else { continue }
            var segment = RawSegment(
                text: p.text, frame: f, role: info.role, isEditable: editable, treeIndex: index,
                filteredPerLine: true)
            let visibleRows = rows.compactMap { row in clipped(row.rect, clip).map { ($0, $0 == row.rect) } }
                .sorted { $0.0.minY < $1.0.minY }
            segment.lineFrames = visibleRows.map(\.0)
            segment.runFrames = segment.lineFrames
            segment.runIsWhole = visibleRows.map(\.1)
            segment.style.isMonospaced = true
            segment.style.fontSize = fontSize
            segment.style.lineHeight = Self.rowPitch(rows) ?? cell.map { Double($0.height * scale) }
            if let first = p.spans.first(where: { $0.length > 0 }) {
                // Terminal.app has no attributed ranges (dropped after a few misses); iTerm2 reports colors.
                segment.styleSource = StyleSource(element: el, location: first.location, length: first.length)
            }
            segment.links = Self.terminalLinks(p, lines: lineByRow, grid: grid) { rect in
                clipped(transform?.apply(rect) ?? rect, clip)
            }
            emit(segment)
        }
        // Borders, prompts and the rest of the screen stay visible: translations must not grow over them.
        // Their rectangles come from the grid, without more AX calls.
        if let grid {
            var rects: [CGRect] = []
            for run in TerminalSegmenter.uncoveredRuns(lines, paragraphs: paragraphs) {
                rects += grid.rects(line: run.row, startCol: run.startCol, endCol: run.endCol).map(\.rect)
            }
            for rect in Self.stackedColumns(rects) {
                noteObstacle(transform?.apply(rect) ?? rect, clip: clip)
            }
        }
    }

    /// The last `maxLines` lines of a terminal screen, with the marks typed after password prompts blanked
    /// (`TerminalPasswordPrompt.blankingInput`): typing a password does not change the text that is translated.
    static func terminalLines(fromScreen screen: String, baseOffset: Int, maxLines: Int) -> [TerminalLine] {
        var lines = TerminalSegmenter.lines(fromScreen: screen, baseOffset: baseOffset)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        for i in lines.indices { lines[i].text = TerminalPasswordPrompt.blankingInput(lines[i].text) }
        return lines
    }

    /// AXVisibleCharacterRange and AXSelectedTextRange of a terminal text area.
    struct TerminalRanges {
        var visible: CFRange?
        /// The insertion point (length 0) or the selection; nil when the terminal does not report it.
        var selected: CFRange?
    }

    private static let terminalRangeNames = [AXAttr.visibleCharacterRange, AXAttr.selectedTextRange]

    /// Both ranges in one IPC. A range the terminal does not support comes back as an error value: nil.
    static func terminalRanges(_ el: AXElement) -> TerminalRanges {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el.ref, terminalRangeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [AnyObject] else { return TerminalRanges() }
        return terminalRanges(values: array)
    }

    /// Decodes the values of `terminalRanges(_:)`, in the order of `terminalRangeNames`.
    static func terminalRanges(values: [AnyObject]) -> TerminalRanges {
        func range(_ i: Int) -> CFRange? { i < values.count ? AXDecode.range(values[i]) : nil }
        return TerminalRanges(visible: range(0), selected: range(1))
    }

    /// URLs in a terminal paragraph (`NSDataDetector`): their cells come from the grid, without more AX calls.
    /// `place` turns a grid rectangle into the visible one on screen (nil when it is not visible).
    static func terminalLinks(
        _ p: TerminalParagraph, lines: [Int: TerminalLine], grid: TerminalSegmenter.Grid?,
        place: (CGRect) -> CGRect?
    ) -> [RawLink] {
        let detected = TerminalSegmenter.detectLinks(in: p, lines: lines)
        guard !detected.isEmpty else { return [] }
        // The style source is the first row's text: a URL in it is looked up there, so it is not read as the
        // paragraph's color.
        let firstIndex = p.spans.firstIndex { $0.length > 0 }
        return detected.map { d in
            var link = RawLink(range: d.range, kind: .detected, element: nil, url: d.url)
            if let grid {
                for c in d.cells {
                    link.frames += grid.rects(line: c.row, startCol: c.startCol, endCol: c.endCol).compactMap {
                        place($0.rect)
                    }
                }
            }
            if let i = firstIndex, i < p.pieceOffsets.count {
                let piece = p.pieceOffsets[i]..<(p.pieceOffsets[i] + p.spans[i].length)
                let overlap = d.range.clamped(to: piece)
                if !overlap.isEmpty {
                    link.styleText = LinkText.substring(p.text, overlap)
                    link.styleOffset = overlap.lowerBound - piece.lowerBound
                }
            }
            return link
        }
    }

    /// Joins rectangles of the same columns on consecutive rows (a box's sides, a diff's line numbers) into one,
    /// so a dense screen does not use up the obstacles before the input box at its bottom. They cover the same
    /// cells as before. `rects` are in row order.
    static func stackedColumns(_ rects: [CGRect]) -> [CGRect] {
        struct Columns: Hashable {
            var minX: CGFloat
            var width: CGFloat
        }
        var result: [CGRect] = []
        // The last rectangle of each column span: the next row joins it when it starts where it ends.
        var last: [Columns: Int] = [:]
        for rect in rects {
            let key = Columns(minX: rect.minX, width: rect.width)
            if let i = last[key], abs(result[i].maxY - rect.minY) < 0.5 {
                result[i].size.height = rect.maxY - result[i].minY
            } else {
                last[key] = result.count
                result.append(rect)
            }
        }
        return result
    }

    /// The screen rows of one span: its bounds when it is one row, else the grid's rows when they add up to the
    /// bounds (a soft-wrapped line). Rows are numbered on the screen, so the pitch between them is right.
    static func screenRows(
        of span: TerminalSpan, bounds: CGRect, line: TerminalLine?, grid: TerminalSegmenter.Grid?
    ) -> [(row: Int, rect: CGRect)] {
        guard let grid, let line, let first = grid.screenRow[span.row] else { return [(span.row, bounds)] }
        guard bounds.height > grid.cell.height * 1.5 else { return [(first, bounds)] }
        guard let cols = TerminalSegmenter.Grid.columns(of: line, location: span.location, length: span.length)
        else { return [(first, bounds)] }
        let pieces = grid.rects(line: span.row, startCol: cols.start, endCol: cols.end)
        let union = pieces.dropFirst().reduce(pieces.first?.rect) { $0?.union($1.rect) }
        // Wide characters wrap a cell early and the last row may be cut differently: only trust rows that
        // match what the app reported.
        let tolerance = max(2, grid.cell.width)
        guard let union, pieces.count >= 2, abs(union.minY - bounds.minY) <= tolerance,
            abs(union.maxY - bounds.maxY) <= tolerance, abs(union.minX - bounds.minX) <= tolerance,
            abs(union.maxX - bounds.maxX) <= tolerance
        else { return [(first, bounds)] }
        return pieces.map { ($0.screenRow, $0.rect) }
    }

    /// Distance between the tops of consecutive rows, from the paragraph's first and last rows.
    static func rowPitch(_ rows: [(row: Int, rect: CGRect)]) -> Double? {
        guard let first = rows.min(by: { $0.row < $1.row }), let last = rows.max(by: { $0.row < $1.row }),
            last.row > first.row
        else { return nil }
        let pitch = (last.rect.minY - first.rect.minY) / CGFloat(last.row - first.row)
        return pitch > 0 ? Double(pitch) : nil
    }

    /// The grid from two AXBoundsForRange calls: the first character of the widest line gives the cell and the
    /// first column (a line is a whole row, so it starts there), the whole widest line tells whether lines
    /// wrap and at how many columns.
    private static func terminalGrid(_ el: AXElement, lines: [TerminalLine]) -> TerminalSegmenter.Grid? {
        guard let widest = lines.max(by: { TextMetrics.cellWidth($0.text) < TextMetrics.cellWidth($1.text) }),
            let firstChar = widest.text.first
        else { return nil }
        let cells = TextMetrics.cellWidth(widest.text)
        let firstCells = max(1, TextMetrics.cellWidth(firstChar))
        guard cells >= 4,
            let c = el.bounds(forRange: CFRange(location: widest.utf16Offset, length: firstChar.utf16.count)),
            c.width > 0, c.height > 0, c.height < 80,
            let b = el.bounds(forRange: CFRange(location: widest.utf16Offset, length: widest.text.utf16.count)),
            b.width >= c.width, b.height >= c.height
        else { return nil }
        let cell = CGSize(width: c.width / CGFloat(firstCells), height: c.height)
        // A line taller than a row is soft-wrapped: its rows are as wide as the terminal.
        let wraps = b.height > cell.height * 1.5
        let wrapColumns = wraps ? Int((b.width / cell.width).rounded()) : nil
        return TerminalSegmenter.Grid(
            cell: cell, left: c.minX, anchorTop: c.minY, anchorRow: widest.row, wrapColumns: wrapColumns,
            lines: lines)
    }

    func clipped(_ frame: CGRect?, _ clip: CGRect) -> CGRect? {
        guard let frame else { return nil }
        let c = frame.intersection(clip)
        guard !c.isNull, c.width >= 1, c.height >= limits.minVisibleHeight else { return nil }
        return c
    }

    private static func isSpaceOrNewline(_ u: unichar) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0xA0 || u == 0x2028 || u == 0x2029
    }
}
