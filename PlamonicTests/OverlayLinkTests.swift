import AppKit
import XCTest

@testable import Plamonic

/// Links in translations (DESIGN §6.1): which part is drawn as a link, break opportunities in long URLs, the
/// cut with "…", link colors, and the click areas of one window.
final class OverlayLinkTests: XCTestCase {
    private let zwsp = "\u{200B}"

    private func link(_ text: String, color: RGBAColor? = nil, underlined: Bool = false, frames: [CGRect] = [])
        -> SegmentLink
    {
        SegmentLink(range: 0..<text.utf16.count, text: text, frames: frames, color: color, isUnderlined: underlined)
    }

    private func range(of part: String, in text: String) -> Range<Int> {
        let r = (text as NSString).range(of: part)
        return r.location..<NSMaxRange(r)
    }

    // MARK: - Styled text

    func testBreakOpportunitiesOnlyInsideLinks() {
        let url = "https://example.com/docs/setup-guide?lang=ja&ref=x_y"
        let translation = "詳しくは \(url) を見てください。foo.bar/baz"
        let styled = OverlayLinkText.styled(
            translation: translation, links: [OverlayLink(range: range(of: url, in: translation), linkIndex: 0)],
            originalLinks: [link(url, color: RGBAColor(red: 0, green: 0, blue: 1), underlined: true)])
        XCTAssertEqual(styled.links.count, 1)
        let drawn = styled.text as NSString
        let linkText = drawn.substring(with: styled.links[0].range)
        // The link keeps its characters; breaks come after each run of separators, never at its end.
        XCTAssertEqual(linkText.replacingOccurrences(of: zwsp, with: ""), url)
        XCTAssertEqual(
            linkText,
            "https://\(zwsp)example.\(zwsp)com/\(zwsp)docs/\(zwsp)setup-\(zwsp)guide?\(zwsp)lang=\(zwsp)ja&\(zwsp)ref=\(zwsp)x_\(zwsp)y")
        // Nothing is added outside the link.
        XCTAssertTrue(drawn.substring(from: NSMaxRange(styled.links[0].range)).hasSuffix("foo.bar/baz"))
        XCTAssertFalse(drawn.substring(to: styled.links[0].range.location).contains(zwsp))
        XCTAssertEqual(styled.text.replacingOccurrences(of: zwsp, with: ""), translation)
        XCTAssertEqual(styled.links[0].color, RGBAColor(red: 0, green: 0, blue: 1))
        XCTAssertTrue(styled.links[0].isUnderlined)
    }

    func testRangesAfterALongLinkFollowItsBreaks() {
        let url = "https://a.b/c/d"
        let translation = "\(url) と 設定ガイド"
        let styled = OverlayLinkText.styled(
            translation: translation,
            links: [
                OverlayLink(range: range(of: "設定ガイド", in: translation), linkIndex: 1),
                OverlayLink(range: range(of: url, in: translation), linkIndex: 0),
            ],
            originalLinks: [link(url), link("setup guide")])
        // Text order, each range on its own text.
        XCTAssertEqual(styled.links.map(\.linkIndex), [0, 1])
        let drawn = styled.text as NSString
        XCTAssertEqual(drawn.substring(with: styled.links[1].range), "設定ガイド")
        XCTAssertEqual(drawn.substring(with: styled.links[0].range).replacingOccurrences(of: zwsp, with: ""), url)
    }

    func testInvalidLinksAreDropped() {
        let translation = "  ガイド と FAQ です"
        let styled = OverlayLinkText.styled(
            translation: translation,
            links: [
                // Unknown original link.
                OverlayLink(range: 0..<4, linkIndex: 5),
                // Spaces around the link are not part of it.
                OverlayLink(range: 0..<5, linkIndex: 0),
                // Overlaps the previous one.
                OverlayLink(range: 3..<6, linkIndex: 1),
                // Out of range.
                OverlayLink(range: 40..<50, linkIndex: 1),
                // Empty.
                OverlayLink(range: 8..<8, linkIndex: 1),
            ],
            originalLinks: [link("guide"), link("FAQ")])
        XCTAssertEqual(styled.text, translation)
        XCTAssertEqual(styled.links.count, 1)
        XCTAssertEqual((styled.text as NSString).substring(with: styled.links[0].range), "ガイド")
    }

