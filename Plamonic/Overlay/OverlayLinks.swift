import AppKit

// Links in translations (DESIGN §6.1): which part of the drawn text is a link, where its glyphs are, and the
// click areas of one window (translated links, and original links hidden under translations).

/// A link as drawn in an item's text.
struct OverlayDrawLink: Hashable, Sendable {
    /// UTF-16 range in the drawn text (`OverlayDrawItem.text`).
    var range: NSRange
    /// Index into the item's `originalLinks`.
    var linkIndex: Int
    /// The original link's color; nil = a link color picked for the background.
    var color: RGBAColor?
    var isUnderlined: Bool
}

/// An item's text with its links laid out the way the canvas draws it.
struct OverlayPreparedText: Equatable {
    /// What is drawn (the text, or its cut version ending with "…").
    var text: String
    /// The links that are drawn, with ranges in `text`. Links past a cut are gone; a link cut in the middle keeps
    /// its drawn part.
    var links: [OverlayDrawLink]
    /// Per entry of `links`: one rect per line, relative to the text rect's origin (x from the glyphs, y from
    /// the line).
    var linkRects: [[CGRect]]
    /// The text was cut with "…".
    var isCut: Bool
}

enum OverlayLinkText {
    /// Zero-width space: a line break opportunity that draws nothing.
    static let breakOpportunity: unichar = 0x200B
    /// Long URLs and paths may wrap after these (inside link runs only).
    static let breaksAfter: Set<unichar> = Set("/?&=-_.".utf16)
    private static let lineSeparator: unichar = 0x2028

    /// The text to lay out and draw for `item` when links are shown, and its links in that text. Invalid links
    /// (out of range, overlapping, unknown original) are dropped; ranges are widened to whole characters and
    /// trimmed of surrounding spaces. Break opportunities are added inside links (not in the rest of the text).
    static func styled(_ item: OverlayItem) -> (text: String, links: [OverlayDrawLink]) {
        styled(translation: item.translation, links: item.links, originalLinks: item.originalLinks)
    }

    static func styled(
        translation: String, links: [OverlayLink], originalLinks: [SegmentLink]
    ) -> (text: String, links: [OverlayDrawLink]) {
        let ns = translation as NSString
        let length = ns.length
        guard !links.isEmpty, length > 0 else { return (translation, []) }
        var valid: [(range: NSRange, link: OverlayLink)] = []
        for link in links.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard originalLinks.indices.contains(link.linkIndex) else { continue }
            var lower = max(0, min(link.range.lowerBound, length))
            var upper = max(lower, min(link.range.upperBound, length))
            while lower < upper, isSpace(ns.character(at: lower)) { lower += 1 }
            while upper > lower, isSpace(ns.character(at: upper - 1)) { upper -= 1 }
            guard lower < upper else { continue }
            let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
            if let last = valid.last, range.location < NSMaxRange(last.range) { continue }
            valid.append((range, link))
        }
        guard !valid.isEmpty else { return (translation, []) }

