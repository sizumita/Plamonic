import AppKit
import XCTest

@testable import Plamonic

/// A replace-style translation cut with "…" shows its full text in the hover popup once the pointer rests
/// on it; in the in-place mode, other items never open a popup.
@MainActor
final class OverlayTruncatedHoverTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let key = WindowKey(pid: 1, windowID: 77)

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Waits until `condition` holds, checking every 10 ms, for at most `timeout`: the rest timers run late on
    /// a loaded machine, so the test waits for their effect instead of a fixed time. The caller asserts after.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = now + timeout
        while !condition(), now < deadline { await sleep(0.01) }
    }

    /// One 14pt line with a long translation and a pending item right below it (no room to add lines),
    /// and a short one that fits.
    private func items(long: String) -> [OverlayItem] {
        let style = TextStyleHint(fontSize: 14, lineHeight: 20)
        return [
            OverlayItem(
                id: "long", axFrame: CGRect(x: 120, y: 200, width: 200, height: 17), original: "Hello there",
                translation: long, state: .final, style: style,
                lineFrames: [CGRect(x: 120, y: 200, width: 200, height: 17)]),
            OverlayItem(
                id: "below", axFrame: CGRect(x: 120, y: 218, width: 200, height: 17), original: "Next",
                translation: "", state: .pending, style: style),
            OverlayItem(
                id: "short", axFrame: CGRect(x: 120, y: 300, width: 200, height: 17), original: "Hi",
                translation: "やあ", state: .final, style: style,
                lineFrames: [CGRect(x: 120, y: 300, width: 200, height: 17)]),
        ]
    }

    private func update(
        _ controller: OverlayController, _ items: [OverlayItem],
        interaction: OverlayInteractionSettings = OverlayInteractionSettings(hoverOriginal: .inPlace)
    ) {
        controller.update(
            window: key, axWindowFrame: window, axClipRect: nil, cgWindowID: nil, items: items,
            style: OverlayStyle(displayStyle: .replace, appearance: OverlayAppearance(), interaction: interaction),
            targetIsFrontmost: false)
    }

    func testWithTheDefaultPopupModeItemsThatFitOpenAPopupToo() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        controller.revealOriginal = true
        let interaction = OverlayInteractionSettings()
        XCTAssertEqual(interaction.hoverOriginal, .popup)
        update(controller, items(long: String(repeating: "長い訳文", count: 40)), interaction: interaction)

        // An item that fits shows its original in the popup after the hover delay; the translation stays.
        let rested = now
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 308))
        XCTAssertNil(controller.hoverPopupItem)
        await waitUntil { controller.hoverPopupItem != nil }
        XCTAssertGreaterThanOrEqual(now - rested, interaction.hoverDelay - 0.05)
        XCTAssertEqual(controller.hoverPopupItem?.id, "short")
        XCTAssertNil(controller.revealedItem)

        // The cut one still opens its popup.
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 208))
        await waitUntil { controller.hoverPopupItem?.id == "long" }
        XCTAssertEqual(controller.hoverPopupItem?.id, "long")
        XCTAssertNil(controller.revealedItem)
    }

    func testCutTranslationOpensItsPopupAfterTheDelay() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        // The popup stays invisible (alpha 0) while the original is revealed; its owner is still tracked.
        controller.revealOriginal = true
        var changes = 0
        controller.onTruncatedItemsChanged = { changes += 1 }
        update(controller, items(long: String(repeating: "長い訳文", count: 40)))
        XCTAssertTrue(controller.hasTruncatedItems)
        XCTAssertEqual(changes, 1)

        // Items that fit never open a popup (waiting well past their own rest delay).
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 308))
        await sleep(OverlayInteractionSettings(hoverOriginal: .inPlace).hoverDelay + 0.3)
        XCTAssertNil(controller.hoverPopupItem)

        // Resting on the cut one: nothing at once, the popup after the delay.
        let rested = now
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 208))
        XCTAssertNil(controller.hoverPopupItem)
        await waitUntil { controller.hoverPopupItem != nil }
        XCTAssertGreaterThanOrEqual(now - rested, OverlayController.truncatedHoverDelay - 0.05)
        XCTAssertEqual(controller.hoverPopupItem?.id, "long")

        // A rescan with the same text keeps it open.
        update(controller, items(long: String(repeating: "長い訳文", count: 40)))
        XCTAssertEqual(controller.hoverPopupItem?.id, "long")

        // Once the translation fits, the popup closes and mouse moves are no longer needed.
        update(controller, items(long: "短い"))
        XCTAssertNil(controller.hoverPopupItem)
        XCTAssertFalse(controller.hasTruncatedItems)
        XCTAssertEqual(changes, 2)
    }

    func testPassingOverACutTranslationOpensNothing() async {
        let controller = OverlayController()
        defer { controller.removeAll() }
        controller.revealOriginal = true
        update(controller, items(long: String(repeating: "長い訳文", count: 40)))
        controller.updateMouseLocation(ax: CGPoint(x: 140, y: 208))
        await sleep(OverlayController.truncatedHoverDelay / 3)
        controller.updateMouseLocation(ax: CGPoint(x: 600, y: 500))
        await sleep(OverlayController.truncatedHoverDelay + 0.15)
        XCTAssertNil(controller.hoverPopupItem)
    }

    func testRemovingTheWindowClearsTheState() {
        let controller = OverlayController()
        update(controller, items(long: String(repeating: "長い訳文", count: 40)))
        XCTAssertTrue(controller.hasTruncatedItems)
        controller.remove(window: key)
        XCTAssertFalse(controller.hasTruncatedItems)
    }
}
