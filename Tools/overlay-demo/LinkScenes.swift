import AppKit

// Off-screen render of translations with links (DESIGN §6.1), drawn by a real OverlayController (its panels are
// never ordered on screen): a synthetic page with links in the paragraphs, the items as the extraction and the
// translation report them (link ranges, frames, colors), then the controller's canvas on top. One item is
// revealed by "clicking" an original link hidden under it (the click panel's view gets a synthetic NSEvent; no
// real event is posted). The "-areas" PNG outlines the click panels: blue = translated links, red = original
// links kept from clicks. The "-hover-*" PNGs (1x and 2x) show a translated link under the pointer (its click
// panel's `simulateHover`, which never touches the real cursor): a short link and a URL wrapped over lines.

struct DemoLinkParagraph {
    var text: String
    /// Link texts in `text` (first occurrence each).
    var links: [String]
    var translation: String
    /// For each link: its text in the translation, or nil when the translation lost it.
    var translatedLinks: [String?]
    var state: OverlayItemState = .final
    /// Reveal this item with a click on one of its hidden original links.
    var reveal = false
    var gapAfter: CGFloat = 12
}

struct DemoLinkScene {
    var name: String
    var size: CGSize
    var background: RGBAColor
    var textColor: RGBAColor
    var linkColor: RGBAColor
    var underlined: Bool
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var width: CGFloat
    var paragraphs: [DemoLinkParagraph]
}

@MainActor
enum DemoLinkScenes {
    static func scenes() -> [DemoLinkScene] {
        let paragraphs = [
            DemoLinkParagraph(
                text: "Before you start, read the setup guide and the FAQ for the known problems.",
                links: ["setup guide", "FAQ"],
                translation: "始める前に、セットアップガイドと既知の問題の FAQ を読んでください。",
                translatedLinks: ["セットアップガイド", "FAQ"]),
            DemoLinkParagraph(
                text: "Full steps: https://example.com/docs/getting-started/install-on-macos?lang=en&ref=overlay-demo",
                links: ["https://example.com/docs/getting-started/install-on-macos?lang=en&ref=overlay-demo"],
                translation: "詳しい手順: https://example.com/docs/getting-started/install-on-macos?lang=en&ref=overlay-demo",
                translatedLinks: ["https://example.com/docs/getting-started/install-on-macos?lang=en&ref=overlay-demo"]),
            DemoLinkParagraph(
                text: "Ask @maria in #design if the colors look wrong.", links: ["@maria", "#design"],
                translation: "色がおかしいときは #design で @maria に聞いてください。", translatedLinks: ["@maria", "#design"],
                state: .draft),
            DemoLinkParagraph(
                text: "Click where the original link was to see the original and press it.",
                links: ["original link"],
                translation: "訳文で見つからないリンクは、その場所をクリックすれば原文から押せます。", translatedLinks: [nil]),
            DemoLinkParagraph(
                text: "This paragraph shows its original: a click on the hidden link revealed it.", links: ["hidden link"],
                translation: "この段落は原文を表示しています。", translatedLinks: [nil], reveal: true),
            DemoLinkParagraph(
                text: "Release notes", links: ["Release notes"], translation: "リリースノート",
                translatedLinks: ["リリースノート"], gapAfter: 8),
            DemoLinkParagraph(
                text: "A short line with a link.", links: ["link"],
                translation: "短い原文に長い訳文が入らないとき、末尾は「…」で切られ、切れた先のリンクは押せません。最後のリンクはここです。",
                translatedLinks: ["最後のリンク"], gapAfter: 0),
            DemoLinkParagraph(
                text: "Next item right below.", links: [], translation: "", translatedLinks: [], state: .pending),
        ]
        return [
            DemoLinkScene(
                name: "links-dark", size: CGSize(width: 520, height: 440),
                background: RGBAColor(red: 0.102, green: 0.114, blue: 0.129),
                textColor: RGBAColor(red: 0.82, green: 0.824, blue: 0.827),
                linkColor: RGBAColor(red: 0.114, green: 0.608, blue: 0.82), underlined: false, fontSize: 15,
                lineHeight: 22, width: 360, paragraphs: paragraphs),
            DemoLinkScene(
                name: "links-light", size: CGSize(width: 520, height: 440),
                background: RGBAColor(red: 1, green: 1, blue: 1),
                textColor: RGBAColor(red: 0.13, green: 0.13, blue: 0.14),
                linkColor: RGBAColor(red: 0.04, green: 0.35, blue: 0.75), underlined: true, fontSize: 14,
                lineHeight: 21, width: 360, paragraphs: paragraphs),
        ]
    }

