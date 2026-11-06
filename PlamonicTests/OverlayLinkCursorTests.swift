import AppKit
import XCTest

@testable import Plamonic

/// Stands in for the real cursor: records what would be set and runs delayed work on a manual clock. The real
/// cursor is never touched.
@MainActor
final class OverlayFakeCursor {
    /// What `currentShape` reports (a set shows at once unless `setsShow` is false).
    var shape: OverlayCursorShape? = .iBeam
    var setsShow = true
    /// What `windowUnderPointer` reports.
    var under = 0
    var enableResult = true
    private(set) var enables = 0
    private(set) var sets: [OverlayCursorShape] = []
    private(set) var clock: TimeInterval = 100
    private var pending: [(at: TimeInterval, action: @MainActor @Sendable () -> Void)] = []

    var system: OverlayCursorSystem {
        OverlayCursorSystem(
            enableBackgroundCursor: { [self] in
                enables += 1
                return enableResult
            },
            currentShape: { [self] in shape },
            set: { [self] in
                sets.append($0)
                if setsShow { shape = $0 }
            },
            windowUnderPointer: { [self] in under },
            after: { [self] delay, action in pending.append((clock + delay, action)) },
            now: { [self] in clock })
    }

    /// Moves the clock and runs what came due, in order.
    func advance(_ seconds: TimeInterval) {
        let end = clock + seconds
        while let next = pending.indices.filter({ pending[$0].at <= end }).min(by: { pending[$0].at < pending[$1].at }) {
            let entry = pending.remove(at: next)
            clock = max(clock, entry.at)
            entry.action()
        }
        clock = end
    }

    func clearSets() {
        sets = []
    }
}

/// The pointing hand over translated links (DESIGN §6.1), with a fake system.
@MainActor
final class OverlayLinkCursorTests: XCTestCase {
    private var fake = OverlayFakeCursor()
    private var live: Set<Int> = [5, 6]
    private var hoverChanges = 0

    private func makeCursor() -> OverlayLinkCursor {
        fake = OverlayFakeCursor()
        let cursor = OverlayLinkCursor(system: fake.system) { [unowned self] in live.contains($0) }
        cursor.onHoverChanged = { [unowned self] in hoverChanges += 1 }
        return cursor
    }

    func testEnterRemembersTheCursorAndSetsTheHand() {
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        XCTAssertEqual(fake.enables, 1)
        XCTAssertEqual(fake.sets, [.pointingHand])
        XCTAssertTrue(cursor.ownsCursor)
        XCTAssertEqual(cursor.hoveredPanel, 5)
        // Leaving onto plain text: the I-beam shown before comes back.
        fake.under = 0
        fake.advance(1)
        cursor.exited(panel: 5)
        XCTAssertEqual(fake.sets.last, .iBeam)
        XCTAssertFalse(cursor.ownsCursor)
        XCTAssertNil(cursor.hoveredPanel)
        // Enabled once for the process.
        fake.under = 6
        cursor.entered(panel: 6)
        XCTAssertEqual(fake.enables, 1)
        // Nothing is set while not over a link panel.
        cursor.exited(panel: 6)
        fake.clearSets()
        cursor.exited(panel: 6)
        cursor.revalidate()
        fake.advance(1)
        XCTAssertEqual(fake.sets, [])
    }

    func testReassertsOnlyWhileHoveredAndOnTop() {
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        // The app below sets its own cursor right after the pointer left it.
        fake.shape = .arrow
        fake.advance(0.06)
        XCTAssertEqual(fake.sets, [.pointingHand, .pointingHand])
        // An app's menu covers the panel: no more.
        fake.shape = .arrow
        fake.under = 42
        fake.advance(0.3)
        XCTAssertEqual(fake.sets, [.pointingHand, .pointingHand])
        // Moves set the hand only while the panel is the window under the pointer.
        cursor.moved(panel: 5)
        XCTAssertEqual(fake.sets.count, 2)
        fake.under = 5
        cursor.moved(panel: 5)
        XCTAssertEqual(fake.sets.count, 3)

        // After a restore, a pending re-assert does nothing.
        let other = makeCursor()
        fake.under = 5
        other.entered(panel: 5)
        fake.under = 0
        other.exited(panel: 5)
        fake.clearSets()
        fake.advance(0.3)
        XCTAssertEqual(fake.sets, [])
    }

