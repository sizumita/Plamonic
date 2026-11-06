import AppKit
import XCTest

@testable import Plamonic

final class OverlayLayoutTests: XCTestCase {
    private let window = CGRect(x: 100, y: 200, width: 800, height: 600)
    private let appearance = OverlayAppearance()

    private func item(_ state: OverlayItemState, _ translation: String = "訳文") -> OverlayItem {
        OverlayItem(id: "a", axFrame: .zero, original: "original", translation: translation, state: state)
    }

    func testDrawableStates() {
        XCTAssertFalse(OverlayLayout.isDrawable(item(.pending)))
        XCTAssertFalse(OverlayLayout.isDrawable(item(.failed)))
        XCTAssertTrue(OverlayLayout.isDrawable(item(.streaming)))
        XCTAssertTrue(OverlayLayout.isDrawable(item(.draft)))
        XCTAssertTrue(OverlayLayout.isDrawable(item(.final)))
        XCTAssertFalse(OverlayLayout.isDrawable(item(.streaming, " \n")))
        // The same text as the original (only the spacing differs) leaves the original visible.
        XCTAssertFalse(OverlayLayout.isDrawable(item(.final, " original\n")))
        XCTAssertFalse(OverlayLayout.isDrawable(item(.draft, "original")))
        XCTAssertTrue(OverlayLayout.isDrawable(item(.streaming, "origin")))
    }

    func testLocalRectAndClip() {
        XCTAssertEqual(
            OverlayLayout.localRect(CGRect(x: 150, y: 260, width: 50, height: 20), windowAXFrame: window),
            CGRect(x: 50, y: 60, width: 50, height: 20))
        XCTAssertEqual(
            OverlayLayout.localClip(axClipRect: CGRect(x: 150, y: 260, width: 500, height: 400), windowAXFrame: window),
            CGRect(x: 50, y: 60, width: 500, height: 400))
        XCTAssertEqual(
            OverlayLayout.localClip(axClipRect: nil, windowAXFrame: window), CGRect(x: 0, y: 0, width: 800, height: 600))
        // A clip reaching outside the window is cut to the window.
        XCTAssertEqual(
            OverlayLayout.localClip(axClipRect: CGRect(x: 0, y: 700, width: 2000, height: 500), windowAXFrame: window),
            CGRect(x: 0, y: 500, width: 800, height: 100))
        XCTAssertNil(OverlayLayout.localClip(axClipRect: CGRect(x: 0, y: 0, width: 50, height: 50), windowAXFrame: window))
    }

    func testFittingItemCoversFrameWithPadding() throws {
        let fitter = TextFitter()
        let frame = CGRect(x: 40, y: 80, width: 300, height: 18)
        let clip = CGRect(x: 0, y: 0, width: 800, height: 600)
        let layout = try XCTUnwrap(
            OverlayLayout.layoutItem(id: "a", text: "こんにちは", frame: frame, clip: clip, appearance: appearance, fitter: fitter))
        XCTAssertFalse(layout.overflows)
        // Only the original's area, with a little horizontal padding and none vertically.
        XCTAssertEqual(layout.backgroundRect, frame.insetBy(dx: -1.5, dy: 0))
        XCTAssertEqual(layout.visibleRect, layout.backgroundRect)
        XCTAssertGreaterThanOrEqual(layout.fontSize, 9)
        XCTAssertLessThanOrEqual(layout.fontSize, 16)
        // Single line: centered vertically inside the frame.
        XCTAssertGreaterThanOrEqual(layout.textRect.minY, frame.minY)
        XCTAssertLessThanOrEqual(layout.textRect.maxY, frame.maxY + 0.5)
    }

