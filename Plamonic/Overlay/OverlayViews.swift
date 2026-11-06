import AppKit
import QuartzCore

/// One translation ready to draw, in the coordinates of the view that draws it.
struct OverlayDrawItem: Equatable {
    var layout: OverlayItemLayout
    var text: String
    var state: OverlayItemState
    var colors: OverlayItemColors = OverlayItemColors()
    /// Center of the draft dot (see `OverlayLayout.indicatorCenter`); nil = the background's top-right corner.
    var indicatorCenter: CGPoint? = nil
    /// Parts of `text` drawn as links (DESIGN §6.1). Empty = none.
    var links: [OverlayDrawLink] = []
    /// `linkIndex` of the link the pointer is over: every part of it is drawn with the hover look.
    var hoveredLink: Int? = nil
}

/// Draws items, shared by the per-window canvas and the popup.
enum OverlayRenderer {
    /// Radius of the draft dot.
    static let indicatorRadius: CGFloat = 1.5

    /// Popup background: rounded, with a hairline that separates it from whatever is below.
    static func drawPopupBackground(_ rect: CGRect, cornerRadius: CGFloat, palette: OverlayPalette) {
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        palette.background.setFill()
        path.fill()
        let inner = rect.insetBy(dx: 0.25, dy: 0.25)
        let border = NSBezierPath(roundedRect: inner, xRadius: max(0, radius - 0.25), yRadius: max(0, radius - 0.25))
        border.lineWidth = 0.5
        palette.border.setStroke()
        border.stroke()
    }

    static func drawText(
        _ text: String, in rect: CGRect, fontSize: CGFloat, look: TextLook = .plain, color: NSColor,
        colored parts: [(range: NSRange, color: NSColor, underlined: Bool)] = []
    ) {
        var string = TextFitter.attributedString(text, fontSize: fontSize, color: color, look: look)
        if !parts.isEmpty {
            // Color and underline do not change the layout: the text wraps exactly as measured.
            let styled = NSMutableAttributedString(attributedString: string)
            let length = styled.length
            for part in parts where part.range.location >= 0 && NSMaxRange(part.range) <= length {
                styled.addAttribute(.foregroundColor, value: part.color, range: part.range)
                if part.underlined {
                    styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: part.range)
                }
            }
            string = styled
        }
        string.draw(with: rect, options: TextFitter.drawingOptions.union(.truncatesLastVisibleLine), context: nil)
    }

    /// Small filled dot centered at `center` (draft state).
    static func drawDraftIndicator(at center: CGPoint, color: NSColor) {
        let r = indicatorRadius
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
    }

    /// The draft dot's fallback place: inside the top-right corner of the background.
    static func cornerIndicatorCenter(for background: OverlayBackgroundShape) -> CGPoint {
        let rect = background.rect
        let r = indicatorRadius
        return CGPoint(x: rect.maxX - 1.5 - r, y: rect.minY + min(1 + r, rect.height / 2))
    }

    /// Draws one item: a borderless background over the original's lines, then the text in the original's
    /// size and color (as resolved), then the draft dot. The hovered link is underlined in its own color like
    /// any underline of the text (same position and thickness); one underlined already gets a stronger color.
    static func drawItem(_ item: OverlayDrawItem, appearance: OverlayAppearance, systemIsDark: Bool) {
        let layout = item.layout
        let colors = OverlayPalette.resolve(item.colors, appearance: appearance, systemIsDark: systemIsDark)
        colors.background.setFill()
        NSBezierPath(cgPath: layout.background.path(cornerRadius: OverlayLayout.effectiveCornerRadius(appearance)))
            .fill()
        let streaming = item.state == .streaming
        let links = item.links.map { link in
            var color = OverlayPalette.linkColor(original: link.color, resolved: colors)
            var underlined = link.isUnderlined
            if link.linkIndex == item.hoveredLink {
                if underlined {
                    color = OverlayPalette.hoveredLinkColor(color, resolved: colors)
                } else {
                    underlined = true
                }
            }
            return (
                range: link.range, color: streaming ? color.withAlphaComponent(OverlayPalette.streamingTextAlpha) : color,
                underlined: underlined
            )
        }
        drawText(
            item.text, in: layout.textRect, fontSize: layout.fontSize, look: layout.look,
            color: streaming ? colors.streamingText : colors.text, colored: links)
        if item.state == .draft, appearance.showStateIndicator {
            drawDraftIndicator(
                at: item.indicatorCenter ?? cornerIndicatorCenter(for: layout.background), color: colors.indicator)
        }
    }
}

/// Container that fills an overlay panel. Draws nothing itself (no backing store).
final class OverlayContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws every translation of one target window. Sized to the union of the visible items (inside the clip),
/// so the layer's backing store stays small and drawing outside the clip is cut off by its bounds.
final class OverlayCanvasView: NSView {
    private(set) var items: [OverlayDrawItem] = []
    private(set) var appearanceSettings = OverlayAppearance()
    /// Bounds size when the content was last set. A partial redraw reuses the rest of the backing store,
    /// which is only valid while the size is unchanged.
    private var contentSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The canvas frame is the clip rect; views stopped clipping to bounds by default in macOS 14.
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Default length of `setContent`'s crossfade.
    static let crossfadeDuration: TimeInterval = 0.15

