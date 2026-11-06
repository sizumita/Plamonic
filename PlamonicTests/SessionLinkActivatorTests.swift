import ApplicationServices
import XCTest

@testable import Plamonic

@MainActor
final class SessionLinkActivatorTests: XCTestCase {
    private let window = WindowKey(pid: 42, windowID: 7)
    /// Never pressed for real: the fake presser only counts.
    private let element = AXElement(AXUIElementCreateApplication(getpid()))
    private var clock: CFAbsoluteTime = 1000

    private func makeActivator(_ presser: SessionFakePresser, _ opener: SessionFakeOpener) -> LinkActivator {
        // The fake presenter and pasteboard: no menu is shown, the real pasteboard is never written.
        LinkActivator(
            presser: presser, opener: opener, menuPresenter: SessionFakeMenuPresenter(),
            pasteboard: SessionFakePasteboard(), now: { [unowned self] in self.clock })
    }

    private func link(
        _ url: String?, element: AXElement? = nil, kind: SegmentLinkKind = .link, range: Range<Int> = 0..<5
    ) -> SegmentLink {
        SegmentLink(range: range, text: "guide", kind: kind, url: url.flatMap(URL.init(string:)), element: element)
    }

    func testOnlyHTTPHTTPSAndMailtoMayBeOpened() {
        XCTAssertTrue(LinkActivator.isAllowed(URL(string: "https://example.com/a?b=c")))
        XCTAssertTrue(LinkActivator.isAllowed(URL(string: "http://example.com")))
        XCTAssertTrue(LinkActivator.isAllowed(URL(string: "HTTPS://EXAMPLE.COM/")))
        XCTAssertTrue(LinkActivator.isAllowed(URL(string: "mailto:someone@example.com")))
        XCTAssertFalse(LinkActivator.isAllowed(nil))
        XCTAssertFalse(LinkActivator.isAllowed(URL(string: "file:///etc/hosts")))
        XCTAssertFalse(LinkActivator.isAllowed(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(LinkActivator.isAllowed(URL(string: "slack://channel?id=C1")))
        XCTAssertFalse(LinkActivator.isAllowed(URL(string: "ftp://example.com/file")))
        XCTAssertFalse(LinkActivator.isAllowed(URL(string: "x-apple.systempreferences:com.apple")))
        XCTAssertFalse(LinkActivator.isAllowed(URL(string: "https:///no-host")))
    }

    func testPressesTheElementAndOpensNothing() async {
        let presser = SessionFakePresser(result: .success)
        let opener = SessionFakeOpener()
        let report = await makeActivator(presser, opener).activate(
            link("https://example.com", element: element), window: window, itemID: "a")
        XCTAssertEqual(report.outcome, .pressed)
        XCTAssertEqual(presser.presses, 1)
        XCTAssertEqual(opener.opened, [])
        XCTAssertEqual(report.scheme, "https")
        XCTAssertEqual(report.host, "example.com")
    }

    func testFailedPressFallsBackToTheURL() async {
        for error in [AXError.invalidUIElement, .actionUnsupported, .failure, .illegalArgument] {
            let presser = SessionFakePresser(result: error)
            let opener = SessionFakeOpener()
            let report = await makeActivator(presser, opener).activate(
                link("https://example.com/doc", element: element), window: window, itemID: "a")
            XCTAssertEqual(presser.presses, 1, "\(error.rawValue)")
            XCTAssertEqual(report.outcome, .openedURL, "\(error.rawValue)")
            XCTAssertEqual(report.pressError, error)
            XCTAssertEqual(opener.opened, [URL(string: "https://example.com/doc")!])
        }
    }

    func testTimedOutPressDoesNotAlsoOpenTheURL() async {
        // The app may still act on a press it did not answer in time: opening the URL too could open it twice.
        let presser = SessionFakePresser(result: .cannotComplete)
        let opener = SessionFakeOpener()
        let report = await makeActivator(presser, opener).activate(
            link("https://example.com", element: element), window: window, itemID: "a")
        XCTAssertEqual(report.outcome, .ignored(.pressTimedOut))
        XCTAssertEqual(opener.opened, [])
    }

    func testFailedPressWithoutURLOpensNothing() async {
        // A mention or an inline button: only the app knows where it leads.
        let presser = SessionFakePresser(result: .invalidUIElement)
        let opener = SessionFakeOpener()
        let report = await makeActivator(presser, opener).activate(
            link(nil, element: element, kind: .button), window: window, itemID: "a")
        XCTAssertEqual(report.outcome, .ignored(.disallowedURL))
        XCTAssertEqual(opener.opened, [])
    }

    func testWithoutElementOpensTheURL() async {
        let presser = SessionFakePresser()
        let opener = SessionFakeOpener()
        let activator = makeActivator(presser, opener)
        let report = await activator.activate(
            link("https://example.com/x", kind: .detected), window: window, itemID: "a")
        XCTAssertEqual(report.outcome, .openedURL)
        XCTAssertEqual(presser.presses, 0)
        XCTAssertEqual(opener.opened, [URL(string: "https://example.com/x")!])

        let mail = await activator.activate(
            link("mailto:someone@example.com", kind: .detected, range: 10..<20), window: window, itemID: "a")
        XCTAssertEqual(mail.outcome, .openedURL)
        XCTAssertEqual(opener.opened.count, 2)
    }

    func testDisallowedSchemesOpenNothing() async {
        let presser = SessionFakePresser()
        let opener = SessionFakeOpener()
        let activator = makeActivator(presser, opener)
        let urls = ["file:///etc/hosts", "javascript:alert(1)", "slack://open", "ssh://host", "tel:123", "data:text/html,x"]
        for (index, url) in urls.enumerated() {
            let report = await activator.activate(
                link(url, kind: .detected, range: index * 10..<(index * 10 + 5)), window: window, itemID: "a")
            XCTAssertEqual(report.outcome, .ignored(.disallowedURL), url)
        }
        let none = await activator.activate(link(nil, range: 100..<105), window: window, itemID: "a")
        XCTAssertEqual(none.outcome, .ignored(.disallowedURL))
        XCTAssertEqual(opener.opened, [])
        XCTAssertEqual(presser.presses, 0)
    }

    func testSecondActivationOfTheSameLinkWithinHalfASecondIsIgnored() async {
        let presser = SessionFakePresser()
        let opener = SessionFakeOpener()
        let activator = makeActivator(presser, opener)
        let target = link("https://example.com", element: element)

        let first = await activator.activate(target, window: window, itemID: "a")
        XCTAssertEqual(first.outcome, .pressed)
        clock += 0.3
        let second = await activator.activate(target, window: window, itemID: "a")
        XCTAssertEqual(second.outcome, .ignored(.repeated))
        // Another link, or the same link text in another item, is not held back.
        let other = await activator.activate(
            link("https://example.com", element: element, range: 8..<13), window: window, itemID: "a")
        XCTAssertEqual(other.outcome, .pressed)
        let otherItem = await activator.activate(target, window: window, itemID: "b")
        XCTAssertEqual(otherItem.outcome, .pressed)
        XCTAssertEqual(presser.presses, 3)

        clock += 0.25  // 0.55 s after the first
        let later = await activator.activate(target, window: window, itemID: "a")
        XCTAssertEqual(later.outcome, .pressed)
        XCTAssertEqual(presser.presses, 4)
        XCTAssertEqual(opener.opened, [])
    }

    func testDoubleClickIsCaughtWhileTheFirstPressIsStillRunning() async {
        let presser = SessionFakePresser()
        let opener = SessionFakeOpener()
        let activator = makeActivator(presser, opener)
        let target = link("https://example.com", element: element)
        // Both start before the first press returns from the background queue.
        let first = Task { await activator.activate(target, window: window, itemID: "a") }
        let second = Task { await activator.activate(target, window: window, itemID: "a") }
        let outcomes = [await first.value.outcome, await second.value.outcome]
        XCTAssertEqual(outcomes.filter { $0 == .pressed }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .ignored(.repeated) }.count, 1)
        XCTAssertEqual(presser.presses, 1)
    }

    func testDryRunPressesAndOpensNothing() async {
        let opener = SessionFakeOpener()
        let pressable = SessionFakePresser(supported: true)
        let dry = makeActivator(pressable, opener)
        dry.dryRun = true
        let press = await dry.activate(link("https://example.com", element: element), window: window, itemID: "a")
        XCTAssertEqual(press.outcome, .wouldPress)
        XCTAssertEqual(press.pressSupported, true)
        XCTAssertEqual(pressable.presses, 0)
        XCTAssertEqual(pressable.checks, 1)

        // An element that cannot be pressed would fall back to the URL.
        let gone = SessionFakePresser(supported: false)
        let dryGone = makeActivator(gone, opener)
        dryGone.dryRun = true
        let fallback = await dryGone.activate(
            link("https://example.com", element: element), window: window, itemID: "a")
        XCTAssertEqual(fallback.outcome, .wouldOpenURL)
        XCTAssertEqual(fallback.pressSupported, false)

        let detected = await dryGone.activate(
            link("https://example.com", kind: .detected, range: 20..<30), window: window, itemID: "a")
        XCTAssertEqual(detected.outcome, .wouldOpenURL)
        let blocked = await dryGone.activate(
            link("file:///etc/hosts", kind: .detected, range: 40..<50), window: window, itemID: "a")
        XCTAssertEqual(blocked.outcome, .ignored(.disallowedURL))
        XCTAssertEqual(gone.presses, 0)
        XCTAssertEqual(opener.opened, [])
    }

    func testOverlayStyleCarriesTheInteractionSettings() {
        var global = GlobalSettings()
        global.interaction = OverlayInteractionSettings(hoverOriginal: .popup, hoverDelay: 0.8, clickableLinks: false)
        global.displayStyle = .replace
        let settings = EffectiveSettings(profile: AppProfile(bundleID: "x", displayName: "X"), global: global)
        let style = LiveTranslationSession.overlayStyle(settings)
        XCTAssertEqual(style.interaction, global.interaction)
        XCTAssertEqual(style.appearance, global.appearance)
        XCTAssertEqual(style.displayStyle, .replace)
    }
}

/// Mouse moves reach the overlay at most once per interval, and the point where the pointer stopped always
/// arrives (the rest timers for showing the original depend on it).
final class SessionMouseMoveThrottleTests: XCTestCase {
    func testFirstMoveIsDeliveredAtOnce() {
        var throttle = MouseMoveThrottle(interval: 0.03)
        XCTAssertEqual(throttle.move(to: CGPoint(x: 1, y: 1), at: 10), .deliver(CGPoint(x: 1, y: 1)))
        XCTAssertNil(throttle.flush(at: 10.03))
    }

