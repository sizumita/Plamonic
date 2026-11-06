import AppKit

// Off-screen render of the overlay look (no windows, nothing on screen): synthetic "app" pages are typeset
// with TextKit, their line rectangles are taken the way the extraction reports them (one AX-like rect per
// line, a paragraph split mid-line into two items included), and the translations are laid out with
// OverlayLayout and drawn with OverlayCanvasView on top. Each scene is rendered three times: with colors
// "measured from the screen" (the page's own colors), without (the palette, dark or light by the original
// text color), and with the original's look not matched (sizes fitted to the original's area).

/// One paragraph of a synthetic page. `splitAt` cuts it into two items at that character (mid-line),
/// like Chromium does when a paragraph is split by an inline element.
struct DemoParagraph {
    var text: String
    var translations: [String]
    var states: [OverlayItemState]
    var splitAt: Int? = nil
    /// Report the original's size to the overlay (false = unknown size: the min…max fitting).
    var reportsStyle = true
    /// The element is as wide as its text (a label), not the whole column (a paragraph).
    var tightFrame = false
    var indent: CGFloat = 0
    var gapAfter: CGFloat = 10
    var prefix: String? = nil
}

struct DemoScene {
    var name: String
    var size: CGSize
    var background: RGBAColor
    var textColor: RGBAColor
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var monospaced: Bool
    var width: CGFloat
    var paragraphs: [DemoParagraph]
}

@MainActor
enum DemoScenes {
    static func scenes() -> [DemoScene] {
        [
            DemoScene(
                name: "chat-dark", size: CGSize(width: 560, height: 420),
                background: RGBAColor(red: 0.149, green: 0.149, blue: 0.141),
                textColor: RGBAColor(red: 0.91, green: 0.90, blue: 0.87), fontSize: 15, lineHeight: 24,
                monospaced: false, width: 480,
                paragraphs: [
                    DemoParagraph(
                        text: "The overlay now draws each translation in the original text size, starting at the first line of the original, so it reads like the app's own text instead of a card placed on top.",
                        translations: [
                            "オーバーレイは訳文を原文と同じ文字の大きさで、原文の 1 行目から描くようになりました。",
                            "上に貼った札ではなく、アプリ自身の文章のように読めます。",
                        ],
                        states: [.draft, .final], splitAt: 92, indent: 22, prefix: "1."),
                    DemoParagraph(
                        text: "When a translation is longer than the original, lines are added into the free space below, then the text is shrunk a little, and only then is the last line cut with an ellipsis.",
                        translations: [
                            "訳文が原文より長いときは、まず下の空いている場所に行を足し、次に少しだけ文字を小さくし、それでも入らないときに限って最後の行を「…」で切ります。全文はホバーで読めます。"
                        ],
                        states: [.final], indent: 22, prefix: "2."),
                    DemoParagraph(
                        text: "Items never cover each other.",
                        translations: ["項目どうしは決して重なりません。重なりそうなときは、前の項目を次の項目の上端で切り、長すぎる訳文は小さくするか省略します。"],
                        states: [.final], gapAfter: 6),
                    DemoParagraph(
                        text: "This paragraph is still waiting for its first translation, so its original stays visible.",
                        translations: [""], states: [.pending]),
                    DemoParagraph(
                        text: "Streaming output is drawn a little dimmer until the model finishes.",
                        translations: ["生成途中の訳文は、モデルが終わるまで少し"], states: [.streaming]),
                ]),
            DemoScene(
                name: "terminal", size: CGSize(width: 560, height: 260),
                background: RGBAColor(red: 0.08, green: 0.09, blue: 0.10),
                textColor: RGBAColor(red: 0.80, green: 0.86, blue: 0.80), fontSize: 12, lineHeight: 15,
                monospaced: true, width: 520,
                paragraphs: [
                    DemoParagraph(
                        text: "Compiling the overlay module with the new layout engine.", translations: ["新しいレイアウトでオーバーレイのモジュールをコンパイルしています。"],
                        states: [.final], gapAfter: 0),
                    DemoParagraph(
                        text: "warning: the sampler is not authorized; theme colors are used.",
                        translations: ["警告: 画面収録が許可されていないため、テーマの色を使います。"], states: [.draft], gapAfter: 0),
                    DemoParagraph(
                        text: "All 42 tests passed in 3.1 seconds.", translations: ["42 件のテストすべてに 3.1 秒で合格しました。"],
                        states: [.final], gapAfter: 0),
                    DemoParagraph(
                        text: "Next: run the smoke test against the fixture window and compare the screenshots line by line.",
                        translations: ["次に、フィクスチャのウインドウでスモークテストを実行し、スクリーンショットを 1 行ずつ比べます。"],
                        states: [.final], gapAfter: 0),
                ]),
            DemoScene(
                name: "notes-light", size: CGSize(width: 560, height: 300),
                background: RGBAColor(red: 1, green: 1, blue: 1),
                textColor: RGBAColor(red: 0.13, green: 0.13, blue: 0.14), fontSize: 13, lineHeight: 18,
                monospaced: false, width: 300,
                paragraphs: [
                    DemoParagraph(
                        text: "Settings", translations: ["設定"], states: [.final], tightFrame: true, gapAfter: 8),
                    DemoParagraph(
                        text: "OK", translations: ["了解（短いラベルの長い訳文）"], states: [.final], tightFrame: true,
                        gapAfter: 22),
                    DemoParagraph(
                        text: "A label whose size the app does not report is fitted between the minimum and maximum sizes.",
                        translations: ["アプリが文字の大きさを教えないラベルは、最小と最大のあいだの大きさで枠に合わせます。"],
                        states: [.final], reportsStyle: false, gapAfter: 8),
                    DemoParagraph(
                        text: "Failed items keep the original text visible.", translations: [""], states: [.failed]),
                ]),
        ]
    }