        var out: [unichar] = []
        out.reserveCapacity(length + 16)
        // Drawn offset of each original offset (boundaries).
        var map = [Int](repeating: 0, count: length + 1)
        var current = 0
        for i in 0..<length {
            map[i] = out.count
            let c = ns.character(at: i)
            out.append(c)
            while current < valid.count, NSMaxRange(valid[current].range) <= i { current += 1 }
            guard current < valid.count, NSLocationInRange(i, valid[current].range),
                i + 1 < NSMaxRange(valid[current].range), breaksAfter.contains(c)
            else { continue }
            // After the last of a run of separators ("https://"), never before a space.
            let next = ns.character(at: i + 1)
            if !breaksAfter.contains(next), !isSpace(next), next != breakOpportunity { out.append(breakOpportunity) }
        }
        map[length] = out.count
        let text = String(utf16CodeUnits: out, count: out.count)
        let drawn = valid.map { entry -> OverlayDrawLink in
            let original = originalLinks[entry.link.linkIndex]
            let start = map[entry.range.location]
            let end = map[NSMaxRange(entry.range)]
            return OverlayDrawLink(
                range: NSRange(location: start, length: end - start), linkIndex: entry.link.linkIndex,
                color: original.color, isUnderlined: original.isUnderlined)
        }
        return (text, drawn)
    }

    // MARK: - Laying out what is drawn

    /// Lays `text` out exactly as the canvas draws it into a text rect of `size` (NSStringDrawing with the
    /// fitter's attributes) and finds each link's glyphs. When the text has more lines than fit, it is cut the
    /// way `.truncatesLastVisibleLine` cuts it (the last visible line takes as much of the rest as fits before
    /// "…"); the cut is made here so the drawn text and the link rects agree.
    static func prepare(
        _ text: String, links: [OverlayDrawLink], fontSize: CGFloat, look: TextLook, size: CGSize
    ) -> OverlayPreparedText {
        let unchanged = OverlayPreparedText(text: text, links: [], linkRects: [], isCut: false)
        guard !text.isEmpty, size.width > 0, size.height > 0 else { return unchanged }
        let full = Layout(text, fontSize: fontSize, look: look, width: size.width)
        let lines = full.lines
        let visible = lines.prefix { $0.rect.maxY <= size.height + 0.01 }.count
        guard visible > 0 else { return unchanged }
        if visible == lines.count {
            return rects(in: full, text: text, links: links, height: size.height, isCut: false)
        }
        guard let cut = cut(text, lines: lines, lastVisible: visible - 1, fontSize: fontSize, look: look, size: size)
        else { return unchanged }
        let cutLinks = links.compactMap { link -> OverlayDrawLink? in
            let lower = link.range.location
            let upper = min(NSMaxRange(link.range), cut.keptEnd)
            guard upper > lower else { return nil }
            func mapped(_ offset: Int) -> Int { offset < cut.lineStart ? offset : offset + cut.inserted }
            var copy = link
            let start = mapped(lower)
            copy.range = NSRange(location: start, length: (upper <= cut.lineStart ? upper : upper + cut.inserted) - start)
            return copy
        }
        return rects(
            in: Layout(cut.text, fontSize: fontSize, look: look, width: size.width), text: cut.text, links: cutLinks,
            height: size.height, isCut: true)
    }

    /// The cut text: everything before the last visible line, then as much of the rest (up to a hard line
    /// break) as fits before "…". `keptEnd`: end of the kept part in the original text; `inserted`: units added
    /// at `lineStart` (a line separator that keeps the earlier lines wrapped where they were).
    private static func cut(
        _ text: String, lines: [Layout.Line], lastVisible: Int, fontSize: CGFloat, look: TextLook, size: CGSize
    ) -> (text: String, lineStart: Int, keptEnd: Int, inserted: Int)? {
        let ns = text as NSString
        let start = lines[lastVisible].characters.location
        guard start <= ns.length else { return nil }
        var end = ns.length
        let hardBreak = ns.rangeOfCharacter(
            from: .newlines, options: [], range: NSRange(location: start, length: ns.length - start))
        if hardBreak.location != NSNotFound { end = hardBreak.location }
        // Character boundaries of the candidate line.
        var boundaries: [Int] = [start]
        ns.enumerateSubstrings(in: NSRange(location: start, length: end - start), options: .byComposedCharacterSequences) {
            _, range, _, _ in boundaries.append(NSMaxRange(range))
        }
        let available = size.width - (lastVisible == 0 ? look.firstLineIndent : 0)
        var plain = look
        plain.firstLineIndent = 0
        func fits(_ upTo: Int) -> Bool {
            let line = ns.substring(with: NSRange(location: start, length: upTo - start)) + "…"
            let width = TextFitter.attributedString(line, fontSize: fontSize, color: .black, look: plain)
                .boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: TextFitter.drawingOptions
                ).width
            return ceil(width) <= available + 0.5
        }
        // Largest boundary that fits (widths grow with the length).
        var lo = 0
        var hi = boundaries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(boundaries[mid]) { lo = mid } else { hi = mid - 1 }
        }
        let needsSeparator =
            lastVisible > 0 && start > 0 && !CharacterSet.newlines.contains(Unicode.Scalar(ns.character(at: start - 1)) ?? " ")
        var index = lo
        // A few tries: the cut line must stay one line (kerning and fallback fonts can differ by a point).
        for _ in 0..<4 {
            var kept = boundaries[index]
            while kept > start, isSpace(ns.character(at: kept - 1)) || ns.character(at: kept - 1) == breakOpportunity {
                kept -= 1
            }
            var result = ns.substring(to: start)
            if needsSeparator { result += String(utf16CodeUnits: [lineSeparator], count: 1) }
            result += ns.substring(with: NSRange(location: start, length: kept - start)) + "…"
            let check = Layout(result, fontSize: fontSize, look: look, width: size.width)
            if check.lines.count <= lastVisible + 1 || index == 0 {
                return (result, start, kept, needsSeparator ? 1 : 0)
            }
            index -= 1
        }
        return nil
    }

    private static func rects(
        in layout: Layout, text: String, links: [OverlayDrawLink], height: CGFloat, isCut: Bool
    ) -> OverlayPreparedText {
        var kept: [OverlayDrawLink] = []
        var rects: [[CGRect]] = []
        let length = (text as NSString).length
        for link in links {
            guard link.range.length > 0, NSMaxRange(link.range) <= length else { continue }
            let linkRects = layout.rects(for: link.range).filter { $0.maxY <= height + 0.5 }
            guard !linkRects.isEmpty else { continue }
            kept.append(link)
            rects.append(linkRects)
        }
        return OverlayPreparedText(text: text, links: kept, linkRects: rects, isCut: isCut)
    }

    static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// TextKit layout with the attributes and options NSStringDrawing uses for the canvas.
    private struct Layout {
        struct Line {
            var rect: CGRect
            var glyphs: NSRange
            var characters: NSRange
        }

        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        let lines: [Line]

        init(_ text: String, fontSize: CGFloat, look: TextLook, width: CGFloat) {
            storage = NSTextStorage(
                attributedString: TextFitter.attributedString(text, fontSize: fontSize, color: .black, look: look))
            manager = NSLayoutManager()
            manager.usesFontLeading = false
            container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            var lines: [Line] = []
            let manager = self.manager
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                rect, _, _, glyphs, _ in
                lines.append(
                    Line(
                        rect: rect, glyphs: glyphs,
                        characters: manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
            }
            self.lines = lines
        }

        /// One rect per line the characters are on: x from the glyphs, y from the line.
        func rects(for characters: NSRange) -> [CGRect] {
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            var result: [CGRect] = []
            for line in lines {
                let part = NSIntersectionRange(line.glyphs, glyphs)
                guard part.length > 0 else { continue }
                let bounds = manager.boundingRect(forGlyphRange: part, in: container)
                guard bounds.width > 0.5 else { continue }
                result.append(CGRect(x: bounds.minX, y: line.rect.minY, width: bounds.width, height: line.rect.height))
            }
            return result
        }
    }
}