    func testRestingPointArrivesByTheTrailingUpdate() {
        var throttle = MouseMoveThrottle(interval: 0.03)
        _ = throttle.move(to: CGPoint(x: 1, y: 1), at: 10)
        guard case .hold(let after) = throttle.move(to: CGPoint(x: 2, y: 2), at: 10.01) else {
            return XCTFail("expected the move to be held back")
        }
        XCTAssertEqual(after, 0.02, accuracy: 1e-9)
        // Later moves replace the held point; the flush delivers only the last one.
        XCTAssertNotEqual(throttle.move(to: CGPoint(x: 3, y: 3), at: 10.02), .deliver(CGPoint(x: 3, y: 3)))
        XCTAssertEqual(throttle.flush(at: 10.03), CGPoint(x: 3, y: 3))
        XCTAssertNil(throttle.flush(at: 10.04))
    }

    func testMoveAfterTheIntervalIsDeliveredAndClearsTheHeldPoint() {
        var throttle = MouseMoveThrottle(interval: 0.03)
        _ = throttle.move(to: CGPoint(x: 1, y: 1), at: 10)
        _ = throttle.move(to: CGPoint(x: 2, y: 2), at: 10.01)
        // The trailing update was late (main thread busy) and a newer move got through first.
        XCTAssertEqual(throttle.move(to: CGPoint(x: 4, y: 4), at: 10.05), .deliver(CGPoint(x: 4, y: 4)))
        XCTAssertNil(throttle.flush(at: 10.06), "a stale point must not follow the newer one")
    }

