import AppKit
import XCTest

@testable import Plamonic

/// Drawing in the original's style (size, line spacing, monospaced font) and the fit stages:
/// original area → lines added below → shrunk to 85% → last line cut with "…".
final class OverlayFitTests: XCTestCase {
    private let clip = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// Grid model: every character is `fontSize` wide, lines wrap by character, rows are the look's fixed
    /// pitch (else 1.25 × size); the first line is shorter by the look's indent.
    static func gridMeasure(_ text: String, _ size: CGFloat, _ width: CGFloat, _ look: TextLook) -> CGSize {
        let count = text.count
        guard count > 0 else { return .zero }
        let width = min(width, 100_000)  // unbounded widths measure one line
        let perLine = max(1, Int((width / size).rounded(.down)))
        let firstLine = max(0, Int(((width - look.firstLineIndent) / size).rounded(.down)))
        let rows = count <= firstLine ? 1 : 1 + Int((Double(count - firstLine) / Double(perLine)).rounded(.up))
        let pitch = look.fixedLineHeight(fontSize: size) ?? ceil(size * 1.25)
        let used = rows == 1 ? look.firstLineIndent + CGFloat(count) * size : CGFloat(perLine) * size
        return CGSize(width: ceil(used), height: CGFloat(rows) * pitch)
    }

    /// The grid model's last line: what is left after the first line and the full lines.
    static func gridLastLine(_ text: String, _ size: CGFloat, _ width: CGFloat, _ look: TextLook) -> CGFloat {
        let count = text.count
        guard count > 0 else { return 0 }
        let width = min(width, 100_000)
        let perLine = max(1, Int((width / size).rounded(.down)))
        let firstLine = max(0, Int(((width - look.firstLineIndent) / size).rounded(.down)))
        if count <= firstLine { return ceil(look.firstLineIndent + CGFloat(count) * size) }
        let rest = (count - firstLine) % perLine
        return ceil(CGFloat(rest == 0 ? perLine : rest) * size)
    }

    private func gridFitter() -> TextFitter {
        TextFitter(styledMeasure: Self.gridMeasure, lastLineWidth: Self.gridLastLine)
    }

    /// A paragraph of `rows` lines at 14pt, 20pt apart, 17pt line boxes, starting at y = 100, 200pt wide.
    private func paragraph(
        _ id: String = "p", text: String, rows: Int = 2, y: CGFloat = 100, x: CGFloat = 20, width: CGFloat = 200,
        style: TextStyleHint = TextStyleHint(fontSize: 14, lineHeight: 20)
    ) -> OverlayLayoutInput {
        let lines = (0..<rows).map { CGRect(x: x, y: y + 1.5 + CGFloat($0) * 20, width: width, height: 17) }
        let frame = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
        return OverlayLayoutInput(id: id, text: text, frame: frame, lineFrames: lines, style: style)
    }

    private func pending(_ id: String, y: CGFloat, x: CGFloat = 20, width: CGFloat = 200) -> OverlayLayoutInput {
        OverlayLayoutInput(
            id: id, text: "", frame: CGRect(x: x, y: y, width: width, height: 17), drawable: false)
    }

    private func layout(
        _ inputs: [OverlayLayoutInput], appearance: OverlayAppearance = OverlayAppearance(), fitter: TextFitter? = nil
    ) -> [String: OverlayItemLayout] {
        let layouts = OverlayLayout.layoutWindow(
            inputs, clip: clip, appearance: appearance, fitter: fitter ?? gridFitter())
        return Dictionary(uniqueKeysWithValues: layouts.map { ($0.id, $0) })
    }

    // MARK: - Stages

    func testOriginalSizeInOriginalArea() throws {
        // 20 characters at 14pt: 14 per 200pt line -> 2 rows, as many as the original.
        let input = paragraph(text: String(repeating: "訳", count: 20))
        let l = try XCTUnwrap(layout([input])["p"])
        XCTAssertEqual(l.stage, .original)
        XCTAssertEqual(l.fontSize, 14)
        XCTAssertEqual(l.look.fixedLineHeight(fontSize: 14), 20)
        // Rows are centered on the original lines: the first row on the first line.
        XCTAssertEqual(l.textRect.minY, input.lineFrames[0].midY - 10)
        XCTAssertEqual(l.textRect.minX, 20)
        // The background covers the original lines only (horizontal padding, none vertically).
        XCTAssertEqual(l.backgroundRect, CGRect(x: 18.5, y: 101.5, width: 203, height: 37))
        XCTAssertFalse(l.background.hasNotch)
    }

    func testAddsLinesIntoFreeSpaceBelow() throws {
        // 40 characters -> 3 rows; the next item starts far below.
        let items = [paragraph(text: String(repeating: "訳", count: 40)), pending("next", y: 200)]
        let l = try XCTUnwrap(layout(items)["p"])
        XCTAssertEqual(l.stage, .extended)
        XCTAssertEqual(l.fontSize, 14)
        // Third row: centered 40pt below the first line's center, with the same 17pt box.
        XCTAssertEqual(l.backgroundRect.maxY, 110 + 40 + 8.5)
        XCTAssertLessThanOrEqual(l.backgroundRect.maxY, 200)
    }

