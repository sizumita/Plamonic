import AppKit
import XCTest

@testable import Plamonic

/// The session's mouse moves reach the overlay throttled; the trailing update delivers where the pointer is
/// now, so it never undoes a newer point the click panels already sent (DESIGN §6.1).
@MainActor
final class SessionMouseMoveForwarderTests: XCTestCase {
    private let key = WindowKey(pid: 1, windowID: 92)
    private let delay = 0.1

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testTrailingUpdateDeliversTheCurrentPointer() async {
        var pointer = CGPoint(x: 3, y: 3)
        var delivered: [CGPoint] = []
        let forwarder = MouseMoveForwarder(interval: 0.03, pointer: { pointer }) { delivered.append($0) }
        forwarder.move(to: CGPoint(x: 1, y: 1), at: 10)
        forwarder.move(to: CGPoint(x: 2, y: 2), at: 10.01)
        XCTAssertEqual(delivered, [CGPoint(x: 1, y: 1)])
        pointer = CGPoint(x: 4, y: 4)
        await sleep(0.08)
        XCTAssertEqual(delivered, [CGPoint(x: 1, y: 1), CGPoint(x: 4, y: 4)])
    }

    func testNoTrailingUpdateWithoutAHeldPoint() async {
        var delivered: [CGPoint] = []
        let forwarder = MouseMoveForwarder(interval: 0.03, pointer: { CGPoint(x: 9, y: 9) }) { delivered.append($0) }
        forwarder.move(to: CGPoint(x: 1, y: 1), at: 10)
        await sleep(0.06)
        XCTAssertEqual(delivered, [CGPoint(x: 1, y: 1)])
        // A reset drops the held point: the scheduled update delivers nothing.
        forwarder.move(to: CGPoint(x: 2, y: 2), at: 10.01)
        forwarder.reset()
        await sleep(0.06)
        XCTAssertEqual(delivered, [CGPoint(x: 1, y: 1)])
    }

    /// The pointer moves onto a translated link while the session holds an off-link point. The link's click
    /// panel reports the on-link point first; the session's trailing update must not put the pointer back
    /// off the link, or resting there would reveal the original and remove the link's panel.
    func testTrailingUpdateDoesNotUndoAClickPanelReport() async throws {
        let controller = OverlayController()
        defer { controller.removeAll() }
        let translation = "今すぐガイドを読んでください" as NSString
        let guide = translation.range(of: "ガイド")
        let item = OverlayItem(
            id: "a", axFrame: CGRect(x: 120, y: 200, width: 300, height: 17), original: "Read the guide now please",
            translation: translation as String, state: .final,
            style: TextStyleHint(fontSize: 14, lineHeight: 20, textColor: RGBAColor(red: 0.1, green: 0.1, blue: 0.1)),
            lineFrames: [CGRect(x: 120, y: 200, width: 180, height: 17)],
            originalLinks: [
                SegmentLink(
                    range: 9..<14, text: "guide", url: URL(string: "https://example.com/guide"),
                    frames: [CGRect(x: 180, y: 200, width: 40, height: 17)],
                    color: RGBAColor(red: 0, green: 0.3, blue: 0.9), isUnderlined: true)
            ],
            links: [OverlayLink(range: guide.location..<NSMaxRange(guide), linkIndex: 0)])
        let style = OverlayStyle(
            displayStyle: .replace, appearance: OverlayAppearance(),
            interaction: OverlayInteractionSettings(hoverOriginal: .inPlace, hoverDelay: delay, clickableLinks: true))
        controller.update(
            window: key, axWindowFrame: CGRect(x: 100, y: 100, width: 800, height: 600), axClipRect: nil,
            cgWindowID: nil, items: [item], style: style, targetIsFrontmost: false)
        let link = try XCTUnwrap(controller.clickAreas(window: key).first { $0.isLink })
        let onLink = CGPoint(x: link.rect.midX, y: link.rect.midY)

        var pointer = CGPoint(x: 125, y: 208)
        let forwarder = MouseMoveForwarder(interval: 0.03, pointer: { pointer }) { [weak controller] point in
            controller?.updateMouseLocation(ax: point)
        }
        forwarder.move(to: CGPoint(x: 110, y: 208))
        forwarder.move(to: CGPoint(x: 125, y: 208))  // held back
        // The pointer enters the link's click panel, which reports its point itself.
        pointer = onLink
        controller.updateMouseLocation(ax: onLink)
        await sleep(0.03 + delay + 0.15)
        XCTAssertNil(controller.revealedItem)
        XCTAssertEqual(controller.clickPanelCounts(window: key).links, 1)
    }
}
