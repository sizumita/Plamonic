import ApplicationServices
import XCTest

@testable import Plamonic

/// Visible content that is not translated: the overlay keeps translations off it (docs/DESIGN.md §6).
final class ExtractionObstacleTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testTerminalBordersPromptsAndToolLinesAreUncovered() {
        let lines = TerminalSegmenter.lines(fromScreen: ExtractionFixtures.claudeCodeScreen)
        let paragraphs = TerminalSegmenter.segment(lines)
        let runs = TerminalSegmenter.uncoveredRuns(lines, paragraphs: paragraphs)
        let rows = Dictionary(grouping: runs, by: \.row)

        // The welcome box: its top and bottom borders are whole runs.
        XCTAssertEqual(rows[0], [TerminalSegmenter.CellRun(row: 0, startCol: 0, endCol: 53)])
        XCTAssertEqual(rows[6], [TerminalSegmenter.CellRun(row: 6, startCol: 0, endCol: 53)])
        // The prompt is visible content that is not translated.
        XCTAssertEqual(rows[8]?.count, 1)
        XCTAssertEqual(rows[8]?.first?.startCol, 0)
        // The tool call and its output.
        XCTAssertNotNil(rows[13])
        XCTAssertNotNil(rows[14])
        // Blank rows never are.
        XCTAssertNil(rows[7])
        XCTAssertNil(rows[9])