    func testFlushStartsANewInterval() {
        var throttle = MouseMoveThrottle(interval: 0.03)
        _ = throttle.move(to: CGPoint(x: 1, y: 1), at: 10)
        _ = throttle.move(to: CGPoint(x: 2, y: 2), at: 10.01)
        XCTAssertEqual(throttle.flush(at: 10.03), CGPoint(x: 2, y: 2))
        guard case .hold = throttle.move(to: CGPoint(x: 3, y: 3), at: 10.04) else {
            return XCTFail("expected the move right after the flush to be held back")
        }
        XCTAssertEqual(throttle.flush(at: 10.06), CGPoint(x: 3, y: 3))
    }

    func testResetForgetsTheHeldPoint() {
        var throttle = MouseMoveThrottle(interval: 0.03)
        _ = throttle.move(to: CGPoint(x: 1, y: 1), at: 10)
        _ = throttle.move(to: CGPoint(x: 2, y: 2), at: 10.01)
        throttle.reset()
        XCTAssertNil(throttle.flush(at: 10.03))
        XCTAssertEqual(throttle.move(to: CGPoint(x: 5, y: 5), at: 10.031), .deliver(CGPoint(x: 5, y: 5)))
    }
}

/// The smoke test's link options and summaries (dev tool; the summaries never print text or URLs).
@MainActor
final class SessionSmokeLinkOptionsTests: XCTestCase {
    func testParsesTheLinkOptions() {
        let options = SmokeTestOptions(arguments: [
            "Plamonic", "--smoke-test", "com.google.Chrome", "40", "--pid", "123", "--show-overlays",
            "--activate-first-link", "--dry-run-links", "--hover-at", "640,212.5", "--hover-hold", "3.5",
        ])
        XCTAssertEqual(options?.pid, 123)
        XCTAssertEqual(options?.activateFirstLink, true)
        XCTAssertEqual(options?.dryRunLinks, true)
        XCTAssertEqual(options?.hoverAt, CGPoint(x: 640, y: 212.5))
        XCTAssertEqual(options?.hoverHold, 3.5)
        let plain = SmokeTestOptions(arguments: ["Plamonic", "--smoke-test", "com.apple.Terminal"])
        XCTAssertEqual(plain?.activateFirstLink, false)
        XCTAssertEqual(plain?.dryRunLinks, false)
        XCTAssertNil(plain?.hoverAt)
        XCTAssertEqual(plain?.hoverHold, 1)
        XCTAssertNil(SmokeTestOptions.point("12"))
        XCTAssertNil(SmokeTestOptions.point("a,b"))
    }