// MARK: - Click areas

/// One click area of a window (window-local coordinates, like the layouts).
struct OverlayHitArea: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A link drawn in the translation: a click opens the original link `originalLinks[index]`.
        case link(Int)
        /// An original link hidden under the translation: a click is kept from it and shows the original.
        case blocker
    }

    var itemID: String
    var kind: Kind
    var rect: CGRect

    var isLink: Bool {
        if case .link = kind { return true }
        return false
    }
}

enum OverlayHitAreas {
    /// Most click areas (= small panels) per window. Over it, items lose clickable links before any original
    /// link under a translation loses its cover (`compute`).
    static let maximumPerWindow = 64
    /// Areas thinner than this are not worth a panel.
    static let minimumSide: CGFloat = 2

    /// One drawn item, window-local.
    struct Item {
        var id: String
        var layout: OverlayItemLayout
        /// Drawn link glyphs: the original link's index and its rects (one per line).
        var links: [(linkIndex: Int, rects: [CGRect])]
        /// Every line of every original link of the item (AX coordinates).
        var originalLinkFrames: [CGRect]
    }

    /// What the limit cost: items whose links were merged into blockers (not clickable, still covered), and
    /// items left without any click area.
    struct OverLimit: Equatable {
        var merged = 0
        var unprotected = 0
    }