    /// Replaces the content. `crossfade` blends old and new contents briefly (draft -> final swaps, colors
    /// measured from the screen, an item fading out to show its original). When items only changed in place
    /// (streaming text, draft -> final), just their area is redrawn.
    func setContent(
        _ items: [OverlayDrawItem], appearance: OverlayAppearance, crossfade: Bool,
        duration: TimeInterval = crossfadeDuration
    ) {
        guard items != self.items || appearance != appearanceSettings else { return }
        let dirtyRect =
            appearance == appearanceSettings && bounds.size == contentSize
            ? Self.redrawRect(from: self.items, to: items) : nil
        if crossfade, let layer, !self.items.isEmpty || !items.isEmpty {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = duration
            layer.add(transition, forKey: "contents")
        }
        self.items = items
        appearanceSettings = appearance
        contentSize = bounds.size
        if let dirtyRect {
            setNeedsDisplay(dirtyRect)
        } else {
            needsDisplay = true
        }
    }

    /// The area to redraw when `old` is replaced by `new`: the old and new drawing bounds of every item that
    /// changed. nil (redraw everything) unless the same items, in the same order, changed in place.
    static func redrawRect(from old: [OverlayDrawItem], to new: [OverlayDrawItem]) -> CGRect? {
        guard old.count == new.count else { return nil }
        var rect = CGRect.null
        for (before, after) in zip(old, new) {
            guard before.layout.id == after.layout.id else { return nil }
            if before != after {
                rect = rect.union(before.layout.drawingBounds).union(after.layout.drawingBounds)
            }
        }
        return rect.isNull ? nil : rect
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else { return }
        NSBezierPath.clip(bounds)
        let systemIsDark = OverlayPalette.isDark(effectiveAppearance)
        // Every item reaching into the dirty area is redrawn in draw order, so edges composite as before.
        for item in items where item.layout.drawingBounds.intersects(dirtyRect) {
            OverlayRenderer.drawItem(item, appearance: appearanceSettings, systemIsDark: systemIsDark)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// What a popup shows.
struct OverlayPopupContent: Equatable {
    enum Parts: Equatable {
        /// The translation (hover style, selection, manual translations).
        case translation
        /// The original only (resting on a translation drawn in place, DESIGN §6.1).
        case original
        /// The full translation, then the original (a translation drawn in place but cut with "…").
        case translationAndOriginal
    }

    var translation: String
    var original: String
    var state: OverlayItemState
    var parts: Parts = .translation

    /// The translation as shown: the text, or a Japanese placeholder while there is none.
    var translationText: String {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .failed:
            return trimmed.isEmpty ? "翻訳できませんでした" : translation
        case .pending:
            return "翻訳中…"
        case .streaming, .draft, .final:
            return trimmed.isEmpty ? "翻訳中…" : translation
        }
    }

    /// The text actually drawn (measured as one text; the original goes on its own line after the translation).
    var displayText: String {
        switch parts {
        case .translation: return translationText
        case .original: return original
        case .translationAndOriginal: return translationText + "\n" + original
        }
    }

    /// UTF-16 range of the original in `displayText`, when it is shown.
    var originalRange: NSRange? {
        switch parts {
        case .translation: return nil
        case .original: return NSRange(location: 0, length: (original as NSString).length)
        case .translationAndOriginal:
            let start = (translationText as NSString).length + 1
            return NSRange(location: start, length: (original as NSString).length)
        }
    }

    /// The translation part is a placeholder ("翻訳中…").
    var isPlaceholder: Bool { parts != .original && translationText != translation }
}

/// Content of the popup panel.
final class OverlayPopupView: NSView {
    private(set) var content = OverlayPopupContent(translation: "", original: "", state: .pending)
    private(set) var layout: OverlayPopupLayout?
    private(set) var appearanceSettings = OverlayAppearance()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Returns true when something changed and the view needs to be redrawn.
    @discardableResult
    func setContent(_ content: OverlayPopupContent, layout: OverlayPopupLayout, appearance: OverlayAppearance)
        -> Bool
    {
        let local = OverlayPopupLayout(
            frame: CGRect(origin: .zero, size: layout.frame.size), textRect: layout.textRect,
            fontSize: layout.fontSize, side: layout.side)
        guard content != self.content || local != self.layout || appearance != appearanceSettings else {
            return false
        }
        self.content = content
        self.layout = local
        appearanceSettings = appearance
        setAccessibilityLabel(content.displayText)
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        var appearance = appearanceSettings
        // A popup sits over unrelated content, so keep it nearly opaque.
        appearance.backgroundOpacity = max(appearance.backgroundOpacity, 0.97)
        let palette = OverlayPalette.make(appearance: appearance, effectiveAppearance: effectiveAppearance)
        let bounds = self.bounds
        OverlayRenderer.drawPopupBackground(bounds, cornerRadius: OverlayLayout.popupCornerRadius, palette: palette)
        let color =
            content.isPlaceholder || content.state == .streaming ? palette.secondaryText : palette.text
        var parts: [(range: NSRange, color: NSColor, underlined: Bool)] = []
        if content.parts == .translationAndOriginal, let range = content.originalRange {
            // The original under the full translation, dimmer.
            parts.append((range, palette.secondaryText, false))
        }
        OverlayRenderer.drawText(
            content.displayText, in: layout.textRect, fontSize: layout.fontSize,
            color: content.parts == .original ? palette.text : color, colored: parts)
        if content.state == .draft, content.parts != .original, appearanceSettings.showStateIndicator {
            OverlayRenderer.drawDraftIndicator(
                at: CGPoint(x: bounds.maxX - 6, y: bounds.minY + 6), color: palette.indicator.withAlphaComponent(0.8))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