    func testFittedTextIsNeverCutOff() {
        // Text that fits is drawn into its text rect with the last visible line truncated, so the rect must
        // hold every wrapped line. Box heights in 0.1pt steps hit the fitter's rounding boundaries.
        let fitter = TextFitter()
        let text = "翻訳された文章が枠の中で何行かに折り返されても、最後の行まで欠けずに表示されることを確かめます。"
        let clip = CGRect(x: 0, y: 0, width: 800, height: 600)
        var checked = 0
        var cutOff: [CGSize] = []
        for width in stride(from: 80.0, through: 200.0, by: 30.0) {
            for height in stride(from: 12.0, through: 80.0, by: 0.1) {
                let frame = CGRect(x: 10, y: 10, width: width, height: height)
                guard
                    let layout = OverlayLayout.layoutItem(
                        id: "a", text: text, frame: frame, clip: clip, appearance: appearance, fitter: fitter),
                    !layout.overflows
                else { continue }
                checked += 1
                let needed = TextFitter.measureSystemText(
                    text, fontSize: layout.fontSize, maxWidth: layout.textRect.width)
                if needed.height > layout.textRect.height { cutOff.append(frame.size) }
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(cutOff.count, 0, "text rect shorter than the text, e.g. in \(cutOff.first.map { "\($0)" } ?? "")")
    }

    func testOverflowExtendsBackgroundDownward() throws {
        let fitter = TextFitter()
        let frame = CGRect(x: 40, y: 80, width: 60, height: 14)
        let clip = CGRect(x: 0, y: 0, width: 800, height: 600)
        let text = "とても長い翻訳結果なので、最小の文字サイズでも元の枠には収まりません。"
        let layout = try XCTUnwrap(
            OverlayLayout.layoutItem(id: "a", text: text, frame: frame, clip: clip, appearance: appearance, fitter: fitter))
        XCTAssertEqual(layout.stage, .extended)
        XCTAssertEqual(layout.fontSize, 9)
        XCTAssertEqual(layout.backgroundRect.minY, frame.minY)
        XCTAssertEqual(layout.backgroundRect.minX, frame.minX - 1.5)
        XCTAssertEqual(layout.backgroundRect.width, frame.width + 3)
        XCTAssertGreaterThan(layout.backgroundRect.height, frame.height)
        XCTAssertEqual(layout.textRect.height, layout.backgroundRect.height)
    }

    func testOverflowStopsAtTheClipAndTruncates() throws {
        let fitter = TextFitter()
        let frame = CGRect(x: 40, y: 580, width: 60, height: 14)
        let clip = CGRect(x: 0, y: 0, width: 800, height: 600)
        let layout = try XCTUnwrap(
            OverlayLayout.layoutItem(
                id: "a", text: String(repeating: "長い文章", count: 20), frame: frame, clip: clip,
                appearance: appearance, fitter: fitter))
        XCTAssertEqual(layout.stage, .truncated)
        XCTAssertEqual(layout.visibleRect.maxY, 600)
        // Lines are never added outside the clip.
        XCTAssertEqual(layout.backgroundRect.maxY, 600)
        XCTAssertLessThanOrEqual(layout.textRect.maxY, 600)
    }

    func testPartiallyAndFullyClippedItems() throws {
        let fitter = TextFitter()
        let clip = CGRect(x: 0, y: 100, width: 800, height: 300)
        let partial = try XCTUnwrap(
            OverlayLayout.layoutItem(
                id: "a", text: "訳", frame: CGRect(x: 10, y: 90, width: 100, height: 40), clip: clip,
                appearance: appearance, fitter: fitter))
        XCTAssertEqual(partial.visibleRect.minY, 100)
        XCTAssertEqual(partial.backgroundRect.minY, 90)
        XCTAssertNil(
            OverlayLayout.layoutItem(
                id: "b", text: "訳", frame: CGRect(x: 10, y: 20, width: 100, height: 40), clip: clip,
                appearance: appearance, fitter: fitter))
        // Off-screen placeholders in virtual lists are 1pt high.
        XCTAssertNil(
            OverlayLayout.layoutItem(
                id: "c", text: "訳", frame: CGRect(x: 10, y: 150, width: 100, height: 1), clip: clip,
                appearance: appearance, fitter: fitter))
    }

    func testDrawOrderPutsOverflowLast() {
        func layout(_ id: String, _ overflows: Bool) -> OverlayItemLayout {
            OverlayItemLayout(
                id: id, backgroundRect: .zero, textRect: .zero, fontSize: 9, overflows: overflows, visibleRect: .zero)
        }
        let ordered = OverlayLayout.drawOrder([layout("a", true), layout("b", false), layout("c", false)])
        XCTAssertEqual(ordered.map(\.id), ["b", "c", "a"])
    }

    func testCanvasRect() {
        let clip = CGRect(x: 0, y: 50, width: 400, height: 300)
        func layout(_ visible: CGRect) -> OverlayItemLayout {
            OverlayItemLayout(
                id: "x", backgroundRect: visible, textRect: visible, fontSize: 9, overflows: false, visibleRect: visible)
        }
        XCTAssertTrue(OverlayLayout.canvasRect(for: [], clip: clip).isNull)
        let rect = OverlayLayout.canvasRect(
            for: [layout(CGRect(x: 10, y: 60, width: 100, height: 20)), layout(CGRect(x: 200, y: 300, width: 100, height: 40))],
            clip: clip)
        XCTAssertEqual(rect, CGRect(x: 7, y: 57, width: 296, height: 286))
        // Kept inside the clip.
        let edge = OverlayLayout.canvasRect(for: [layout(CGRect(x: 0, y: 50, width: 400, height: 300))], clip: clip)
        XCTAssertEqual(edge, clip)
    }

    // MARK: - Canvas redraws

    @MainActor
    func testRedrawRectCoversOnlyChangedItems() {
        func item(_ id: String, _ rect: CGRect, _ text: String = "訳") -> OverlayDrawItem {
            OverlayDrawItem(
                layout: OverlayItemLayout(
                    id: id, backgroundRect: rect, textRect: rect, fontSize: 12, overflows: false, visibleRect: rect),
                text: text, state: .streaming)
        }
        let a = item("a", CGRect(x: 0, y: 0, width: 50, height: 20))
        let b = item("b", CGRect(x: 0, y: 40, width: 50, height: 20))
        // Streaming text: only b's area, with room for the indicator.
        XCTAssertEqual(
            OverlayCanvasView.redrawRect(from: [a, b], to: [a, item("b", b.layout.visibleRect, "訳文")]),
            CGRect(x: -3, y: 37, width: 56, height: 26))
        // A background that grew is covered before and after.
        XCTAssertEqual(
            OverlayCanvasView.redrawRect(from: [a, b], to: [a, item("b", CGRect(x: 0, y: 40, width: 50, height: 40))]),
            CGRect(x: -3, y: 37, width: 56, height: 46))
        // Added, removed or reordered items redraw everything.
        XCTAssertNil(OverlayCanvasView.redrawRect(from: [a, b], to: [a]))
        XCTAssertNil(OverlayCanvasView.redrawRect(from: [a], to: [a, b]))
        XCTAssertNil(OverlayCanvasView.redrawRect(from: [a, b], to: [b, a]))
    }

    /// Canvas-local items laid out together: A (draft) left of C (streaming), B above C. B's translation
    /// is too long for its line and may only grow until C's top.
    private func canvasItems(c text: String, fitter: TextFitter) throws -> [OverlayDrawItem] {
        let clip = CGRect(x: 0, y: 0, width: 300, height: 160)
        let inputs = [
            OverlayLayoutInput(id: "a", text: "左の訳文", frame: CGRect(x: 10, y: 30, width: 90, height: 20)),
            OverlayLayoutInput(id: "c", text: text, frame: CGRect(x: 108, y: 30, width: 150, height: 20)),
            OverlayLayoutInput(
                id: "b", text: "上の項目の長い訳文は元の枠に収まらず下へ広がります", frame: CGRect(x: 108, y: 6, width: 60, height: 14)),
        ]
        let states: [String: OverlayItemState] = ["a": .draft, "c": .streaming, "b": .final]
        let layouts = OverlayLayout.layoutWindow(inputs, clip: clip, appearance: appearance, fitter: fitter)
        XCTAssertEqual(layouts.count, 3)
        return layouts.map { layout in
            OverlayDrawItem(
                layout: layout, text: inputs.first { $0.id == layout.id }!.text, state: states[layout.id]!,
                colors: OverlayItemColors(originalText: RGBAColor(red: 0.1, green: 0.1, blue: 0.1)),
                indicatorCenter: states[layout.id] == .draft
                    ? OverlayLayout.indicatorCenter(for: layout, text: inputs[0].text, fitter: fitter) : nil)
        }
    }

    /// Draws `canvas` into `bitmap` (2×, flipped like the view) the way a layer's partial update does:
    /// `rect` is cleared and redrawn, the rest of the bitmap is kept.
    @MainActor
    private func render(_ canvas: OverlayCanvasView, _ rect: CGRect, into bitmap: CGContext) {
        bitmap.saveGState()
        bitmap.translateBy(x: 0, y: CGFloat(bitmap.height))
        bitmap.scaleBy(x: 2, y: -2)
        bitmap.clear(rect)
        bitmap.clip(to: rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        canvas.draw(rect)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.restoreGState()
    }

    private func makeBitmap(_ size: CGSize) throws -> CGContext {
        try XCTUnwrap(
            CGContext(
                data: nil, width: Int(size.width) * 2, height: Int(size.height) * 2, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func pixels(_ bitmap: CGContext) -> [UInt8] {
        guard let data = bitmap.data else { return [] }
        return Array(UnsafeRawBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.height))
    }

    @MainActor
    func testPartialRedrawMatchesFullRedraw() throws {
        let fitter = TextFitter()
        let old = try canvasItems(c: "途中まで", fitter: fitter)
        let new = try canvasItems(c: "途中までの訳文です", fitter: fitter)
        // B overflows but stops at C's top: backgrounds never intersect.
        XCTAssertEqual(new.map(\.layout.stage), [.original, .original, .truncated])
        XCTAssertLessThanOrEqual(new[2].layout.backgroundRect.maxY, 30)
        XCTAssertEqual(new[2].layout.background.overlapArea(with: new[1].layout.background), 0)
        // Only C changed; the layouts of A and B do not depend on C's text.
        XCTAssertEqual(old[0], new[0])
        XCTAssertEqual(old[2], new[2])

        let canvas = OverlayCanvasView(frame: CGRect(x: 0, y: 0, width: 300, height: 160))
        let dirty = try XCTUnwrap(OverlayCanvasView.redrawRect(from: old, to: new))
        // The dirty area reaches into A's and B's drawing bounds; they are redrawn there too.
        XCTAssertTrue(new[0].layout.drawingBounds.intersects(dirty))
        XCTAssertTrue(new[2].layout.drawingBounds.intersects(dirty))

        let partial = try makeBitmap(canvas.bounds.size)
        canvas.setContent(old, appearance: appearance, crossfade: false)
        render(canvas, canvas.bounds, into: partial)
        let before = pixels(partial)
        canvas.setContent(new, appearance: appearance, crossfade: false)
        // Layer updates redraw whole pixels.
        render(canvas, dirty.integral, into: partial)

        let full = try makeBitmap(canvas.bounds.size)
        render(canvas, canvas.bounds, into: full)
        XCTAssertNotEqual(before, pixels(full))
        XCTAssertTrue(pixels(partial) == pixels(full), "a partial redraw differs from a full redraw")
    }

    // MARK: - Popups

    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)

    func testPopupGoesBelowWhenThereIsRoom() {
        let anchor = CGRect(x: 100, y: 200, width: 300, height: 40)
        let placed = PopupPlacement.place(size: CGSize(width: 250, height: 60), anchor: anchor, screen: screen, minimumHeight: 25)
        XCTAssertEqual(placed.side, .below)
        XCTAssertEqual(placed.frame, CGRect(x: 100, y: 246, width: 250, height: 60))
        XCTAssertFalse(placed.frame.intersects(anchor))
    }

    func testPopupGoesAboveNearScreenBottom() {
        let anchor = CGRect(x: 100, y: 800, width: 300, height: 40)
        let placed = PopupPlacement.place(size: CGSize(width: 250, height: 60), anchor: anchor, screen: screen, minimumHeight: 25)
        XCTAssertEqual(placed.side, .above)
        XCTAssertEqual(placed.frame.maxY, 794)
        XCTAssertFalse(placed.frame.intersects(anchor))
    }

    func testPopupShrinksIntoRoomierSide() {
        let anchor = CGRect(x: 100, y: 300, width: 300, height: 400)
        let placed = PopupPlacement.place(size: CGSize(width: 250, height: 500), anchor: anchor, screen: screen, minimumHeight: 25)
        XCTAssertEqual(placed.side, .above)
        XCTAssertFalse(placed.frame.intersects(anchor))
        XCTAssertGreaterThanOrEqual(placed.frame.minY, screen.minY + PopupPlacement.screenMargin)
    }

    func testPopupClampsHorizontally() {
        let anchor = CGRect(x: 1400, y: 200, width: 30, height: 20)
        let placed = PopupPlacement.place(size: CGSize(width: 300, height: 40), anchor: anchor, screen: screen, minimumHeight: 25)
        XCTAssertEqual(placed.frame.maxX, screen.maxX - PopupPlacement.screenMargin)
    }

    func testPopupOverlapsOnlyWhenNoRoomAtAll() {
        let anchor = screen
        let placed = PopupPlacement.place(size: CGSize(width: 300, height: 40), anchor: anchor, screen: screen, minimumHeight: 25)
        XCTAssertEqual(placed.side, .overlapping)
        XCTAssertTrue(screen.contains(placed.frame))
    }

    func testPopupLayoutWrapsLongTranslation() {
        let fitter = TextFitter()
        let anchor = CGRect(x: 200, y: 300, width: 500, height: 60)
        let text = String(repeating: "これはポップアップに表示される長い翻訳です。", count: 4)
        let layout = OverlayLayout.popup(text: text, anchor: anchor, screen: screen, appearance: appearance, fitter: fitter)
        XCTAssertEqual(layout.side, .below)
        XCTAssertFalse(layout.frame.intersects(anchor))
        XCTAssertTrue(screen.contains(layout.frame))
        XCTAssertLessThanOrEqual(layout.frame.width, OverlayLayout.popupMaxWidth)
        XCTAssertEqual(layout.fontSize, 13)
        XCTAssertEqual(layout.textRect.width, layout.frame.width - 20)
    }

    func testShrunkPopupHoldsItsText() {
        // Too tall for either side: the text is re-fitted into the roomier side and must not lose its last line.
        let fitter = TextFitter()
        let text = String(repeating: "これはポップアップに表示される長い翻訳です。", count: 5)
        var shrunk = 0
        var cutOff: [CGFloat] = []
        // At 13pt the text needs 62pt (3 lines + padding); 30pt of room above the anchor, `below` under it.
        for below in stride(from: 30.0, through: 61.5, by: 0.1) {
            let top = screen.minY + PopupPlacement.screenMargin + PopupPlacement.gap + 30
            let bottom = screen.maxY - PopupPlacement.screenMargin - PopupPlacement.gap - below
            let anchor = CGRect(x: 200, y: top, width: 500, height: bottom - top)
            let layout = OverlayLayout.popup(text: text, anchor: anchor, screen: screen, appearance: appearance, fitter: fitter)
            // Above the minimum font size the shrink found a size that fits.
            guard layout.fontSize > CGFloat(appearance.minFontSize) else { continue }
            XCTAssertLessThan(layout.fontSize, 13)
            shrunk += 1
            let needed = TextFitter.measureSystemText(text, fontSize: layout.fontSize, maxWidth: layout.textRect.width)
            if needed.height > layout.textRect.height { cutOff.append(below) }
        }
        XCTAssertGreaterThan(shrunk, 0)
        XCTAssertEqual(cutOff.count, 0, "popup text rect shorter than the text, e.g. with \(cutOff.first ?? 0)pt below")
    }

    func testPopupShrinksShortText() {
        let fitter = TextFitter()
        let layout = OverlayLayout.popup(
            text: "設定", anchor: CGRect(x: 10, y: 100, width: 40, height: 16), screen: screen, appearance: appearance,
            fitter: fitter)
        XCTAssertEqual(layout.frame.width, OverlayLayout.popupMinWidth)
    }

    // MARK: - Colors

    func testPaletteContrast() {
        for theme in OverlayTheme.allCases {
            for systemIsDark in [false, true] {
                let p = OverlayPalette.make(theme: theme, systemIsDark: systemIsDark, backgroundOpacity: 0.94)
                XCTAssertGreaterThanOrEqual(OverlayPalette.contrastRatio(p.text, p.solidBackground), 7)
                XCTAssertGreaterThanOrEqual(OverlayPalette.contrastRatio(p.secondaryText, p.solidBackground), 4.5)
                XCTAssertGreaterThanOrEqual(OverlayPalette.contrastRatio(p.indicator, p.solidBackground), 3)
                XCTAssertEqual(p.background.alphaComponent, 0.94, accuracy: 0.001)
            }
        }
        XCTAssertTrue(OverlayPalette.make(theme: .system, systemIsDark: true, backgroundOpacity: 1).isDark)
        XCTAssertFalse(OverlayPalette.make(theme: .light, systemIsDark: true, backgroundOpacity: 1).isDark)
        XCTAssertTrue(OverlayPalette.make(theme: .dark, systemIsDark: false, backgroundOpacity: 1).isDark)
        XCTAssertEqual(OverlayPalette.contrastRatio(.white, .black), 21, accuracy: 0.01)
    }

    func testPopupPlaceholders() {
        XCTAssertEqual(OverlayPopupContent(translation: "", original: "x", state: .pending).displayText, "翻訳中…")
        XCTAssertEqual(OverlayPopupContent(translation: "", original: "x", state: .failed).displayText, "翻訳できませんでした")
        XCTAssertEqual(OverlayPopupContent(translation: "訳", original: "x", state: .draft).displayText, "訳")
        XCTAssertTrue(OverlayPopupContent(translation: "", original: "x", state: .streaming).isPlaceholder)
    }

    // MARK: - Controller bookkeeping (no window is ordered on screen)

    @MainActor
    func testControllerTracksWindows() {
        let controller = OverlayController()
        let key = WindowKey(pid: 1, windowID: 42)
        let style = OverlayStyle(displayStyle: .hover, appearance: appearance)
        controller.update(
            window: key, axWindowFrame: window, axClipRect: nil, cgWindowID: nil,
            items: [OverlayItem(id: "a", axFrame: CGRect(x: 120, y: 220, width: 100, height: 20), original: "Hi", translation: "やあ", state: .final)],
            style: style, targetIsFrontmost: false)
        XCTAssertEqual(controller.activeWindows, [key])
        controller.remove(window: key)
        XCTAssertTrue(controller.activeWindows.isEmpty)
    }
}
