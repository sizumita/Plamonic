import AppKit

/// The background of one item: rows stacked top to bottom, each touching the next. Usually one rectangle;
/// a paragraph split mid-line adds a shorter first row (the start of that line belongs to the item before)
/// or a shorter last row (the rest of that line belongs to the item after).
struct OverlayBackgroundShape: Equatable {
    /// 1 to 3 rectangles; each starts where the previous one ends.
    private(set) var rows: [CGRect]

    init(rect: CGRect) {
        rows = [rect]
    }

    /// `rows` are made contiguous (each starts at the previous one's bottom); empty ones are dropped.
    init(rows: [CGRect]) {
        var stacked: [CGRect] = []
        for row in rows where row.width > 0 && row.height > 0 {
            var r = row
            if let last = stacked.last {
                r.size.height = r.maxY - last.maxY
                r.origin.y = last.maxY
                guard r.height > 0 else { continue }
            }
            stacked.append(r)
        }
        self.rows = stacked.isEmpty ? [.zero] : stacked
    }

    var rect: CGRect { rows.dropFirst().reduce(rows[0]) { $0.union($1) } }
    var hasNotch: Bool { rows.count > 1 }

    /// Area shared with `other` (0 when they only touch).
    func overlapArea(with other: CGRect) -> CGFloat {
        rows.reduce(0) { sum, r in
            let i = r.intersection(other)
            return i.isNull ? sum : sum + max(0, i.width) * max(0, i.height)
        }
    }