    func testNeverAddsLinesPastTheNextItem() throws {
        // The next item starts right below: 40 characters do not fit two rows at 14pt; shrinking helps
        // only down to 85%.
        let items = [paragraph(text: String(repeating: "訳", count: 30)), pending("next", y: 140)]
        let l = try XCTUnwrap(layout(items)["p"])
        XCTAssertEqual(l.stage, .shrunk)
        XCTAssertLessThan(l.fontSize, 14)
        XCTAssertGreaterThanOrEqual(l.fontSize, 14 * 0.85)
        XCTAssertLessThanOrEqual(l.backgroundRect.maxY, 140)
        // The largest size that fits: half a point more needs a third row.
        let fitter = gridFitter()
        let look = l.look
        let rows = { (size: CGFloat) -> CGFloat in
            fitter.measure(items[0].text, fontSize: size, maxWidth: l.textRect.width, look: look).height
                / look.fixedLineHeight(fontSize: size)!
        }
        XCTAssertEqual(rows(l.fontSize), 2)
        XCTAssertEqual(rows(l.fontSize + 0.5), 3)
    }

    func testTruncatesAtEightyFivePercent() throws {
        let items = [paragraph(text: String(repeating: "訳", count: 200)), pending("next", y: 140)]
        let l = try XCTUnwrap(layout(items)["p"])
        XCTAssertEqual(l.stage, .truncated)
        XCTAssertEqual(l.fontSize, 14 * 0.85, accuracy: 0.001)
        XCTAssertLessThanOrEqual(l.backgroundRect.maxY, 140)
        // The text rect holds whole rows only (plus half a point of slack), so the last one gets the "…".
        let pitch = try XCTUnwrap(l.look.fixedLineHeight(fontSize: l.fontSize))
        XCTAssertEqual((l.textRect.height - 0.5).truncatingRemainder(dividingBy: pitch), 0, accuracy: 0.01)
    }

    func testShrinkingStopsAtTheMinimumFontSize() throws {
        var appearance = OverlayAppearance()
        appearance.minFontSize = 13
        let items = [paragraph(text: String(repeating: "訳", count: 200)), pending("next", y: 140)]
        let l = try XCTUnwrap(layout(items, appearance: appearance)["p"])
        XCTAssertEqual(l.stage, .truncated)
        XCTAssertEqual(l.fontSize, 13)
        // Never larger than the original either, when the minimum is above it.
        appearance.minFontSize = 20
        let small = try XCTUnwrap(layout(items, appearance: appearance)["p"])
        XCTAssertEqual(small.fontSize, 14)
    }

    func testLinesAreNeverAddedOutsideTheClip() throws {
        let item = paragraph(text: String(repeating: "訳", count: 80), y: 550)
        let l = try XCTUnwrap(layout([item])["p"])
        XCTAssertLessThanOrEqual(l.backgroundRect.maxY, 600)
        XCTAssertNotEqual(l.stage, .extended)
    }

    func testLineHeightIsDerivedFromTheLines() throws {
        var input = paragraph(text: "訳", rows: 3, style: TextStyleHint(fontSize: 14))
        input.lineFrames = (0..<3).map { CGRect(x: 20, y: 100 + CGFloat($0) * 22, width: 200, height: 17) }
        let l = try XCTUnwrap(layout([input])["p"])
        XCTAssertEqual(l.look.fixedLineHeight(fontSize: 14), 22)
        // One row is needed; the background still hides all three original lines.
        XCTAssertEqual(l.backgroundRect.maxY, 100 + 44 + 17)
    }

    func testMonospacedOriginalUsesMonospacedFont() throws {
        let style = TextStyleHint(fontSize: 12, lineHeight: 15, isMonospaced: true)
        let input = paragraph(text: "ビルドに成功しました", rows: 1, style: style)
        let l = try XCTUnwrap(layout([input])["p"])
        XCTAssertTrue(l.look.monospaced)
        XCTAssertTrue(TextFitter.font(ofSize: 12, monospaced: true).isFixedPitch)
        let string = TextFitter.attributedString("abc", fontSize: 12, color: .white, look: l.look)
        let font = try XCTUnwrap(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch)
        XCTAssertEqual(font.pointSize, 12)
        // Without a known size the min…max fitting still picks the monospaced font.
        let unknown = OverlayLayoutInput(
            id: "u", text: "ビルド", frame: CGRect(x: 20, y: 300, width: 200, height: 15),
            style: TextStyleHint(isMonospaced: true))
        XCTAssertEqual(layout([unknown])["u"]?.look.monospaced, true)
        // The proportional font otherwise.
        XCTAssertFalse(layout([paragraph(text: "訳", rows: 1)])["p"]!.look.monospaced)
    }

    func testUnknownSizeKeepsMinMaxFitting() throws {
        var appearance = OverlayAppearance()
        appearance.minFontSize = 9
        appearance.maxFontSize = 16
        let input = OverlayLayoutInput(id: "u", text: "設定", frame: CGRect(x: 20, y: 100, width: 60, height: 17))
        let l = try XCTUnwrap(layout([input], appearance: appearance, fitter: TextFitter())["u"])
        XCTAssertEqual(l.stage, .original)
        XCTAssertNil(l.look.lineHeightMultiple)
        XCTAssertGreaterThanOrEqual(l.fontSize, 9)
        XCTAssertLessThanOrEqual(l.fontSize, 16)
        // Not widened: the text stays in its frame.
        XCTAssertLessThanOrEqual(l.backgroundRect.maxX, 81.5)
    }