    // MARK: - Typesetting the synthetic page

    struct Placed {
        var input: OverlayLayoutInput
        var state: OverlayItemState
        var original: String
    }

    static func color(_ c: RGBAColor) -> NSColor { OverlayPalette.nsColor(c) }

    /// Draws the page into the current (flipped) context and returns its items as the extraction would.
    static func drawPage(_ scene: DemoScene) -> [Placed] {
        color(scene.background).setFill()
        CGRect(origin: .zero, size: scene.size).fill()
        let font =
            scene.monospaced
            ? NSFont.monospacedSystemFont(ofSize: scene.fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: scene.fontSize)
        let natural = TextFitter.naturalLineHeight(font)
        var placed: [Placed] = []
        var y: CGFloat = 16
        let x0: CGFloat = 20
        for (pi, paragraph) in scene.paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = scene.lineHeight
            style.maximumLineHeight = scene.lineHeight
            style.lineBreakMode = .byWordWrapping
            let storage = NSTextStorage(
                string: paragraph.text,
                attributes: [
                    .font: font, .foregroundColor: color(scene.textColor), .paragraphStyle: style,
                    .baselineOffset: max(0, (scene.lineHeight - natural) / 2),
                ])
            let manager = NSLayoutManager()
            let container = NSTextContainer(
                size: CGSize(width: scene.width - paragraph.indent, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            let origin = CGPoint(x: x0 + paragraph.indent, y: y)
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: origin)
            if let prefix = paragraph.prefix {
                NSAttributedString(string: prefix, attributes: storage.attributes(at: 0, effectiveRange: nil))
                    .draw(at: CGPoint(x: x0, y: y))
            }

            // Item character ranges: the whole paragraph, or two parts cut mid-line.
            let length = (paragraph.text as NSString).length
            var ranges = [NSRange(location: 0, length: length)]
            if let cut = paragraph.splitAt, cut > 0, cut < length {
                ranges = [NSRange(location: 0, length: cut), NSRange(location: cut, length: length - cut)]
            }
            for (ri, range) in ranges.enumerated() {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var lines: [CGRect] = []
                manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(lineGlyphs, glyphs)
                    guard part.length > 0 else { return }
                    let bounds = manager.boundingRect(forGlyphRange: part, in: container)
                    // AX reports the glyph box of a line (about the font's height), centered in its line.
                    let height = natural
                    lines.append(
                        CGRect(
                            x: origin.x + bounds.minX, y: origin.y + fragment.midY - height / 2,
                            width: bounds.width, height: height))
                }
                guard let first = lines.first else { continue }
                var frame = lines.dropFirst().reduce(first) { $0.union($1) }
                if !paragraph.tightFrame {
                    // A paragraph element spans its column, like Chromium's block elements.
                    let columnLeft = lines.count > 1 ? origin.x : frame.minX
                    frame = CGRect(
                        x: min(frame.minX, columnLeft), y: frame.minY,
                        width: origin.x + container.size.width - min(frame.minX, columnLeft), height: frame.height)
                }
                let translation = paragraph.translations[min(ri, paragraph.translations.count - 1)]
                let state = paragraph.states[min(ri, paragraph.states.count - 1)]
                let drawable = state != .pending && state != .failed && !translation.isEmpty
                let styleHint =
                    paragraph.reportsStyle
                    ? TextStyleHint(
                        fontSize: Double(scene.fontSize), lineHeight: Double(scene.lineHeight),
                        isMonospaced: scene.monospaced, textColor: scene.textColor)
                    : TextStyleHint(textColor: scene.textColor)
                placed.append(
                    Placed(
                        input: OverlayLayoutInput(
                            id: "p\(pi)-\(ri)", text: drawable ? translation : "", frame: frame,
                            lineFrames: paragraph.reportsStyle ? lines : [], style: styleHint, drawable: drawable),
                        state: state, original: (paragraph.text as NSString).substring(with: range)))
            }
            let used = manager.usedRect(for: container)
            y += used.height + paragraph.gapAfter
        }
        return placed
    }

    // MARK: - Rendering

    /// Renders every scene (with and without measured colors) as PNGs into `directory`. Returns the number of
    /// problems found (overlapping backgrounds, backgrounds over another item's original text).
    static func render(to directory: String) -> Int {
        var problems = 0
        let fitter = TextFitter()
        for scene in scenes() {
            // Measured colors, theme colors, and the original's look not matched (size from the min…max range,
            // which also draws split paragraphs from where their first line starts).
            for (variant, sampled, matched) in [("sampled", true, true), ("palette", false, true), ("unmatched", true, false)] {
                let scale: CGFloat = 2
                guard
                    let bitmap = CGContext(
                        data: nil, width: Int(scene.size.width * scale), height: Int(scene.size.height * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                bitmap.translateBy(x: 0, y: scene.size.height * scale)
                bitmap.scaleBy(x: scale, y: -scale)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)

                let placed = drawPage(scene)
                var appearance = OverlayAppearance()
                appearance.theme = .system
                appearance.matchOriginalStyle = matched
                let clip = CGRect(origin: .zero, size: scene.size)
                let inputs = placed.map(\.input)
                let layouts = OverlayLayout.layoutWindow(inputs, clip: clip, appearance: appearance, fitter: fitter)
                problems += check(layouts, inputs: inputs, scene: scene.name)

                let canvasRect = OverlayLayout.canvasRect(for: layouts, clip: clip)
                if !canvasRect.isNull {
                    let canvas = OverlayCanvasView(frame: canvasRect)
                    let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.input.id, $0) })
                    let items = OverlayLayout.drawOrder(layouts).map { layout -> OverlayDrawItem in
                        let item = byID[layout.id]!
                        let colors = OverlayItemColors(
                            sampled: sampled ? SampledColors(background: scene.background, text: scene.textColor) : nil,
                            originalText: item.input.style.textColor)
                        let local = layout.offsetBy(dx: -canvasRect.minX, dy: -canvasRect.minY)
                        return OverlayDrawItem(
                            layout: local, text: item.input.text, state: item.state, colors: colors,
                            indicatorCenter: item.state == .draft
                                ? OverlayLayout.indicatorCenter(for: local, text: item.input.text, fitter: fitter) : nil)
                    }
                    canvas.setContent(items, appearance: appearance, crossfade: false)
                    bitmap.saveGState()
                    bitmap.translateBy(x: canvasRect.minX, y: canvasRect.minY)
                    canvas.draw(canvas.bounds)
                    bitmap.restoreGState()
                }
                NSGraphicsContext.restoreGraphicsState()

                for layout in layouts {
                    let stage = layout.stage.rawValue
                    print(
                        "  \(scene.name) \(layout.id): \(stage) \(String(format: "%.1f", layout.fontSize))pt",
                        layout.look.monospaced ? "mono" : "", layout.background.hasNotch ? "notched" : "")
                }
                guard let image = bitmap.makeImage() else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let url = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(scene.name)-\(variant).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote", url.path)
            }
        }
        return problems
    }

    /// Backgrounds must not intersect each other or cover another item's original text.
    static func check(_ layouts: [OverlayItemLayout], inputs: [OverlayLayoutInput], scene: String) -> Int {
        var problems = 0
        for (i, a) in layouts.enumerated() {
            for b in layouts[(i + 1)...] where a.background.overlapArea(with: b.background) > 0.01 {
                print("PROBLEM \(scene): backgrounds of \(a.id) and \(b.id) intersect")
                problems += 1
            }
            for input in inputs where input.id != a.id {
                guard let (area, lines) = OverlayLayout.originalArea(of: input) else { continue }
                let covered = (lines.isEmpty ? [area] : lines).reduce(0) { $0 + a.background.overlapArea(with: $1) }
                if covered > 0.01 {
                    print("PROBLEM \(scene): \(a.id) covers the original text of \(input.id)")
                    problems += 1
                }
            }
        }
        return problems
    }
}