        // A translated paragraph's own text never is; its decorative bullet is (one cell, left of the text).
        let answer = paragraphs.first { $0.text.hasPrefix("I'll start by reading") }
        XCTAssertNotNil(answer)
        for span in answer?.spans ?? [] {
            for run in rows[span.row] ?? [] {
                XCTAssertLessThanOrEqual(run.endCol, 1, "row \(span.row): only the bullet is uncovered")
            }
        }
        // Inside the box: the side borders are separate runs around the paragraph text.
        let welcome = paragraphs.first { $0.text.contains("Welcome to Claude Code") }
        if let row = welcome?.spans.first?.row {
            let sideRuns = rows[row] ?? []
            XCTAssertTrue(sideRuns.contains { $0.startCol == 0 && $0.endCol == 1 }, "\(sideRuns)")
            XCTAssertTrue(sideRuns.contains { $0.endCol == 53 }, "\(sideRuns)")
        }
    }

    func testRunsJoinAcrossSingleSpacesOnly() {
        let line = TerminalLine(row: 0, text: "ab c    de", utf16Offset: 0)
        XCTAssertEqual(
            TerminalSegmenter.uncoveredRuns([line], paragraphs: []),
            [
                TerminalSegmenter.CellRun(row: 0, startCol: 0, endCol: 4),
                TerminalSegmenter.CellRun(row: 0, startCol: 8, endCol: 10),
            ])
        // Wide characters take two cells.
        let wide = TerminalLine(row: 3, text: "日本", utf16Offset: 0)
        XCTAssertEqual(
            TerminalSegmenter.uncoveredRuns([wide], paragraphs: []),
            [TerminalSegmenter.CellRun(row: 3, startCol: 0, endCol: 4)])
    }

    // MARK: Soft-wrapped terminal lines

    /// 10-column screen of 9 x 17 cells starting at (100, 200): "abcdefghijklmno" wraps onto two rows.
    private func wrappedGrid() -> (lines: [TerminalLine], grid: TerminalSegmenter.Grid) {
        let lines = TerminalSegmenter.lines(fromScreen: "short\nabcdefghijklmno\n\nend")
        let grid = TerminalSegmenter.Grid(
            cell: CGSize(width: 9, height: 17), left: 100, anchorTop: 217, anchorRow: 1, wrapColumns: 10, lines: lines)
        return (lines, grid)
    }

    func testGridCountsSoftWrappedRows() {
        let (_, grid) = wrappedGrid()
        XCTAssertEqual(grid.screenRow, [0: 0, 1: 1, 2: 3, 3: 4])
        XCTAssertEqual(grid.top(ofScreenRow: 0), 200)
        XCTAssertEqual(grid.top(ofScreenRow: 4), 268)
        // Cells 3..<14 of the wrapped line: the end of its first row and the start of the second.
        let rects = grid.rects(line: 1, startCol: 3, endCol: 14)
        XCTAssertEqual(rects.map(\.screenRow), [1, 2])
        XCTAssertEqual(rects.map(\.rect), [rect(127, 217, 63, 17), rect(100, 234, 36, 17)])
        // Without wrapping a line is one row, however long.
        let flat = TerminalSegmenter.Grid(
            cell: CGSize(width: 9, height: 17), left: 100, anchorTop: 200, anchorRow: 0, wrapColumns: nil,
            lines: wrappedGrid().lines)
        XCTAssertEqual(flat.screenRow, [0: 0, 1: 1, 2: 2, 3: 3])
        XCTAssertEqual(flat.rects(line: 1, startCol: 0, endCol: 15).map(\.rect), [rect(100, 217, 135, 17)])
    }

    func testCellColumnsOfARange() {
        let line = TerminalLine(row: 0, text: "日本 abc", utf16Offset: 40)
        XCTAssertEqual(TerminalSegmenter.Grid.columns(of: line, location: 43, length: 3)?.start, 5)
        XCTAssertEqual(TerminalSegmenter.Grid.columns(of: line, location: 43, length: 3)?.end, 8)
        XCTAssertNil(TerminalSegmenter.Grid.columns(of: line, location: 30, length: 3))
    }

    func testSoftWrappedSpanIsSplitIntoItsRows() {
        let (lines, grid) = wrappedGrid()
        let span = TerminalSpan(row: 1, location: lines[1].utf16Offset, length: 15)
        // Terminal reports the union of both rows.
        let union = rect(100, 217, 90, 34)
        let rows = ExtractionWalk.screenRows(of: span, bounds: union, line: lines[1], grid: grid)
        XCTAssertEqual(rows.map(\.row), [1, 2])
        XCTAssertEqual(rows.map(\.rect), [rect(100, 217, 90, 17), rect(100, 234, 45, 17)])
        XCTAssertEqual(ExtractionWalk.rowPitch(rows), 17)
        // Bounds that do not match the grid are kept whole.
        let odd = rect(100, 217, 90, 51)
        XCTAssertEqual(ExtractionWalk.screenRows(of: span, bounds: odd, line: lines[1], grid: grid).map(\.rect), [odd])
        // One-row spans keep their bounds, numbered by screen row.
        let end = TerminalSpan(row: 3, location: lines[3].utf16Offset, length: 3)
        let endRows = ExtractionWalk.screenRows(of: end, bounds: rect(100, 268, 27, 17), line: lines[3], grid: grid)
        XCTAssertEqual(endRows.map(\.row), [4])
    }

    func testKeptObstaclesLeaveSegmentsAlone() {
        let paragraph = TextSegment(
            id: "p", text: "Hello there", axFrame: rect(100, 100, 300, 40), role: "AXGroup", isEditable: false,
            order: 0)
        let edited = rect(350, 124, 40, 14)  // "(edited)" at the end of the paragraph's last line
        let name = rect(100, 80, 80, 16)  // the author's name above it
        let touching = rect(100, 140, 300, 20)  // the next row, touching the paragraph's bottom edge
        let inner = rect(110, 82, 20, 10)  // inside the name's frame
        let tiny = rect(0, 0, 50, 2)
        let kept = TextExtractor.keptObstacles([edited, name, touching, inner, tiny], segments: [paragraph])
        XCTAssertEqual(kept, [name, touching])

        // A larger obstacle replaces the ones it contains; the limit is kept.
        let block = rect(90, 70, 200, 30)
        XCTAssertEqual(TextExtractor.keptObstacles([inner, name, block], segments: []), [block])
        let many = (0..<10).map { rect(0, CGFloat($0) * 20, 50, 10) }
        XCTAssertEqual(TextExtractor.keptObstacles(many, segments: [], limit: 4).count, 4)
    }

    func testOverTheLimitTheObstaclesNearTheTranslationsAreKept() {
        // A tall terminal: an answer, a long diff (two runs per row), the last answer and the input box below it.
        func answer(_ y: CGFloat) -> TextSegment {
            TextSegment(
                id: "\(y)", text: "answer", axFrame: rect(18, y, 400, 34), role: "AXTextArea", isEditable: false,
                order: 0)
        }
        let first = answer(0)
        let last = answer(1300)
        var obstacles: [CGRect] = []
        for row in 0..<70 {
            let y = 40 + CGFloat(row) * 17
            obstacles += [rect(18, y, 45, 17), rect(81, y, 300, 17)]
        }
        let box = [rect(0, 1340, 500, 17), rect(0, 1357, 27, 17), rect(491, 1357, 9, 17), rect(0, 1374, 500, 17)]
        obstacles += box
        let kept = TextExtractor.keptObstacles(obstacles, segments: [first, last], limit: 100)
        XCTAssertEqual(kept.count, 100)
        // The input box under the last answer is kept, the middle of the diff is not.
        for b in box { XCTAssertTrue(kept.contains(b), "\(b)") }
        XCTAssertTrue(kept.contains(obstacles[0]), "the diff row under the first answer")
        XCTAssertFalse(kept.contains(rect(18, 40 + 35 * 17, 45, 17)), "the middle of the diff")
        // Still in the given order.
        XCTAssertEqual(kept, kept.sorted { obstacles.firstIndex(of: $0)! < obstacles.firstIndex(of: $1)! })

        // Without segments: the last ones (newest content is at the bottom).
        XCTAssertEqual(TextExtractor.keptObstacles(obstacles, segments: [], limit: 4), box)
    }

    func testStackedColumnsCoverTheSameCells() {
        // A box's left side and a diff's line numbers on consecutive rows, a code run per row, a gap row.
        let rects = [
            rect(100, 200, 9, 17), rect(127, 200, 36, 17), rect(181, 200, 90, 17),
            rect(100, 217, 9, 17), rect(127, 217, 36, 17), rect(181, 217, 45, 17),
            rect(100, 234, 9, 17), rect(127, 234, 36, 17),
            // Row 3 is blank: the line numbers start again.
            rect(127, 268, 36, 17),
        ]
        XCTAssertEqual(
            ExtractionWalk.stackedColumns(rects),
            [
                rect(100, 200, 9, 51), rect(127, 200, 36, 51), rect(181, 200, 90, 17), rect(181, 217, 45, 17),
                rect(127, 268, 36, 17),
            ])
        XCTAssertEqual(ExtractionWalk.stackedColumns([]), [])
    }

    // MARK: Buttons

    private func walk(controls: Bool = false) -> ExtractionWalk {
        var profile = AppProfile(bundleID: "com.example.native", displayName: "Native")
        profile.includeControls = controls
        return ExtractionWalk(
            settings: EffectiveSettings(profile: profile, global: GlobalSettings()), limits: ExtractionLimits(),
            ignore: nil, start: CFAbsoluteTimeGetCurrent())
    }

    /// A leaf AXButton as the walk fetches it. Its title is given, so no AX call is made.
    private func button(_ title: String, _ frame: CGRect, classes: [String] = []) -> AXNodeInfo {
        var info = AXNodeInfo(element: AXElement(AXUIElementCreateApplication(1)))
        info.role = "AXButton"
        info.title = title
        info.frame = frame
        info.domClasses = classes
        return info
    }

    private let state = ExtractionWalk.VisitState(
        depth: 1, clip: CGRect(x: 0, y: 0, width: 800, height: 600), inItem: true, itemsOnly: false, transform: nil,
        parentFrame: nil)

    func testNativePushButtonsStayBoundariesAndObstacles() {
        // Sized like their titles, without DOM classes: a dialog's buttons, a "Details…" button on a label's row.
        let w = walk()
        let buttons = [("Cancel", rect(399, 545, 82, 20)), ("Details…", rect(479, 105, 84, 22))]
        for (title, frame) in buttons {
            let piece = w.visitContent(button(title, frame), index: 2, state)
            guard case .boundary = piece else { return XCTFail("\(title) became text: \(piece)") }
        }
        XCTAssertEqual(w.obstacles, buttons.map(\.1))

        // With 「ボタンやメニューの文字も訳す」 each is a segment of its own, never part of a line.
        let piece = walk(controls: true).visitContent(button("Cancel", rect(399, 545, 82, 20)), index: 2, state)
        guard case .block(_, false, true) = piece else { return XCTFail("\(piece)") }
    }

    func testLinkStyledButtonsJoinTheSentenceAndStayObstaclesOtherwise() {
        // Claude's file reference: part of the line around it. Dropped when it is on no line, it stays an
        // obstacle (inside a segment the obstacle is discarded by keptObstacles).
        let w = walk()
        let frame = rect(256, 351, 167, 26)
        let link = button("ExtractionWalk.swift", frame, classes: ["inline", "prose-link"])
        let piece = w.visitContent(link, index: 2, state)
        guard case .block(let run, true, false) = piece else { return XCTFail("\(piece)") }
        XCTAssertEqual(run.parts.map(\.text), ["ExtractionWalk.swift"])
        XCTAssertEqual(w.obstacles, [frame])
    }
}
