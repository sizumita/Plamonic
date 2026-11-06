import AppKit
import XCTest

@testable import Plamonic

final class OverlayCoordinateSpaceTests: XCTestCase {
    private let primaryHeight: CGFloat = 1080

    func testPrimaryScreenRectFlipsAroundPrimaryHeight() {
        let ax = CGRect(x: 100, y: 50, width: 200, height: 30)
        let cocoa = CoordinateSpace.cocoaRect(fromAX: ax, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 1000, width: 200, height: 30))
        XCTAssertEqual(CoordinateSpace.axRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight), ax)
    }

    func testFullPrimaryScreenMapsOntoItself() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(CoordinateSpace.cocoaRect(fromAX: screen, primaryScreenHeight: primaryHeight), screen)
    }

    func testScreenAbovePrimaryHasNegativeAXY() {
        // Cocoa: a 1440pt-high screen stacked on top of the primary screen.
        let cocoa = CGRect(x: 0, y: 1080, width: 2560, height: 1440)
        let ax = CoordinateSpace.axRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: 0, y: -1440, width: 2560, height: 1440))
    }

    func testScreenLeftOfPrimaryBottomAligned() {
        let cocoa = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let ax = CoordinateSpace.axRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: -1440, y: 180, width: 1440, height: 900))
    }

    func testScreenBelowPrimary() {
        let cocoa = CGRect(x: 200, y: -1200, width: 1920, height: 1200)
        let ax = CoordinateSpace.axRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: 200, y: 1080, width: 1920, height: 1200))
    }

    func testPoints() {
        XCTAssertEqual(
            CoordinateSpace.cocoaPoint(fromAX: CGPoint(x: 10, y: 0), primaryScreenHeight: primaryHeight),
            CGPoint(x: 10, y: 1080))
        XCTAssertEqual(
            CoordinateSpace.axPoint(fromCocoa: CGPoint(x: -5, y: 1500), primaryScreenHeight: primaryHeight),
            CGPoint(x: -5, y: -420))
    }

    func testRoundTripIsIdentity() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let rect = CGRect(
                x: CGFloat(Int.random(in: -3000...3000, using: &generator)),
                y: CGFloat(Int.random(in: -3000...3000, using: &generator)),
                width: CGFloat(Int.random(in: 0...2000, using: &generator)),
                height: CGFloat(Int.random(in: 0...2000, using: &generator)))
            let back = CoordinateSpace.axRect(
                fromCocoa: CoordinateSpace.cocoaRect(fromAX: rect, primaryScreenHeight: 1117),
                primaryScreenHeight: 1117)
            XCTAssertEqual(back, rect)
        }
    }

    func testNegativeSizeRectIsStandardized() {
        let ax = CGRect(x: 100, y: 100, width: -50, height: -20)
        let cocoa = CoordinateSpace.cocoaRect(fromAX: ax, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(cocoa, CGRect(x: 50, y: 980, width: 50, height: 20))
    }

    func testScreenIndexPicksLargestOverlap() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]
        XCTAssertEqual(CoordinateSpace.screenIndex(for: CGRect(x: 1800, y: 100, width: 400, height: 50), screens: screens), 1)
        XCTAssertEqual(CoordinateSpace.screenIndex(for: CGRect(x: 100, y: 100, width: 10, height: 10), screens: screens), 0)
        // Off every screen: the nearest one.
        XCTAssertEqual(CoordinateSpace.screenIndex(for: CGRect(x: 5000, y: 100, width: 10, height: 10), screens: screens), 1)
        XCTAssertEqual(CoordinateSpace.screenIndex(for: CGRect(x: -900, y: 10, width: 10, height: 10), screens: screens), 0)
        XCTAssertNil(CoordinateSpace.screenIndex(for: .zero, screens: []))
    }

    @MainActor
    func testLiveConversionUsesFirstScreen() throws {
        let primary = try XCTUnwrap(NSScreen.screens.first)
        XCTAssertEqual(primary.frame.origin, .zero)
        let ax = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(
            CoordinateSpace.cocoaRect(fromAX: ax),
            CoordinateSpace.cocoaRect(fromAX: ax, primaryScreenHeight: primary.frame.height))
        // Every screen converted to AX and back is unchanged; the primary starts at the AX origin.
        let screens = CoordinateSpace.axScreens()
        XCTAssertEqual(screens.first?.frame.origin, .zero)
        for (screen, ns) in zip(screens, NSScreen.screens) {
            XCTAssertEqual(CoordinateSpace.cocoaRect(fromAX: screen.frame), ns.frame)
            XCTAssertTrue(screen.frame.contains(screen.visibleFrame))
        }
    }
}