    func testMovingBetweenPiecesKeepsTheHand() {
        let cursor = makeCursor()
        // Exit first: the next piece is under the pointer and takes over.
        fake.under = 5
        cursor.entered(panel: 5)
        fake.under = 6
        cursor.exited(panel: 5)
        XCTAssertEqual(cursor.hoveredPanel, 6)
        XCTAssertTrue(cursor.ownsCursor)
        cursor.entered(panel: 6)
        cursor.moved(panel: 6)
        fake.advance(0.5)
        XCTAssertTrue(fake.sets.allSatisfy { $0 == .pointingHand })
        // Enter first: the old panel's exit changes nothing.
        cursor.entered(panel: 5)
        cursor.exited(panel: 6)
        XCTAssertEqual(cursor.hoveredPanel, 5)
        XCTAssertTrue(fake.sets.allSatisfy { $0 == .pointingHand })
        // Off the last piece: back to what showed before the first.
        fake.under = 0
        cursor.exited(panel: 5)
        XCTAssertEqual(fake.sets.last, .iBeam)
        XCTAssertEqual(fake.sets.filter { $0 != .pointingHand }.count, 1)
    }

    func testRestoreLeavesTheAppsOwnCursor() {
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        fake.advance(0.5)
        // The app set its own cursor (the pointer is over its window again).
        fake.shape = .arrow
        fake.clearSets()
        fake.under = 0
        cursor.exited(panel: 5)
        XCTAssertEqual(fake.sets, [])
        XCTAssertFalse(cursor.ownsCursor)
    }

    func testRestoreRightAfterASetTrustsIt() {
        let cursor = makeCursor()
        // The hand does not show yet when the pointer leaves again.
        fake.setsShow = false
        fake.under = 5
        cursor.entered(panel: 5)
        fake.under = 0
        cursor.exited(panel: 5)
        XCTAssertEqual(fake.sets, [.pointingHand, .iBeam])
    }

    /// A set on a move does not count as a recent set: the hand showed already, so the app's own newer cursor
    /// stays when the pointer leaves right after.
    func testAnExitRightAfterAMoveLeavesTheAppsCursor() {
        for (before, app) in [(OverlayCursorShape.iBeam, OverlayCursorShape.arrow), (.arrow, .iBeam)] {
            let cursor = makeCursor()
            fake.shape = before
            fake.under = 5
            cursor.entered(panel: 5)
            fake.advance(0.5)
            for wait in [0.016, 0.008] {
                cursor.moved(panel: 5)
                fake.advance(wait)
            }
            fake.clearSets()
            // The app below set its own cursor as the pointer left onto it.
            fake.shape = app
            fake.under = 0
            cursor.exited(panel: 5)
            XCTAssertEqual(fake.sets, [], "\(before) -> \(app)")
            XCTAssertEqual(fake.shape, app)
            XCTAssertFalse(cursor.ownsCursor)
        }
    }

    /// A timed re-assert that put the hand back over the app's cursor counts as a recent set; one that found the
    /// hand showing does not.
    func testATimedReassertCountsOnlyWhenItChangedTheCursor() {
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        fake.advance(0.04)
        // The app reset the cursor; the re-assert at +0.05 s brings the hand back, but it does not show yet.
        fake.shape = .arrow
        fake.setsShow = false
        fake.advance(0.012)
        XCTAssertEqual(fake.sets, [.pointingHand, .pointingHand])
        fake.under = 0
        cursor.exited(panel: 5)
        XCTAssertEqual(fake.sets.last, .iBeam)

        let other = makeCursor()
        fake.under = 5
        other.entered(panel: 5)
        // The hand still shows at +0.05 s: that re-assert changes nothing.
        fake.advance(0.055)
        XCTAssertEqual(fake.sets, [.pointingHand, .pointingHand])
        fake.shape = .arrow
        fake.under = 0
        fake.clearSets()
        other.exited(panel: 5)
        XCTAssertEqual(fake.sets, [])
    }

