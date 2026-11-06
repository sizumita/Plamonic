import AppKit
import XCTest

@testable import Plamonic

/// The original's look (font size, line pitch, color, line rectangles) and the merge of overlapping pieces.
/// Frames are synthetic, shaped like what Chromium and Terminal report (see docs/DESIGN.md §6).
final class ExtractionStyleTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Reported style

    private func attributed(_ runs: [(String, [String: Any])]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (text, attrs) in runs {
            var keyed: [NSAttributedString.Key: Any] = [:]
            for (k, v) in attrs { keyed[NSAttributedString.Key(k)] = v }
            s.append(NSAttributedString(string: text, attributes: keyed))
        }
        return s
    }

    func testParsePicksTheRunWithMostVisibleCharacters() throws {
        let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let pink = CGColor(srgbRed: 0.9, green: 0.5, blue: 0.7, alpha: 1)
        let s = attributed([
            ("ファイル参照は ", ["AXFont": ["AXFontSize": 16], "AXForegroundColor": gray]),
            ("ExtractionWalk.swift", ["AXFont": ["AXFontSize": 14, "AXFontName": "Menlo-Regular"], "AXForegroundColor": pink]),
            ("                         ", ["AXFont": ["AXFontSize": 30]]),
            (" のように描画されるため、段落の境界として扱われていました。", ["AXFont": ["AXFontSize": 16], "AXForegroundColor": gray]),
        ])
        let style = try XCTUnwrap(TextStyleReader.parse(s))
        XCTAssertEqual(style.fontSize, 16)
        XCTAssertFalse(style.isMonospaced)
        let color = try XCTUnwrap(style.textColor)
        XCTAssertEqual(color.red, color.green, accuracy: 0.001)
        XCTAssertEqual(color.red, 0.5, accuracy: 0.03)
    }

    func testParseMonospacedFontAndColorConversion() throws {
        let s = attributed([
            ("let x = 1", ["AXFont": ["AXFontSize": 13, "AXFontName": "Menlo-Regular"], "AXForegroundColor": CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)])
        ])
        let style = try XCTUnwrap(TextStyleReader.parse(s))
        XCTAssertEqual(style.fontSize, 13)
        XCTAssertTrue(style.isMonospaced)
        XCTAssertEqual(style.textColor?.red ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(style.textColor?.green ?? 1, 0, accuracy: 0.001)
        // Colors in other spaces (Chromium sends device gray / RGB) come out as sRGB.
        let gray = TextStyleReader.rgba(CGColor(gray: 0.5, alpha: 0.8))
        XCTAssertEqual(gray?.red ?? 0, gray?.blue ?? 1, accuracy: 0.001)
        XCTAssertEqual(gray?.alpha ?? 0, 0.8, accuracy: 0.001)
        // No size and no color: nothing to report.
        XCTAssertNil(TextStyleReader.parse(attributed([("plain", [:])])))
        XCTAssertNil(TextStyleReader.parse(NSAttributedString(string: "")))
    }

    func testMonospacedNames() {
        XCTAssertTrue(TextStyleReader.defaultIsMonospaced("SFMono-Regular", nil))
        XCTAssertTrue(TextStyleReader.defaultIsMonospaced(nil, "Courier New"))
        XCTAssertFalse(TextStyleReader.defaultIsMonospaced("Helvetica", nil))
        XCTAssertFalse(TextStyleReader.defaultIsMonospaced("NoSuchFont-Regular", nil))
    }

    // MARK: Line geometry (Chromium runs)

    /// <li><p><strong>…</strong> text <code>…</code> text over three lines</p></li> at 16 px / line-height 26 px.
    private let listItemRuns = [
        CGRect(x: 140, y: 262, width: 101, height: 16),  // strong
        CGRect(x: 241, y: 262, width: 229, height: 16),  // text before the code span
        CGRect(x: 474, y: 263, width: 93, height: 17),  // code
        CGRect(x: 140, y: 262, width: 660, height: 68),  // text wrapping over three lines
    ]

    func testTextHeightIgnoresRunsOverSeveralLines() {
        XCTAssertEqual(LineGeometry.textHeight(runs: listItemRuns, fontSize: 16), 16)
        // Without a size, runs much taller than the smallest are not one line.
        XCTAssertEqual(LineGeometry.textHeight(runs: listItemRuns, fontSize: nil), 16)
    }

    func testPitchFromARunSpanningSeveralLines() {
        XCTAssertEqual(LineGeometry.linePitch(runs: listItemRuns, fontSize: 16), 26)
        // Claude: 15 px text, 20 pt runs, one text node over three lines (72 pt): 26 pt pitch.
        let claude = [rect(789, 948, 236, 20), rect(789, 948, 671, 72)]
        XCTAssertEqual(LineGeometry.linePitch(runs: claude, fontSize: 15), 26)
    }

    func testExactGapsWin() {
        // Two single-line runs on consecutive lines: the gap is the pitch.
        let runs = [rect(140, 450, 118, 16), rect(140, 450, 645, 42), rect(181, 477, 144, 17), rect(329, 476, 234, 16)]
        let g = LineGeometry.gaps(runs: runs, fontSize: 16)
        XCTAssertEqual(g?.direct.isEmpty, false)
        XCTAssertEqual(LineGeometry.linePitch(runs: runs, fontSize: 16) ?? 0, 26, accuracy: 0.6)
    }

    func testWindowPitchDividesLongGaps() {
        // Discord: one text node of six lines (explicit line breaks), 22 pt pitch measured elsewhere in the window.
        let run = [rect(1173, 381, 304, 132)]
        XCTAssertNil(LineGeometry.linePitch(runs: run, fontSize: 16), "no single-line run: text height unknown")
        XCTAssertEqual(LineGeometry.linePitch(runs: run, fontSize: 16, textHeight: 22, windowPitch: 22), 22)
        // Without the window's pitch the most usual spacing (about 1.4 em) is chosen.
        XCTAssertEqual(LineGeometry.linePitch(runs: run, fontSize: 16, textHeight: 22), 22)
    }

    func testOneLineParagraphHasNoPitch() {
        XCTAssertNil(LineGeometry.linePitch(runs: [rect(100, 220, 638, 16)], fontSize: 16))
    }

    func testLineFramesOnlyForSingleLineRuns() {
        let marker = rect(120, 513, 20, 26)
        let lines = LineGeometry.lineFrames(
            runs: [rect(140, 518, 111, 16), rect(140, 544, 60, 16)], markers: [marker], fontSize: 16)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].minX, 120, "the list marker joins the first line")
        XCTAssertEqual(lines[1], rect(140, 544, 60, 16))
        XCTAssertEqual(LineGeometry.lineFrames(runs: listItemRuns, fontSize: 16), [], "line ends of a wrapped run are unknown")
    }

    // MARK: Terminal

    func testTerminalFontSizeFromCells() {
        XCTAssertEqual(TerminalMetrics.fontSize(cellWidth: 9, rowHeight: 17), 15)
        XCTAssertEqual(TerminalMetrics.fontSize(cellWidth: 7.2, rowHeight: 15), 12)
        // Line spacing 1.6: the advance still decides.
        XCTAssertEqual(TerminalMetrics.fontSize(cellWidth: 7.2, rowHeight: 19), 12)
        // Cells no 0.6 em font gives: fall back to the row height.
        XCTAssertEqual(TerminalMetrics.fontSize(cellWidth: 20, rowHeight: 17), 14)
    }

    func testTerminalRowPitch() {
        let rows: [(row: Int, rect: CGRect)] = [(4, rect(439, 755, 576, 17)), (6, rect(439, 789, 400, 17))]
        XCTAssertEqual(ExtractionWalk.rowPitch(rows), 17)
        XCTAssertNil(ExtractionWalk.rowPitch([(4, rect(0, 0, 10, 17))]))
    }

    // MARK: Runs and inline buttons

    private func part(
        _ text: String, _ frame: CGRect, role: String = "AXStaticText", code: Bool = false
    ) -> ExtractionWalk.Part {
        ExtractionWalk.Part(
            text: text, frame: frame, visible: true, role: role, treeIndex: 0,
            element: AXElement(AXUIElementCreateSystemWide()), isCode: code, isWhole: true)
    }

    func testDescribeRunsExcludesMarkersAndFindsCode() {
        var s = RawSegment(text: "", frame: .zero, role: "AXGroup", isEditable: false, treeIndex: 0)
        ExtractionWalk.describeRuns(
            [part("1. ", rect(120, 257, 20, 26), role: "AXListMarker"), part("重なりの解消", rect(140, 262, 96, 16))],
            into: &s)
        XCTAssertEqual(s.markerFrames, [rect(120, 257, 20, 26)])
        XCTAssertEqual(s.runFrames, [rect(140, 262, 96, 16)])
        XCTAssertNotNil(s.styleSource)
        XCTAssertEqual(s.dominantEm ?? 0, 16, accuracy: 0.01)
        XCTAssertFalse(s.style.isMonospaced)

        var c = RawSegment(text: "", frame: .zero, role: "AXGroup", isEditable: false, treeIndex: 0)
        ExtractionWalk.describeRuns(
            [part("run ", rect(0, 0, 30, 16)), part("git status --short", rect(30, 0, 150, 17), code: true)], into: &c)
        XCTAssertTrue(c.style.isMonospaced, "mostly inline code")
    }

    func testCJKEm() {
        XCTAssertEqual(ExtractionWalk.cjkEm("今回の修正では、オーバーレイ", width: 224) ?? 0, 16, accuracy: 0.01)
        XCTAssertNil(ExtractionWalk.cjkEm("mostly latin text 字字", width: 200))
        XCTAssertNil(ExtractionWalk.cjkEm("字字", width: 32), "too short to measure")
    }

    func testInlineButtons() {
        // Claude's file references: link-styled buttons inside prose.
        XCTAssertTrue(ExtractionWalk.looksLikeInlineText("ExtractionWalk.swift", frame: rect(256, 351, 167, 26)))
        XCTAssertTrue(ExtractionWalk.looksLikeInlineText("main.rs", frame: rect(795, 600, 60, 20)))
        // Wrapped over two lines.
        XCTAssertTrue(ExtractionWalk.looksLikeInlineText("SessionScanner.swift", frame: rect(140, 539, 660, 52)))
        // Icon buttons carry long labels in small frames.
        XCTAssertFalse(ExtractionWalk.looksLikeInlineText("メッセージをコピーしてクリップボードへ", frame: rect(975, 573, 14, 24)))
        // Padded push buttons are much wider than their title.
        XCTAssertFalse(ExtractionWalk.looksLikeInlineText("OK", frame: rect(0, 0, 120, 28)))
        // Web buttons must look like links; plain "Edit" buttons next to a name stay boundaries.
        XCTAssertTrue(ExtractionWalk.hasLinkStyle(["aria-busy:opacity-60", "inline", "box-decoration-clone", "prose-link"]))
        XCTAssertTrue(ExtractionWalk.hasLinkStyle(["mention", "wrapper_f61b3a"]))
        XCTAssertFalse(ExtractionWalk.hasLinkStyle(["cds-reset", "inline-flex", "shrink-0"]))
        // Native push buttons have no DOM classes, and most are sized like their title: the geometry cannot
        // tell them from text, so they never take the inline path.
        XCTAssertTrue(ExtractionWalk.looksLikeInlineText("Cancel", frame: rect(0, 0, 82, 20)))
        XCTAssertFalse(ExtractionWalk.hasLinkStyle([]))
    }

    // MARK: Zoom

    func testZoomFromCJKRuns() {
        var z = ZoomEstimator()
        XCTAssertEqual(z.factor(pid: 1), 1)
        for _ in 0..<5 { z.add(pid: 1, reportedSize: 16, measuredEm: 20, runHeight: 20) }
        XCTAssertEqual(z.factor(pid: 1), 1.25)
        // Measurement noise around 1 is no zoom.
        z.add(pid: 2, reportedSize: 14, measuredEm: 13.9, runHeight: 18)
        z.add(pid: 2, reportedSize: 14, measuredEm: 14.2, runHeight: 18)
        XCTAssertEqual(z.factor(pid: 2), 1)
        // A run over two lines is not a sample, nor is a run cut short with an ellipsis.
        for _ in 0..<3 { z.add(pid: 3, reportedSize: 16, measuredEm: 8, runHeight: 42) }
        for _ in 0..<3 { z.add(pid: 3, reportedSize: 16, measuredEm: 3.6, runHeight: 21) }
        XCTAssertEqual(z.factor(pid: 3), 1)
        // One sample is not enough.
        z.add(pid: 4, reportedSize: 16, measuredEm: 20, runHeight: 20)
        XCTAssertEqual(z.factor(pid: 4), 1)
        z.forget(pid: 1)
        XCTAssertEqual(z.factor(pid: 1), 1)
    }

    // MARK: Resolving

    func testApplyKeepsPlausibleSizesAndTerminalEstimates() {
        var web = TextStyleHint()
        TextExtractor.apply(ReportedTextStyle(fontSize: 14, textColor: RGBAColor(red: 1, green: 1, blue: 1)), to: &web, runs: [rect(0, 0, 100, 20)])
        XCTAssertEqual(web.fontSize, 14)
        XCTAssertNotNil(web.textColor)

        // Text drawn far larger than the reported size (a zoom the app does not report): trust the frames.
        var zoomed = TextStyleHint()
        TextExtractor.apply(ReportedTextStyle(fontSize: 10), to: &zoomed, runs: [rect(0, 0, 100, 30)])
        XCTAssertEqual(zoomed.fontSize, 24)

        var terminal = TextStyleHint(fontSize: 15, lineHeight: 17, isMonospaced: true)
        TextExtractor.apply(ReportedTextStyle(fontSize: 30), to: &terminal, runs: [])
        XCTAssertEqual(terminal.fontSize, 15, "an implausible report does not replace the cell estimate")
        TextExtractor.apply(ReportedTextStyle(fontSize: 14), to: &terminal, runs: [])
        XCTAssertEqual(terminal.fontSize, 14)
    }

    func testClippedRunsDoNotDecideTheSize() {
        // A run cut to 8 pt by the scroll view's edge says nothing about the font: the reported size stays.
        var s = RawSegment(text: "x", frame: rect(1173, 320, 131, 8), role: "AXGroup", isEditable: false, treeIndex: 0)
        s.runFrames = [rect(1173, 320, 131, 8)]
        s.runIsWhole = [false]
        let styles = TextExtractor.resolveStyles([s], reported: [ReportedTextStyle(fontSize: 16)])
        XCTAssertEqual(styles[0].style.fontSize, 16)
        XCTAssertEqual(styles[0].lineFrames.count, 1, "the visible part of the line is still covered")
    }

    func testResolveStylesSharesThePitchWithOneLineParagraphs() {
        func segment(_ runs: [CGRect]) -> RawSegment {
            var s = RawSegment(
                text: "x", frame: runs.dropFirst().reduce(runs[0]) { $0.union($1) }, role: "AXGroup",
                isEditable: false, treeIndex: 0)
            s.runFrames = runs
            s.runIsWhole = runs.map { _ in true }
            return s
        }
        let segments = [segment(listItemRuns), segment([rect(100, 400, 300, 16)]), segment([rect(100, 500, 300, 68)])]
        let reported = Array(repeating: ReportedTextStyle(fontSize: 16) as ReportedTextStyle?, count: 3)
        let styles = TextExtractor.resolveStyles(segments, reported: reported)
        XCTAssertEqual(styles.map(\.style.lineHeight), [26, 26, 26])
        XCTAssertEqual(styles[1].lineFrames, [rect(100, 400, 300, 16)])
        XCTAssertEqual(styles[0].lineFrames, [])
    }
}