    private func segment(_ text: String, color: RGBAColor?, links: [SegmentLink]) -> TextSegment {
        TextSegment(
            id: "s", text: text, axFrame: .zero, role: "AXGroup", isEditable: false, order: 0,
            style: TextStyleHint(fontSize: 14, textColor: color), links: links)
    }

    func testLinkSummaryCountsKinds() {
        let blue = RGBAColor(red: 0, green: 0.4, blue: 1)
        let segments = [
            segment(
                "Read the setup guide now.", color: .init(red: 0, green: 0, blue: 0),
                links: [SegmentLink(range: 9..<20, text: "setup guide", color: blue)]),
            segment(
                "Open https://example.com", color: nil,
                links: [SegmentLink(range: 5..<24, text: "https://example.com", kind: .detected)]),
            segment("Plain text.", color: nil, links: []),
        ]
        XCTAssertEqual(SmokeTest.linkSummary(segments), "links=2 in 2 segs (link=1,detected=1)")
        XCTAssertEqual(SmokeTest.linkSummary([segments[2]]), "links=0")
    }

    func testFlagsAParagraphColoredLikeItsLink() {
        let blue = RGBAColor(red: 0, green: 0.4, blue: 1)
        let link = SegmentLink(range: 9..<20, text: "setup guide", color: blue)
        XCTAssertTrue(SmokeTest.textTakesLinkColor(segment("Read the setup guide now.", color: blue, links: [link])))
        XCTAssertFalse(
            SmokeTest.textTakesLinkColor(
                segment("Read the setup guide now.", color: .init(red: 0, green: 0, blue: 0), links: [link])))
        // A paragraph that is only the link takes the link's color by design.
        let whole = SegmentLink(range: 0..<11, text: "setup guide", color: blue)
        XCTAssertFalse(SmokeTest.textTakesLinkColor(segment("setup guide.", color: blue, links: [whole])))
        XCTAssertTrue(
            SmokeTest.linkSummary([segment("Read the setup guide now.", color: blue, links: [link])])
                .hasSuffix("textColorIsLinkColor=1"))
    }

    func testLinkTagIsMasked() {
        let link = SegmentLink(
            range: 9..<20, text: "setup guide", url: URL(string: "https://docs.example.com/private/path?q=1"),
            frames: [CGRect(x: 0, y: 0, width: 10, height: 10)], isUnderlined: true)
        let tag = SmokeTest.linkTag(link, in: segment("Read the setup guide now.", color: nil, links: [link]))
        XCTAssertTrue(tag.contains("range=9..<20(ok)"), tag)
        XCTAssertTrue(tag.contains("url=https://"), tag)
        XCTAssertFalse(tag.contains("example"), tag)
        XCTAssertFalse(tag.contains("private"), tag)
        XCTAssertFalse(tag.contains("setup"), tag)
        XCTAssertTrue(tag.contains("underline"), tag)
        XCTAssertTrue(tag.contains("frames=1[0,0 10x10]"), tag)
    }
}