    /// After a right click no move re-asserts the hand, and leaving never puts back the cursor from before the
    /// link (the pointer is on the menu or on its way there).
    func testAfterAMenuLeavingNeverRestoresTheCursorFromBefore() {
        for handStillShows in [false, true] {
            let cursor = makeCursor()
            fake.under = 5
            cursor.entered(panel: 5)
            fake.advance(0.3)
            cursor.pauseForMenu()
            fake.clearSets()
            // The app's menu shows its arrow; the pointer is still over the panel for a moment.
            fake.shape = handStillShows ? .pointingHand : .arrow
            cursor.moved(panel: 5)
            XCTAssertEqual(fake.sets, [])
            fake.advance(0.016)
            // Onto the menu window.
            fake.under = 4242
            cursor.exited(panel: 5)
            XCTAssertFalse(fake.sets.contains(.iBeam))
            XCTAssertEqual(fake.sets, handStillShows ? [.arrow] : [])
            XCTAssertFalse(cursor.ownsCursor)
            // The next enter ends that: moves re-assert again.
            fake.under = 5
            cursor.entered(panel: 5)
            fake.clearSets()
            cursor.moved(panel: 5)
            XCTAssertEqual(fake.sets, [.pointingHand])
        }
    }

    /// Plamonic's own menu closed and AppKit put the hand back, after a scan had given it up while the menu was
    /// open: it goes back to the cursor from before the link (at once, or a moment later when it shows late).
    func testAHandPutBackAsTheOwnMenuClosesGoes() {
        for late in [false, true] {
            let cursor = makeCursor()
            fake.under = 5
            cursor.entered(panel: 5)
            fake.advance(0.3)
            cursor.pauseForMenu()
            // The menu covers the pointer and shows its arrow; a scan checks the panels.
            fake.under = 777
            fake.shape = .arrow
            cursor.revalidate()
            XCTAssertFalse(cursor.ownsCursor)
            fake.clearSets()
            // The menu closes over the app's text.
            fake.under = 0
            if !late { fake.shape = .pointingHand }
            cursor.menuClosed()
            if late {
                XCTAssertEqual(fake.sets, [])
                fake.shape = .pointingHand
                fake.advance(OverlayLinkCursor.menuCloseRecheckDelay + 0.01)
            }
            XCTAssertEqual(fake.sets, [.iBeam], "late \(late)")
            XCTAssertEqual(fake.shape, .iBeam)
            // Nothing more later.
            fake.advance(1)
            XCTAssertEqual(fake.sets, [.iBeam])
        }
    }

    func testAfterTheOwnMenuTheHandStaysOnALinkAndTheAppsCursorIsLeft() {
        // Still owning, the pointer back on the link panel: the hand stays.
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        fake.advance(0.3)
        cursor.pauseForMenu()
        fake.clearSets()
        cursor.menuClosed()
        XCTAssertTrue(cursor.ownsCursor)
        fake.advance(1)
        XCTAssertFalse(fake.sets.contains { $0 != .pointingHand })
        // Moves re-assert again.
        cursor.moved(panel: 5)
        XCTAssertEqual(fake.sets.last, .pointingHand)

        // Given up during the menu, then the pointer is on a link panel or the app shows its own cursor: nothing.
        for (under, shape) in [(6, OverlayCursorShape.pointingHand), (0, .arrow)] {
            let other = makeCursor()
            fake.under = 5
            other.entered(panel: 5)
            fake.advance(0.3)
            other.pauseForMenu()
            fake.under = 777
            fake.shape = .arrow
            other.revalidate()
            fake.clearSets()
            fake.under = under
            fake.shape = shape
            other.menuClosed()
            fake.advance(1)
            XCTAssertEqual(fake.sets, [], "under \(under)")
        }

        // No menu was asked for: like revalidate (nothing set while not owning).
        let plain = makeCursor()
        fake.shape = .pointingHand
        plain.menuClosed()
        fake.advance(1)
        XCTAssertEqual(fake.sets, [])

        // Entered again before the second look: it does nothing.
        let again = makeCursor()
        fake.under = 5
        again.entered(panel: 5)
        fake.advance(0.3)
        again.pauseForMenu()
        fake.under = 777
        fake.shape = .arrow
        again.revalidate()
        fake.under = 0
        again.menuClosed()
        fake.under = 5
        again.entered(panel: 5)
        fake.clearSets()
        fake.advance(OverlayLinkCursor.menuCloseRecheckDelay + 0.01)
        XCTAssertFalse(fake.sets.contains { $0 != .pointingHand })
    }

