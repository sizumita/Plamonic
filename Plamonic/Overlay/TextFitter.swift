import AppKit

struct TextFit: Equatable, Sendable {
    var fontSize: CGFloat
    /// Size of the wrapped text at `fontSize`. Its width never exceeds the box width it was fitted to
    /// (unless a single glyph is wider than the box).
    var textSize: CGSize
    /// false when the text is taller (or wider) than the box even at the minimum font size.
    var fits: Bool
}

/// How a translation is typeset, apart from its size.
struct TextLook: Hashable, Sendable {
    /// Monospaced system font (terminals, code) instead of the proportional one.
    var monospaced = false
    /// Fixed distance between lines as a multiple of the font size (the original's line spacing),
    /// nil = the font's own spacing. A multiple keeps the spacing in proportion when the text is shrunk.
    var lineHeightMultiple: CGFloat?
    /// Extra indent of the first line, in points: the original starts in the middle of a line.
    var firstLineIndent: CGFloat = 0
    /// Lines at least this far apart, in points, when `lineHeightMultiple` is nil: the second line of an
    /// original that starts mid-line must start below that first line (the line's start belongs to
    /// another item).
    var minimumLineHeight: CGFloat?

    static let plain = TextLook()

    init(
        monospaced: Bool = false, lineHeightMultiple: CGFloat? = nil, firstLineIndent: CGFloat = 0,
        minimumLineHeight: CGFloat? = nil
    ) {
        self.monospaced = monospaced
        self.lineHeightMultiple = lineHeightMultiple
        self.firstLineIndent = firstLineIndent
        self.minimumLineHeight = minimumLineHeight
    }

    /// Fixed line pitch at `fontSize` (quarter points, so whole rows add up exactly), or nil.
    func fixedLineHeight(fontSize: CGFloat) -> CGFloat? {
        if let multiple = lineHeightMultiple, multiple > 0 {
            return max(1, (fontSize * multiple * 4).rounded() / 4)
        }
        guard let minimum = minimumLineHeight, minimum > 0,
            TextFitter.naturalLineHeight(TextFitter.font(ofSize: fontSize, monospaced: monospaced)) < minimum
        else { return nil }
        return (minimum * 4).rounded(.up) / 4
    }
}

/// Finds the largest font size in [minFontSize, maxFontSize] at which a text, wrapped to the box width,
/// fits the box. Sizes are searched on a `step` grid with a binary search; results and measurements are cached.
///
/// Measuring and drawing both go through NSStringDrawing with the same attributes and options
/// (`attributedString(_:fontSize:color:look:)`, `drawingOptions`), so what fits here fits when drawn:
/// a fitting text's measured (rounded-up) height never exceeds the box height.
/// Not thread-safe: the overlay uses one instance on the main thread.
final class TextFitter {
    /// (text, fontSize, maxWidth) -> size of the wrapped text in the plain look.
    typealias Measure = (_ text: String, _ fontSize: CGFloat, _ maxWidth: CGFloat) -> CGSize
    /// (text, fontSize, maxWidth, look) -> size of the wrapped text.
    typealias StyledMeasure = (_ text: String, _ fontSize: CGFloat, _ maxWidth: CGFloat, _ look: TextLook) -> CGSize
    /// (text, fontSize, maxWidth, look) -> width of the wrapped text's last line.
    typealias LastLineMeasure = (_ text: String, _ fontSize: CGFloat, _ maxWidth: CGFloat, _ look: TextLook) -> CGFloat

    let step: CGFloat
    let cacheLimit: Int
    /// Number of calls to the measure function (cache misses). Used by tests.
    private(set) var measureCount = 0

    private let measureFunction: StyledMeasure
    private let lastLineFunction: LastLineMeasure
    private var fitCache: [FitKey: TextFit] = [:]
    private var sizeCache: [SizeKey: CGSize] = [:]
    private var lastLineCache: [SizeKey: CGFloat] = [:]

    init(step: CGFloat = 0.5, cacheLimit: Int = 4000, measure: Measure? = nil) {
        self.step = max(step, 0.05)
        self.cacheLimit = max(cacheLimit, 16)
        if let measure {
            self.measureFunction = { text, size, width, _ in measure(text, size, width) }
        } else {
            self.measureFunction = { TextFitter.measureSystemText($0, fontSize: $1, maxWidth: $2, look: $3) }
        }
        lastLineFunction = { TextFitter.measureLastLineWidth($0, fontSize: $1, maxWidth: $2, look: $3) }
    }

