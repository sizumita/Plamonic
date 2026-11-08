import CoreGraphics
import XCTest

@testable import Plamonic

final class SessionScrollHideTests: XCTestCase {
    // A chat panel and a side chat next to it, with a thread list on the left (outside both).
    private let chat = CGRect(x: 346, y: 82, width: 554, height: 783)
    private let side = CGRect(x: 901, y: 82, width: 566, height: 802)

    private func item(_ id: String, _ frame: CGRect) -> OverlayItem {
        OverlayItem(id: id, axFrame: frame, original: id, translation: id, state: .final)
    }

    func testUnknownAreasHideTheWholeWindow() {
        XCTAssertEqual(ScrollHidePolicy.hit(at: CGPoint(x: 100, y: 300), regions: []), .window)
    }

    func testScrollInOnePanelHidesOnlyThatPanel() {
        XCTAssertEqual(ScrollHidePolicy.hit(at: CGPoint(x: 1000, y: 400), regions: [chat, side]), .regions([side]))
        XCTAssertEqual(ScrollHidePolicy.hit(at: CGPoint(x: 500, y: 400), regions: [chat, side]), .regions([chat]))
    }

    func testScrollOutsideEveryPanelHidesNothing() {
        // The thread list.
        XCTAssertEqual(ScrollHidePolicy.hit(at: CGPoint(x: 100, y: 300), regions: [chat, side]), .none)
        XCTAssertEqual(ScrollHidePolicy.hit(at: CGPoint(x: 100, y: 300), regions: [chat]), .none)
    }

    func testItemsInTheScrolledPanelAreLeftOut() {
        let items = [
            item("main", CGRect(x: 377, y: 185, width: 451, height: 46)),
            item("side", CGRect(x: 918, y: 200, width: 500, height: 40)),
        ]
        XCTAssertEqual(ScrollHidePolicy.visible(items, hiding: [side]).map(\.id), ["main"])
        XCTAssertEqual(ScrollHidePolicy.visible(items, hiding: [chat]).map(\.id), ["side"])
        XCTAssertEqual(ScrollHidePolicy.visible(items, hiding: []).map(\.id), ["main", "side"])
    }

    func testAnItemTouchingThePanelEdgeIsNotInIt() {
        // Ends exactly where the side chat starts.
        let edge = item("edge", CGRect(x: 800, y: 300, width: 101, height: 20))
        XCTAssertEqual(ScrollHidePolicy.visible([edge], hiding: [side]).map(\.id), ["edge"])
    }
}