    func testMatchOriginalStyleOffIgnoresTheSize() throws {
        var appearance = OverlayAppearance()
        appearance.matchOriginalStyle = false
        let input = paragraph(text: "訳", rows: 1, style: TextStyleHint(fontSize: 30, isMonospaced: true))
        let l = try XCTUnwrap(layout([input], appearance: appearance, fitter: TextFitter())["p"])
        XCTAssertLessThanOrEqual(l.fontSize, CGFloat(appearance.maxFontSize))
        XCTAssertFalse(l.look.monospaced)
        XCTAssertNil(l.look.lineHeightMultiple)
    }

    func testReportedSizeMuchLargerThanItsLineFollowsTheLine() throws {
        // A zoomed-out page reports CSS sizes: 28 in a 17pt line.
        let input = paragraph(text: "訳", rows: 1, style: TextStyleHint(fontSize: 28))
        let l = try XCTUnwrap(layout([input])["p"])
        XCTAssertLessThan(l.fontSize, 17)
    }

    func testOneLineLabelOfKnownSizeRunsOnToTheRight() throws {
        let label = OverlayLayoutInput(
            id: "ok", text: "了解しました", frame: CGRect(x: 20, y: 100, width: 20, height: 17),
            lineFrames: [CGRect(x: 20, y: 100, width: 20, height: 17)], style: TextStyleHint(fontSize: 13))
        let neighbour = pending("right", y: 100, x: 200, width: 40)
        let l = try XCTUnwrap(layout([label, neighbour])["ok"])
        XCTAssertEqual(l.stage, .original)
        XCTAssertEqual(l.fontSize, 13)
        XCTAssertGreaterThan(l.backgroundRect.maxX, 41.5)
        // Up to the next item on its line at most.
        XCTAssertLessThanOrEqual(l.backgroundRect.maxX, 200)
        XCTAssertEqual(l.background.overlapArea(with: neighbour.frame), 0)
    }

    // MARK: - Paragraph split mid-line

    /// A: the first line and the start of the second; B: the rest of the second line and a third line.
    private func splitParagraph(aText: String, bText: String) -> [OverlayLayoutInput] {
        let style = TextStyleHint(fontSize: 14, lineHeight: 20)
        let a = OverlayLayoutInput(
            id: "a", text: aText, frame: CGRect(x: 20, y: 100, width: 380, height: 37),
            lineFrames: [CGRect(x: 20, y: 100, width: 380, height: 17), CGRect(x: 20, y: 120, width: 130, height: 17)],
            style: style)
        let b = OverlayLayoutInput(
            id: "b", text: bText, frame: CGRect(x: 20, y: 120, width: 380, height: 37),
            lineFrames: [CGRect(x: 154, y: 120, width: 246, height: 17), CGRect(x: 20, y: 140, width: 300, height: 17)],
            style: style)
        return [a, b]
    }

    func testSplitParagraphKeepsBothPartsOfTheSharedLine() throws {
        let inputs = splitParagraph(aText: String(repeating: "あ", count: 30), bText: String(repeating: "い", count: 20))
        let out = layout(inputs, fitter: TextFitter())
        let a = try XCTUnwrap(out["a"])
        let b = try XCTUnwrap(out["b"])
        XCTAssertEqual(a.background.overlapArea(with: b.background), 0)
        // A covers its own part of the shared line (its tail); B's first row starts after it.
        XCTAssertEqual(a.background.rows.count, 2)
        XCTAssertEqual(a.background.rows[1].minY, 120)
        XCTAssertLessThanOrEqual(a.background.rows[1].maxX, 154)
        XCTAssertGreaterThanOrEqual(a.background.rows[1].maxX, 150)
        XCTAssertEqual(b.background.rows.count, 2)
        XCTAssertGreaterThanOrEqual(b.background.rows[0].minX, 150)
        XCTAssertEqual(b.textRect.minX, 20)
        XCTAssertEqual(b.look.firstLineIndent, 134)
        // Neither covers the other's original lines.
        for line in inputs[1].lineFrames { XCTAssertEqual(a.background.overlapArea(with: line), 0) }
        for line in inputs[0].lineFrames { XCTAssertEqual(b.background.overlapArea(with: line), 0) }
    }

    func testSplitParagraphLastLineFlowsIntoTheTail() throws {
        // At 14pt about 27 characters fill the first line; a few more fit the 130pt tail.
        let inputs = splitParagraph(aText: String(repeating: "あ", count: 30), bText: "い")
        let a = try XCTUnwrap(layout(inputs, fitter: TextFitter())["a"])
        XCTAssertEqual(a.stage, .original)
        XCTAssertEqual(a.fontSize, 14)
        // Too long for the tail: shrunk or truncated, never drawn over B.
        let long = splitParagraph(aText: String(repeating: "あ", count: 50), bText: "い")
        let cut = try XCTUnwrap(layout(long, fitter: TextFitter())["a"])
        XCTAssertNotEqual(cut.stage, .original)
        XCTAssertLessThanOrEqual(cut.textRect.maxY, 120.5)
    }

    /// The reported case (Chromium, 16pt em boxes 24pt apart): A ends with the start of a line, B starts later
    /// on that line and wraps below.
    private func webSplit(aText: String, bText: String, style: TextStyleHint, bDrawable: Bool = true)
        -> [OverlayLayoutInput]
    {
        let aLines = [CGRect(x: 40, y: 100, width: 500, height: 16), CGRect(x: 40, y: 124, width: 200, height: 16)]
        let bLines = [CGRect(x: 246, y: 124, width: 294, height: 16), CGRect(x: 40, y: 148, width: 300, height: 16)]
        return [
            OverlayLayoutInput(id: "a", text: aText, frame: aLines[0].union(aLines[1]), lineFrames: aLines, style: style),
            OverlayLayoutInput(
                id: "b", text: bDrawable ? bText : "", frame: bLines[0].union(bLines[1]), lineFrames: bLines,
                style: style, drawable: bDrawable),
        ]
    }

