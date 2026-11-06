import AppKit
import XCTest

@testable import Plamonic

/// Click panels over translated links and over original links hidden under translations (DESIGN §6.1). Clicks
/// are simulated by calling the panel view's `mouseDown` / `mouseUp` with synthetic NSEvents (nothing is
/// posted). Panels go on screen only in the on-screen tests, over windows far outside every screen.
@MainActor
final class OverlayClickPanelTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let key = WindowKey(pid: 1, windowID: 92)
    private let guideURL = URL(string: "https://example.com/guide")!

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Polls `condition` every 10 ms until it holds (true) or `timeout` passes (false). For what timers, tasks
    /// and the window server do "a moment later": much later on a loaded machine or a CI VM.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            await sleep(0.01)
        }
        return true
    }

    /// Seconds since `start`. The continuous clock never runs slower than the one `Task.sleep` waits on, so
    /// "less than x" here means a timer of x armed after `start` has surely not fired yet.
    private func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds) + TimeInterval(elapsed.components.attoseconds) * 1e-18
    }

    /// "a": "Read the guide now" translated with the link mapped; the original link sits right of the
    /// translated one, so part of it is a blocker.
    private func item(origin: CGPoint = CGPoint(x: 120, y: 200), translation: String = "今すぐガイドを読んでください")
        -> OverlayItem
    {
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
                    color: RGBAColor(red: 0, green: 0.3, blue: 0.9), isUnderlined: true)
            ],
            links: guide.location == NSNotFound ? [] : [OverlayLink(range: guide.location..<NSMaxRange(guide), linkIndex: 0)])
    }

    private func style(clickableLinks: Bool = true, display: DisplayStyle = .replace) -> OverlayStyle {
        OverlayStyle(
            displayStyle: display, appearance: OverlayAppearance(),
            interaction: OverlayInteractionSettings(hoverOriginal: .inPlace, hoverDelay: 0.1, clickableLinks: clickableLinks))
    }

    private func update(_ controller: OverlayController, _ items: [OverlayItem], style: OverlayStyle? = nil) {
        controller.update(
            window: key, axWindowFrame: window, axClipRect: nil, cgWindowID: nil, items: items,
            style: style ?? self.style(), targetIsFrontmost: false)
    }

    private func event(
        _ type: NSEvent.EventType, _ panel: OverlayClickPanel, at location: CGPoint = CGPoint(x: 1, y: 1),
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
    }

    private func press(_ panel: OverlayClickPanel, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws {
        let down = try event(.leftMouseDown, panel, modifiers: modifiers, clickCount: clickCount)
        XCTAssertTrue(panel.clickView.acceptsFirstMouse(for: down))
        panel.clickView.mouseDown(with: down)
    }

    /// `location` in the panel's window; (1, 1) is inside it.
    private func release(
        _ panel: OverlayClickPanel, at location: CGPoint = CGPoint(x: 1, y: 1), modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) throws {
        panel.clickView.mouseUp(with: try event(.leftMouseUp, panel, at: location, modifiers: modifiers, clickCount: clickCount))
    }

    private func click(_ panel: OverlayClickPanel, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws {
        try press(panel, modifiers: modifiers, clickCount: clickCount)
        try release(panel, modifiers: modifiers, clickCount: clickCount)
    }

    private func counts(_ controller: OverlayController) -> [Int] {
        let c = controller.clickPanelCounts(window: key)
        return [c.links, c.blockers]
    }

    // MARK: - Lifecycle

    func testPanelsComeAndGoWithTheOverlay() {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, [item()])
        XCTAssertEqual(counts(controller), [1, 1])
        let panels = controller.clickPanels(window: key)
        XCTAssertEqual(panels.count, 2)
        XCTAssertEqual(panels.compactMap(\.target?.kind), [.link(0), .blocker])
        XCTAssertTrue(panels.allSatisfy { $0.target?.itemID == "a" && $0.target?.window == key })
        // The overlay panel is not on screen here (no window number, target in the background), so neither are
        // the click panels.
        XCTAssertFalse(panels.contains(where: \.isVisible))
        XCTAssertFalse(panels.contains(where: \.canBecomeKey))
        XCTAssertFalse(panels.contains(where: \.ignoresMouseEvents))
        XCTAssertTrue(controller.overlayWindowNumbers.isSuperset(of: panels.map(\.windowNumber).filter { $0 > 0 }))
        // The link panel covers the drawn link; the blocker the rest of the original link.
        let areas = controller.activeClickAreas(window: key)
        XCTAssertEqual(areas.count, 2)
        let link = areas[0].rect
        let blocker = areas[1].rect
        XCTAssertTrue(link.intersection(blocker).isEmpty)
        XCTAssertTrue(CGRect(x: 180, y: 200, width: 40, height: 17).contains(blocker))

        // Scrolling, hiding everything, the modifier: no panels; they come back with the overlay.
        controller.setTemporarilyHidden(true, window: key)
        XCTAssertEqual(counts(controller), [0, 0])
        controller.setTemporarilyHidden(false, window: key)
        XCTAssertEqual(counts(controller), [1, 1])
        controller.setAllTemporarilyHidden(true)
        XCTAssertEqual(counts(controller), [0, 0])
        controller.setAllTemporarilyHidden(false)
        XCTAssertEqual(counts(controller), [1, 1])
        controller.revealOriginal = true
        XCTAssertEqual(counts(controller), [0, 0])
        controller.revealOriginal = false
        XCTAssertEqual(counts(controller), [1, 1])

        // A pending item draws nothing and gets no panels.
        var pending = item()
        pending.state = .pending
        update(controller, [pending])
        XCTAssertEqual(counts(controller), [0, 0])
        // Hover display style: nothing in place.
        update(controller, [item()], style: style(display: .hover))
        XCTAssertEqual(counts(controller), [0, 0])
        update(controller, [item()])
        XCTAssertEqual(counts(controller), [1, 1])

        controller.remove(window: key)
        XCTAssertEqual(counts(controller), [0, 0])
        XCTAssertTrue(controller.clickPanels(window: key).isEmpty)
    }

    func testLinksOffRestoresThePlainTranslation() {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, [item()], style: style(clickableLinks: false))
        XCTAssertEqual(counts(controller), [0, 0])
        let drawn = controller.contentItems(window: key)
        XCTAssertEqual(drawn.count, 1)
        XCTAssertTrue(drawn[0].links.isEmpty)
        XCTAssertEqual(drawn[0].text, "今すぐガイドを読んでください")
        // On: only the link is a link.
        update(controller, [item()])
        let linked = controller.contentItems(window: key)
        XCTAssertEqual(linked[0].links.count, 1)
        XCTAssertEqual((linked[0].text as NSString).substring(with: linked[0].links[0].range), "ガイド")
        XCTAssertEqual(linked[0].links[0].color, RGBAColor(red: 0, green: 0.3, blue: 0.9))
        XCTAssertTrue(linked[0].links[0].isUnderlined)
        // The rest keeps the paragraph's own color.
        XCTAssertEqual(linked[0].colors.originalText, RGBAColor(red: 0.1, green: 0.1, blue: 0.1))
        // A link the translation lost: nothing is drawn as a link, the original link is still kept from clicks.
        var lost = item()
        lost.links = []
        update(controller, [lost])
        XCTAssertTrue(controller.contentItems(window: key)[0].links.isEmpty)
        XCTAssertEqual(counts(controller), [0, 1])
    }

    func testCutTranslationsKeepOnlyDrawnLinksClickable() {
        let controller = OverlayController()
        defer { controller.removeAll() }
        let long = "最初のガイドは押せます。" + String(repeating: "長い訳文が続きます。", count: 30) + "最後のリンク"
        var cut = item(translation: long)
        let last = (long as NSString).range(of: "最後のリンク")
        cut.originalLinks.append(
            SegmentLink(range: 0..<4, text: "last", frames: [CGRect(x: 300, y: 200, width: 30, height: 17)]))
        cut.links.append(OverlayLink(range: last.location..<NSMaxRange(last), linkIndex: 1))
        // A pending item right below leaves no room to add lines.
        let below = OverlayItem(
            id: "below", axFrame: CGRect(x: 120, y: 218, width: 300, height: 17), original: "Next", translation: "",
            state: .pending)
        update(controller, [cut, below])
        XCTAssertTrue(controller.hasTruncatedItems)
        let drawn = controller.contentItems(window: key)
        XCTAssertEqual(drawn.first?.links.map(\.linkIndex), [0])
        XCTAssertTrue(drawn.first?.text.hasSuffix("…") ?? false)
        let areas = controller.activeClickAreas(window: key)
        XCTAssertEqual(areas.filter(\.isLink).map(\.kind), [.link(0)])
        // Both original links stay kept from clicks where the translation covers them.
        XCTAssertEqual(areas.filter { !$0.isLink }.count, 2)
    }

    func testClickAreasAreCappedPerWindow() {
        let controller = OverlayController()
        defer { controller.removeAll() }
        var many = item()
        // A long paragraph full of small original links.
        many.lineFrames = (0..<20).map { CGRect(x: 120, y: 200 + CGFloat($0) * 20, width: 400, height: 17) }
        many.axFrame = CGRect(x: 120, y: 200, width: 400, height: 397)
        many.translation = String(repeating: "訳文です。", count: 60)
        many.links = []
        many.originalLinks = (0..<100).map { i in
            SegmentLink(
                range: 0..<1, text: "x",
                frames: [CGRect(x: 120 + CGFloat(i % 5) * 70, y: 200 + CGFloat(i / 5) * 20, width: 40, height: 17)])
        }
        update(controller, [many])
        let areas = controller.clickAreas(window: key)
        XCTAssertLessThanOrEqual(areas.count, OverlayHitAreas.maximumPerWindow)
        XCTAssertEqual(controller.clickPanels(window: key).count, areas.count)
        // Merged one per line rather than dropped: every original link is still covered where it is hidden.
        XCTAssertTrue(areas.allSatisfy { !$0.isLink })
        let covered = many.originalLinks.flatMap(\.frames).filter { frame in
            areas.contains { $0.rect.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        }
        XCTAssertGreaterThan(covered.count, 0)
        let lines = Set(covered.map(\.minY))
        for frame in many.originalLinks.flatMap(\.frames) where lines.contains(frame.minY) {
            XCTAssertTrue(areas.contains { $0.rect.contains(CGPoint(x: frame.midX, y: frame.midY)) }, "\(frame)")
        }
    }

    /// A busy chat: every message has a mapped link over its original link. Over the limit, the last messages
    /// lose their clickable links but keep their original links covered; none is left unprotected.
    func testOverTheLimitLinksGoBeforeAnyHiddenOriginalLink() {
        let controller = OverlayController()
        defer { controller.removeAll() }
        let messages = (0..<40).map { i in
            var message = item(origin: CGPoint(x: 120, y: 120 + CGFloat(i) * 20))
            message.id = "m\(i)"
            return message
        }
        controller.update(
            window: key, axWindowFrame: CGRect(x: 100, y: 100, width: 800, height: 900), axClipRect: nil,
            cgWindowID: nil, items: messages, style: style(), targetIsFrontmost: false)
        let areas = controller.clickAreas(window: key)
        XCTAssertLessThanOrEqual(areas.count, OverlayHitAreas.maximumPerWindow)
        // The first messages keep their links; the last ones do not.
        XCTAssertTrue(areas.contains { $0.itemID == "m0" && $0.kind == .link(0) })
        XCTAssertFalse(areas.contains { $0.itemID == "m39" && $0.isLink })
        // Every message: its original link is covered by its own areas.
        for message in messages {
            let frame = message.originalLinks[0].frames[0]
            for x in stride(from: frame.minX + 1, to: frame.maxX, by: 4) {
                let point = CGPoint(x: x, y: frame.midY)
                XCTAssertTrue(
                    areas.contains { $0.itemID == message.id && $0.rect.contains(point) }, "\(message.id) at \(x)")
            }
        }
    }

    // MARK: - Clicks

    func testClickOnALinkOpensTheOriginalLink() throws {
        let controller = OverlayController()
        defer { controller.removeAll() }
        var opened: [(WindowKey, String, SegmentLink)] = []
        controller.onLinkActivated = { opened.append(($0, $1, $2)) }
        update(controller, [item()])
        let panel = try XCTUnwrap(controller.clickPanels(window: key).first { $0.target?.kind == .link(0) })
        XCTAssertTrue(panel.clickView.isLink)
        // Like a link: the press alone does nothing, the release on the link opens it.
        try press(panel)
        XCTAssertTrue(opened.isEmpty)
        try release(panel)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, key)
        XCTAssertEqual(opened.first?.1, "a")
        XCTAssertEqual(opened.first?.2.url, guideURL)
        XCTAssertNil(controller.revealedItem)
    }

    func testOnlyAPlainClickOnALinkOpensIt() throws {
        let controller = OverlayController()
        defer { controller.removeAll() }
        var opened = 0
        controller.onLinkActivated = { _, _, _ in opened += 1 }
        update(controller, [item()])
        let panel = try XCTUnwrap(controller.clickPanels(window: key).first { $0.target?.kind == .link(0) })
        // Control-click is the context menu gesture: swallowed, nothing opens.
        try click(panel, modifiers: .control)
        XCTAssertEqual(opened, 0)
        // Dragging off the link before the release cancels.
        try press(panel)
        try release(panel, at: CGPoint(x: -30, y: -30))
        XCTAssertEqual(opened, 0)
        // A release without a press on this panel does nothing.
        try release(panel)
        XCTAssertEqual(opened, 0)
        // Command-click opens it like a plain click.
        try click(panel, modifiers: .command)
        XCTAssertEqual(opened, 1)
        // The second click of a double-click does not open it again.
        try click(panel, clickCount: 2)
        XCTAssertEqual(opened, 1)
        // A press that the next scan moves to another target does not finish there.
        try press(panel)
        var moved = item()
        moved.links = []
        update(controller, [moved])
        try release(panel)
        XCTAssertEqual(opened, 1)
        XCTAssertNil(controller.revealedItem)
    }

    func testClickOnAHiddenOriginalLinkShowsTheOriginal() async throws {
        let controller = OverlayController()
        defer { controller.removeAll() }
        var opened = 0
        controller.onLinkActivated = { _, _, _ in opened += 1 }
        update(controller, [item()])
        let panel = try XCTUnwrap(controller.clickPanels(window: key).first { $0.target?.kind == .blocker })
        XCTAssertFalse(panel.clickView.isLink)
        let area = try XCTUnwrap(controller.activeClickAreas(window: key).first { !$0.isLink })
        let point = CGPoint(x: area.rect.midX, y: area.rect.midY)
        try press(panel)
        // At once, on the press, without opening anything.
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(controller.revealedItem?.id, "a")
        XCTAssertTrue(controller.contentItems(window: key).isEmpty)
        XCTAssertTrue(controller.needsMouseMoves)
        // The item's areas stay a double-click interval, all only swallowing clicks: the rest of a double-click
        // must not press the original link that just appeared under the pointer.
        XCTAssertEqual(controller.guardedItem?.id, "a")
        XCTAssertEqual(counts(controller), [0, 2])
        XCTAssertTrue(controller.activeClickAreas(window: key).contains { $0.rect.contains(point) })
        XCTAssertTrue(controller.clickPanels(window: key).contains { $0 === panel })
        try release(panel)
        try click(panel, clickCount: 2)
        let former = try XCTUnwrap(controller.clickPanels(window: key).first { $0 !== panel })
        XCTAssertFalse(former.clickView.isLink)
        // The last press and release re-arm the guard; it ends no earlier than an interval after this.
        let lastClick = ContinuousClock.now
        try click(former, clickCount: 3)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(controller.revealedItem?.id, "a")
        // Each press and release there keeps them a little longer; then the original's links take clicks.
        let interval = OverlayController.revealGuardInterval
        await sleep(interval * 0.5)
        let midway = counts(controller)
        // Only while the interval is surely not over: a wake-up late past it (a loaded machine) proves nothing.
        if seconds(since: lastClick) < interval {
            XCTAssertEqual(midway, [0, 2], "still guarded")
        }
        let unguarded = await waitUntil(timeout: interval + 2) { controller.guardedItem == nil }
        XCTAssertTrue(unguarded, "the guard never ended")
        // Not before the interval from the last press or release (holds however late anything runs).
        XCTAssertGreaterThanOrEqual(seconds(since: lastClick), interval - 0.005)
        XCTAssertNil(controller.guardedItem)
        XCTAssertEqual(counts(controller), [0, 0])
        // It stays while the pointer is there, and ends once it leaves.
        XCTAssertEqual(controller.revealedItem?.id, "a")
        controller.updateMouseLocation(ax: CGPoint(x: 700, y: 600))
        let ended = await waitUntil(timeout: 2) { controller.revealedItem == nil }
        XCTAssertTrue(ended, "the original still shows after the pointer left")
        XCTAssertNil(controller.revealedItem)
        XCTAssertEqual(counts(controller), [1, 1])
    }

    func testPointerMovesOverPanelsFeedTheHover() async throws {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, [item()])
        let blocker = try XCTUnwrap(controller.clickPanels(window: key).first { $0.target?.kind == .blocker })
        let area = try XCTUnwrap(controller.activeClickAreas(window: key).first { !$0.isLink })
        // The panel reports moves the global monitor never sees; resting there shows the original.
        blocker.clickView.onPointerMoved?(CGPoint(x: area.rect.midX, y: area.rect.midY))
        // After the rest (hoverDelay 0.1 s).
        _ = await waitUntil { controller.revealedItem != nil }
        XCTAssertEqual(controller.revealedItem?.id, "a")
    }

    func testScrollOverAPanelTakesThePanelsAwayUntilTheNextScan() throws {
        let controller = OverlayController()
        defer { controller.removeAll() }
        update(controller, [item()])
        let panel = try XCTUnwrap(controller.clickPanels(window: key).first)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        panel.clickView.scrollWheel(with: event)
        XCTAssertEqual(counts(controller), [0, 0])
        update(controller, [item()])
        XCTAssertEqual(counts(controller), [1, 1])
    }

    // MARK: - On screen (far outside every screen)

    /// Without relative ordering (no window number here) the overlay floats while its app is in front. Click
    /// panels there would sit above every window, also above windows in front of the target, so they stay off
    /// screen: the links are drawn but clicks pass through.
    func testNoClickPanelsOnScreenInTheFloatingFallback() async throws {
        _ = NSApplication.shared
        let controller = OverlayController()
        defer { controller.removeAll() }
        let far = CGRect(x: -30000, y: -30000, width: 800, height: 600)
        controller.update(
            window: key, axWindowFrame: far, axClipRect: nil, cgWindowID: nil,
            items: [item(origin: CGPoint(x: far.minX + 20, y: far.minY + 100))], style: style(), targetIsFrontmost: true)
        await sleep(0.2)
        guard let overlay = controller.canvasView(window: key)?.window, overlay.isVisible else {
            throw XCTSkip("no window server")
        }
        XCTAssertEqual(overlay.level, .floating)
        XCTAssertEqual(controller.contentItems(window: key).first?.links.count, 1)
        let panels = controller.clickPanels(window: key)
        XCTAssertEqual(panels.count, 2)
        XCTAssertFalse(panels.contains(where: \.isVisible))
        XCTAssertTrue(panels.allSatisfy { $0.parent == nil })
    }

    func testPanelsStayDirectlyAboveTheirOverlay() async throws {
        _ = NSApplication.shared
        let target = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.orderFrontRegardless()
        defer { target.orderOut(nil) }
        let shown = await waitUntil(timeout: 2) {
            target.windowNumber > 0
                && OverlayWindowServer.info(for: CGWindowID(target.windowNumber))?.isOnScreen == true
        }
        guard shown else { throw XCTSkip("no window server") }
        let id = CGWindowID(target.windowNumber)
        let key = WindowKey(pid: getpid(), windowID: id)
        let frame = CoordinateSpace.axRect(fromCocoa: target.frame)
        let controller = OverlayController()
        defer { controller.removeAll() }
        func push() {
            controller.update(
                window: key, axWindowFrame: frame, axClipRect: nil, cgWindowID: id,
                items: [item(origin: CGPoint(x: frame.minX + 20, y: frame.minY + 40))], style: style(),
                targetIsFrontmost: false)
        }
        /// Front-to-back numbers of our windows in front of the target, and whether the target is right below.
        func order() -> (above: [Int], panels: [Int]) {
            let above = OverlayWindowServer.windowsAbove(id).map { Int($0.number) }
            let panels = controller.clickPanels(window: key).map(\.windowNumber)
            return (above, panels)
        }
        push()
        // Not before the overlay is checked to be directly above the target.
        XCTAssertFalse(controller.clickPanels(window: key).contains(where: \.isVisible))
        // The check runs about 0.1 s after the ordering (retried twice if the window server is not there yet),
        // and much later under load.
        let placed = await waitUntil(timeout: 5) {
            let panels = controller.clickPanels(window: key)
            return panels.count == 2 && panels.allSatisfy { $0.isVisible && $0.parent != nil }
        }
        let panels = controller.clickPanels(window: key)
        XCTAssertTrue(
            placed, "overlay on screen: \(controller.canvasView(window: key)?.window?.isVisible == true)")
        XCTAssertEqual(panels.count, 2)
        XCTAssertTrue(panels.allSatisfy(\.isVisible))
        XCTAssertTrue(panels.allSatisfy { $0.parent != nil })
        /// What is wrong with the order in front of the target, nil when nothing is.
        func misordering() -> String? {
            let (above, numbers) = order()
            let overlay = controller.overlayWindowNumbers.subtracting(numbers)
            guard let overlayIndex = above.lastIndex(where: { overlay.contains($0) }) else {
                return "overlay not above the target"
            }
            // Nothing between the overlay panel and the target.
            if overlayIndex != above.count - 1 {
                return "\(above.count - 1 - overlayIndex) windows between the overlay and the target"
            }
            for number in numbers {
                guard let index = above.firstIndex(of: number) else { return "click panel not above the target" }
                if index >= overlayIndex { return "click panel below the overlay" }
            }
            return nil
        }
        /// The window server applies an order a moment later (much later under load).
        func assertOrdered(_ label: String) async {
            _ = await waitUntil { misordering() == nil }
            if let problem = misordering() { XCTFail("\(label): \(problem)") }
        }
        await assertOrdered("first")
        // The target comes to the front (like an activation); the next update orders the overlay above it again
        // and the click panels come along. Only once the target is in front of them, or the check after the
        // update could pass without the update ordering anything.
        target.orderFrontRegardless()
        let raised = await waitUntil {
            !order().above.contains { controller.overlayWindowNumbers.contains($0) }
        }
        XCTAssertTrue(raised, "the target did not come in front of the overlay")
        push()
        await assertOrdered("after raise")

        controller.setTemporarilyHidden(true, window: key)
        XCTAssertFalse(panels.contains(where: \.isVisible))
        controller.setTemporarilyHidden(false, window: key)
        XCTAssertTrue(controller.clickPanels(window: key).allSatisfy(\.isVisible))
        controller.remove(window: key)
        XCTAssertFalse(panels.contains(where: \.isVisible))
    }
}