    static func color(_ c: RGBAColor) -> NSColor { OverlayPalette.nsColor(c) }

    /// Draws the page into the current (flipped) context and returns its items as extraction + translation
    /// report them (AX = page coordinates).
    static func drawPage(_ scene: DemoLinkScene) -> [OverlayItem] {
        color(scene.background).setFill()
        CGRect(origin: .zero, size: scene.size).fill()
        let font = NSFont.systemFont(ofSize: scene.fontSize)
        let natural = TextFitter.naturalLineHeight(font)
        var items: [OverlayItem] = []
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
            let ns = paragraph.text as NSString
            let linkRanges = paragraph.links.map { ns.range(of: $0) }
            for range in linkRanges where range.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: color(scene.linkColor), range: range)
                if scene.underlined {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: scene.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            let origin = CGPoint(x: x0, y: y)
            manager.drawBackground(forGlyphRange: manager.glyphRange(for: container), at: origin)
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: origin)

            /// One AX-like rect per line for a character range: the glyph box, centered in its line.
            func lineRects(_ characters: NSRange) -> [CGRect] {
                let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                var rects: [CGRect] = []
                manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(lineGlyphs, glyphs)
                    guard part.length > 0 else { return }
                    let bounds = manager.boundingRect(forGlyphRange: part, in: container)
                    rects.append(
                        CGRect(
                            x: origin.x + bounds.minX, y: origin.y + fragment.midY - natural / 2, width: bounds.width,
                            height: natural))
                }
                return rects
            }
            let lines = lineRects(NSRange(location: 0, length: ns.length))
            guard let first = lines.first else { continue }
            var frame = lines.dropFirst().reduce(first) { $0.union($1) }
            frame = CGRect(x: origin.x, y: frame.minY, width: scene.width, height: frame.height)

            var originalLinks: [SegmentLink] = []
            var links: [OverlayLink] = []
            let translation = paragraph.translation as NSString
            for (li, range) in linkRanges.enumerated() where range.location != NSNotFound {
                let text = ns.substring(with: range)
                originalLinks.append(
                    SegmentLink(
                        range: range.location..<NSMaxRange(range), text: text, kind: .link,
                        url: text.hasPrefix("https://") ? URL(string: text) : nil, frames: lineRects(range),
                        color: scene.linkColor, isUnderlined: scene.underlined))
                if let translated = paragraph.translatedLinks[li] {
                    let at = translation.range(of: translated)
                    if at.location != NSNotFound {
                        links.append(OverlayLink(range: at.location..<NSMaxRange(at), linkIndex: originalLinks.count - 1))
                    }
                }
            }
            // A paragraph that is all link reports the link's color as its own (DESIGN §6.1).
            let allLink = linkRanges.count == 1 && linkRanges[0] == NSRange(location: 0, length: ns.length)
            items.append(
                OverlayItem(
                    id: "p\(pi)", axFrame: frame, original: paragraph.text, translation: paragraph.translation,
                    state: paragraph.state,
                    style: TextStyleHint(
                        fontSize: Double(scene.fontSize), lineHeight: Double(scene.lineHeight),
                        textColor: allLink ? scene.linkColor : scene.textColor),
                    lineFrames: lines, originalLinks: originalLinks, links: links))
            y += manager.usedRect(for: container).height + paragraph.gapAfter
        }
        return items
    }

    /// Renders every link scene into `directory` (`<name>.png` and `<name>-areas.png`). Returns the number of
    /// problems found (a revealed item still drawn, a link without a click area, click areas outside an item).
    static func render(to directory: String) -> Int {
        var problems = 0
        for scene in scenes() {
            for withAreas in [false, true] {
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

                let items = drawPage(scene)
                let controller = OverlayController()
                let key = WindowKey(pid: getpid(), windowID: 900)
                var appearance = OverlayAppearance()
                appearance.theme = .system
                let style = OverlayStyle(displayStyle: .replace, appearance: appearance)
                controller.update(
                    window: key, axWindowFrame: CGRect(origin: .zero, size: scene.size), axClipRect: nil,
                    cgWindowID: nil, items: items, style: style, targetIsFrontmost: false)
                // Reveal: "click" a hidden original link of the item that asks for it.
                for item in items where scene.paragraphs[Int(item.id.dropFirst())!].reveal {
                    guard
                        let panel = controller.clickPanels(window: key).first(where: {
                            $0.target?.itemID == item.id && $0.target?.kind == .blocker
                        }),
                        let event = NSEvent.mouseEvent(
                            with: .leftMouseDown, location: CGPoint(x: 2, y: 2), modifierFlags: [], timestamp: 0,
                            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    else {
                        print("PROBLEM \(scene.name): no blocker panel to reveal \(item.id)")
                        problems += 1
                        continue
                    }
                    panel.clickView.mouseDown(with: event)
                    if controller.revealedItem?.id != item.id {
                        print("PROBLEM \(scene.name): \(item.id) was not revealed")
                        problems += 1
                    }
                }
                if let canvas = controller.canvasView(window: key), !canvas.frame.isEmpty {
                    bitmap.saveGState()
                    bitmap.translateBy(x: canvas.frame.minX, y: canvas.frame.minY)
                    canvas.draw(canvas.bounds)
                    bitmap.restoreGState()
                }
                let drawn = controller.contentItems(window: key)
                let areas = controller.activeClickAreas(window: key)
                if withAreas {
                    for area in areas {
                        (area.isLink ? NSColor.systemBlue : NSColor.systemRed).withAlphaComponent(0.9).setStroke()
                        let path = NSBezierPath(rect: area.rect.insetBy(dx: 0.25, dy: 0.25))
                        path.lineWidth = 0.5
                        path.stroke()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                problems += check(scene: scene.name, items: items, drawn: drawn, areas: areas, controller: controller)

                if !withAreas {
                    for item in drawn {
                        let links = item.links.map { (item.text as NSString).substring(with: $0.range) }
                        print(
                            "  \(scene.name) \(item.layout.id): \(item.layout.stage.rawValue)",
                            String(format: "%.1fpt", item.layout.fontSize), "links:", links)
                    }
                    let counts = controller.clickPanelCounts(window: key)
                    print("  \(scene.name) click panels: \(counts.links) links, \(counts.blockers) blockers")
                }
                controller.removeAll()
                guard let image = bitmap.makeImage() else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let url = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(scene.name)\(withAreas ? "-areas" : "").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote", url.path)
            }
        }
        renderPopups(to: directory)
        problems += renderHovers(to: directory)
        return problems
    }

    /// What a hover change redraws (just the item), in milliseconds: drawn 20 times into a scratch 2x bitmap.
    static func redrawTime(_ item: OverlayDrawItem, appearance: OverlayAppearance) -> Double {
        let rect = item.layout.drawingBounds
        guard
            let scratch = CGContext(
                data: nil, width: Int(ceil(rect.maxX * 2)) + 2, height: Int(ceil(rect.maxY * 2)) + 2,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        scratch.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: scratch, flipped: true)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { OverlayRenderer.drawItem(item, appearance: appearance, systemIsDark: false) }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 20
        NSGraphicsContext.restoreGraphicsState()
        return ms
    }

    /// The hover look of a translated link (DESIGN §6.1): `<scene>-hover-<link>@<scale>x.png`. Returns the number
    /// of problems (no look, a look on another item, a look left after the pointer left).
    static func renderHovers(to directory: String) -> Int {
        var problems = 0
        // (paragraph, link index, name)
        let targets = [(0, 0, "guide"), (1, 0, "url")]
        for scene in scenes() {
            for (paragraph, linkIndex, name) in targets {
                for scale: CGFloat in [1, 2] {
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
                    let items = drawPage(scene)
                    let controller = OverlayController()
                    let key = WindowKey(pid: getpid(), windowID: 901)
                    var appearance = OverlayAppearance()
                    appearance.theme = .system
                    controller.update(
                        window: key, axWindowFrame: CGRect(origin: .zero, size: scene.size), axClipRect: nil,
                        cgWindowID: nil, items: items, style: OverlayStyle(displayStyle: .replace, appearance: appearance),
                        targetIsFrontmost: false)
                    let id = "p\(paragraph)"
                    let pieces = controller.clickPanels(window: key).filter {
                        $0.target?.itemID == id && $0.target?.kind == .link(linkIndex)
                    }
                    pieces.first?.clickView.simulateHover(true)
                    let drawn = controller.contentItems(window: key)
                    let looks = drawn.compactMap { item in item.hoveredLink.map { (item.layout.id, $0) } }
                    if looks.count != 1 || looks.first?.0 != id || looks.first?.1 != linkIndex {
                        print("PROBLEM \(scene.name) hover \(name): look on \(looks) (pieces \(pieces.count))")
                        problems += 1
                    }
                    if let canvas = controller.canvasView(window: key), !canvas.frame.isEmpty {
                        bitmap.saveGState()
                        bitmap.translateBy(x: canvas.frame.minX, y: canvas.frame.minY)
                        canvas.draw(canvas.bounds)
                        bitmap.restoreGState()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    if scale == 2, let item = drawn.first(where: { $0.layout.id == id }) {
                        print(
                            "  \(scene.name) hover \(name): \(pieces.count) pieces,",
                            String(format: "item redraw %.2f ms", redrawTime(item, appearance: appearance)))
                    }
                    pieces.first?.clickView.simulateHover(false)
                    if controller.contentItems(window: key).contains(where: { $0.hoveredLink != nil }) {
                        print("PROBLEM \(scene.name) hover \(name): the look stays after the pointer left")
                        problems += 1
                    }
                    controller.removeAll()
                    guard let image = bitmap.makeImage() else { continue }
                    let url = URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(scene.name)-hover-\(name)@\(Int(scale))x.png")
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    print("wrote", url.path)
                }
            }
        }
        return problems
    }

    /// The hover popup's contents (DESIGN §6.1): the original alone (resting on a translation, popup mode), and
    /// a cut translation's full text with the original under it. Written to `popups.png`.
    static func renderPopups(to directory: String) {
        let size = CGSize(width: 560, height: 260)
        let scale: CGFloat = 2
        guard
            let bitmap = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        bitmap.translateBy(x: 0, y: size.height * scale)
        bitmap.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        NSColor(white: 0.93, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let fitter = TextFitter()
        var appearance = OverlayAppearance()
        appearance.theme = .light
        let contents = [
            OverlayPopupContent(
                translation: "始める前に、セットアップガイドを読んでください。",
                original: "Before you start, read the setup guide.", state: .final, parts: .original),
            OverlayPopupContent(
                translation: "短い原文に長い訳文が入らないとき、末尾は「…」で切られます。全文と原文はここで読めます。",
                original: "A short line with a link.", state: .draft, parts: .translationAndOriginal),
        ]
        var y: CGFloat = 16
        for content in contents {
            let layout = OverlayLayout.popup(
                text: content.displayText, anchor: CGRect(x: 16, y: y - 6 - 1, width: 300, height: 1),
                screen: CGRect(origin: .zero, size: size), appearance: appearance, fitter: fitter)
            let view = OverlayPopupView(frame: CGRect(origin: .zero, size: layout.frame.size))
            view.appearance = NSAppearance(named: .aqua)
            view.setContent(content, layout: layout, appearance: appearance)
            bitmap.saveGState()
            bitmap.translateBy(x: layout.frame.minX, y: layout.frame.minY)
            view.draw(view.bounds)
            bitmap.restoreGState()
            y = layout.frame.maxY + 20
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.makeImage() else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("popups.png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("wrote", url.path)
    }

    static func check(
        scene: String, items: [OverlayItem], drawn: [OverlayDrawItem], areas: [OverlayHitArea],
        controller: OverlayController
    ) -> Int {
        var problems = 0
        if let revealed = controller.revealedItem, drawn.contains(where: { $0.layout.id == revealed.id }) {
            print("PROBLEM \(scene): revealed \(revealed.id) is still drawn")
            problems += 1
        }
        for item in drawn {
            for link in item.links where !areas.contains(where: { $0.itemID == item.layout.id && $0.kind == .link(link.linkIndex) }) {
                print("PROBLEM \(scene): link \(link.linkIndex) of \(item.layout.id) has no click area")
                problems += 1
            }
        }
        // Right after a reveal the item's areas stay as blockers for a double-click interval (nothing else).
        for area in areas where controller.revealedItem?.id == area.itemID {
            guard area.isLink || controller.guardedItem?.id != area.itemID else { continue }
            print("PROBLEM \(scene): \(area.itemID) is revealed but keeps a click panel")
            problems += 1
        }
        return problems
    }
}