    /// Glyph boxes of the drawn rows (80% of the size high, around each row's middle), from TextKit.
    private func textRows(_ layout: OverlayItemLayout, text: String, fitter: TextFitter) -> [CGRect] {
        let size = layout.fontSize
        let pitch = layout.look.fixedLineHeight(fontSize: size) ?? fitter.lineHeight(fontSize: size, look: layout.look)
        let measured = fitter.measure(text, fontSize: size, maxWidth: layout.textRect.width, look: layout.look)
        let rows = min(
            max(1, Int((measured.height / pitch).rounded())), Int(((layout.textRect.height + 0.01) / pitch).rounded(.down)))
        let last = fitter.lastLineWidth(text, fontSize: size, maxWidth: layout.textRect.width, look: layout.look)
        return (0..<rows).map { k in
            let x = layout.textRect.minX + (k == 0 ? layout.look.firstLineIndent : 0)
            let right = k == rows - 1 ? layout.textRect.minX + last : layout.textRect.minX + measured.width
            let center = layout.textRect.minY + (CGFloat(k) + 0.5) * pitch
            return CGRect(x: x, y: center - 0.4 * size, width: max(0, right - x), height: 0.8 * size)
        }
    }

    private func isInside(_ rect: CGRect, _ shape: OverlayBackgroundShape) -> Bool {
        let r = rect.insetBy(dx: 0.25, dy: 0.25)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.maxX, y: r.maxY)]
            .allSatisfy { p in shape.rows.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(p) } }
    }

    func testSplitParagraphOfUnknownSizeStartsWhereItsOriginalStarts() throws {
        let fitter = TextFitter()
        var notMatched = OverlayAppearance()
        notMatched.matchOriginalStyle = false
        // Size unknown (past the style budget, a failed read), or known but not matched.
        let cases: [(TextStyleHint, OverlayAppearance)] = [
            (TextStyleHint(), OverlayAppearance()), (TextStyleHint(fontSize: 16, lineHeight: 24), notMatched),
        ]
        for (style, appearance) in cases {
            for bText in ["続き", String(repeating: "続", count: 30)] {
                let inputs = webSplit(aText: String(repeating: "訳", count: 30), bText: bText, style: style)
                let out = layout(inputs, appearance: appearance, fitter: fitter)
                let a = try XCTUnwrap(out["a"])
                let b = try XCTUnwrap(out["b"])
                XCTAssertEqual(a.background.overlapArea(with: b.background), 0)
                // B's first line starts where its original does, at the top of its own first row.
                XCTAssertEqual(b.look.firstLineIndent, 206)
                XCTAssertEqual(b.textRect.minY, 124)
                let rows = textRows(b, text: bText, fitter: fitter)
                XCTAssertGreaterThanOrEqual(rows[0].minX, b.background.rows[0].minX)
                // Its next line starts below that line, out of A's part of it.
                let pitch = b.look.fixedLineHeight(fontSize: b.fontSize) ?? fitter.lineHeight(fontSize: b.fontSize, look: b.look)
                XCTAssertGreaterThanOrEqual(b.textRect.minY + pitch, 140)
                for row in rows {
                    XCTAssertTrue(isInside(row, b.background), "\(row) outside \(b.background.rows)")
                    XCTAssertEqual(a.background.overlapArea(with: row), 0)
                    for line in inputs[0].lineFrames { XCTAssertFalse(row.intersects(line)) }
                }
                for row in textRows(a, text: inputs[0].text, fitter: fitter) {
                    XCTAssertTrue(isInside(row, a.background), "\(row) outside \(a.background.rows)")
                }
            }
        }
    }

    func testSplitParagraphShrinksIntoTheTailBeforeTruncating() throws {
        // 50 characters: about 31 fit the first line at 16pt and 12 the start of the next (the tail), so the
        // text is shrunk until the rest fits the tail instead of being cut after the first line.
        let fitter = TextFitter()
        let text = String(repeating: "訳", count: 50)
        let inputs = webSplit(aText: text, bText: "", style: TextStyleHint(fontSize: 16, lineHeight: 24), bDrawable: false)
        let a = try XCTUnwrap(layout(inputs, fitter: fitter)["a"])
        XCTAssertEqual(a.stage, .shrunk)
        XCTAssertGreaterThanOrEqual(a.fontSize, 16 * OverlayLayout.minimumShrink)
        let rows = textRows(a, text: text, fitter: fitter)
        guard rows.count == 2 else { return XCTFail("\(rows.count) rows") }
        // The last line is in the tail, before B's original; every line on A's own background.
        XCTAssertLessThanOrEqual(rows[1].maxX, 244.5)
        XCTAssertGreaterThan(rows[1].maxY, 124)
        for row in rows { XCTAssertTrue(isInside(row, a.background), "\(row) outside \(a.background.rows)") }
        for line in inputs[1].lineFrames { XCTAssertEqual(a.background.overlapArea(with: line), 0) }

        // Size unknown: a larger size is used when the last line can go into the tail.
        var notMatched = OverlayAppearance()
        notMatched.matchOriginalStyle = false
        let medium = String(repeating: "訳", count: 45)
        let fitted = try XCTUnwrap(
            layout(webSplit(aText: medium, bText: "", style: TextStyleHint(), bDrawable: false), appearance: notMatched,
                fitter: fitter)["a"])
        let aboveTheCut = fitter.fit(
            medium, in: CGSize(width: 500, height: 24), minFontSize: 9, maxFontSize: 16, look: fitted.look)
        XCTAssertGreaterThan(fitted.fontSize, aboveTheCut.fontSize)
        XCTAssertEqual(fitted.stage, .original)
        let fittedRows = textRows(fitted, text: medium, fitter: fitter)
        guard fittedRows.count == 2 else { return XCTFail("\(fittedRows.count) rows") }
        XCTAssertLessThanOrEqual(fittedRows[1].maxX, 244.5)
        for row in fittedRows {
            XCTAssertTrue(isInside(row, fitted.background), "\(row) outside \(fitted.background.rows)")
        }
    }

    func testOneLineItemContinuedOnItsLine() throws {
        // A is only the start of a line; B continues it and wraps below A.
        let style = TextStyleHint(fontSize: 14, lineHeight: 20)
        let a = OverlayLayoutInput(
            id: "a", text: String(repeating: "あ", count: 30), frame: CGRect(x: 20, y: 120, width: 130, height: 17),
            lineFrames: [CGRect(x: 20, y: 120, width: 130, height: 17)], style: style)
        let b = OverlayLayoutInput(
            id: "b", text: "い", frame: CGRect(x: 20, y: 120, width: 380, height: 37),
            lineFrames: [CGRect(x: 154, y: 120, width: 246, height: 17), CGRect(x: 20, y: 140, width: 300, height: 17)],
            style: style)
        let out = layout([a, b], fitter: TextFitter())
        let la = try XCTUnwrap(out["a"])
        let lb = try XCTUnwrap(out["b"], "B starts on the same line but is not an overlap")
        XCTAssertEqual(la.background.overlapArea(with: lb.background), 0)
        XCTAssertLessThanOrEqual(la.backgroundRect.maxX, 154)
        XCTAssertLessThanOrEqual(la.backgroundRect.maxY, 137)
        for line in b.lineFrames { XCTAssertEqual(la.background.overlapArea(with: line), 0) }
    }

    func testOverlappingOriginalsCutTheEarlierAtTheLaterTop() throws {
        let a = OverlayLayoutInput(
            id: "a", text: "前の項目", frame: CGRect(x: 20, y: 100, width: 300, height: 60),
            style: TextStyleHint(fontSize: 14, lineHeight: 20))
        let b = OverlayLayoutInput(
            id: "b", text: "後の項目", frame: CGRect(x: 20, y: 140, width: 300, height: 40),
            style: TextStyleHint(fontSize: 14, lineHeight: 20))
        let out = layout([a, b])
        XCTAssertLessThanOrEqual(try XCTUnwrap(out["a"]).backgroundRect.maxY, 140)
        XCTAssertEqual(try XCTUnwrap(out["b"]).backgroundRect.minY, 140)
    }

    func testSameLineOverlapKeepsTheEarlierItemAndVisibleOriginals() {
        let a = OverlayLayoutInput(id: "a", text: "親", frame: CGRect(x: 20, y: 100, width: 300, height: 40))
        let b = OverlayLayoutInput(id: "b", text: "子", frame: CGRect(x: 40, y: 100, width: 100, height: 17))
        XCTAssertEqual(Set(layout([a, b]).keys), ["a"])
        // A pending original on the same line is never covered.
        var pendingB = b
        pendingB.drawable = false
        pendingB.text = ""
        XCTAssertTrue(layout([a, pendingB]).isEmpty)
    }

    func testWebTextBackgroundCoversGlyphsPastTheLineFrame() throws {
        // Chromium reports em-box high runs (16pt lines for 16pt text): descenders reach below them.
        let style = TextStyleHint(fontSize: 16, lineHeight: 26)
        let lines = [CGRect(x: 20, y: 100, width: 300, height: 16), CGRect(x: 20, y: 126, width: 200, height: 16)]
        let text = String(repeating: "訳", count: 30)
        let paragraph = OverlayLayoutInput(
            id: "p", text: text, frame: lines[0].union(lines[1]), lineFrames: lines, style: style)
        let above = OverlayLayoutInput(id: "a", text: "", frame: CGRect(x: 20, y: 80, width: 300, height: 16), drawable: false)
        let below = OverlayLayoutInput(id: "b", text: "", frame: CGRect(x: 20, y: 148, width: 300, height: 16), drawable: false)

        let alone = try XCTUnwrap(layout([paragraph])["p"])
        // 0.22 em above and below.
        XCTAssertEqual(alone.backgroundRect.minY, 100 - 3.5)
        XCTAssertEqual(alone.backgroundRect.maxY, 142 + 3.5)
        // Between neighbours: half of each free gap at most (4 above, 6 below).
        let packed = try XCTUnwrap(layout([above, paragraph, below])["p"])
        XCTAssertEqual(packed.backgroundRect.minY, 98)
        XCTAssertEqual(packed.backgroundRect.maxY, 145)
        // Line boxes (native text, terminals) and unknown sizes get nothing extra.
        let boxes = lines.map { $0.insetBy(dx: 0, dy: -2) }
        var native = paragraph
        native.lineFrames = boxes
        native.frame = boxes[0].union(boxes[1])
        XCTAssertEqual(try XCTUnwrap(layout([native])["p"]).backgroundRect.minY, 98)
        var mono = paragraph
        mono.style.isMonospaced = true
        XCTAssertEqual(try XCTUnwrap(layout([mono])["p"]).backgroundRect.minY, 100)
    }

    func testTerminalBoxBordersStayVisible() throws {
        // One row of text inside a box (9 x 17 cells): side borders on its row, the bottom border right below.
        let style = TextStyleHint(fontSize: 15, lineHeight: 17, isMonospaced: true)
        let row = CGRect(x: 18, y: 100, width: 360, height: 17)
        let text = String(repeating: "訳", count: 60)
        let paragraph = OverlayLayoutInput(id: "p", text: text, frame: row, lineFrames: [row], style: style)
        func obstacle(_ id: String, _ r: CGRect) -> OverlayLayoutInput {
            OverlayLayoutInput(id: id, text: "", frame: r, drawable: false)
        }
        let left = obstacle("l", CGRect(x: 0, y: 100, width: 9, height: 17))
        let right = obstacle("r", CGRect(x: 468, y: 100, width: 9, height: 17))
        let border = obstacle("b", CGRect(x: 0, y: 117, width: 477, height: 17))

        let boxed = try XCTUnwrap(layout([paragraph, left, right, border])["p"])
        XCTAssertGreaterThanOrEqual(boxed.backgroundRect.minX, left.frame.maxX)
        XCTAssertLessThanOrEqual(boxed.backgroundRect.maxX, right.frame.minX)
        XCTAssertLessThanOrEqual(boxed.backgroundRect.maxY, border.frame.minY)
        XCTAssertNotEqual(boxed.stage, .extended)
        // Without the border the same translation takes the rows below.
        let open = try XCTUnwrap(layout([paragraph, left, right])["p"])
        XCTAssertEqual(open.stage, .extended)
        XCTAssertGreaterThan(open.backgroundRect.maxY, border.frame.minY)
    }

    func testSideBySideItemsSplitTheGap() throws {
        let a = OverlayLayoutInput(id: "a", text: "左", frame: CGRect(x: 20, y: 100, width: 100, height: 17))
        let b = OverlayLayoutInput(id: "b", text: "右", frame: CGRect(x: 122, y: 100, width: 100, height: 17))
        let out = layout([a, b])
        let la = try XCTUnwrap(out["a"])
        let lb = try XCTUnwrap(out["b"])
        XCTAssertEqual(la.backgroundRect.maxX, 121)
        XCTAssertEqual(lb.backgroundRect.minX, 121)
    }

    // MARK: - No overlap on random layouts

    /// Deterministic generator (xorshift).
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func cgFloat(_ range: ClosedRange<CGFloat>) -> CGFloat {
            range.lowerBound + CGFloat(Double(next() % 10_000) / 10_000) * (range.upperBound - range.lowerBound)
        }
        mutating func bool(_ probability: Double = 0.5) -> Bool { Double(next() % 1000) / 1000 < probability }
    }

    /// Columns of paragraphs (some split mid-line, some pending, some of unknown size), one-line labels,
    /// side-by-side items; originals never overlap.
    private func randomPage(_ random: inout Random) -> [OverlayLayoutInput] {
        var inputs: [OverlayLayoutInput] = []
        let columns = random.int(1...2)
        for column in 0..<columns {
            let x0 = CGFloat(10 + column * 400) + random.cgFloat(0...20)
            let width = random.cgFloat(120...360)
            var y = random.cgFloat(-30...40)
            while y < 640 {
                let size = CGFloat(random.int(11...16))
                let pitch = (size * random.cgFloat(1.2...1.7)).rounded()
                // Line boxes (native text) or em boxes (web text, whose glyphs reach past them).
                let box = (size * (random.bool(0.4) ? 1.0 : 1.2)).rounded()
                let rows = random.int(1...4)
                let known = random.bool(0.8)
                let style =
                    known
                    ? TextStyleHint(
                        fontSize: Double(size), lineHeight: random.bool() ? Double(pitch) : nil,
                        isMonospaced: random.bool(0.2))
                    : TextStyleHint()
                func line(_ r: Int, from: CGFloat = x0, width w: CGFloat? = nil) -> CGRect {
                    CGRect(
                        x: from, y: y + (pitch - box) / 2 + CGFloat(r) * pitch, width: w ?? width,
                        height: box)
                }
                var lines = (0..<rows).map { line($0) }
                lines[rows - 1].size.width = random.cgFloat(20...width)
                let text = String(repeating: "訳", count: random.int(1...90))
                let id = "i\(inputs.count)"
                if rows >= 2, random.bool(0.25) {
                    // Split mid-line: the second item starts on the first item's last line.
                    let cut = lines[rows - 1].maxX
                    let restWidth = x0 + width - cut - 4
                    if restWidth > 20 {
                        let tailStart = cut + 4
                        let a = Array(lines)
                        let b = [CGRect(x: tailStart, y: lines[rows - 1].minY, width: restWidth, height: box), line(rows)]
                        let frameA = a.dropFirst().reduce(a[0]) { $0.union($1) }
                        let frameB = b.dropFirst().reduce(b[0]) { $0.union($1) }
                        inputs.append(
                            OverlayLayoutInput(
                                id: id, text: text, frame: frameA, lineFrames: known ? a : [], style: style,
                                drawable: random.bool(0.85)))
                        inputs.append(
                            OverlayLayoutInput(
                                id: id + "b", text: String(repeating: "続", count: random.int(1...60)), frame: frameB,
                                lineFrames: known ? b : [], style: style, drawable: random.bool(0.85)))
                        y += CGFloat(rows + 1) * pitch + random.cgFloat(0...14)
                        continue
                    }
                }
                let frame = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
                var item = OverlayLayoutInput(
                    id: id, text: text, frame: random.bool(0.5) ? frame : frame.insetBy(dx: 0, dy: -(pitch - box) / 2),
                    lineFrames: known && random.bool(0.7) ? lines : [], style: style, drawable: random.bool(0.85))
                if !item.drawable { item.text = "" }
                inputs.append(item)
                if rows == 1, random.bool(0.3), column == columns - 1 || frame.maxX + 70 < 400 {
                    // Something else further right on the same line.
                    let x = frame.maxX + random.cgFloat(0...30)
                    inputs.append(
                        OverlayLayoutInput(
                            id: id + "r", text: "右", frame: CGRect(x: x, y: frame.minY, width: 40, height: frame.height),
                            drawable: random.bool()))
                }
                y += CGFloat(rows) * pitch + random.cgFloat(0...14)
            }
        }
        for i in inputs.indices where !inputs[i].drawable { inputs[i].text = "" }
        return inputs
    }

    private func originalLines(_ input: OverlayLayoutInput) -> [CGRect] {
        guard let (area, lines) = OverlayLayout.originalArea(of: input) else { return [] }
        return lines.isEmpty ? [area] : lines
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : max(0, i.width) * max(0, i.height)
    }

    func testRandomLayoutsNeverOverlap() {
        var random = Random(state: 0x9E37_79B9_7F4A_7C15)
        let fitter = gridFitter()
        var drawn = 0
        var stages: [OverlayFitStage: Int] = [:]
        var notched = 0
        var fittedNotched = 0
        var textInTail = 0
        for page in 0..<300 {
            let inputs = randomPage(&random)
            var appearance = OverlayAppearance()
            appearance.matchOriginalStyle = page % 7 != 0
            let clip = CGRect(x: 0, y: random.cgFloat(0...60), width: 800, height: random.cgFloat(300...560))
            let layouts = OverlayLayout.layoutWindow(inputs, clip: clip, appearance: appearance, fitter: fitter)
            drawn += layouts.count
            for l in layouts {
                stages[l.stage, default: 0] += 1
                if l.background.hasNotch { notched += 1 }
            }
            let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
            for (i, a) in layouts.enumerated() {
                let input = byID[a.id]!
                // Only inputs that draw are laid out.
                XCTAssertTrue(input.drawable)
                // Lines are added only inside the clip.
                let area = OverlayLayout.originalArea(of: input)!.area
                XCTAssertLessThanOrEqual(a.backgroundRect.maxY, max(clip.maxY, area.maxY) + 0.01, "page \(page) \(a.id)")
                for b in layouts[(i + 1)...] {
                    let shared = a.background.overlapArea(with: b.background)
                    XCTAssertLessThanOrEqual(shared, 0.01, "page \(page): \(a.id) and \(b.id) overlap by \(shared)")
                }
                let own = originalLines(input)
                for other in inputs where other.id != a.id {
                    let lines = originalLines(other)
                    // Originals that overlap each other (frames only, no lines) may cover each other there.
                    if lines.contains(where: { l in own.contains { overlap(l, $0) > 0.01 } }) { continue }
                    for line in lines {
                        let covered = a.background.overlapArea(with: line)
                        XCTAssertLessThanOrEqual(
                            covered, 0.01, "page \(page): \(a.id) covers the original of \(other.id) by \(covered)")
                    }
                }
                // The text stays on its own background, row by row (a notched first row, a tail).
                let rows = gridTextRows(a, text: input.text)
                for row in rows {
                    XCTAssertTrue(
                        isInside(row, a.background), "page \(page): text of \(a.id) (\(a.stage)) leaves its background at \(row)")
                }
                if a.look.firstLineIndent > 0, a.look.lineHeightMultiple == nil { fittedNotched += 1 }
                if a.background.rows.count >= 2, let tail = a.background.rows.last,
                    tail.maxX < a.background.rows[a.background.rows.count - 2].maxX - 1,
                    rows.contains(where: { $0.maxY > tail.minY + 1 })
                {
                    textInTail += 1
                }
            }
        }
        // The pages exercise every stage and the split-line shapes.
        XCTAssertGreaterThan(drawn, 2000)
        for stage in [OverlayFitStage.original, .extended, .shrunk, .truncated] {
            XCTAssertGreaterThan(stages[stage] ?? 0, 10, "\(stage)")
        }
        XCTAssertGreaterThan(notched, 10)
        XCTAssertGreaterThan(fittedNotched, 3)
        XCTAssertGreaterThan(textInTail, 3)
    }

    /// Glyph boxes of the drawn rows in the grid model (`gridMeasure`: every character `fontSize` wide), 80%
    /// of the size high around each row's middle.
    private func gridTextRows(_ layout: OverlayItemLayout, text: String) -> [CGRect] {
        let size = layout.fontSize
        let look = layout.look
        let width = min(layout.textRect.width, 100_000)
        let pitch = look.fixedLineHeight(fontSize: size) ?? ceil(size * 1.25)
        let perLine = max(1, Int((width / size).rounded(.down)))
        let firstLine = max(0, Int(((width - look.firstLineIndent) / size).rounded(.down)))
        var counts = [min(text.count, firstLine)]
        var rest = text.count - counts[0]
        while rest > 0 {
            counts.append(min(rest, perLine))
            rest -= counts[counts.count - 1]
        }
        let drawn = min(counts.count, Int(((layout.textRect.height + 0.01) / pitch).rounded(.down)))
        return (0..<drawn).compactMap { k in
            guard counts[k] > 0 else { return nil }
            let x = layout.textRect.minX + (k == 0 ? look.firstLineIndent : 0)
            let w = min(CGFloat(counts[k]) * size, layout.textRect.maxX - x)
            let center = layout.textRect.minY + (CGFloat(k) + 0.5) * pitch
            return CGRect(x: x, y: center - 0.4 * size, width: w, height: 0.8 * size)
        }
    }

    // MARK: - Background shape

    func testNotchedShapeRowsAndPath() {
        let shape = OverlayBackgroundShape(rows: [
            CGRect(x: 100, y: 0, width: 200, height: 20), CGRect(x: 0, y: 20, width: 300, height: 40),
            CGRect(x: 0, y: 60, width: 120, height: 20),
        ])
        XCTAssertEqual(shape.rect, CGRect(x: 0, y: 0, width: 300, height: 80))
        XCTAssertEqual(shape.overlapArea(with: CGRect(x: 0, y: 0, width: 100, height: 20)), 0)
        XCTAssertEqual(shape.overlapArea(with: CGRect(x: 120, y: 60, width: 180, height: 20)), 0)
        let path = shape.path(cornerRadius: 2)
        XCTAssertFalse(path.contains(CGPoint(x: 50, y: 10)))
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 10)))
        XCTAssertTrue(path.contains(CGPoint(x: 50, y: 40)))
        XCTAssertFalse(path.contains(CGPoint(x: 200, y: 70)))
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 70)))
        // Rows are made contiguous.
        let gapped = OverlayBackgroundShape(rows: [
            CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 12, width: 10, height: 10),
        ])
        XCTAssertEqual(gapped.rows[1].minY, 10)
    }

    func testCornerRadiusIsSmall() {
        var appearance = OverlayAppearance()
        XCTAssertEqual(OverlayLayout.effectiveCornerRadius(appearance), 2)
        appearance.cornerRadius = 8
        XCTAssertEqual(OverlayLayout.effectiveCornerRadius(appearance), 2)
        appearance.cornerRadius = 1
        XCTAssertEqual(OverlayLayout.effectiveCornerRadius(appearance), 1)
        appearance.cornerRadius = 0
        XCTAssertEqual(OverlayLayout.effectiveCornerRadius(appearance), 0)
    }

    // MARK: - Draft dot

    func testDraftDotFollowsTheTextWhenThereIsRoom() throws {
        let fitter = TextFitter()
        let input = paragraph(text: "短い訳文", rows: 1)
        let l = try XCTUnwrap(layout([input], fitter: fitter)["p"])
        let center = OverlayLayout.indicatorCenter(for: l, text: input.text, fitter: fitter)
        let textEnd = l.textRect.minX + fitter.lastLineWidth(input.text, fontSize: 14, maxWidth: l.textRect.width, look: l.look)
        XCTAssertGreaterThan(center.x, textEnd)
        XCTAssertLessThan(center.x, textEnd + 8)
        XCTAssertEqual(center.y, input.lineFrames[0].midY, accuracy: 0.5)
        // A text cut with "…" ends at the edge: the dot goes to the corner.
        let long = paragraph(text: String(repeating: "訳", count: 200))
        let lt = try XCTUnwrap(layout([long, pending("next", y: 140)], fitter: fitter)["p"])
        XCTAssertEqual(lt.stage, .truncated)
        let corner = OverlayLayout.indicatorCenter(for: lt, text: long.text, fitter: fitter)
        XCTAssertEqual(corner, OverlayRenderer.cornerIndicatorCenter(for: lt.background))
        XCTAssertTrue(lt.backgroundRect.contains(corner))
    }

    // MARK: - Drawing

    func testFixedLineHeightCentersGlyphsInTheRow() throws {
        // Ink of a 14pt line drawn with a 24pt pitch sits in the middle of the row, not at its bottom.
        let look = TextLook(lineHeightMultiple: 24 / 14)
        let string = TextFitter.attributedString("Hxg", fontSize: 14, color: .black, look: look)
        XCTAssertEqual(TextFitter.measureSystemText("Hxg", fontSize: 14, maxWidth: 200, look: look).height, 24)
        let width = 100
        let height = 30
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        string.draw(with: CGRect(x: 0, y: 0, width: 100, height: 24.5), options: TextFitter.drawingOptions, context: nil)
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var rows: [Int] = []
        for y in 0..<height where (0..<width).contains(where: { data[y * width * 4 + $0 * 4 + 3] > 40 }) {
            rows.append(y)
        }
        let top = try XCTUnwrap(rows.first)
        let bottom = try XCTUnwrap(rows.last)
        XCTAssertEqual(Double(top + bottom) / 2, 12, accuracy: 2.5)
    }

    func testFixedPitchMeasuresWholeRows() {
        let look = TextLook(lineHeightMultiple: 21.0 / 14.0, firstLineIndent: 40)
        let text = String(repeating: "日本語の文章です。", count: 6)
        let size = TextFitter.measureSystemText(text, fontSize: 14, maxWidth: 180, look: look)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 21), 0)
        XCTAssertGreaterThan(size.height, 21 * 2)
        XCTAssertLessThanOrEqual(size.width, 180.5)
        // The last line's width agrees with the drawing: it is never wider than the box.
        let last = TextFitter.measureLastLineWidth(text, fontSize: 14, maxWidth: 180, look: look)
        XCTAssertGreaterThan(last, 0)
        XCTAssertLessThanOrEqual(last, 180)
    }
}