    func overlapArea(with other: OverlayBackgroundShape) -> CGFloat {
        other.rows.reduce(0) { $0 + overlapArea(with: $1) }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> OverlayBackgroundShape {
        var copy = self
        copy.rows = rows.map { $0.offsetBy(dx: dx, dy: dy) }
        return copy
    }

    /// Outline with rounded corners (inner corners of a notch included).
    func path(cornerRadius: CGFloat) -> CGPath {
        let r = max(0, cornerRadius)
        guard rows.count > 1 else {
            let rect = rows[0]
            let radius = min(r, rect.width / 2, rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        // Down the right side, then up the left side.
        var points: [CGPoint] = []
        for row in rows {
            points.append(CGPoint(x: row.maxX, y: row.minY))
            points.append(CGPoint(x: row.maxX, y: row.maxY))
        }
        for row in rows.reversed() {
            points.append(CGPoint(x: row.minX, y: row.maxY))
            points.append(CGPoint(x: row.minX, y: row.minY))
        }
        points = Self.corners(of: points)
        let path = CGMutablePath()
        guard points.count >= 3 else { return path }
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { abs(a.x - b.x) + abs(a.y - b.y) }
        // Start halfway along the last edge so every corner is drawn with the same tangent arc.
        let n = points.count
        path.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
        for i in 0..<n {
            let previous = points[(i + n - 1) % n]
            let next = points[(i + 1) % n]
            let radius = min(r, length(previous, points[i]) / 2, length(points[i], next) / 2)
            path.addArc(tangent1End: points[i], tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }

    /// Drops repeated points and points in the middle of a straight edge.
    private static func corners(of points: [CGPoint]) -> [CGPoint] {
        var unique: [CGPoint] = []
        for p in points where unique.last.map({ abs($0.x - p.x) > 0.01 || abs($0.y - p.y) > 0.01 }) ?? true {
            unique.append(p)
        }
        if let first = unique.first, let last = unique.last, abs(first.x - last.x) <= 0.01, abs(first.y - last.y) <= 0.01 {
            unique.removeLast()
        }
        var changed = true
        while changed, unique.count > 3 {
            changed = false
            for i in unique.indices {
                let a = unique[(i + unique.count - 1) % unique.count]
                let b = unique[i]
                let c = unique[(i + 1) % unique.count]
                let vertical = abs(a.x - b.x) <= 0.01 && abs(b.x - c.x) <= 0.01
                let horizontal = abs(a.y - b.y) <= 0.01 && abs(b.y - c.y) <= 0.01
                if vertical || horizontal {
                    unique.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return unique
    }
}

/// How the text of one item was made to fit.
enum OverlayFitStage: String, Equatable, Sendable {
    /// In the original's area (at the original size, or within the min…max range when the size is unknown).
    case original
    /// Lines were added into free space below the original.
    case extended
    /// Smaller than the original size (down to 85%).
    case shrunk
    /// Still too long: the last line ends with "…" (the full text is in the hover popup).
    case truncated
}

/// Where one item is drawn. Coordinates are "window-local": flipped, origin at the target window's top-left
/// (AX coordinates minus the window's AX origin).
struct OverlayItemLayout: Equatable {
    var id: String
    /// Covers the original text's lines (plus lines added below), with a little horizontal padding.
    var background: OverlayBackgroundShape
    /// The box the text is drawn into (wrapped to its width, starting at its top).
    var textRect: CGRect
    var fontSize: CGFloat
    var look: TextLook
    var stage: OverlayFitStage
    /// `background.rect` clipped to the visible region.
    var visibleRect: CGRect

    var backgroundRect: CGRect { background.rect }
    /// The text does not fit the original's area at its size (it was extended, shrunk or truncated).
    var overflows: Bool { stage != .original }

    init(
        id: String, background: OverlayBackgroundShape, textRect: CGRect, fontSize: CGFloat, look: TextLook = .plain,
        stage: OverlayFitStage, visibleRect: CGRect
    ) {
        self.id = id
        self.background = background
        self.textRect = textRect
        self.fontSize = fontSize
        self.look = look
        self.stage = stage
        self.visibleRect = visibleRect
    }

    init(
        id: String, backgroundRect: CGRect, textRect: CGRect, fontSize: CGFloat, overflows: Bool, visibleRect: CGRect
    ) {
        self.init(
            id: id, background: OverlayBackgroundShape(rect: backgroundRect), textRect: textRect, fontSize: fontSize,
            stage: overflows ? .extended : .original, visibleRect: visibleRect)
    }

    /// Everything drawing this item can touch: the visible background plus room for anti-aliasing and glyphs
    /// that reach a little past their line.
    var drawingBounds: CGRect {
        visibleRect.insetBy(dx: -OverlayLayout.canvasOutset, dy: -OverlayLayout.canvasOutset)
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> OverlayItemLayout {
        var copy = self
        copy.background = background.offsetBy(dx: dx, dy: dy)
        copy.textRect = textRect.offsetBy(dx: dx, dy: dy)
        copy.visibleRect = visibleRect.offsetBy(dx: dx, dy: dy)
        return copy
    }
}

/// One item as the window layout sees it, in window-local coordinates.
struct OverlayLayoutInput: Equatable {
    var id: String
    /// The translation (empty for items that draw nothing).
    var text: String
    var frame: CGRect
    /// The original's lines, top to bottom; empty = unknown.
    var lineFrames: [CGRect] = []
    var style: TextStyleHint = TextStyleHint()
    /// false for items whose original stays visible (pending, failed): they only keep the others away.
    var drawable: Bool = true
}

/// The room one item may draw in, decided from the original areas of every item in the window
/// (never from translations, so a streaming text never moves its neighbours).
struct OverlayRegion: Equatable {
    /// The original text: the union of its lines, or the element frame when the lines are unknown.
    var area: CGRect
    var lines: [CGRect]
    /// Background edges: left and right (with padding), and the lowest bottom of the full-width rows (the
    /// top of the next item below, or the clip). The top is always `area.minY - inkTop`.
    var left: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    /// Where the first row's background starts when the original starts mid-line (nil = `left`).
    var firstRowLeft: CGFloat?
    /// The original's last line when the next item starts later on that same line: this part of it
    /// (from `left` to just before the next item) still belongs to this item.
    var tail: CGRect?
    /// Extra cover above the first line and below the last one for glyphs that reach past their line frame
    /// (Chromium reports em-box high runs; Latin descenders and accents stick out of them). Only free room.
    var inkTop: CGFloat
    var inkBottom: CGFloat

    init(
        area: CGRect, lines: [CGRect], left: CGFloat, right: CGFloat, bottom: CGFloat,
        firstRowLeft: CGFloat? = nil, tail: CGRect? = nil, inkTop: CGFloat = 0, inkBottom: CGFloat = 0
    ) {
        self.area = area
        self.lines = lines
        self.left = left
        self.right = right
        self.bottom = bottom
        self.firstRowLeft = firstRowLeft
        self.tail = tail
        self.inkTop = inkTop
        self.inkBottom = inkBottom
    }
}

enum OverlayLayout {
    /// Horizontal padding of a background around the original text (covers anti-aliased edges).
    static let backgroundPadding: CGFloat = 1.5
    /// Frames thinner than this are off-screen placeholders (virtual lists report 1pt-high frames).
    static let minimumItemSide: CGFloat = 3
    /// Room around backgrounds kept inside the canvas (anti-aliasing, glyphs reaching past their line).
    static let canvasOutset: CGFloat = 3
    /// Shrinking at the original style stops at this fraction of the original size.
    static let minimumShrink: CGFloat = 0.85
    /// Corner radius never exceeds this: a larger one makes the text look like a pasted label.
    static let maximumCornerRadius: CGFloat = 2
    /// Tops closer than this count as the same line.
    static let sameTopTolerance: CGFloat = 0.5
    /// How far glyphs may reach past an em-box high line frame, as a fraction of the font size.
    static let inkMargin: CGFloat = 0.22

    /// Items that draw something. Pending and failed items leave the original visible, and so do translations
    /// that came out the same as the original (code, names): drawn in our font they would only cover it.
    static func isDrawable(_ item: OverlayItem) -> Bool {
        switch item.state {
        case .pending, .failed:
            return false
        case .streaming, .draft, .final:
            let words = item.translation.split(whereSeparator: \.isWhitespace)
            return !words.isEmpty && words != item.original.split(whereSeparator: \.isWhitespace)
        }
    }

    static func localRect(_ axRect: CGRect, windowAXFrame: CGRect) -> CGRect {
        axRect.standardized.offsetBy(dx: -windowAXFrame.minX, dy: -windowAXFrame.minY)
    }

    /// The visible region in window-local coordinates: the clip (or the whole window) intersected with
    /// the window bounds. nil when nothing is visible.
    static func localClip(axClipRect: CGRect?, windowAXFrame: CGRect) -> CGRect? {
        let window = windowAXFrame.standardized
        let clip = (axClipRect?.standardized ?? window).intersection(window)
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return nil }
        return clip.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    static func effectiveCornerRadius(_ appearance: OverlayAppearance) -> CGFloat {
        min(max(0, CGFloat(appearance.cornerRadius)), maximumCornerRadius)
    }

    // MARK: - Regions (no overlap)

    /// The original text area of an input and its usable lines, or nil when it is too small to draw.
    static func originalArea(of input: OverlayLayoutInput) -> (area: CGRect, lines: [CGRect])? {
        var lines: [CGRect] = []
        for line in input.lineFrames {
            let r = line.standardized
            if !r.isNull, r.width >= 1, r.height >= minimumItemSide { lines.append(r) }
        }
        lines.sort { (a: CGRect, b: CGRect) -> Bool in a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX }
        var area = input.frame.standardized
        if let first = lines.first { area = lines.dropFirst().reduce(first) { $0.union($1) } }
        guard !area.isNull, area.width >= minimumItemSide, area.height >= minimumItemSide else { return nil }
        return (area, lines)
    }

    /// Decides where every drawable input may draw, so that no two backgrounds intersect and no background
    /// covers another item's original text:
    /// - the right edge stops before items to the right on the same rows (a gap narrower than the padding
    ///   is split in the middle);
    /// - the bottom stops at the top of the first item below whose columns overlap, and at the clip;
    ///   an earlier item whose original reaches into a later one is cut at the later one's top, except for
    ///   the start of its last line when the later one begins further right on that line (a paragraph split
    ///   mid-line), which it keeps as `tail`; the later one's first row starts just after it;
    /// - an item that overlaps an earlier item (or a pending one) starting on the same line is not drawn.
    /// `widensLabels`: one-line labels of known size (drawn at the original size) may run on to the right.
    /// Returns one region per input (nil = not drawable or no room).
    static func regions(
        for inputs: [OverlayLayoutInput], clip: CGRect, widensLabels: Bool = true
    ) -> [OverlayRegion?] {
        let pad = backgroundPadding
        let originals = inputs.map(originalArea(of:))
        var left = [CGFloat](repeating: 0, count: inputs.count)
        var right = [CGFloat](repeating: 0, count: inputs.count)
        for (i, input) in inputs.enumerated() {
            guard let (area, _) = originals[i] else { continue }
            if input.drawable {
                // The element can be wider than its text (a paragraph's box); the translation may use that
                // width, but never more than the clip allows beyond the original's own width.
                let frame = input.frame.standardized
                let frameRight = frame.isNull || frame.width < minimumItemSide ? area.maxX : max(area.maxX, frame.maxX)
                left[i] = area.minX - pad
                right[i] = min(frameRight + pad, max(area.maxX + pad, clip.maxX))
                if widensLabels, input.style.fontSize != nil, frameRight <= area.maxX + 2,
                    isSingleLine(area: area, lines: lines(of: originals[i]), style: input.style)
                {
                    // A one-line label as wide as its text may run on to the right (up to the next item on its
                    // line, or the clip) at its own size, instead of being folded into its own narrow box.
                    right[i] = max(right[i], clip.maxX)
                }
            } else {
                // Pending and failed items draw nothing; only their text has to stay visible.
                left[i] = area.minX
                right[i] = area.maxX
            }
        }

        // Side by side: stop before the item to the right (any vertical overlap counts: a background must
        // not touch another original even by a fraction of a point).
        for i in inputs.indices {
            guard let (a, _) = originals[i] else { continue }
            for j in inputs.indices where j != i {
                guard let (b, _) = originals[j], a.minY < b.maxY, b.minY < a.maxY, b.minX >= a.maxX - 1 else { continue }
                let boundary = split(a.maxX, b.minX)
                if inputs[i].drawable { right[i] = min(right[i], boundary) }
                if inputs[j].drawable { left[j] = max(left[j], boundary) }
            }
        }

        // A paragraph split mid-line: j starts on i's last line, after it, and wraps below. When that line is
        // all of i, i ends just before j on it and never goes below it.
        var continued = Set<[Int]>()
        var lowest = [CGFloat](repeating: .greatestFiniteMagnitude, count: inputs.count)
        for i in inputs.indices {
            guard let (_, aLines) = originals[i], let last = aLines.last else { continue }
            for j in inputs.indices where j != i {
                guard let (b, bLines) = originals[j], bLines.count >= 2, let first = bLines.first,
                    rowsOverlap(last, first), first.minX >= last.maxX - 1, b.minX < first.minX - 1
                else { continue }
                continued.insert([i, j])
                if aLines.count == 1 {
                    if inputs[i].drawable { right[i] = min(right[i], split(last.maxX, first.minX)) }
                    lowest[i] = min(lowest[i], first.maxY)
                }
            }
        }

        func columnsOverlap(_ i: Int, _ j: Int) -> Bool { min(right[i], right[j]) - max(left[i], left[j]) > 0.5 }

        // Room for glyphs outside tight line frames: at most half the free gap to the nearest original above or
        // below (the other half is that one's), and never past the clip.
        var inkTop = [CGFloat](repeating: 0, count: inputs.count)
        var inkBottom = [CGFloat](repeating: 0, count: inputs.count)
        for (i, input) in inputs.enumerated() where input.drawable {
            guard let (area, lines) = originals[i], let ink = inkReach(of: input, lines: lines) else { continue }
            var above = min(ink, max(0, area.minY - clip.minY))
            var below = min(ink, max(0, clip.maxY - area.maxY))
            for j in inputs.indices where j != i {
                guard let (b, _) = originals[j], columnsOverlap(i, j) else { continue }
                if continued.contains([j, i]) || continued.contains([i, j]) {
                    // Two parts of one paragraph share a line: keep to the frames.
                    above = 0
                    below = 0
                } else if b.maxY <= area.minY + sameTopTolerance {
                    above = min(above, max(0, area.minY - b.maxY) / 2)
                } else if b.minY >= area.maxY - sameTopTolerance {
                    below = min(below, max(0, b.minY - area.maxY) / 2)
                } else {
                    // Overlapping originals: no room either way.
                    above = 0
                    below = 0
                }
            }
            inkTop[i] = above
            inkBottom[i] = below
        }

        var result = [OverlayRegion?](repeating: nil, count: inputs.count)
        for (i, input) in inputs.enumerated() where input.drawable {
            guard let (area, lines) = originals[i], right[i] - left[i] >= minimumItemSide else { continue }
            // Lines are added only inside the clip; the original's own lines always count.
            var bottom = min(area.maxY > clip.maxY ? area.maxY : clip.maxY, lowest[i])
            var cutBy: Int?
            var blocked = false
            for j in inputs.indices where j != i {
                guard let (b, _) = originals[j], columnsOverlap(i, j) else { continue }
                if continued.contains([i, j]) || continued.contains([j, i]), abs(b.minY - area.minY) <= sameTopTolerance {
                    // Two parts of one line (handled above and by the first row's start).
                    continue
                }
                if b.minY > area.minY + sameTopTolerance {
                    // Stop above that item, and above its glyphs' room (at most half the gap, see above).
                    let limit = b.minY - inkTop[j]
                    if limit < bottom {
                        bottom = limit
                        cutBy = j
                    }
                } else if abs(b.minY - area.minY) <= sameTopTolerance, !inputs[j].drawable || j < i {
                    // Same first line and overlapping: the earlier item (or a visible original) wins.
                    blocked = true
                    break
                }
            }
            guard !blocked, bottom - area.minY >= minimumItemSide else { continue }
            var region = OverlayRegion(
                area: area, lines: lines, left: left[i], right: right[i], bottom: bottom, inkTop: inkTop[i],
                inkBottom: min(inkBottom[i], max(0, bottom - area.maxY)))

            // A first line that starts mid-line: its row starts just after whatever ends before it there.
            if lines.count >= 2, let first = lines.first, first.minX > area.minX + 1 {
                var rowLeft = max(left[i], first.minX - pad)
                for (j, other) in originals.enumerated() where j != i {
                    guard let (b, otherLines) = other else { continue }
                    for line in otherLines.isEmpty ? [b] : otherLines
                    where rowsOverlap(line, first) && line.maxX <= first.minX + 1 && line.maxX > left[i] {
                        rowLeft = max(rowLeft, split(line.maxX, first.minX))
                    }
                }
                region.firstRowLeft = rowLeft
            }

            // Cut inside its last line by an item that starts further right on that line: keep the start.
            if let j = cutBy, let last = lines.last, lines.count >= 2, let (b, otherLines) = originals[j] {
                let next = otherLines.first ?? b
                if rowsOverlap(last, next), next.minX >= last.maxX - 1, bottom > last.minY - 1 {
                    let tail = CGRect(
                        x: left[i], y: bottom, width: split(last.maxX, next.minX) - left[i],
                        height: min(last.maxY, next.maxY) - bottom)
                    // Nothing else may be on that part of the line.
                    let free = inputs.indices.allSatisfy { k in
                        guard k != i, k != j, let (c, _) = originals[k] else { return true }
                        let shared = c.intersection(tail)
                        return shared.isNull || shared.width <= 0 || shared.height <= 0
                    }
                    if free, tail.width >= minimumItemSide, tail.height >= minimumItemSide { region.tail = tail }
                }
            }
            result[i] = region
        }
        return result
    }

    private static func lines(of original: (area: CGRect, lines: [CGRect])?) -> [CGRect] { original?.lines ?? [] }

    /// How far the item's glyphs may reach past its frames: some of an em when the frames are em-box high
    /// (web text), nothing when they are whole line boxes (terminals, native text) or the size is unknown.
    static func inkReach(of input: OverlayLayoutInput, lines: [CGRect]) -> CGFloat? {
        guard let size = input.style.fontSize, size > 0, !input.style.isMonospaced else { return nil }
        let fontSize = CGFloat(size)
        if !lines.isEmpty {
            let heights = lines.map(\.height).sorted()
            guard heights[heights.count / 2] <= fontSize * 1.15 else { return nil }
        }
        return (fontSize * inkMargin * 2).rounded() / 2
    }

    /// The original is one line of text: one reported line, or (lines unknown) a frame no taller than one
    /// line of its size (26pt when the size is unknown).
    static func isSingleLine(area: CGRect, lines: [CGRect], style: TextStyleHint) -> Bool {
        if !lines.isEmpty { return lines.count == 1 }
        let limit = style.fontSize.map { CGFloat($0) * 1.9 } ?? 26
        return area.height <= limit
    }

    /// Two lines share a row when they overlap vertically by more than a point.
    static func rowsOverlap(_ a: CGRect, _ b: CGRect) -> Bool { a.minY < b.maxY - 1 && b.minY < a.maxY - 1 }

    /// The boundary between text ending at `end` and text starting at `start` on the same row: the padding
    /// after the first, or the middle when the gap is narrower than two paddings.
    static func split(_ end: CGFloat, _ start: CGFloat) -> CGFloat {
        let boundary = start - backgroundPadding
        return boundary < end + backgroundPadding ? (end + start) / 2 : boundary
    }

    // MARK: - Window layout

    /// Lays out every drawable input of one window (window-local coordinates). Returns the layouts of the
    /// items that are drawn and visible in `clip`, in input order. No two backgrounds intersect.
    /// `regions`: from `regions(for:clip:)` for the same geometry, to skip recomputing them when only
    /// translations changed.
    static func layoutWindow(
        _ inputs: [OverlayLayoutInput], clip: CGRect, appearance: OverlayAppearance, fitter: TextFitter,
        regions known: [OverlayRegion?]? = nil
    ) -> [OverlayItemLayout] {
        var regions = known ?? []
        if regions.count != inputs.count {
            regions = Self.regions(for: inputs, clip: clip, widensLabels: appearance.matchOriginalStyle)
        }
        var placed: [OverlayItemLayout] = []
        for (input, region) in zip(inputs, regions) {
            guard let region,
                let layout = layoutItem(input, region: region, clip: clip, appearance: appearance, fitter: fitter)
            else { continue }
            // The regions already keep backgrounds apart; this guards rounding at their edges.
            if placed.contains(where: { $0.background.overlapArea(with: layout.background) > 0.25 }) { continue }
            placed.append(layout)
        }
        return placed
    }

    /// Lays out one translation over `frame` (window-local) with nothing else in the window.
    /// nil when the item is not visible in `clip`.
    static func layoutItem(
        id: String, text: String, frame: CGRect, clip: CGRect,
        appearance: OverlayAppearance, fitter: TextFitter
    ) -> OverlayItemLayout? {
        layoutWindow(
            [OverlayLayoutInput(id: id, text: text, frame: frame)], clip: clip, appearance: appearance, fitter: fitter
        ).first
    }

    /// Lays out one item inside its region. nil when not even its first line has room or it is not visible.
    static func layoutItem(
        _ input: OverlayLayoutInput, region: OverlayRegion, clip: CGRect, appearance: OverlayAppearance,
        fitter: TextFitter
    ) -> OverlayItemLayout? {
        guard !input.text.isEmpty else { return nil }
        let layout: OverlayItemLayout?
        if appearance.matchOriginalStyle, let size = input.style.fontSize, size >= 1 {
            layout = layoutOriginalStyle(
                input, size: CGFloat(size), region: region, appearance: appearance, fitter: fitter)
        } else {
            layout = layoutFitted(input, region: region, appearance: appearance, fitter: fitter)
        }
        guard var layout else { return nil }
        let visible = layout.background.rect.intersection(clip)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        layout.visibleRect = visible
        return layout
    }

    // MARK: - Original style

    /// Rows of the original: the first row's center and box height, the line pitch, and how many rows the
    /// original takes. Rows are spaced `pitch` apart; row k spans `center + k·pitch ± box/2`.
    struct RowGrid: Equatable {
        var center: CGFloat
        var box: CGFloat
        var pitch: CGFloat
        var originalRows: Int

        /// How many rows fit above `bottom` when rows are `pitch` apart and `box` high.
        static func capacity(center: CGFloat, box: CGFloat, pitch: CGFloat, bottom: CGFloat) -> Int {
            let room = bottom + 0.5 - center - box / 2
            guard room >= 0, pitch > 0 else { return 0 }
            return 1 + Int((room / pitch).rounded(.down))
        }
    }

    /// The original's row grid at its own size. `pitch` is `style.lineHeight`, else derived from the lines.
    static func rowGrid(region: OverlayRegion, fontSize: CGFloat, style: TextStyleHint, natural: CGFloat) -> RowGrid {
        let area = region.area
        let lines = region.lines
        var pitch: CGFloat
        if let lineHeight = style.lineHeight, lineHeight > 0 {
            pitch = CGFloat(lineHeight)
        } else if lines.count >= 2 {
            // The smallest step between lines; larger steps are gaps between paragraphs.
            let steps = zip(lines, lines.dropFirst()).map { $1.minY - $0.minY }.filter { $0 >= fontSize * 0.9 }
            pitch = steps.min() ?? max(natural, lines[0].height)
        } else if let line = lines.first {
            pitch = max(natural, min(line.height, fontSize * 1.6))
        } else if area.height < fontSize * 2.2 {
            pitch = max(natural, min(area.height, fontSize * 1.6))
        } else {
            let rows = max(1, (area.height / (fontSize * 1.35)).rounded())
            pitch = area.height / rows
        }
        pitch = min(max(pitch, fontSize), fontSize * 3)

        if let first = lines.first {
            let box = min(first.height, pitch)
            let rows = 1 + max(0, Int(((area.maxY - first.maxY) / pitch).rounded()))
            return RowGrid(center: first.midY, box: box, pitch: pitch, originalRows: max(rows, 1))
        }
        if area.height < pitch * 1.5 {
            return RowGrid(center: area.midY, box: min(area.height, pitch), pitch: pitch, originalRows: 1)
        }
        let rows = max(1, Int((area.height / pitch).rounded()))
        let top = area.minY + (area.height - CGFloat(rows) * pitch) / 2
        return RowGrid(center: top + pitch / 2, box: pitch, pitch: pitch, originalRows: rows)
    }

    /// Draws at the original size and line spacing from the original's first line. When the text is longer:
    /// add lines below (up to the region's bottom), then shrink to 85% (never below the minimum font size),
    /// then end the last line with "…". At every size the last line may go into the region's tail.
    private static func layoutOriginalStyle(
        _ input: OverlayLayoutInput, size originalSize: CGFloat, region: OverlayRegion,
        appearance: OverlayAppearance, fitter: TextFitter
    ) -> OverlayItemLayout? {
        let area = region.area
        let pad = backgroundPadding
        let monospaced = input.style.isMonospaced
        var size = originalSize
        var natural = TextFitter.naturalLineHeight(TextFitter.font(ofSize: size, monospaced: monospaced))
        if let line = region.lines.first ?? (area.height < natural * 1.5 ? area : nil), natural > line.height * 1.3 {
            // The reported size is much larger than the line it is drawn in (a zoomed-out page): follow the line.
            size = max(4, (size * line.height / natural * 4).rounded() / 4)
            natural = TextFitter.naturalLineHeight(TextFitter.font(ofSize: size, monospaced: monospaced))
        }
        let grid = rowGrid(region: region, fontSize: size, style: input.style, natural: natural)
        let maxRows = RowGrid.capacity(center: grid.center, box: grid.box, pitch: grid.pitch, bottom: region.bottom)
        guard maxRows >= 1 else { return nil }
        let originalRows = min(grid.originalRows, maxRows)

        let textLeft = area.minX
        let textWidth = max(1, region.right - pad - textLeft)
        let indent = firstLineIndent(region: region, textWidth: textWidth)
        let look = TextLook(monospaced: monospaced, lineHeightMultiple: grid.pitch / size, firstLineIndent: indent)

        /// Rows needed at `fontSize`, and whether the width fits.
        func rows(at fontSize: CGFloat) -> (rows: Int, width: CGFloat, fitsWidth: Bool) {
            let measured = fitter.measure(input.text, fontSize: fontSize, maxWidth: textWidth, look: look)
            let pitch = look.fixedLineHeight(fontSize: fontSize) ?? grid.pitch
            let count = max(1, Int((measured.height / pitch).rounded()))
            return (count, measured.width, measured.width <= textWidth + 0.5)
        }
        /// Whether row `rowIndex` is the original's last line where the next item starts later on it (at the
        /// original size; smaller rows sit a little higher, still on this item's own background), and the
        /// text's last line at `fontSize` fits the start of that line.
        func fitsTail(rowIndex: Int, fontSize: CGFloat) -> Bool {
            guard let tail = region.tail else { return false }
            let center = grid.center + CGFloat(rowIndex) * (look.fixedLineHeight(fontSize: size) ?? grid.pitch)
            guard abs(center - tail.midY) <= grid.pitch / 2 else { return false }
            let lastLine = fitter.lastLineWidth(input.text, fontSize: fontSize, maxWidth: textWidth, look: look)
            return textLeft + lastLine <= tail.maxX - pad + 0.5
        }
        func capacity(at fontSize: CGFloat) -> Int {
            let scale = fontSize / size
            let pitch = look.fixedLineHeight(fontSize: fontSize) ?? grid.pitch * scale
            return RowGrid.capacity(
                center: grid.center, box: min(grid.box * scale, pitch), pitch: pitch, bottom: region.bottom)
        }

        let chosen: (size: CGFloat, rows: Int, width: CGFloat, stage: OverlayFitStage)
        let full = rows(at: size)
        if full.fitsWidth, full.rows <= originalRows {
            chosen = (size, full.rows, full.width, .original)
        } else if full.fitsWidth, full.rows == originalRows + 1, fitsTail(rowIndex: originalRows, fontSize: size) {
            // The last line goes where the original's own last line starts (before the next item).
            chosen = (size, full.rows, full.width, .original)
        } else if full.fitsWidth, full.rows <= maxRows {
            chosen = (size, full.rows, full.width, .extended)
        } else {
            let floorSize = min(size, max(size * minimumShrink, CGFloat(appearance.minFontSize)))
            // Sizes on a half-point grid between the floor and the original; binary search for the largest
            // that fits (fewer rows are needed and more fit as the size goes down).
            var sizes: [CGFloat] = []
            var candidate = (size * 2).rounded(.up) / 2 - 0.5
            while candidate > floorSize + 0.01 {
                sizes.append(candidate)
                candidate -= 0.5
            }
            sizes.append(floorSize)
            sizes.reverse()  // ascending
            func fits(_ s: CGFloat) -> (Bool, Int, CGFloat) {
                let r = rows(at: s)
                let rowsAbove = capacity(at: s)
                // One more row fits when it is the tail and the last line is short enough for it.
                let fitsRows = r.rows <= rowsAbove || (r.rows == rowsAbove + 1 && fitsTail(rowIndex: rowsAbove, fontSize: s))
                return (r.fitsWidth && fitsRows, r.rows, r.width)
            }
            var best: (CGFloat, Int, CGFloat)?
            if floorSize < size {
                var lo = 0
                var hi = sizes.count - 1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    let attempt = fits(sizes[mid])
                    if attempt.0 {
                        best = (sizes[mid], attempt.1, attempt.2)
                        lo = mid + 1
                    } else {
                        hi = mid - 1
                    }
                }
            }
            if let best {
                chosen = (best.0, best.1, best.2, .shrunk)
            } else {
                let r = rows(at: floorSize)
                chosen = (floorSize, min(r.rows, capacity(at: floorSize)), r.width, .truncated)
            }
        }

        let pitch = look.fixedLineHeight(fontSize: chosen.size) ?? grid.pitch
        let scale = chosen.size / size
        let box = min(grid.box * scale, pitch)
        let textTop = grid.center - pitch / 2
        // Half a point of slack: a line is drawn only when it fits in the rect, and rows add up in floats.
        let textRect = CGRect(x: textLeft, y: textTop, width: textWidth, height: CGFloat(chosen.rows) * pitch + 0.5)
        let lastRowBottom = grid.center + CGFloat(chosen.rows - 1) * pitch + box / 2
        let bottom = min(region.bottom, max(area.maxY, lastRowBottom) + region.inkBottom)
        let backgroundRight = min(region.right, max(area.maxX, textLeft + chosen.width) + pad)
        guard backgroundRight > region.left, bottom > area.minY else { return nil }
        let shape = backgroundShape(region: region, bottom: bottom, right: backgroundRight)
        return OverlayItemLayout(
            id: input.id, background: shape, textRect: textRect, fontSize: chosen.size, look: look,
            stage: chosen.stage, visibleRect: shape.rect)
    }

    // MARK: - Unknown size

    /// The original size is unknown (or not used): the largest size in the min…max range that fits the
    /// original's area; at the minimum size, lines are added below, then the last line ends with "…".
    /// An original that starts mid-line is written from there, its second line below that first line (the
    /// start of the line belongs to another item); the last line may go into the region's tail.
    private static func layoutFitted(
        _ input: OverlayLayoutInput, region: OverlayRegion, appearance: OverlayAppearance, fitter: TextFitter
    ) -> OverlayItemLayout? {
        let area = region.area
        let pad = backgroundPadding
        let textLeft = area.minX
        let textWidth = max(1, region.right - pad - textLeft)
        let indent = firstLineIndent(region: region, textWidth: textWidth)
        // The second line must start below the first one: the start of that line belongs to another item.
        let look = TextLook(
            monospaced: appearance.matchOriginalStyle && input.style.isMonospaced, firstLineIndent: indent,
            minimumLineHeight: indent > 0 ? region.lines.first?.height : nil)
        let boxHeight = min(area.maxY, region.bottom) - area.minY
        guard boxHeight >= minimumItemSide else { return nil }
        let minSize = CGFloat(appearance.minFontSize)
        let maxSize = CGFloat(appearance.maxFontSize)
        var fit = fitter.fit(
            input.text, in: CGSize(width: textWidth, height: boxHeight), minFontSize: minSize, maxFontSize: maxSize,
            look: look)
        if let tail = region.tail,
            let size = largestSizeEndingInTail(
                input.text, tail: tail, top: area.minY, cut: area.minY + boxHeight, textLeft: textLeft,
                textWidth: textWidth, sizes: (minSize, maxSize), above: fit.fits ? fit.fontSize : nil, look: look,
                fitter: fitter)
        {
            let measured = fitter.measure(input.text, fontSize: size, maxWidth: textWidth, look: look)
            fit = TextFit(fontSize: size, textSize: measured, fits: true)
        }

        let textRect: CGRect
        let stage: OverlayFitStage
        if fit.fits {
            let lineHeight = fitter.lineHeight(fontSize: fit.fontSize, look: look)
            if indent > 0 || fit.textSize.height > boxHeight + 0.5 {
                // From the first line's top: centered, the first line would leave its own row.
                textRect = CGRect(x: textLeft, y: area.minY, width: textWidth, height: max(boxHeight, fit.textSize.height))
            } else if fit.textSize.height < lineHeight * 1.5 {
                // A single line is centered vertically, like a label.
                let y = area.minY + max(0, (boxHeight - fit.textSize.height) / 2)
                textRect = CGRect(x: textLeft, y: y, width: textWidth, height: fit.textSize.height)
            } else {
                textRect = CGRect(x: textLeft, y: area.minY, width: textWidth, height: boxHeight)
            }
            stage = .original
        } else {
            let room = region.bottom - area.minY
            if fit.textSize.height <= room {
                textRect = CGRect(x: textLeft, y: area.minY, width: textWidth, height: fit.textSize.height)
                stage = .extended
            } else {
                textRect = CGRect(x: textLeft, y: area.minY, width: textWidth, height: room)
                stage = .truncated
            }
        }
        let bottom = min(region.bottom, max(area.maxY, textRect.maxY) + region.inkBottom)
        let backgroundRight = min(region.right, max(area.maxX, textLeft + fit.textSize.width) + pad)
        guard backgroundRight > region.left, bottom > area.minY else { return nil }
        let shape = backgroundShape(region: region, bottom: bottom, right: backgroundRight)
        return OverlayItemLayout(
            id: input.id, background: shape, textRect: textRect, fontSize: fit.fontSize, look: look, stage: stage,
            visibleRect: shape.rect)
    }

    /// The indent of the first line when the original starts mid-line (its first line starts right of the
    /// lines below it), else 0.
    static func firstLineIndent(region: OverlayRegion, textWidth: CGFloat) -> CGFloat {
        guard region.lines.count >= 2, let first = region.lines.first, first.minX - region.area.minX > 1 else { return 0 }
        return min(first.minX - region.area.minX, textWidth - 1)
    }

    /// Unknown size, original cut mid-line by the next item: the largest size on the fitter's grid (larger than
    /// `above` when given, else from the minimum) at which every line but the last ends above `cut` and the
    /// last one ends inside the tail, no wider than it. nil when none does.
    private static func largestSizeEndingInTail(
        _ text: String, tail: CGRect, top: CGFloat, cut: CGFloat, textLeft: CGFloat, textWidth: CGFloat,
        sizes: (min: CGFloat, max: CGFloat), above: CGFloat?, look: TextLook, fitter: TextFitter
    ) -> CGFloat? {
        let tall = fitter.fit(
            text, in: CGSize(width: textWidth, height: tail.maxY - top), minFontSize: sizes.min, maxFontSize: sizes.max,
            look: look)
        guard tall.fits else { return nil }
        var size = tall.fontSize
        while size >= (above.map { $0 + fitter.step / 2 } ?? sizes.min - 0.01) {
            let measured = fitter.measure(text, fontSize: size, maxWidth: textWidth, look: look)
            let lineHeight = fitter.lineHeight(fontSize: size, look: look)
            if measured.width <= textWidth + 0.5, measured.height <= tail.maxY - top,
                top + measured.height - lineHeight <= cut + 0.5,
                textLeft + fitter.lastLineWidth(text, fontSize: size, maxWidth: textWidth, look: look)
                    <= tail.maxX - backgroundPadding + 0.5
            {
                return size
            }
            size -= fitter.step
        }
        return nil
    }

    /// The background rows: the first row from `firstRowLeft` when the original starts mid-line, the full
    /// rows down to `bottom`, and the tail of the original's last line when the next item starts on it.
    static func backgroundShape(region: OverlayRegion, bottom: CGFloat, right: CGFloat) -> OverlayBackgroundShape {
        let top = region.area.minY - region.inkTop
        var rows: [CGRect] = []
        if let rowLeft = region.firstRowLeft, let first = region.lines.first, rowLeft < right - 1 {
            let rowBottom = min(first.maxY, bottom)
            rows.append(CGRect(x: rowLeft, y: top, width: right - rowLeft, height: rowBottom - top))
            rows.append(CGRect(x: region.left, y: rowBottom, width: right - region.left, height: bottom - rowBottom))
        } else {
            rows.append(CGRect(x: region.left, y: top, width: right - region.left, height: bottom - top))
        }
        if let tail = region.tail, abs(bottom - tail.minY) < 0.01 {
            rows.append(
                CGRect(x: region.left, y: tail.minY, width: min(tail.maxX, right) - region.left, height: tail.height))
        }
        return OverlayBackgroundShape(rows: rows)
    }

    // MARK: - Draft dot

    /// Where the draft dot goes (same coordinates as `layout`): just after the end of the text on its last
    /// line when there is room there, else in the background's top-right corner.
    static func indicatorCenter(for layout: OverlayItemLayout, text: String, fitter: TextFitter) -> CGPoint {
        let r = OverlayRenderer.indicatorRadius
        let corner = OverlayRenderer.cornerIndicatorCenter(for: layout.background)
        guard layout.stage != .truncated, !text.isEmpty else { return corner }
        let look = layout.look
        let pitch = look.fixedLineHeight(fontSize: layout.fontSize) ?? fitter.lineHeight(fontSize: layout.fontSize, look: look)
        let size = fitter.measure(text, fontSize: layout.fontSize, maxWidth: layout.textRect.width, look: look)
        let rows = max(1, Int((size.height / pitch).rounded()))
        let lastWidth = fitter.lastLineWidth(text, fontSize: layout.fontSize, maxWidth: layout.textRect.width, look: look)
        let x = layout.textRect.minX + lastWidth + 2 + r
        let y = layout.textRect.minY + (CGFloat(rows) - 0.5) * pitch
        // The dot must stay on the background (in the row of the last line).
        let dot = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
        return layout.background.rows.contains { $0.contains(dot) } ? CGPoint(x: x, y: y) : corner
    }

    // MARK: - Canvas

    /// Draw order: items that fit first, then the others. Backgrounds never intersect, so this only matters
    /// for glyphs reaching a little past their line.
    static func drawOrder(_ layouts: [OverlayItemLayout]) -> [OverlayItemLayout] {
        layouts.filter { !$0.overflows } + layouts.filter(\.overflows)
    }

    /// The smallest rect (window-local) that holds every visible background, kept inside `clip`.
    /// `.null` when there is nothing to draw.
    static func canvasRect(for layouts: [OverlayItemLayout], clip: CGRect) -> CGRect {
        var union = CGRect.null
        for layout in layouts { union = union.union(layout.visibleRect) }
        guard !union.isNull else { return .null }
        let rect = union.insetBy(dx: -canvasOutset, dy: -canvasOutset).intersection(clip)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return .null }
        // Whole points keep the backing store pixel-aligned.
        return rect.integral.intersection(clip.integral)
    }
}