    func testNoLinksNoChanges() {
        let styled = OverlayLinkText.styled(translation: "訳文 a.b/c", links: [], originalLinks: [link("x")])
        XCTAssertEqual(styled.text, "訳文 a.b/c")
        XCTAssertTrue(styled.links.isEmpty)
    }

    // MARK: - Layout of what is drawn

    @MainActor
    func testLinkRectsFollowTheGlyphsLineByLine() throws {
        let url = "https://example.com/docs/getting-started/install-on-macos?lang=en&ref=overlay-demo"
        let translation = "詳しい手順は \(url) を見てください。"
        let styled = OverlayLinkText.styled(
            translation: translation, links: [OverlayLink(range: range(of: url, in: translation), linkIndex: 0)],
            originalLinks: [link(url)])
        let look = TextLook(lineHeightMultiple: 20.0 / 14.0)
        let prepared = OverlayLinkText.prepare(
            styled.text, links: styled.links, fontSize: 14, look: look, size: CGSize(width: 200, height: 400))
        XCTAssertFalse(prepared.isCut)
        XCTAssertEqual(prepared.text, styled.text)
        let rects = try XCTUnwrap(prepared.linkRects.first)
        // The URL wraps over several lines, one rect each, 20pt apart, inside the box.
        XCTAssertGreaterThanOrEqual(rects.count, 2)
        for (a, b) in zip(rects, rects.dropFirst()) { XCTAssertEqual(b.minY - a.minY, 20, accuracy: 0.01) }
        for rect in rects {
            XCTAssertEqual(rect.height, 20, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
            XCTAssertLessThanOrEqual(rect.maxX, 200.5)
        }
        // The link starts after "詳しい手順は " on the first line.
        XCTAssertGreaterThan(rects[0].minX, 60)
    }

    @MainActor
    func testLongURLsBreakAfterSeparators() {
        let url = "https://example.com/docs/getting-started/install-on-macos?lang=en&ref=overlay-demo"
        let styled = OverlayLinkText.styled(
            translation: url, links: [OverlayLink(range: 0..<url.utf16.count, linkIndex: 0)], originalLinks: [link(url)])
        // Every line inside the link ends after a separator: the URL is not broken in the middle of a word.
        let storage = NSTextStorage(attributedString: TextFitter.attributedString(styled.text, fontSize: 14, color: .black))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 150, height: 1000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lineEnds: [Int] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, _, _, glyphs, _ in
            lineEnds.append(NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
        }
        XCTAssertGreaterThan(lineEnds.count, 2)
        let units = Array(styled.text.utf16)
        for end in lineEnds.dropLast() {
            let last = units[end - 1]
            XCTAssertTrue(
                last == 0x200B || OverlayLinkText.breaksAfter.contains(last),
                "line ends with \(String(utf16CodeUnits: [last], count: 1))")
        }
    }

    @MainActor
    func testCutTextDropsLinksPastTheCutAndKeepsTheDrawnPart() throws {
        let translation = "最初のガイドは押せます。長い訳文が入らないので最後の行を省略します。途中のリンクテキストが切れて、最後のリンクは見えません。"
        let styled = OverlayLinkText.styled(
            translation: translation,
            links: [
                OverlayLink(range: range(of: "ガイド", in: translation), linkIndex: 0),
                OverlayLink(range: range(of: "最後の行を省略します。途中のリンクテキスト", in: translation), linkIndex: 1),
                OverlayLink(range: range(of: "最後のリンク", in: translation), linkIndex: 2),
            ],
            originalLinks: [link("guide"), link("middle"), link("last")])
        let look = TextLook(lineHeightMultiple: 20.0 / 14.0)
        // Two lines of room.
        let prepared = OverlayLinkText.prepare(
            styled.text, links: styled.links, fontSize: 14, look: look, size: CGSize(width: 200, height: 40.5))
        XCTAssertTrue(prepared.isCut)
        XCTAssertTrue(prepared.text.hasSuffix("…"))
        XCTAssertEqual(prepared.links.map(\.linkIndex), [0, 1])
        let text = prepared.text as NSString
        XCTAssertEqual(text.substring(with: prepared.links[0].range), "ガイド")
        // The middle link is cut: only its drawn part is a link, and "…" is not.
        let middle = text.substring(with: prepared.links[1].range).replacingOccurrences(of: "\u{2028}", with: "")
        XCTAssertTrue("最後の行を省略します。途中のリンクテキスト".hasPrefix(middle))
        XCTAssertLessThan(NSMaxRange(prepared.links[1].range), text.length)
        XCTAssertFalse(text.substring(with: prepared.links[1].range).contains("…"))
        // Everything drawn fits two lines; the link rects are on those lines only.
        for rects in prepared.linkRects {
            for rect in rects { XCTAssertLessThanOrEqual(rect.maxY, 40.5) }
        }
        let size = TextFitter.measureSystemText(prepared.text, fontSize: 14, maxWidth: 200, look: look)
        XCTAssertLessThanOrEqual(size.height, 40)
    }

    // MARK: - Colors

    func testLinkColorKeepsContrast() {
        let dark = OverlayPalette.resolve(
            OverlayItemColors(sampled: SampledColors(background: RGBAColor(red: 0.1, green: 0.1, blue: 0.11), text: nil)),
            appearance: OverlayAppearance(), systemIsDark: false)
        // The original link color when it reads on the background.
        let blue = RGBAColor(red: 0.3, green: 0.65, blue: 1)
        XCTAssertEqual(
            OverlayPalette.linkColor(original: blue, resolved: dark).usingColorSpace(.sRGB)?.blueComponent ?? 0, 1,
            accuracy: 0.001)
        // Unknown or unreadable: a link color for the background, at least 3:1.
        for original in [nil, RGBAColor(red: 0.05, green: 0.1, blue: 0.3)] {
            let color = OverlayPalette.linkColor(original: original, resolved: dark)
            XCTAssertGreaterThanOrEqual(OverlayPalette.contrastRatio(color, dark.solidBackground), 3)
            XCTAssertNotEqual(color, dark.text)
        }
        let light = OverlayPalette.resolve(OverlayItemColors(), appearance: OverlayAppearance(), systemIsDark: false)
        XCTAssertGreaterThanOrEqual(
            OverlayPalette.contrastRatio(OverlayPalette.linkColor(original: nil, resolved: light), light.solidBackground), 3)
    }

    func testMeasuredTextColorOfALinkIsNotTheParagraphColor() {
        let linkColor = RGBAColor(red: 0.11, green: 0.6, blue: 0.92)
        let text = RGBAColor(red: 0.85, green: 0.85, blue: 0.85)
        var item = OverlayItem(
            id: "a", axFrame: .zero, original: "See https://example.com", translation: "https://example.com を見て",
            state: .final, style: TextStyleHint(fontSize: 14, textColor: text))
        let background = RGBAColor(red: 0.1, green: 0.1, blue: 0.1)
        let measured = SampledColors(background: background, text: RGBAColor(red: 0.12, green: 0.61, blue: 0.9))
        // Without links the measured color wins, as before.
        XCTAssertEqual(
            OverlayController.itemColors(item, sampled: measured, appearance: OverlayAppearance()).sampled?.text,
            measured.text)
        // With links the paragraph's own (non-link) color is used.
        item.originalLinks = [link("https://example.com", color: linkColor)]
        let colors = OverlayController.itemColors(item, sampled: measured, appearance: OverlayAppearance())
        XCTAssertNil(colors.sampled?.text)
        XCTAssertEqual(colors.sampled?.background, background)
        let resolved = OverlayPalette.resolve(colors, appearance: OverlayAppearance(), systemIsDark: false)
        XCTAssertEqual(resolved.text.usingColorSpace(.sRGB)?.redComponent ?? 0, 0.85, accuracy: 0.001)
        // Original color unknown: a measured color that is a link's is still not used.
        item.style.textColor = nil
        XCTAssertNil(OverlayController.itemColors(item, sampled: measured, appearance: OverlayAppearance()).sampled?.text)
        // ... and one that is not a known link's color is.
        let other = SampledColors(background: background, text: RGBAColor(red: 0.8, green: 0.8, blue: 0.8))
        XCTAssertEqual(
            OverlayController.itemColors(item, sampled: other, appearance: OverlayAppearance()).sampled?.text, other.text)
    }

    /// The follow-up request: with links in a sentence, only the links take the link color, also when the
    /// paragraph's color comes from the screen.
    func testLinkParagraphsNeverTakeAMeasuredLinkColor() {
        let gray = RGBAColor(red: 0.85, green: 0.85, blue: 0.85)
        let blue = RGBAColor(red: 0.22, green: 0.74, blue: 0.97)
        let background = RGBAColor(red: 0.1, green: 0.1, blue: 0.1)
        // A long link whose color the app does not report; the screen's most common text color is the link's.
        let measured = SampledColors(background: background, text: blue)
        var item = OverlayItem(
            id: "a", axFrame: .zero, original: "See https://example.com/a/very/long/path for details.",
            translation: "詳しくは https://example.com/a/very/long/path を見て", state: .final,
            style: TextStyleHint(fontSize: 14, textColor: gray),
            originalLinks: [link("https://example.com/a/very/long/path")])
        var notMatched = OverlayAppearance()
        notMatched.matchOriginalStyle = false
        // The original's look not matched, its non-link color known: a measured color that is not that one is
        // not used (the theme's text color instead).
        var colors = OverlayController.itemColors(item, sampled: measured, appearance: notMatched)
        XCTAssertNil(colors.sampled?.text)
        XCTAssertNil(colors.originalText)
        XCTAssertEqual(colors.sampled?.background, background)
        let close = SampledColors(background: background, text: RGBAColor(red: 0.84, green: 0.86, blue: 0.85))
        XCTAssertEqual(OverlayController.itemColors(item, sampled: close, appearance: notMatched).sampled?.text, close.text)
        // Nothing reported (Terminal.app): neither text nor link color known, so the measured color is not used...
        item.style.textColor = nil
        for appearance in [OverlayAppearance(), notMatched] {
            colors = OverlayController.itemColors(item, sampled: measured, appearance: appearance)
            XCTAssertNil(colors.sampled?.text)
            let resolved = OverlayPalette.resolve(colors, appearance: appearance, systemIsDark: false)
            XCTAssertGreaterThan(OverlayPalette.contrastRatio(resolved.text, OverlayPalette.nsColor(blue)), 1.5)
            // ... unless it was measured where there is no link.
            colors = OverlayController.itemColors(item, sampled: measured, nonLinkText: gray, appearance: appearance)
            XCTAssertEqual(colors.sampled?.text, gray)
        }
        // The original's own non-link color wins when the look is matched, over any measurement.
        item.style.textColor = gray
        colors = OverlayController.itemColors(
            item, sampled: measured, nonLinkText: RGBAColor(red: 0.5, green: 0.5, blue: 0.5), appearance: OverlayAppearance())
        XCTAssertNil(colors.sampled?.text)
        XCTAssertEqual(colors.originalText, gray)
        // Not matched: the color measured around the links.
        colors = OverlayController.itemColors(item, sampled: measured, nonLinkText: gray, appearance: notMatched)
        XCTAssertEqual(colors.sampled?.text, gray)
        // No links: as before, whatever was measured.
        item.originalLinks = []
        XCTAssertEqual(OverlayController.itemColors(item, sampled: measured, appearance: notMatched).sampled?.text, blue)
    }

    func testUnrecordedLinkRunsKeepAMeasuredLinkColorOff() {
        // A native text view: the app marks link runs, extraction does not record them as links.
        let gray = RGBAColor(red: 0.2, green: 0.2, blue: 0.2)
        let blue = RGBAColor(red: 0.0, green: 0.4, blue: 0.85)
        let background = RGBAColor(red: 1, green: 1, blue: 1)
        let measured = SampledColors(background: background, text: blue)
        var style = TextStyleHint(fontSize: 13, textColor: gray)
        style.hasLinkRuns = true
        let line = CGRect(x: 100, y: 200, width: 400, height: 17)
        let item = OverlayItem(
            id: "a", axFrame: line, original: "See the documentation for this feature now.",
            translation: "この機能の説明を見てください。", state: .final, style: style, lineFrames: [line])
        XCTAssertTrue(OverlayController.hasLinks(item))
        // Matched: the original's own non-link color.
        var colors = OverlayController.itemColors(item, sampled: measured, appearance: OverlayAppearance())
        XCTAssertNil(colors.sampled?.text)
        XCTAssertEqual(colors.originalText, gray)
        // Not matched: a measured color is used only when it is close to the non-link color.
        var notMatched = OverlayAppearance()
        notMatched.matchOriginalStyle = false
        colors = OverlayController.itemColors(item, sampled: measured, appearance: notMatched)
        XCTAssertNil(colors.sampled?.text)
        let close = SampledColors(background: background, text: RGBAColor(red: 0.21, green: 0.2, blue: 0.19))
        XCTAssertEqual(OverlayController.itemColors(item, sampled: close, appearance: notMatched).sampled?.text, close.text)
        // No link rects to measure around: only the whole paragraph is measured.
        let targets = OverlayController.colorSampleTargets(
            items: [item], axClipRect: nil, axWindowFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(Set(targets.keys), ["a"])
        // Without link runs, as before: whatever was measured.
        var plain = item
        plain.style.hasLinkRuns = false
        XCTAssertFalse(OverlayController.hasLinks(plain))
        XCTAssertEqual(OverlayController.itemColors(plain, sampled: measured, appearance: notMatched).sampled?.text, blue)
    }

    func testTheTextAroundLinksIsMeasuredApartFromThem() throws {
        // "See <URL> for details." on one line, the link in the middle.
        let line = CGRect(x: 100, y: 200, width: 400, height: 17)
        let item = OverlayItem(
            id: "a", axFrame: line, original: "x", translation: "x", state: .final, lineFrames: [line],
            originalLinks: [link("u", frames: [CGRect(x: 130, y: 200, width: 250, height: 16)])])
        let piece = try XCTUnwrap(OverlayController.nonLinkSampleRect(item, visible: line))
        // The larger side, kept away from the link by the sampler's margin.
        XCTAssertEqual(piece.minX, 380 + OverlayController.nonLinkSampleGap, accuracy: 0.01)
        XCTAssertEqual(piece.maxX, 500, accuracy: 0.01)
        XCTAssertEqual(piece.minY, 200)
        XCTAssertEqual(piece.height, 17)
        // Over two lines: the first is all link, the text is on the second.
        let lines = [CGRect(x: 100, y: 200, width: 300, height: 17), CGRect(x: 100, y: 220, width: 200, height: 17)]
        var wrapped = item
        wrapped.lineFrames = lines
        wrapped.axFrame = lines[0].union(lines[1])
        wrapped.originalLinks = [
            link(
                "u",
                frames: [CGRect(x: 100, y: 200, width: 300, height: 17), CGRect(x: 100, y: 220, width: 60, height: 17)])
        ]
        let second = try XCTUnwrap(OverlayController.nonLinkSampleRect(wrapped, visible: wrapped.axFrame))
        XCTAssertEqual(second.minY, 220)
        XCTAssertGreaterThanOrEqual(second.minX, 160 + OverlayController.nonLinkSampleGap)
        // Nothing but the link: nothing to measure.
        var only = item
        only.id = "b"
        only.originalLinks = [link("u", frames: [line])]
        XCTAssertNil(OverlayController.nonLinkSampleRect(only, visible: line))
        // The controller asks for it next to the whole paragraph, apart from the paragraph's own measurement.
        let targets = OverlayController.colorSampleTargets(
            items: [item, only], axClipRect: nil, axWindowFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(Set(targets.keys), ["a", OverlayController.nonLinkSampleID("a"), "b"])
        let text = try XCTUnwrap(targets[OverlayController.nonLinkSampleID("a")])
        XCTAssertTrue(text.isNonLinkText)
        XCTAssertFalse(targets["a"]?.isNonLinkText ?? true)
        XCTAssertTrue(text.axRect.intersection(CGRect(x: 130, y: 200, width: 250, height: 16)).isEmpty)
    }

    // MARK: - Click areas

    func testHitAreasCoverLinksAndHiddenOriginalLinks() {
        let window = CGRect(x: 100, y: 50, width: 600, height: 400)
        let layout = OverlayItemLayout(
            id: "a", background: OverlayBackgroundShape(rect: CGRect(x: 18.5, y: 100, width: 303, height: 40)),
            textRect: CGRect(x: 20, y: 100, width: 300, height: 40), fontSize: 14, stage: .original,
            visibleRect: CGRect(x: 18.5, y: 100, width: 303, height: 40))
        let item = OverlayHitAreas.Item(
            id: "a", layout: layout, links: [(linkIndex: 0, rects: [CGRect(x: 60, y: 100, width: 40, height: 20)])],
            // AX: one original link line inside the item, one partly outside its background.
            originalLinkFrames: [
                CGRect(x: 100 + 50, y: 50 + 102, width: 80, height: 16),
                CGRect(x: 100 + 300, y: 50 + 122, width: 60, height: 16),
            ])
        let (areas, merged, unprotected) = OverlayHitAreas.compute(
            [item], windowAXFrame: window, clip: CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(merged, 0)
        XCTAssertEqual(unprotected, 0)
        XCTAssertEqual(areas.first, OverlayHitArea(itemID: "a", kind: .link(0), rect: CGRect(x: 60, y: 100, width: 40, height: 20)))
        let blockers = areas.filter { $0.kind == .blocker }.map(\.rect)
        // The first original link minus the translated link over it: its left and right parts.
        XCTAssertTrue(blockers.contains(CGRect(x: 50, y: 102, width: 10, height: 16)))
        XCTAssertTrue(blockers.contains(CGRect(x: 100, y: 102, width: 30, height: 16)))
        // The second one only where the background covers it.
        XCTAssertTrue(blockers.contains(CGRect(x: 300, y: 122, width: 21.5, height: 16)))
        XCTAssertEqual(blockers.count, 3)
        for blocker in blockers { XCTAssertTrue(blocker.intersection(CGRect(x: 60, y: 100, width: 40, height: 20)).isEmpty) }
    }

    func testHitAreasStayInsideTheClipAndUnderTheCap() {
        let layout = OverlayItemLayout(
            id: "a", background: OverlayBackgroundShape(rect: CGRect(x: 0, y: 0, width: 300, height: 100)),
            textRect: CGRect(x: 0, y: 0, width: 300, height: 100), fontSize: 14, stage: .original,
            visibleRect: CGRect(x: 0, y: 0, width: 300, height: 100))
        let links = (0..<2).map { i in (linkIndex: i, rects: [CGRect(x: 10, y: CGFloat(i) * 20, width: 30, height: 20)]) }
        let frames = (0..<3).map { i in CGRect(x: 100, y: CGFloat(i) * 20, width: 40, height: 18) }
        let item = OverlayHitAreas.Item(id: "a", layout: layout, links: links, originalLinkFrames: frames)
        // Clip: only the top 50 points are visible.
        let clip = CGRect(x: 0, y: 0, width: 300, height: 50)
        let clipped = OverlayHitAreas.compute([item], windowAXFrame: .zero, clip: clip).areas
        for area in clipped { XCTAssertTrue(clip.contains(area.rect), "\(area.rect)") }
        XCTAssertEqual(clipped.filter(\.isLink).count, 2)
        let full = CGRect(x: 0, y: 0, width: 300, height: 100)
        let all = OverlayHitAreas.compute([item], windowAXFrame: .zero, clip: full)
        XCTAssertEqual(all.areas.count, 5)
        XCTAssertEqual(all.merged, 0)
        /// Every point of every original link is covered.
        func assertCovered(_ areas: [OverlayHitArea], _ label: String) {
            for frame in frames {
                for x in stride(from: frame.minX + 0.5, to: frame.maxX, by: 3) {
                    for y in stride(from: frame.minY + 0.5, to: frame.maxY, by: 3) {
                        XCTAssertTrue(areas.contains { $0.rect.contains(CGPoint(x: x, y: y)) }, "\(label) \(x),\(y)")
                    }
                }
            }
        }
        assertCovered(all.areas, "all")
        // Too many: the links are merged with the original links one blocker per line, never dropped first.
        let lines = OverlayHitAreas.compute([item], windowAXFrame: .zero, clip: full, limit: 3)
        XCTAssertEqual(lines.areas.count, 3)
        XCTAssertTrue(lines.areas.allSatisfy { $0.kind == .blocker })
        XCTAssertEqual(lines.merged, 1)
        XCTAssertEqual(lines.unprotected, 0)
        assertCovered(lines.areas, "lines")
        // Still too many: one per background row.
        let rows = OverlayHitAreas.compute([item], windowAXFrame: .zero, clip: full, limit: 1)
        XCTAssertEqual(rows.areas.count, 1)
        XCTAssertEqual(rows.areas.first?.kind, .blocker)
        XCTAssertTrue(full.contains(rows.areas[0].rect))
        assertCovered(rows.areas, "rows")
        // Only when nothing fits is an item left without areas.
        let none = OverlayHitAreas.compute([item], windowAXFrame: .zero, clip: full, limit: 0)
        XCTAssertTrue(none.areas.isEmpty)
        XCTAssertEqual(none.unprotected, 1)
    }

    func testOverTheCapTheLastItemsAreMergedFirstAndLinkOnlyItemsLeftOutFirst() {
        func layout(_ id: String, y: CGFloat) -> OverlayItemLayout {
            let rect = CGRect(x: 0, y: y, width: 300, height: 20)
            return OverlayItemLayout(
                id: id, background: OverlayBackgroundShape(rect: rect), textRect: rect, fontSize: 14, stage: .original,
                visibleRect: rect)
        }
        // Each: a translated link and the original link partly beside it (link + 1 blocker).
        let covering = (0..<3).map { i in
            OverlayHitAreas.Item(
                id: "c\(i)", layout: layout("c\(i)", y: CGFloat(i) * 20),
                links: [(linkIndex: 0, rects: [CGRect(x: 10, y: CGFloat(i) * 20, width: 30, height: 20)])],
                originalLinkFrames: [CGRect(x: 20, y: CGFloat(i) * 20 + 1, width: 60, height: 18)])
        }
        // Only a translated link, no original link under the translation.
        let linkOnly = OverlayHitAreas.Item(
            id: "l", layout: layout("l", y: 100), links: [(linkIndex: 0, rects: [CGRect(x: 10, y: 100, width: 30, height: 20)])],
            originalLinkFrames: [])
        let clip = CGRect(x: 0, y: 0, width: 300, height: 200)
        let items = covering + [linkOnly]
        XCTAssertEqual(OverlayHitAreas.compute(items, windowAXFrame: .zero, clip: clip).areas.count, 7)
        let five = OverlayHitAreas.compute(items, windowAXFrame: .zero, clip: clip, limit: 5)
        XCTAssertEqual(five.areas.count, 5)
        // c2 then c1 merged; c0 and the link-only item keep their links.
        XCTAssertEqual(Set(five.areas.filter(\.isLink).map(\.itemID)), ["c0", "l"])
        XCTAssertEqual(five.areas.filter { $0.itemID == "c2" }.map(\.kind), [.blocker])
        XCTAssertEqual(five.merged, 2)
        // Three: everything that covers an original link is merged, and the link-only item goes.
        let three = OverlayHitAreas.compute(items, windowAXFrame: .zero, clip: clip, limit: 3)
        XCTAssertEqual(Set(three.areas.map(\.itemID)), ["c0", "c1", "c2"])
        XCTAssertEqual(three.unprotected, 0)
        XCTAssertTrue(three.areas.allSatisfy { $0.kind == .blocker })
    }

    func testLineBands() {
        let bands = OverlayHitAreas.lineBands([
            CGRect(x: 0, y: 0, width: 10, height: 20), CGRect(x: 50, y: 2, width: 10, height: 16),
            CGRect(x: 20, y: 20, width: 10, height: 20), CGRect(x: 0, y: 19, width: 5, height: 3),
        ])
        XCTAssertEqual(bands, [CGRect(x: 0, y: 0, width: 60, height: 20), CGRect(x: 0, y: 19, width: 30, height: 21)])
    }

    func testRectSubtraction() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 20)
        XCTAssertEqual(OverlayHitAreas.subtract(CGRect(x: 200, y: 0, width: 10, height: 10), from: rect), [rect])
        XCTAssertEqual(OverlayHitAreas.subtract(rect, from: rect), [])
        let pieces = OverlayHitAreas.subtract(CGRect(x: 40, y: 5, width: 20, height: 10), from: rect)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.width * $1.height }, 100 * 20 - 20 * 10, accuracy: 0.001)
        for (i, a) in pieces.enumerated() {
            for b in pieces[(i + 1)...] { XCTAssertTrue(a.intersection(b).isEmpty) }
        }
    }
}
