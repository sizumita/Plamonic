import AppKit
import XCTest

@testable import Plamonic

/// Resting the pointer on a translation drawn in place shows its original (DESIGN §6.1). No window is ordered
/// on screen (no window number, target not frontmost), except the hover popup at alpha 0 while the original is
/// revealed by the modifier.
@MainActor
final class OverlayHoverOriginalTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let key = WindowKey(pid: 1, windowID: 91)
    private let delay = 0.1

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes, and returns whether it held. The
    /// controller's timers are main-actor tasks that can run well after their delay under load, so what they
    /// bring about is waited for rather than expected after a fixed sleep.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = now + timeout
        while !condition() {
            guard now < deadline else { return false }
            await sleep(0.01)
        }
        return true
    }

    private let lineStyle = TextStyleHint(fontSize: 14, lineHeight: 20, textColor: RGBAColor(red: 0.1, green: 0.1, blue: 0.1))

    /// "a" at y 200 (with a link "ガイド" for "guide"), "b" at y 300.
    private func items(aTranslation: String = "今すぐガイドを読んでください", withA: Bool = true) -> [OverlayItem] {
        var result: [OverlayItem] = []
        if withA {
            let translation = aTranslation as NSString
            let guide = translation.range(of: "ガイド")
            result.append(
                OverlayItem(
                    id: "a", axFrame: CGRect(x: 120, y: 200, width: 300, height: 17), original: "Read the guide now please",
                    translation: aTranslation, state: .final, style: lineStyle,
                    lineFrames: [CGRect(x: 120, y: 200, width: 180, height: 17)],
                    originalLinks: [
                        SegmentLink(
                            range: 9..<14, text: "guide", url: URL(string: "https://example.com/guide"),
                            frames: [CGRect(x: 180, y: 200, width: 40, height: 17)],
                            color: RGBAColor(red: 0, green: 0.3, blue: 0.9), isUnderlined: true)
                    ],
                    links: guide.location == NSNotFound
                        ? [] : [OverlayLink(range: guide.location..<NSMaxRange(guide), linkIndex: 0)]))
        }
        result.append(
            OverlayItem(
                id: "b", axFrame: CGRect(x: 120, y: 300, width: 300, height: 17), original: "Another line here",
                translation: "別の行です", state: .final, style: lineStyle,
                lineFrames: [CGRect(x: 120, y: 300, width: 150, height: 17)]))
        return result
    }

    private func style(
        _ mode: HoverOriginalMode = .inPlace, clickableLinks: Bool = true, hoverDelay: TimeInterval? = nil
    ) -> OverlayStyle {
        OverlayStyle(
            displayStyle: .replace, appearance: OverlayAppearance(),
            interaction: OverlayInteractionSettings(
                hoverOriginal: mode, hoverDelay: hoverDelay ?? delay, clickableLinks: clickableLinks))
    }

    private func update(_ controller: OverlayController, _ items: [OverlayItem], style: OverlayStyle? = nil) {
        controller.update(
            window: key, axWindowFrame: window, axClipRect: nil, cgWindowID: nil, items: items, style: style ?? self.style(),
            targetIsFrontmost: false)
    }

    private func drawnIDs(_ controller: OverlayController) -> [String] {
        controller.contentItems(window: key).map(\.layout.id).sorted()
    }

    func testRestingOnATranslationShowsItsOriginalInPlace() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, items())
        XCTAssertEqual(drawnIDs(controller), ["a", "b"])
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        XCTAssertNil(controller.revealedItem)
        await waitUntil { controller.revealedItem?.id == "b" }
        XCTAssertEqual(controller.revealedItem?.id, "b")
        // Only that item fades out; the other keeps its translation.
        XCTAssertEqual(drawnIDs(controller), ["a"])
        // Its click areas stay; only the revealed item would lose its panels.
        XCTAssertEqual(controller.clickPanelCounts(window: key).links, 1)
        // A redraw of the same item keeps it revealed.
        var changed = items()
        changed[1].translation = "別の行の訳文です"
        update(controller, changed)
        XCTAssertEqual(controller.revealedItem?.id, "b")
        XCTAssertEqual(drawnIDs(controller), ["a"])
        // The item going away ends it.
        update(controller, [changed[0]])
        XCTAssertNil(controller.revealedItem)
    }

    func testOnlyAMoveStartsTheWait() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        // The pointer stops where "b" will appear; the scan that brings it there is not a move.
        update(controller, [])
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        update(controller, items())
        await sleep(delay + 0.1)
        XCTAssertNil(controller.revealedItem)
        // The same point again is not a move either.
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        await sleep(delay + 0.1)
        XCTAssertNil(controller.revealedItem)
        // A real move does.
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 308))
        await waitUntil { controller.revealedItem?.id == "b" }
        XCTAssertEqual(controller.revealedItem?.id, "b")
    }

    func testMovingKeepsRestartingTheWait() async {
        // A long rest, so each move comes well within it even under load, while all the moves together take
        // longer than one rest: a move that did not restart the wait would reveal "b" before the last one.
        let rest = 0.4
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, items(), style: style(hoverDelay: rest))
        var lastMove = now
        var longestGap: TimeInterval = 0
        for i in 0..<6 {
            let moveTime = now
            if i > 0 { longestGap = max(longestGap, moveTime - lastMove) }
            lastMove = moveTime
            controller.updateMouseLocation(ax: CGPoint(x: 130 + CGFloat(i) * 10, y: 308))
            await sleep(0.1)
        }
        longestGap = max(longestGap, now - lastMove)
        // A wait lasts at least `rest` from its move, so none can have ended while every gap was shorter (a
        // longer one only happens when the test is starved, and then the rest may rightly have ended).
        if longestGap < rest {
            XCTAssertNil(controller.revealedItem)
        }
        // Tiny moves count as resting.
        controller.updateMouseLocation(ax: CGPoint(x: 181.5, y: 308))
        await waitUntil { controller.revealedItem?.id == "b" }
        XCTAssertEqual(controller.revealedItem?.id, "b")
    }

    func testLeavingBringsTheTranslationBackAfterAGrace() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, items())
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        await waitUntil { controller.revealedItem?.id == "b" }
        XCTAssertEqual(controller.revealedItem?.id, "b")
        XCTAssertTrue(controller.needsMouseMoves)
        // Out and back in within the grace: stays.
        let out = now
        controller.updateMouseLocation(ax: CGPoint(x: 600, y: 500))
        await sleep(OverlayController.revealLeaveDelay / 3)
        let backIn = now
        controller.updateMouseLocation(ax: CGPoint(x: 135, y: 308))
        await sleep(OverlayController.revealLeaveDelay + 0.05)
        if backIn - out < OverlayController.revealLeaveDelay {
            XCTAssertEqual(controller.revealedItem?.id, "b")
        } else {
            // Starved past the grace (the translation may rightly have come back): the move back in rests on "b"
            // again.
            await waitUntil { controller.revealedItem?.id == "b" }
        }
        // Out for longer: the translation comes back.
        controller.updateMouseLocation(ax: CGPoint(x: 600, y: 500))
        XCTAssertEqual(controller.revealedItem?.id, "b")
        await waitUntil { controller.revealedItem == nil }
        XCTAssertNil(controller.revealedItem)
        XCTAssertEqual(drawnIDs(controller), ["a", "b"])
    }

    func testPointerOnATranslatedLinkShowsNothing() async throws {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, items())
        let link = try XCTUnwrap(controller.clickAreas(window: key).first { $0.isLink })
        XCTAssertEqual(link.itemID, "a")
        controller.updateMouseLocation(ax: CGPoint(x: link.rect.midX, y: link.rect.midY))
        await sleep(delay + 0.1)
        XCTAssertNil(controller.revealedItem)
        // Off the link, on the same translation: it shows.
        controller.updateMouseLocation(ax: CGPoint(x: 125, y: 208))
        await waitUntil { controller.revealedItem?.id == "a" }
        XCTAssertEqual(controller.revealedItem?.id, "a")
        // Right after the reveal its areas only swallow clicks (a click meant for the translation must not press
        // the original link that just appeared); then it has no click panels and the original's own links work.
        // (Checked within a poll of the reveal; the guard lasts at least 0.3 s.)
        XCTAssertEqual(controller.clickPanelCounts(window: key).links, 0)
        XCTAssertEqual(controller.clickPanelCounts(window: key).blockers, 2)
        await waitUntil(timeout: OverlayController.revealGuardInterval + 3) { controller.guardedItem == nil }
        XCTAssertEqual(controller.revealedItem?.id, "a")
        XCTAssertEqual(controller.clickPanelCounts(window: key).links, 0)
        XCTAssertEqual(controller.clickPanelCounts(window: key).blockers, 0)
    }

    func testContentMovingAwayFromAStillPointerEndsTheReveal() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, items())
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        await waitUntil { controller.revealedItem?.id == "b" }
        XCTAssertEqual(controller.revealedItem?.id, "b")
        // "b" moves up and "c" comes under the pointer, which does not move (auto-scroll, streaming text, or a
        // scroll that does not hide the overlay).
        var moved = items()
        moved[1].axFrame.origin.y -= 150
        moved[1].lineFrames = moved[1].lineFrames.map { $0.offsetBy(dx: 0, dy: -150) }
        moved.append(
            OverlayItem(
                id: "c", axFrame: CGRect(x: 120, y: 300, width: 300, height: 17), original: "Third line here",
                translation: "三行目です", state: .final, style: lineStyle,
                lineFrames: [CGRect(x: 120, y: 300, width: 150, height: 17)]))
        update(controller, moved)
        XCTAssertEqual(controller.revealedItem?.id, "b")
        // Its translation comes back after the usual grace.
        await waitUntil { controller.revealedItem == nil }
        XCTAssertNil(controller.revealedItem)
        XCTAssertEqual(drawnIDs(controller), ["a", "b", "c"])
        // Nothing starts under the still pointer.
        await sleep(delay + 0.1)
        XCTAssertNil(controller.revealedItem)
        // Content that keeps the item under the pointer keeps it revealed.
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 308))
        await waitUntil { controller.revealedItem?.id == "c" }
        XCTAssertEqual(controller.revealedItem?.id, "c")
        var redrawn = moved
        redrawn[2].translation = "三行目の訳文です"
        update(controller, redrawn)
        await sleep(OverlayController.revealLeaveDelay + 0.1)
        XCTAssertEqual(controller.revealedItem?.id, "c")
    }

    func testPopupModeShowsTheOriginalInThePopup() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        // The popup stays invisible (alpha 0) while the modifier reveals everything; its owner is still tracked.
        controller.revealOriginal = true
        update(controller, items(), style: style(.popup))
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        XCTAssertNil(controller.hoverPopupItem)
        await waitUntil { controller.hoverPopupItem?.id == "b" }
        XCTAssertEqual(controller.hoverPopupItem?.id, "b")
        XCTAssertNil(controller.revealedItem)
        // The translation stays drawn.
        XCTAssertEqual(drawnIDs(controller), ["a", "b"])
    }

    func testOffModeShowsNothingButCutItemsKeepTheirPopup() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        controller.revealOriginal = true
        var changes = 0
        controller.onNeedsMouseMovesChanged = { changes += 1 }
        update(controller, items(), style: style(.off))
        XCTAssertFalse(controller.needsMouseMoves)
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        await sleep(delay + OverlayController.truncatedHoverDelay)
        XCTAssertNil(controller.revealedItem)
        XCTAssertNil(controller.hoverPopupItem)
        // "b" cut with "…" (a pending item right below leaves no room): its popup still opens.
        var cut = items()
        cut[1].translation = String(repeating: "長い訳文", count: 40)
        cut.append(
            OverlayItem(
                id: "c", axFrame: CGRect(x: 120, y: 318, width: 300, height: 17), original: "Pending", translation: "",
                state: .pending, style: lineStyle))
        update(controller, cut, style: style(.off))
        XCTAssertTrue(controller.hasTruncatedItems)
        XCTAssertTrue(controller.needsMouseMoves)
        XCTAssertEqual(changes, 1)
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 308))
        await waitUntil { controller.hoverPopupItem?.id == "b" }
        XCTAssertEqual(controller.hoverPopupItem?.id, "b")
        XCTAssertNil(controller.revealedItem)
    }

    func testNeedsMouseMovesFollowsTheMode() {
        let controller = OverlayController()
        defer { controller.removeAll() }
        var changes = 0
        controller.onNeedsMouseMovesChanged = { changes += 1 }
        update(controller, items())
        XCTAssertTrue(controller.needsMouseMoves)
        update(controller, items(), style: style(.off))
        XCTAssertFalse(controller.needsMouseMoves)
        update(controller, items(), style: style(.popup))
        XCTAssertTrue(controller.needsMouseMoves)
        controller.remove(window: key)
        XCTAssertFalse(controller.needsMouseMoves)
        XCTAssertEqual(changes, 4)
    }

    func testModifierAndScrollingResetTheHoverState() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, items())
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        await waitUntil { controller.revealedItem?.id == "b" }
        XCTAssertEqual(controller.revealedItem?.id, "b")
        // The modifier hides everything; when it is released the hover starts over.
        controller.revealOriginal = true
        controller.revealOriginal = false
        XCTAssertNil(controller.revealedItem)
        XCTAssertEqual(drawnIDs(controller), ["a", "b"])
        // While the modifier is held, resting does not reveal (everything is hidden already).
        controller.revealOriginal = true
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 308))
        await sleep(delay + 0.1)
        XCTAssertNil(controller.revealedItem)
        controller.revealOriginal = false

        // Scrolling: a wait in progress stops, and a revealed item comes back.
        controller.updateMouseLocation(ax: CGPoint(x: 150, y: 308))
        controller.setTemporarilyHidden(true, window: key)
        await sleep(delay + 0.1)
        XCTAssertNil(controller.revealedItem)
        controller.setTemporarilyHidden(false, window: key)
        controller.updateMouseLocation(ax: CGPoint(x: 160, y: 308))
        await waitUntil { controller.revealedItem?.id == "b" }
        XCTAssertEqual(controller.revealedItem?.id, "b")
        controller.setTemporarilyHidden(true, window: key)
        XCTAssertNil(controller.revealedItem)
    }

    func testScrollingClosesThePopupAndItDoesNotComeBackByItself() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, items(), style: style(.popup))
        controller.updateMouseLocation(ax: CGPoint(x: 130, y: 308))
        await waitUntil { controller.hoverPopupItem?.id == "b" }
        XCTAssertEqual(controller.hoverPopupItem?.id, "b")

        // The content scrolls: the popup closes at once and stays closed when the overlay shows again (the
        // session draws first, then shows the window in the same turn).
        controller.setTemporarilyHidden(true, window: key)
        XCTAssertNil(controller.hoverPopupItem)
        update(controller, items(), style: style(.popup))
        controller.setTemporarilyHidden(false, window: key)
        XCTAssertNil(controller.hoverPopupItem)
        await sleep(delay + 0.1)
        XCTAssertNil(controller.hoverPopupItem)

        // A move and a rest open it again.
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 308))
        await waitUntil { controller.hoverPopupItem?.id == "b" }
        XCTAssertEqual(controller.hoverPopupItem?.id, "b")
    }

    func testAnOpenPopupClosesWhenAWindowComesInFrontOfItsItem() async throws {
        // A real target window far off-screen (the overlay needs one to be on screen); coverage is faked.
        let target = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.orderFrontRegardless()
        defer { target.orderOut(nil) }
        let id = CGWindowID(target.windowNumber)
        await waitUntil { OverlayWindowServer.info(for: id)?.isOnScreen == true }
        guard OverlayWindowServer.info(for: id)?.isOnScreen == true else { throw XCTSkip("no window server") }
        let windowKey = WindowKey(pid: getpid(), windowID: id)
        let frame = CoordinateSpace.axRect(fromCocoa: target.frame)
        let controller = OverlayController()
        defer { controller.removeAll() }
        var covered = false
        var checks = 0
        controller.isPointCovered = { _, _ in
            checks += 1
            return covered
        }
        let origin = CGPoint(x: frame.minX + 20, y: frame.minY + 40)
        let item = OverlayItem(
            id: "p", axFrame: CGRect(x: origin.x, y: origin.y, width: 300, height: 17), original: "Another line here",
            translation: "別の行です", state: .final, style: lineStyle,
            lineFrames: [CGRect(x: origin.x, y: origin.y, width: 150, height: 17)])
        func push() {
            controller.update(
                window: windowKey, axWindowFrame: frame, axClipRect: nil, cgWindowID: id, items: [item],
                style: style(.popup), targetIsFrontmost: false)
        }
        push()
        let point = CGPoint(x: origin.x + 10, y: origin.y + 8)
        controller.updateMouseLocation(ax: point)
        await waitUntil { controller.hoverPopupItem?.id == "p" }
        XCTAssertEqual(controller.hoverPopupItem?.id, "p")
        XCTAssertGreaterThan(checks, 0, "opening checks for covering windows")

        // A sheet or an app's menu comes over the item: the next redraw closes the popup.
        covered = true
        push()
        XCTAssertNil(controller.hoverPopupItem)
        // While covered, a move and a rest do not open it again: the rest ends (it checks for covering windows)
        // and the popup stays closed.
        let checksBeforeRest = checks
        controller.updateMouseLocation(ax: CGPoint(x: point.x + 10, y: point.y))
        await waitUntil { checks > checksBeforeRest }
        XCTAssertNil(controller.hoverPopupItem)

        // Clear again: a move and a rest open it.
        covered = false
        controller.updateMouseLocation(ax: CGPoint(x: point.x + 20, y: point.y))
        await waitUntil { controller.hoverPopupItem?.id == "p" }
        XCTAssertEqual(controller.hoverPopupItem?.id, "p")
        // Moves inside the item check again once the interval has passed.
        covered = true
        await sleep(OverlayController.popupCoverageInterval + 0.05)
        controller.updateMouseLocation(ax: CGPoint(x: point.x + 30, y: point.y))
        XCTAssertNil(controller.hoverPopupItem)
    }
}
