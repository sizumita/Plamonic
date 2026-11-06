import AppKit
import XCTest

@testable import Plamonic

/// Translated links under the pointer and right clicks on them (DESIGN §6.1): the cursor (a fake: the real one
/// is never touched), the hover look drawn by the canvas, and the context menu request. Events are synthetic
/// NSEvents handed to the panel views (nothing is posted); no panel goes on screen.
@MainActor
final class OverlayLinkHoverTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let key = WindowKey(pid: 1, windowID: 93)
    private let guideURL = URL(string: "https://example.com/guide")!
    private let longURL = "https://example.com/docs/getting-started/install-on-macos?lang=en&ref=overlay-demo"
    private var fake = OverlayFakeCursor()

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes. The controller's rest and leave timers
    /// are real `Task.sleep`s, which run late on a busy machine (CI), so a fixed sleep must not stand in for them.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            await sleep(0.01)
        }
        return true
    }

    /// Rests the pointer on `point` (an item's plain text) until the hover popup shows `item`. Another app
    /// becoming active closes every popup (they belong to the app that was active), and only a new rest opens it
    /// again: when that happens meanwhile (someone is using this Mac), the pointer moves a few points and rests
    /// again.
    private func restUntilHoverPopup(_ controller: OverlayController, at point: CGPoint, item: String) async -> Bool {
        @MainActor final class Count { var value = 0 }
        let activations = Count()
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { activations.value += 1 } }
        defer { center.removeObserver(token) }
        var handled = 0
        var nudge: CGFloat = 0
        controller.updateMouseLocation(ax: point)
        return await waitUntil {
            if controller.hoverPopupItem?.id == item { return true }
            if activations.value != handled {
                handled = activations.value
                nudge = 5 - nudge
                controller.updateMouseLocation(ax: CGPoint(x: point.x + nudge, y: point.y))
            }
            return false
        }
    }

    private func makeController() -> OverlayController {
        fake = OverlayFakeCursor()
        return OverlayController(cursorSystem: fake.system)
    }

    /// "a": the link "ガイド" for "guide"; the original link sits right of it, so part of it is a blocker.
    private func item(origin: CGPoint = CGPoint(x: 120, y: 200), underlined: Bool = false) -> OverlayItem {
        let translation = "今すぐガイドを読んでください"
        let guide = (translation as NSString).range(of: "ガイド")
        return OverlayItem(
            id: "a", axFrame: CGRect(x: origin.x, y: origin.y, width: 300, height: 17), original: "Read the guide now please",
            translation: translation, state: .final,
            style: TextStyleHint(fontSize: 14, lineHeight: 20, textColor: RGBAColor(red: 0.1, green: 0.1, blue: 0.1)),
            lineFrames: [CGRect(x: origin.x, y: origin.y, width: 180, height: 17)],
            originalLinks: [
                SegmentLink(
                    range: 9..<14, text: "guide", url: guideURL,
                    frames: [CGRect(x: origin.x + 60, y: origin.y, width: 40, height: 17)],
                    color: RGBAColor(red: 0, green: 0.3, blue: 0.9), isUnderlined: underlined)
            ],
            links: [OverlayLink(range: guide.location..<NSMaxRange(guide), linkIndex: 0)])
    }

    /// "u": a long URL that wraps over three lines, so its link has several pieces.
    private func wrappedItem(underlined: Bool = false) -> OverlayItem {
        let translation = "詳しい手順: " + longURL
        let range = (translation as NSString).range(of: longURL)
        let lines = (0..<3).map { CGRect(x: 120, y: 300 + CGFloat($0) * 20, width: 220, height: 17) }
        return OverlayItem(
            id: "u", axFrame: CGRect(x: 120, y: 300, width: 220, height: 57), original: "Full steps: " + longURL,
            translation: translation, state: .final,
            style: TextStyleHint(fontSize: 14, lineHeight: 20, textColor: RGBAColor(red: 0.1, green: 0.1, blue: 0.1)),
            lineFrames: lines,
            originalLinks: [
                SegmentLink(
                    range: 12..<(12 + (longURL as NSString).length), text: longURL, url: URL(string: longURL),
                    frames: lines, color: RGBAColor(red: 0, green: 0.3, blue: 0.9), isUnderlined: underlined)
            ],
            links: [OverlayLink(range: range.location..<NSMaxRange(range), linkIndex: 0)])
    }

    private func style(_ mode: HoverOriginalMode = .inPlace) -> OverlayStyle {
        var appearance = OverlayAppearance()
        appearance.theme = .light
        return OverlayStyle(
            displayStyle: .replace, appearance: appearance,
            interaction: OverlayInteractionSettings(hoverOriginal: mode, hoverDelay: 0.1, clickableLinks: true))
    }

    private func update(_ controller: OverlayController, _ items: [OverlayItem], mode: HoverOriginalMode = .inPlace) {
        controller.update(
            window: key, axWindowFrame: window, axClipRect: nil, cgWindowID: nil, items: items, style: style(mode),
            targetIsFrontmost: false)
    }

    private func linkPanels(_ controller: OverlayController, item: String = "a") -> [OverlayClickPanel] {
        controller.clickPanels(window: key).filter { $0.target?.itemID == item && $0.isLinkPanel }
    }

    private func blocker(_ controller: OverlayController) throws -> OverlayClickPanel {
        try XCTUnwrap(controller.clickPanels(window: key).first { $0.target?.kind == .blocker })
    }

    private func mouse(
        _ type: NSEvent.EventType, _ panel: OverlayClickPanel, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: 1, y: 1), modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func crossing(_ type: NSEvent.EventType, _ panel: OverlayClickPanel) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: CGPoint(x: 1, y: 1), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    /// The pointer enters `panel` (the fake hit test then names it).
    private func enter(_ panel: OverlayClickPanel) throws {
        fake.under = panel.pointerNumber
        panel.clickView.mouseEntered(with: try crossing(.mouseEntered, panel))
    }

    /// The pointer leaves `panel` for `to` (nil = the app's own content).
    private func exit(_ panel: OverlayClickPanel, to: OverlayClickPanel? = nil) throws {
        fake.under = to?.pointerNumber ?? 0
        panel.clickView.mouseExited(with: try crossing(.mouseExited, panel))
    }

    private func look(_ controller: OverlayController) -> String? {
        controller.hoveredLink.map { "\($0.itemID)#\($0.linkIndex)" }
    }

    private func drawnLook(_ controller: OverlayController, item: String = "a") -> Int? {
        controller.contentItems(window: key).first { $0.layout.id == item }?.hoveredLink
    }

    // MARK: - Right clicks

    func testRightClickOnALinkAsksForTheOriginalLinksMenu() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        var menus: [(WindowKey, String, SegmentLink, CGPoint)] = []
        var opened = 0
        controller.onLinkContextMenu = { menus.append(($0, $1, $2, $3)) }
        controller.onLinkActivated = { _, _, _ in opened += 1 }
        update(controller, [item()])
        let panel = try XCTUnwrap(linkPanels(controller).first)
        panel.clickView.rightMouseDown(with: try mouse(.rightMouseDown, panel))
        panel.clickView.rightMouseUp(with: try mouse(.rightMouseUp, panel))
        XCTAssertEqual(menus.count, 1)
        XCTAssertEqual(menus.first?.0, key)
        XCTAssertEqual(menus.first?.1, "a")
        XCTAssertEqual(menus.first?.2.url, guideURL)
        XCTAssertEqual(opened, 0)
        XCTAssertNil(controller.revealedItem)
        XCTAssertNil(panel.clickView.menu(for: try mouse(.rightMouseDown, panel)))
        // Control-click is the same gesture; its release opens nothing.
        panel.clickView.mouseDown(with: try mouse(.leftMouseDown, panel, modifiers: .control))
        panel.clickView.mouseUp(with: try mouse(.leftMouseUp, panel, modifiers: .control))
        XCTAssertEqual(menus.count, 2)
        XCTAssertEqual(opened, 0)
        // Other buttons do nothing.
        panel.clickView.otherMouseDown(with: try mouse(.otherMouseDown, panel))
        panel.clickView.otherMouseUp(with: try mouse(.otherMouseUp, panel))
        XCTAssertEqual(menus.count, 2)
        XCTAssertEqual(opened, 0)
        // A plain click still opens it.
        panel.clickView.mouseDown(with: try mouse(.leftMouseDown, panel))
        panel.clickView.mouseUp(with: try mouse(.leftMouseUp, panel))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(menus.count, 2)
    }

    func testRightClickOnALinkClosesTheItemsPopup() async throws {
        let controller = makeController()
        defer { controller.removeAll() }
        var menus = 0
        controller.onLinkContextMenu = { _, _, _, _ in menus += 1 }
        update(controller, [item()], mode: .popup)
        // Rest on the item's plain text: its original opens in the popup.
        let opened = await restUntilHoverPopup(controller, at: CGPoint(x: 125, y: 208), item: "a")
        XCTAssertTrue(opened)
        XCTAssertEqual(controller.hoverPopupItem?.id, "a")

        // Right-click its link: the app's menu opens there, so the popup closes and does not come back by itself.
        let panel = try XCTUnwrap(linkPanels(controller).first)
        panel.clickView.rightMouseDown(with: try mouse(.rightMouseDown, panel))
        XCTAssertEqual(menus, 1)
        XCTAssertNil(controller.hoverPopupItem)
        update(controller, [item()], mode: .popup)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(controller.hoverPopupItem)
    }

    func testRightClickOnAHiddenOriginalLinkShowsTheOriginal() throws {
        for control in [false, true] {
            let controller = makeController()
            defer { controller.removeAll() }
            var menus = 0
            controller.onLinkContextMenu = { _, _, _, _ in menus += 1 }
            update(controller, [item()])
            let panel = try blocker(controller)
            if control {
                panel.clickView.mouseDown(with: try mouse(.leftMouseDown, panel, modifiers: .control))
            } else {
                panel.clickView.rightMouseDown(with: try mouse(.rightMouseDown, panel))
            }
            // Like a left click: the original shows at once, no menu.
            XCTAssertEqual(controller.revealedItem?.id, "a")
            XCTAssertEqual(controller.guardedItem?.id, "a")
            XCTAssertEqual(menus, 0)
            // Right after, every area of the item only swallows clicks, right clicks too.
            let guarded = controller.clickPanels(window: key)
            XCTAssertFalse(guarded.isEmpty)
            XCTAssertFalse(guarded.contains(where: \.isLinkPanel))
            for other in guarded {
                other.clickView.rightMouseDown(with: try mouse(.rightMouseDown, other))
                other.clickView.rightMouseUp(with: try mouse(.rightMouseUp, other))
                other.clickView.otherMouseDown(with: try mouse(.otherMouseDown, other))
            }
            XCTAssertEqual(menus, 0)
            XCTAssertEqual(controller.revealedItem?.id, "a")
            XCTAssertEqual(controller.guardedItem?.id, "a")
        }
    }

    func testShowOriginalRevealsTheItemInPlace() {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [item()])
        controller.showOriginal(window: key, itemID: "nope")
        controller.showOriginal(window: WindowKey(pid: 2, windowID: 1), itemID: "a")
        XCTAssertNil(controller.revealedItem)
        controller.showOriginal(window: key, itemID: "a")
        XCTAssertEqual(controller.revealedItem?.id, "a")
        XCTAssertTrue(controller.contentItems(window: key).isEmpty)
        // Not while the window is hidden (scrolling).
        let other = makeController()
        defer { other.removeAll() }
        update(other, [item()])
        other.setTemporarilyHidden(true, window: key)
        other.showOriginal(window: key, itemID: "a")
        XCTAssertNil(other.revealedItem)
    }

    /// 「原文を表示」 is chosen on the menu below the item: the original stays until the pointer has been on the
    /// item and left it, moved far away, or a few seconds passed.
    func testShowOriginalWaitsForThePointerToComeOntoTheItem() async {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [item()])
        // The right click on the link, and the menu's last entry (the menu opens below and right of it).
        let click = CGPoint(x: 170, y: 208)
        let entry = CGPoint(x: click.x + 40, y: click.y + 60)
        // Once the wait is over, the translation comes back `revealLeaveDelay` after the pointer left (a real
        // timer, late on a busy machine): polled for below.

        controller.showOriginal(window: key, itemID: "a")
        XCTAssertEqual(controller.revealedItem?.id, "a")
        controller.updateMouseLocation(ax: entry)
        controller.updateMouseLocation(ax: CGPoint(x: entry.x, y: entry.y - 2))
        // Waiting: no leave timer runs (the wait's limit is on the fake clock), so twice its delay later the original
        // still shows.
        await sleep(0.3)
        XCTAssertEqual(controller.revealedItem?.id, "a")
        // Onto the item and off again: the usual rule.
        controller.updateMouseLocation(ax: CGPoint(x: 300, y: 208))
        let left = ProcessInfo.processInfo.systemUptime
        controller.updateMouseLocation(ax: entry)
        XCTAssertEqual(controller.revealedItem?.id, "a")
        await sleep(0.05)
        // Still there a moment later: checked only while the leave delay has not passed yet (a busy machine may
        // have slept far longer than asked).
        let shownAfterLeaving = controller.revealedItem?.id
        if ProcessInfo.processInfo.systemUptime - left < OverlayController.revealLeaveDelay - 0.01 {
            XCTAssertEqual(shownAfterLeaving, "a")
        }
        let backAfterLeaving = await waitUntil { controller.revealedItem == nil }
        XCTAssertTrue(backAfterLeaving, "left the item")

        // A move far away ends the wait.
        controller.showOriginal(window: key, itemID: "a")
        controller.updateMouseLocation(ax: CGPoint(x: 700, y: 650))
        let backAfterFarMove = await waitUntil { controller.revealedItem == nil }
        XCTAssertTrue(backAfterFarMove, "moved far away")

        // So does a long wait outside.
        controller.showOriginal(window: key, itemID: "a")
        controller.updateMouseLocation(ax: entry)
        fake.advance(OverlayController.originalWaitLimit + 0.1)
        controller.updateMouseLocation(ax: CGPoint(x: entry.x + 5, y: entry.y))
        let backAfterLongWait = await waitUntil { controller.revealedItem == nil }
        XCTAssertTrue(backAfterLongWait, "waited long")

        // Hiding (a scroll) still ends it at once.
        controller.showOriginal(window: key, itemID: "a")
        controller.setTemporarilyHidden(true, window: key)
        XCTAssertNil(controller.revealedItem)
    }

    // MARK: - Hover look and cursor

    func testTheHandAndTheLookFollowThePointerOverALink() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [item()])
        let panel = try XCTUnwrap(linkPanels(controller).first)
        XCTAssertNil(drawnLook(controller))
        try enter(panel)
        XCTAssertEqual(look(controller), "a#0")
        XCTAssertEqual(drawnLook(controller), 0)
        XCTAssertEqual(fake.sets, [.pointingHand])
        XCTAssertEqual(fake.enables, 1)
        panel.clickView.mouseMoved(with: try mouse(.mouseMoved, panel))
        XCTAssertEqual(fake.sets, [.pointingHand, .pointingHand])
        // Resting on a link never shows the original (about to click it).
        fake.advance(1)
        XCTAssertNil(controller.revealedItem)
        try exit(panel)
        XCTAssertNil(look(controller))
        XCTAssertNil(drawnLook(controller))
        XCTAssertEqual(fake.sets.last, .iBeam)
    }

    func testBlockersNeverChangeTheCursor() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [item()])
        let panel = try blocker(controller)
        try enter(panel)
        panel.clickView.mouseMoved(with: try mouse(.mouseMoved, panel))
        try exit(panel)
        XCTAssertEqual(fake.sets, [])
        XCTAssertEqual(fake.enables, 0)
        XCTAssertNil(look(controller))
        // From a link onto the blocker next to it: back to the cursor from before.
        let link = try XCTUnwrap(linkPanels(controller).first)
        try enter(link)
        fake.advance(1)
        try enter(panel)
        XCTAssertNil(look(controller))
        XCTAssertEqual(fake.sets.last, .iBeam)
    }

    func testEveryPieceOfAWrappedLinkSharesTheLook() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [wrappedItem()])
        let pieces = linkPanels(controller, item: "u")
        XCTAssertGreaterThanOrEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.target?.kind == .link(0) })
        try enter(pieces[0])
        XCTAssertEqual(drawnLook(controller, item: "u"), 0)
        let drawn = controller.contentItems(window: key)
        // Onto the next piece, its exit first: no restore, the look stays.
        try exit(pieces[0], to: pieces[1])
        XCTAssertEqual(look(controller), "u#0")
        try enter(pieces[1])
        // Back, its enter first.
        fake.under = pieces[0].pointerNumber
        pieces[0].clickView.mouseEntered(with: try crossing(.mouseEntered, pieces[0]))
        pieces[1].clickView.mouseExited(with: try crossing(.mouseExited, pieces[1]))
        XCTAssertEqual(look(controller), "u#0")
        XCTAssertTrue(fake.sets.allSatisfy { $0 == .pointingHand })
        // The canvas content did not change on the way (no redraw, no flicker).
        XCTAssertEqual(controller.contentItems(window: key), drawn)
        try exit(pieces[0])
        XCTAssertNil(drawnLook(controller, item: "u"))
        XCTAssertEqual(fake.sets.filter { $0 != .pointingHand }, [.iBeam])
    }

    func testTheLookEndsWhenThePanelsChange() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [item()])
        func hover() throws {
            try enter(try XCTUnwrap(linkPanels(controller).first))
            XCTAssertEqual(drawnLook(controller), 0)
            fake.advance(1)
            fake.clearSets()
        }
        func assertEnded(_ label: String) {
            XCTAssertNil(look(controller), label)
            XCTAssertNil(drawnLook(controller), label)
            XCTAssertEqual(fake.sets, [.iBeam], label)
        }

        // Scrolling over a panel.
        try hover()
        let panel = try XCTUnwrap(linkPanels(controller).first)
        panel.clickView.scrollWheel(with: try mouse(.leftMouseDown, panel))
        assertEnded("scroll")
        update(controller, [item()])

        // Hidden while scrolling, everything hidden, the modifier.
        try hover()
        controller.setTemporarilyHidden(true, window: key)
        assertEnded("hidden")
        controller.setTemporarilyHidden(false, window: key)
        try hover()
        controller.setAllTemporarilyHidden(true)
        assertEnded("all hidden")
        controller.setAllTemporarilyHidden(false)
        try hover()
        controller.revealOriginal = true
        assertEnded("modifier")
        controller.revealOriginal = false

        // The item shows its original (a click on its hidden original link).
        try hover()
        let block = try blocker(controller)
        block.clickView.mouseDown(with: try mouse(.leftMouseDown, block))
        XCTAssertEqual(controller.revealedItem?.id, "a")
        assertEnded("reveal")
        controller.remove(window: key)
        fake.clearSets()

        // A redraw moved the link away from the still pointer.
        update(controller, [item(origin: CGPoint(x: 120, y: 400))])
        try hover()
        fake.under = 0
        update(controller, [item(origin: CGPoint(x: 120, y: 450))])
        assertEnded("redraw")

        // The panel is reused for something else (the link is gone from the translation).
        try hover()
        var lost = item(origin: CGPoint(x: 120, y: 450))
        lost.links = []
        update(controller, [lost])
        assertEnded("reuse")

        // The window goes.
        update(controller, [item(origin: CGPoint(x: 120, y: 450))])
        try hover()
        controller.remove(window: key)
        assertEnded("removed")
    }

    func testARedrawInPlaceKeepsTheLook() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [item()])
        let panel = try XCTUnwrap(linkPanels(controller).first)
        try enter(panel)
        fake.advance(1)
        fake.clearSets()
        // A new scan with the same content: the pointer is still on the link.
        update(controller, [item()])
        XCTAssertEqual(drawnLook(controller), 0)
        XCTAssertTrue(linkPanels(controller).first === panel)
        XCTAssertFalse(fake.sets.contains { $0 != .pointingHand })
        // A move the global monitor saw (the pointer left over the app): the hand goes, the look too.
        fake.under = 0
        controller.updateMouseLocation(ax: CGPoint(x: 700, y: 650))
        XCTAssertNil(drawnLook(controller))
        XCTAssertEqual(fake.sets, [.iBeam])
    }

    func testARightClickPausesTheReasserts() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        var menus = 0
        controller.onLinkContextMenu = { _, _, _, _ in menus += 1 }
        update(controller, [item()])
        let panel = try XCTUnwrap(linkPanels(controller).first)
        try enter(panel)
        panel.clickView.rightMouseDown(with: try mouse(.rightMouseDown, panel))
        XCTAssertEqual(menus, 1)
        // The menu's arrow is not fought.
        fake.shape = .arrow
        fake.advance(1)
        XCTAssertEqual(fake.sets, [.pointingHand])
        // After the menu closes the session asks again: the menu covered the panel, the pointer is elsewhere.
        fake.under = 0
        controller.revalidateCursor()
        XCTAssertNil(look(controller))
        // The app's cursor shows: nothing to restore.
        XCTAssertEqual(fake.sets, [.pointingHand])
    }

    /// A scan while Plamonic's own menu is open gives the hand up; when the menu closes and AppKit puts the hand
    /// back, the check after the menu still takes it away.
    func testAHandPutBackAfterTheOwnMenuGoesAlsoAfterAScan() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        var menus = 0
        controller.onLinkContextMenu = { _, _, _, _ in menus += 1 }
        update(controller, [item()])
        let panel = try XCTUnwrap(linkPanels(controller).first)
        try enter(panel)
        fake.advance(0.3)
        panel.clickView.rightMouseDown(with: try mouse(.rightMouseDown, panel))
        XCTAssertEqual(menus, 1)
        // The menu covers the pointer and shows its arrow; a scan comes meanwhile.
        fake.under = 777
        fake.shape = .arrow
        update(controller, [item()])
        XCTAssertNil(look(controller))
        fake.clearSets()
        // The menu closes over the app's text.
        fake.shape = .pointingHand
        fake.under = 0
        controller.revalidateCursor()
        XCTAssertEqual(fake.sets, [.iBeam])
        XCTAssertNil(look(controller))
        fake.advance(1)
        XCTAssertEqual(fake.sets, [.iBeam])
    }

    func testSimulatedHoverNeverTouchesTheCursor() throws {
        let controller = makeController()
        defer { controller.removeAll() }
        update(controller, [item()])
        let panel = try XCTUnwrap(linkPanels(controller).first)
        panel.clickView.simulateHover(true)
        XCTAssertEqual(drawnLook(controller), 0)
        panel.clickView.simulateHover(false)
        XCTAssertNil(drawnLook(controller))
        // Blockers have no look.
        try blocker(controller).clickView.simulateHover(true)
        XCTAssertNil(look(controller))
        // Reused for something else: the look ends.
        panel.clickView.simulateHover(true)
        var lost = item()
        lost.links = []
        update(controller, [lost])
        XCTAssertNil(look(controller))
        XCTAssertEqual(fake.sets, [])
        XCTAssertEqual(fake.enables, 0)
    }

    // MARK: - Drawing

    /// Renders the window's canvas at 2x and returns its RGBA bytes.
    private func render(_ controller: OverlayController) throws -> (bytes: [UInt8], width: Int, origin: CGPoint) {
        let canvas = try XCTUnwrap(controller.canvasView(window: key))
        canvas.appearance = NSAppearance(named: .aqua)
        let size = canvas.bounds.size
        let scale: CGFloat = 2
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Canvas origin in AX coordinates.
        return (bytes, width, CGPoint(x: window.minX + canvas.frame.minX, y: window.minY + canvas.frame.minY))
    }

    /// AX points (pixel centers) where the two renders differ.
    private func changes(_ a: [UInt8], _ b: [UInt8], width: Int, origin: CGPoint) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) where a[i..<i + 4] != b[i..<i + 4] {
            let pixel = i / 4
            points.append(
                CGPoint(x: origin.x + (CGFloat(pixel % width) + 0.5) / 2, y: origin.y + (CGFloat(pixel / width) + 0.5) / 2))
        }
        return points
    }

    /// The look changes pixels only on the link's own glyph rects (no box, no fill): for a link without an
    /// underline, a line in the lower part of every piece.
    func testTheLookIsDrawnOnTheLinksGlyphsOnly() throws {
        for underlined in [false, true] {
            let controller = makeController()
            defer { controller.removeAll() }
            update(controller, [wrappedItem(underlined: underlined)])
            let plain = try render(controller)
            let pieces = linkPanels(controller, item: "u")
            try enter(try XCTUnwrap(pieces.first))
            XCTAssertEqual(drawnLook(controller, item: "u"), 0)
            let hovered = try render(controller)
            XCTAssertEqual(plain.width, hovered.width)
            let changed = changes(plain.bytes, hovered.bytes, width: plain.width, origin: plain.origin)
            let rects = controller.activeClickAreas(window: key).filter(\.isLink).map(\.rect)
            XCTAssertGreaterThanOrEqual(rects.count, 2)
            XCTAssertFalse(changed.isEmpty)
            // AppKit's underline may end up to a pixel past the glyphs at a line end (antialiased).
            let outside = changed.filter { point in !rects.contains { $0.insetBy(dx: -1, dy: -0.5).contains(point) } }
            XCTAssertEqual(outside.count, 0, "underlined \(underlined): \(outside.prefix(5)) rects \(rects)")
            for rect in rects {
                let inside = changed.filter { rect.insetBy(dx: -1, dy: -0.5).contains($0) }
                XCTAssertFalse(inside.isEmpty, "underlined \(underlined): piece \(rect) has no look")
                if !underlined {
                    // An underline: below the middle of the line, across most of the piece.
                    XCTAssertTrue(inside.allSatisfy { $0.y > rect.midY }, "\(rect)")
                    let span = (inside.map(\.x).max() ?? 0) - (inside.map(\.x).min() ?? 0)
                    XCTAssertGreaterThan(span, rect.width * 0.8, "\(rect)")
                }
            }
        }
    }
}