    /// The click areas of one window, all inside `clip`: translated links, then the original links under the
    /// translations (inside each item's background, minus its translated links). At most `limit`. Over it, the
    /// last items in draw order that cover original links give up their own areas for one blocker per line with
    /// links (covering their original links and their drawn links, so a click there shows the original instead
    /// of pressing a link), then for one per background row. Only when that is not enough either are whole items
    /// left out, those with nothing to cover first.
    static func compute(
        _ items: [Item], windowAXFrame: CGRect, clip: CGRect, limit: Int = maximumPerWindow
    ) -> (areas: [OverlayHitArea], merged: Int, unprotected: Int) {
        let origin = windowAXFrame.standardized.origin
        /// An item's areas: its own (links, then blockers), one blocker per line, one per background row.
        struct Forms {
            var links: [OverlayHitArea] = []
            var blockers: [OverlayHitArea] = []
            var lines: [OverlayHitArea] = []
            var rows: [OverlayHitArea] = []
            var full: Int { links.count + blockers.count }
            func count(_ level: Int) -> Int { [full, lines.count, rows.count][level] }
        }
        var forms: [Forms] = []
        for item in items {
            var form = Forms()
            let visible = item.layout.visibleRect.intersection(clip)
            guard !visible.isNull else {
                forms.append(form)
                continue
            }
            var itemLinks: [CGRect] = []
            for (index, rects) in item.links {
                for rect in rects {
                    let r = rect.intersection(visible)
                    guard usable(r) else { continue }
                    itemLinks.append(r)
                    form.links.append(OverlayHitArea(itemID: item.id, kind: .link(index), rect: r))
                }
            }
            let rows = item.layout.background.rows.map { $0.intersection(clip) }.filter(usable)
            let originals = item.originalLinkFrames.map { $0.standardized.offsetBy(dx: -origin.x, dy: -origin.y) }
            var covered: [CGRect] = []
            for row in rows {
                var rowCover = CGRect.null
                for local in originals {
                    let part = local.intersection(row)
                    guard usable(part) else { continue }
                    covered.append(part)
                    rowCover = rowCover.union(part)
                    for piece in subtract(itemLinks, from: part) where usable(piece) {
                        form.blockers.append(OverlayHitArea(itemID: item.id, kind: .blocker, rect: piece))
                    }
                }
                for link in itemLinks {
                    let part = link.intersection(row)
                    guard usable(part) else { continue }
                    covered.append(part)
                    rowCover = rowCover.union(part)
                }
                if usable(rowCover) { form.rows.append(OverlayHitArea(itemID: item.id, kind: .blocker, rect: rowCover)) }
            }
            form.lines = lineBands(covered).map { OverlayHitArea(itemID: item.id, kind: .blocker, rect: $0) }
            forms.append(form)
        }

        let budget = max(0, limit)
        // 0: own areas, 1: one per line, 2: one per background row.
        var level = [Int](repeating: 0, count: forms.count)
        var count = forms.reduce(0) { $0 + $1.full }
        for target in 1...2 {
            // Last items first: their links stop being clickable, their original links stay covered. Items with
            // nothing to cover keep their links (they are left out first below).
            for i in forms.indices.reversed() where count > budget && !forms[i].blockers.isEmpty {
                let saved = forms[i].count(level[i]) - forms[i].count(target)
                guard saved > 0 else { continue }
                level[i] = target
                count -= saved
            }
        }
        var left = [Bool](repeating: false, count: forms.count)
        if count > budget {
            // Still too many: leave out whole items, those with only links (nothing to cover) first.
            let order =
                forms.indices.reversed().filter { forms[$0].blockers.isEmpty }
                + forms.indices.reversed().filter { !forms[$0].blockers.isEmpty }
            for i in order where count > budget && forms[i].count(level[i]) > 0 {
                left[i] = true
                count -= forms[i].count(level[i])
            }
        }
        var links: [OverlayHitArea] = []
        var blockers: [OverlayHitArea] = []
        var merged = 0
        var unprotected = 0
        for (i, form) in forms.enumerated() {
            if left[i] {
                if !form.blockers.isEmpty { unprotected += 1 }
                continue
            }
            switch level[i] {
            case 0:
                links += form.links
                blockers += form.blockers
            case 1:
                blockers += form.lines
                if !form.links.isEmpty { merged += 1 }
            default:
                blockers += form.rows
                if !form.links.isEmpty { merged += 1 }
            }
        }
        return (links + blockers, merged, unprotected)
    }