    /// `lastLineWidth`: the same text model's last line (tests); nil = TextKit's.
    init(
        step: CGFloat = 0.5, cacheLimit: Int = 4000, styledMeasure: @escaping StyledMeasure,
        lastLineWidth: LastLineMeasure? = nil
    ) {
        self.step = max(step, 0.05)
        self.cacheLimit = max(cacheLimit, 16)
        self.measureFunction = styledMeasure
        lastLineFunction =
            lastLineWidth ?? { TextFitter.measureLastLineWidth($0, fontSize: $1, maxWidth: $2, look: $3) }
    }

    func fit(
        _ text: String, in box: CGSize, minFontSize: CGFloat, maxFontSize: CGFloat, look: TextLook = .plain
    ) -> TextFit {
        // Swapped bounds are treated as the same range.
        let lower = max(1, min(minFontSize, maxFontSize))
        let upper = max(lower, minFontSize, maxFontSize)
        // Quantize the box down so cached results stay valid for boxes a fraction larger.
        let width = Self.quantizeDown(max(box.width, 0))
        let height = Self.quantizeDown(max(box.height, 0))
        if text.isEmpty {
            return TextFit(fontSize: upper, textSize: .zero, fits: true)
        }

        let key = FitKey(
            text: text, width: Self.units(width), height: Self.units(height),
            min: Self.units(lower), max: Self.units(upper), look: look)
        if let cached = fitCache[key] { return cached }

        let stepCount = Int(((upper - lower) / step).rounded(.up))
        func size(_ i: Int) -> CGFloat { i >= stepCount ? upper : lower + CGFloat(i) * step }
        func attempt(_ i: Int) -> (CGSize, Bool) {
            let s = measure(text, fontSize: size(i), maxWidth: width, look: look)
            // Measurements are rounded up to whole points. The text is wrapped to `width`, so a rounded width
            // may exceed it by up to 0.5; the height gets no slack: multi-line text is drawn into the box
            // itself, and a line that does not fit there is dropped.
            return (s, s.width <= width + 0.5 && s.height <= height)
        }

        let result: TextFit
        let top = attempt(stepCount)
        if top.1 {
            result = TextFit(fontSize: upper, textSize: top.0, fits: true)
        } else {
            let bottom = attempt(0)
            if !bottom.1 {
                result = TextFit(fontSize: lower, textSize: bottom.0, fits: false)
            } else {
                // Invariant: size(lo) fits, size(hi) does not.
                var lo = 0
                var hi = stepCount
                var loSize = bottom.0
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    let m = attempt(mid)
                    if m.1 {
                        lo = mid
                        loSize = m.0
                    } else {
                        hi = mid
                    }
                }
                result = TextFit(fontSize: size(lo), textSize: loSize, fits: true)
            }
        }

