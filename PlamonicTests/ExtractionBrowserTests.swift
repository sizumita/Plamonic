import ApplicationServices
import CoreGraphics
import XCTest

@testable import Plamonic

/// Shapes measured in Safari and Google Chrome (docs/AX_NOTES.md).
final class ExtractionBrowserTests: XCTestCase {
    private func block(_ text: String, mergeable: Bool) -> ExtractionWalk.Piece {
        let part = ExtractionWalk.Part(
            text: text, frame: CGRect(x: 585, y: 618, width: 22, height: 14), visible: true, role: "AXStaticText",
            treeIndex: 0)
        return .block(ExtractionWalk.Run(parts: [part], role: "AXGroup", treeIndex: 0), mergeable: mergeable, keepAlone: true)
    }

    func testInlineWrapperHandsItsSpanGroupUp() {
        // Chrome's Wikipedia citation: AXLink > AXGroup (mw-reflink-text) > "[2]", and a superscript around a
        // plain group (": p1"). Emitted on their own, they split the sentence and land in the wrong place.
        let span = [block("[2]", mergeable: true)]
        XCTAssertTrue(ExtractionWalk.passesBlockThrough(span, role: "AXLink", subrole: nil, isInline: true))
        XCTAssertTrue(
            ExtractionWalk.passesBlockThrough(span, role: "AXGroup", subrole: "AXSuperscriptStyleGroup", isInline: true))
        // A <span> inside a <span>.
        XCTAssertTrue(ExtractionWalk.passesBlockThrough(span, role: "AXGroup", subrole: nil, isInline: false))
    }

    func testBlocksThatCannotJoinALineStayParagraphs() {
        let span = [block("Title", mergeable: true)]
        // A heading or a list item around one span is a paragraph of its own.
        XCTAssertFalse(ExtractionWalk.passesBlockThrough(span, role: "AXHeading", subrole: nil, isInline: false))
        XCTAssertFalse(
            ExtractionWalk.passesBlockThrough(span, role: "AXGroup", subrole: "AXDocumentArticle", isInline: false))
        // A heading inside a link is not mergeable.
        XCTAssertFalse(
            ExtractionWalk.passesBlockThrough([block("Title", mergeable: false)], role: "AXLink", subrole: nil, isInline: true))
        // Two stacked spans in a link (a card) keep the paragraph logic.
        XCTAssertFalse(
            ExtractionWalk.passesBlockThrough(
                [block("Title", mergeable: true), block("Summary", mergeable: true)], role: "AXLink", subrole: nil,
                isInline: true))
        XCTAssertFalse(ExtractionWalk.passesBlockThrough([], role: "AXLink", subrole: nil, isInline: true))
    }

    func testSkipLinksAreInvisible() {
        // "Skip to content" / "Jump to content": a 1x1 link (Safari gives its text a 53x54 frame).
        XCTAssertTrue(ExtractionWalk.isFocusOnlyLink(CGRect(x: 336, y: 148, width: 1, height: 1), minVisible: 3))
        XCTAssertFalse(ExtractionWalk.isFocusOnlyLink(CGRect(x: 361, y: 244, width: 43, height: 19), minVisible: 3))
        // A full-width squashed row is the virtual-list case, decided elsewhere; an unknown frame is kept.
        XCTAssertFalse(ExtractionWalk.isFocusOnlyLink(CGRect(x: 0, y: 0, width: 600, height: 1), minVisible: 3))
        XCTAssertFalse(ExtractionWalk.isFocusOnlyLink(nil, minVisible: 3))
    }

    func testEnablerTrustsTheValueReadBack() {
        // Chrome answers notImplemented to AXEnhancedUserInterface but switches its web tree on.
        XCTAssertEqual(AppAccessibilityEnabler.outcome(.notImplemented) { true }, .success)
        XCTAssertEqual(AppAccessibilityEnabler.outcome(.notImplemented) { false }, .notImplemented)
        XCTAssertEqual(AppAccessibilityEnabler.outcome(.attributeUnsupported) { nil }, .attributeUnsupported)
        XCTAssertEqual(AppAccessibilityEnabler.outcome(.success) { false }, .success)
        // A timeout is retried on the next call.
        XCTAssertNil(AppAccessibilityEnabler.outcome(.cannotComplete) { true })
    }
}