    func testAHandOrAnUnknownCursorBeforeRestoresTheArrow() {
        for before: OverlayCursorShape? in [.pointingHand, nil] {
            let cursor = makeCursor()
            fake.shape = before
            fake.under = 5
            cursor.entered(panel: 5)
            fake.advance(1)
            fake.under = 0
            cursor.exited(panel: 5)
            XCTAssertEqual(fake.sets.last, .arrow, "\(String(describing: before))")
        }
    }

    func testRevalidateFollowsThePanels() {
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        fake.advance(1)
        // The panel moved off a still pointer onto the next link: that one takes over.
        fake.under = 6
        cursor.revalidate()
        XCTAssertEqual(cursor.hoveredPanel, 6)
        XCTAssertEqual(fake.sets.last, .pointingHand)
        // A second look shortly after: the panel under the pointer went away (no exit comes then).
        live.remove(6)
        fake.advance(OverlayLinkCursor.recheckDelay + 0.01)
        XCTAssertFalse(cursor.ownsCursor)
        XCTAssertEqual(fake.sets.last, .iBeam)
        live.insert(6)

        // Recycled at once.
        let other = makeCursor()
        fake.under = 5
        other.entered(panel: 5)
        live.remove(5)
        other.revalidate()
        XCTAssertFalse(other.ownsCursor)
        XCTAssertNil(other.hoveredPanel)
        XCTAssertEqual(fake.sets.last, .iBeam)
        live.insert(5)
    }

    func testBlockersRestore() {
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        fake.advance(1)
        fake.under = 9
        cursor.pointerOnOtherPanel()
        XCTAssertFalse(cursor.ownsCursor)
        XCTAssertEqual(fake.sets.last, .iBeam)
        // Not owning: nothing.
        fake.clearSets()
        cursor.pointerOnOtherPanel()
        XCTAssertEqual(fake.sets, [])
    }

    func testUnavailableBackgroundCursorStaysBestEffort() {
        let cursor = makeCursor()
        fake.enableResult = false
        fake.under = 5
        cursor.entered(panel: 5)
        XCTAssertEqual(fake.sets, [.pointingHand])
        // No delayed re-asserts.
        fake.shape = .arrow
        fake.advance(0.5)
        XCTAssertEqual(fake.sets, [.pointingHand])
        // On enter and move only; tried once.
        cursor.moved(panel: 5)
        cursor.entered(panel: 6)
        XCTAssertEqual(fake.sets, [.pointingHand, .pointingHand, .pointingHand])
        XCTAssertEqual(fake.enables, 1)
    }

    func testAMenuStopsPendingReasserts() {
        let cursor = makeCursor()
        fake.under = 5
        cursor.entered(panel: 5)
        cursor.pauseForMenu()
        fake.shape = .arrow
        fake.advance(0.5)
        XCTAssertEqual(fake.sets, [.pointingHand])
    }

    /// Reads cursor images only (nothing is set).
    func testStandardCursorsAreRecognized() {
        _ = NSApplication.shared
        for shape in [OverlayCursorShape.arrow, .iBeam, .pointingHand, .crosshair, .openHand] {
            XCTAssertEqual(OverlayCursorFingerprints.shape(of: shape.cursor), shape)
        }
        let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        XCTAssertNil(OverlayCursorFingerprints.shape(of: NSCursor(image: image, hotSpot: .zero)))
    }

    func testHoverChangesAreReported() {
        let cursor = makeCursor()
        hoverChanges = 0
        fake.under = 5
        cursor.entered(panel: 5)
        cursor.moved(panel: 5)
        XCTAssertEqual(hoverChanges, 1)
        fake.under = 6
        cursor.exited(panel: 5)
        cursor.entered(panel: 6)
        XCTAssertEqual(hoverChanges, 2)
        fake.under = 0
        cursor.exited(panel: 6)
        XCTAssertEqual(hoverChanges, 3)
    }
}