        if fitCache.count >= cacheLimit { fitCache.removeAll(keepingCapacity: true) }
        fitCache[key] = result
        return result
    }

    /// Size of `text` wrapped to `maxWidth` at `fontSize` (cached). With a fixed line pitch the height is
    /// exactly rows × pitch.
    func measure(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, look: TextLook = .plain) -> CGSize {
        let key = SizeKey(text: text, fontSize: Self.units(fontSize), width: Self.units(maxWidth), look: look)
        if let cached = sizeCache[key] { return cached }
        measureCount += 1
        let size = measureFunction(text, fontSize, maxWidth, look)
        if sizeCache.count >= cacheLimit { sizeCache.removeAll(keepingCapacity: true) }
        sizeCache[key] = size
        return size
    }

    /// Width of the last line of `text` wrapped to `maxWidth` (cached; TextKit, as NSStringDrawing lays it out).
    func lastLineWidth(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, look: TextLook = .plain) -> CGFloat {
        let key = SizeKey(text: text, fontSize: Self.units(fontSize), width: Self.units(maxWidth), look: look)
        if let cached = lastLineCache[key] { return cached }
        let width = lastLineFunction(text, fontSize, maxWidth, look)
        if lastLineCache.count >= cacheLimit { lastLineCache.removeAll(keepingCapacity: true) }
        lastLineCache[key] = width
        return width
    }

    /// Height of one line of text at `fontSize`.
    func lineHeight(fontSize: CGFloat, look: TextLook = .plain) -> CGFloat {
        if let fixed = look.fixedLineHeight(fontSize: fontSize) { return fixed }
        var single = look
        single.firstLineIndent = 0
        return measure("Agあ", fontSize: fontSize, maxWidth: .greatestFiniteMagnitude, look: single).height
    }

    func removeAllCachedValues() {
        fitCache.removeAll()
        sizeCache.removeAll()
        lastLineCache.removeAll()
    }

    // MARK: - Text attributes shared by measuring and drawing

    static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin]

    static func font(ofSize size: CGFloat, monospaced: Bool = false) -> NSFont {
        // Japanese glyphs fall back to Hiragino Sans through the system fonts' cascade lists.
        monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
    }

    /// Height TextKit gives one line of `font` when nothing forces it (17 for the 14pt system font).
    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    // Never mutated after creation.
    nonisolated(unsafe) static let paragraphStyle: NSParagraphStyle = makeParagraphStyle(lineHeight: nil, indent: 0)

    private static func makeParagraphStyle(lineHeight: CGFloat?, indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // Word wrapping breaks Latin text at spaces, CJK text between characters (with kinsoku rules),
        // and a word wider than the line by character.
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        if let lineHeight {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        style.firstLineHeadIndent = max(0, indent)
        return style
    }

    static func attributedString(
        _ text: String, fontSize: CGFloat, color: NSColor, look: TextLook = .plain
    ) -> NSAttributedString {
        let font = font(ofSize: fontSize, monospaced: look.monospaced)
        let lineHeight = look.fixedLineHeight(fontSize: fontSize)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if lineHeight == nil, look.firstLineIndent <= 0 {
            attributes[.paragraphStyle] = paragraphStyle
        } else {
            attributes[.paragraphStyle] = makeParagraphStyle(lineHeight: lineHeight, indent: look.firstLineIndent)
        }
        if let lineHeight {
            // A taller line puts its extra room above the glyphs; raising them by half centers them,
            // like CSS line-height does.
            let extra = lineHeight - naturalLineHeight(font)
            if extra > 0 { attributes[.baselineOffset] = extra.rounded() / 2 }
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func measureSystemText(
        _ text: String, fontSize: CGFloat, maxWidth: CGFloat, look: TextLook = .plain
    ) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let string = attributedString(text, fontSize: fontSize, color: .black, look: look)
        let rect = string.boundingRect(
            with: CGSize(width: max(maxWidth, 1), height: .greatestFiniteMagnitude), options: drawingOptions)
        if let lineHeight = look.fixedLineHeight(fontSize: fontSize) {
            // Whole rows: the layout stacks lines exactly `lineHeight` apart.
            let rows = max(1, Int((rect.height / lineHeight).rounded()))
            return CGSize(width: ceil(rect.width), height: CGFloat(rows) * lineHeight)
        }
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    static func measureLastLineWidth(
        _ text: String, fontSize: CGFloat, maxWidth: CGFloat, look: TextLook = .plain
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let storage = NSTextStorage(
            attributedString: attributedString(text, fontSize: fontSize, color: .black, look: look))
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: CGSize(width: max(maxWidth, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var last = CGRect.zero
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, used, _, _, _ in last = used
        }
        return ceil(last.maxX)
    }

    // MARK: - Keys

    private struct FitKey: Hashable {
        var text: String
        var width: Int
        var height: Int
        var min: Int
        var max: Int
        var look: TextLook
    }

    private struct SizeKey: Hashable {
        var text: String
        var fontSize: Int
        var width: Int
        var look: TextLook
    }

    /// Hundredths of a point; avoids float keys.
    private static func units(_ value: CGFloat) -> Int {
        let scaled = (value * 100).rounded()
        // Unbounded widths (e.g. .greatestFiniteMagnitude) share one key.
        guard scaled.isFinite, abs(scaled) < 1e15 else { return value > 0 ? Int.max : Int.min }
        return Int(scaled)
    }

    private static func quantizeDown(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return value }
        return (value * 2).rounded(.down) / 2
    }
}