    /// Rects that share a line (overlap vertically by at least half the smaller one) merged into one each.
    static func lineBands(_ rects: [CGRect]) -> [CGRect] {
        var bands: [CGRect] = []
        for rect in rects.sorted(by: { $0.minY < $1.minY }) {
            if let i = bands.lastIndex(where: { band in
                min(band.maxY, rect.maxY) - max(band.minY, rect.minY) >= min(band.height, rect.height) / 2
            }) {
                bands[i] = bands[i].union(rect)
            } else {
                bands.append(rect)
            }
        }
        return bands
    }

    static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.width >= minimumSide && rect.height >= minimumSide
    }

    /// `rect` minus every rect of `holes`, as non-overlapping rects.
    static func subtract(_ holes: [CGRect], from rect: CGRect) -> [CGRect] {
        var pieces = [rect]
        for hole in holes {
            pieces = pieces.flatMap { subtract(hole, from: $0) }
        }
        return pieces
    }

    /// `rect` minus `hole`: up to four bands (above, below, left, right).
    static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        var result: [CGRect] = []
        if cut.minY > rect.minY {
            result.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY))
        }
        if cut.maxY < rect.maxY {
            result.append(CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY))
        }
        if cut.minX > rect.minX {
            result.append(CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height))
        }
        if cut.maxX < rect.maxX {
            result.append(CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height))
        }
        return result
    }
}

// MARK: - Link colors

extension OverlayPalette {
    /// Link colors close to the system's (`NSColor.linkColor` in light and dark).
    static var lightLinkColor: NSColor { NSColor(srgbRed: 0.0, green: 0.408, blue: 0.855, alpha: 1) }
    static var darkLinkColor: NSColor { NSColor(srgbRed: 0.255, green: 0.612, blue: 1.0, alpha: 1) }

    /// The color a translated link is drawn in: the original link's color when it contrasts at least 3:1 with
    /// the background, else the system-like link color for a dark or light background, else the text color.
    static func linkColor(original: RGBAColor?, resolved: ResolvedOverlayColors) -> NSColor {
        let solid = resolved.solidBackground
        if let original {
            let color = flatten(original, on: solid)
            if contrastRatio(color, solid) >= minimumTextContrast { return color }
        }
        let dark = relativeLuminance(solid) < CGFloat(darkLuminance)
        let system = dark ? darkLinkColor : lightLinkColor
        if contrastRatio(system, solid) >= minimumTextContrast { return system }
        let other = dark ? lightLinkColor : darkLinkColor
        if contrastRatio(other, solid) >= minimumTextContrast { return other }
        return resolved.text
    }

    /// How far a hovered, already underlined link's color moves away from the background.
    static let hoveredLinkShift: CGFloat = 0.3

    /// The color of a hovered link that is underlined already: a little stronger (toward black on a light
    /// background, toward white on a dark one), like a browser link under the pointer.
    static func hoveredLinkColor(_ color: NSColor, resolved: ResolvedOverlayColors) -> NSColor {
        let dark = relativeLuminance(resolved.solidBackground) < CGFloat(darkLuminance)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return srgb.blended(withFraction: hoveredLinkShift, of: dark ? .white : .black) ?? srgb
    }

    /// Two colors that read as the same (a sampled text color that is really a link's color).
    static func isClose(_ a: RGBAColor, _ b: RGBAColor, tolerance: Double = 0.08) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance && abs(a.blue - b.blue) <= tolerance
    }
}