/// One paragraph split into two segments (the user's report: a numbered list item whose second half overlapped
/// the first half's second line) is merged back; neighbours that merely touch are not.
final class ExtractionOverlapMergeTests: XCTestCase {
    private func raw(
        _ text: String, _ frame: CGRect, block: Int = -1, emit: Int, editable: Bool = false
    ) -> (segment: RawSegment, text: String) {
        var s = RawSegment(text: text, frame: frame, role: "AXGroup", isEditable: editable, treeIndex: emit)
        s.blockIndex = block
        s.emitIndex = emit
        s.runFrames = [frame]
        s.runIsWhole = [true]
        return (s, text)
    }

    private func merge(_ items: [(segment: RawSegment, text: String)], max: Int = 2000) -> [(segment: RawSegment, text: String)] {
        SegmentMerger.merge(items.sorted { TextExtractor.readingOrder($0.segment, $1.segment) }, maxCharacters: max).items
    }

    func testSplitListItemIsMergedBack() {
        // "2. ファイル参照は" ends on line 1; the rest starts mid-line 1 and covers lines 1–3 (bounding boxes).
        let first = raw("2. ファイル参照は", CGRect(x: 120, y: 351, width: 140, height: 26), block: 7, emit: 3)
        let second = raw("のようにボタンとして描画されるため、段落の境界として扱われていました。", CGRect(x: 140, y: 356, width: 656, height: 68), block: 7, emit: 4)
        let result = merge([second, first])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "2. ファイル参照はのようにボタンとして描画されるため、段落の境界として扱われていました。")
        XCTAssertEqual(result[0].segment.frame, CGRect(x: 120, y: 351, width: 676, height: 73))
        XCTAssertEqual(result[0].segment.runFrames.count, 2)
    }

    func testLatinPiecesJoinWithASpace() {
        let a = raw("The build failed because", CGRect(x: 100, y: 100, width: 600, height: 46), block: 2, emit: 0)
        let b = raw("could not find the module.", CGRect(x: 100, y: 120, width: 600, height: 46), block: 2, emit: 1)
        XCTAssertEqual(merge([a, b]).map(\.text), ["The build failed because could not find the module."])
    }

    func testNeighboursThatOnlyTouchStaySeparate() {
        // Negative margins: the status line overlaps the paragraph below by 6 pt.
        let a = raw("Thinking about the request", CGRect(x: 748, y: 615, width: 806, height: 32), block: 1, emit: 0)
        let b = raw("Here is the answer to the request.", CGRect(x: 752, y: 641, width: 700, height: 46), block: 1, emit: 1)
        XCTAssertEqual(merge([a, b]).count, 2)
        // Side by side on the same line.
        let c = raw("left column text", CGRect(x: 0, y: 0, width: 300, height: 20), block: 3, emit: 2)
        let d = raw("right column text", CGRect(x: 310, y: 0, width: 300, height: 20), block: 3, emit: 3)
        XCTAssertEqual(merge([c, d]).count, 2)
    }

    func testUnrelatedOverlapsStaySeparate() {
        // A sticky header over a message: different blocks, far apart in the tree.
        let header = raw("Today", CGRect(x: 100, y: 300, width: 200, height: 20), block: 1, emit: 0)
        let message = raw("a message under the sticky header", CGRect(x: 100, y: 290, width: 600, height: 60), block: 9, emit: 12)
        XCTAssertEqual(merge([header, message]).count, 2)
        // Editable text never joins static text.
        let field = raw("draft", CGRect(x: 100, y: 300, width: 600, height: 40), block: 1, emit: 1, editable: true)
        let text = raw("static text", CGRect(x: 100, y: 300, width: 600, height: 40), block: 1, emit: 2)
        XCTAssertEqual(merge([field, text]).count, 2)
    }

    func testMergeRespectsTheLengthLimit() {
        let a = raw("aaaa aaaa", CGRect(x: 0, y: 0, width: 600, height: 46), block: 1, emit: 0)
        let b = raw("bbbb bbbb", CGRect(x: 0, y: 20, width: 600, height: 46), block: 1, emit: 1)
        XCTAssertEqual(merge([a, b], max: 12).count, 2)
        XCTAssertEqual(merge([a, b], max: 19).count, 1)
    }

    func testThreePiecesAndOrderAreKept() {
        let a = raw("one", CGRect(x: 0, y: 0, width: 600, height: 46), block: 1, emit: 0)
        let b = raw("two", CGRect(x: 0, y: 20, width: 600, height: 46), block: 1, emit: 1)
        let c = raw("three", CGRect(x: 0, y: 40, width: 600, height: 46), block: 1, emit: 2)
        let other = raw("separate paragraph", CGRect(x: 0, y: 120, width: 600, height: 20), block: 2, emit: 3)
        let result = merge([c, other, a, b])
        XCTAssertEqual(result.map(\.text), ["one two three", "separate paragraph"])
    }
}
