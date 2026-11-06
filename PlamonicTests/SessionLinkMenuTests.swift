import ApplicationServices
import XCTest

@testable import Plamonic

/// A right-click on a translated link shows what right-clicking the original shows: the app's own menu
/// (AXShowMenu), or Plamonic's small menu when the app has none; never both (DESIGN §6.1). All fakes: no app is
/// asked for a menu, no menu is shown, the pasteboard is never written.
@MainActor
final class SessionLinkMenuTests: XCTestCase {
    private let window = WindowKey(pid: 42, windowID: 7)
    /// Never asked for a menu for real: the fake presser only counts.
    private let element = AXElement(AXUIElementCreateApplication(getpid()))
    private let point = CGPoint(x: 640, y: 212)
    private var clock: CFAbsoluteTime = 1000

    private struct Fixture {
        var activator: LinkActivator
        var presser: SessionFakePresser
        var opener: SessionFakeOpener
        var presenter: SessionFakeMenuPresenter
        var pasteboard: SessionFakePasteboard
    }

    private func make(_ presser: SessionFakePresser = SessionFakePresser()) -> Fixture {
        let opener = SessionFakeOpener()
        let presenter = SessionFakeMenuPresenter()
        let pasteboard = SessionFakePasteboard()
        let activator = LinkActivator(
            presser: presser, opener: opener, menuPresenter: presenter, pasteboard: pasteboard,
            now: { [unowned self] in self.clock })
        return Fixture(
            activator: activator, presser: presser, opener: opener, presenter: presenter, pasteboard: pasteboard)
    }

    private func link(
        _ url: String?, element: AXElement? = nil, kind: SegmentLinkKind = .link, range: Range<Int> = 0..<5
    ) -> SegmentLink {
        SegmentLink(range: range, text: "guide", kind: kind, url: url.flatMap(URL.init(string:)), element: element)
    }

    private func menu(
        _ f: Fixture, _ link: SegmentLink, item: String = "a", showOriginal: @escaping @MainActor () -> Void = {},
        opened: @escaping @MainActor (LinkActivationReport) -> Void = { _ in }
    ) async -> LinkMenuReport {
        await f.activator.showMenu(
            link, window: window, itemID: item, at: point, showOriginal: showOriginal, opened: opened)
    }

    func testElementWithAMenuShowsOnlyTheAppsMenu() async {
        let f = make(SessionFakePresser(menuResult: .success))
        let report = await menu(f, link("https://example.com/doc?q=1", element: element))
        XCTAssertEqual(report.outcome, .appMenu)
        XCTAssertEqual(f.presser.menus, 1)
        XCTAssertEqual(f.presser.presses, 0)
        XCTAssertTrue(f.presenter.shown.isEmpty)
        XCTAssertEqual(report.ownMenu, [])
        XCTAssertNil(report.menuError)
        XCTAssertEqual(report.point, point)
        XCTAssertEqual(report.scheme, "https")
        XCTAssertEqual(report.host, "example.com")
        XCTAssertEqual(f.opener.opened, [])
    }

    func testWithoutElementShowsPlamonicsMenuAtThePoint() async {
        let f = make()
        let report = await menu(f, link("https://example.com/x", kind: .detected))
        XCTAssertEqual(report.outcome, .ownMenu)
        XCTAssertEqual(f.presser.menus, 0)
        XCTAssertEqual(f.presenter.shown.count, 1)
        XCTAssertEqual(f.presenter.shown.first?.point, point)
        XCTAssertEqual(f.presenter.actions, [.open, .copyAddress, .showOriginal])
        XCTAssertEqual(report.ownMenu, [.open, .copyAddress, .showOriginal])
        XCTAssertEqual(
            f.presenter.shown.first?.entries.map(\.action.title), ["リンクを開く", "リンクのアドレスをコピー", "原文を表示"])
        // Nothing runs until an entry is chosen.
        XCTAssertEqual(f.pasteboard.written, [])
        XCTAssertEqual(f.opener.opened, [])
    }

    func testAppWithoutAMenuForTheLinkFallsBackToPlamonicsMenu() async {
        for error in [AXError.actionUnsupported, .invalidUIElement, .failure, .notImplemented, .illegalArgument] {
            let f = make(SessionFakePresser(menuResult: error))
            let report = await menu(f, link("https://example.com", element: element))
            XCTAssertEqual(report.outcome, .ownMenu, "\(error.rawValue)")
            XCTAssertEqual(report.menuError, error)
            XCTAssertEqual(f.presser.menus, 1)
            XCTAssertEqual(f.presenter.shown.count, 1, "\(error.rawValue)")
        }
    }

    func testTimedOutRequestShowsNoMenu() async {
        // The app may still show its menu: Plamonic's own would make two.
        let f = make(SessionFakePresser(menuResult: .cannotComplete))
        let report = await menu(f, link("https://example.com", element: element))
        XCTAssertEqual(report.outcome, .ignored(.timedOut))
        XCTAssertEqual(report.menuError, .cannotComplete)
        XCTAssertTrue(f.presenter.shown.isEmpty)
    }

    func testSecondRequestForTheSameLinkWithinHalfASecondIsIgnored() async {
        let f = make()
        let target = link("https://example.com", element: element)
        let first = await menu(f, target)
        XCTAssertEqual(first.outcome, .appMenu)
        clock += 0.3
        let second = await menu(f, target)
        XCTAssertEqual(second.outcome, .ignored(.repeated))
        // Another link, or the same link text in another item, is not held back.
        let other = await menu(f, link("https://example.com", element: element, range: 8..<13))
        XCTAssertEqual(other.outcome, .appMenu)
        let otherItem = await menu(f, target, item: "b")
        XCTAssertEqual(otherItem.outcome, .appMenu)
        XCTAssertEqual(f.presser.menus, 3)
        clock += 0.25  // 0.55 s after the first
        let later = await menu(f, target)
        XCTAssertEqual(later.outcome, .appMenu)
        XCTAssertEqual(f.presser.menus, 4)
    }

    func testRepeatGuardIsCaughtBeforeTheFirstRequestReturns() async {
        let f = make()
        let target = link("https://example.com", element: element)
        let first = Task { await menu(f, target) }
        let second = Task { await menu(f, target) }
        let outcomes = [await first.value.outcome, await second.value.outcome]
        XCTAssertEqual(outcomes.filter { $0 == .appMenu }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .ignored(.repeated) }.count, 1)
        XCTAssertEqual(f.presser.menus, 1)
    }

    func testClickAndMenuHaveSeparateRepeatGuards() async {
        let f = make()
        let target = link("https://example.com", element: element)
        let click = await f.activator.activate(target, window: window, itemID: "a")
        XCTAssertEqual(click.outcome, .pressed)
        let report = await menu(f, target)
        XCTAssertEqual(report.outcome, .appMenu)
        clock += 0.1
        let again = await f.activator.activate(target, window: window, itemID: "a")
        XCTAssertEqual(again.outcome, .ignored(.repeated))
    }

    func testDryRunShowsNothing() async {
        let supported = make(SessionFakePresser(menuSupported: true))
        supported.activator.dryRun = true
        let app = await menu(supported, link("https://example.com", element: element))
        XCTAssertEqual(app.outcome, .wouldShowAppMenu)
        XCTAssertEqual(app.menuSupported, true)
        XCTAssertEqual(supported.presser.menuChecks, 1)
        XCTAssertEqual(supported.presser.menus, 0)

        let unsupported = make(SessionFakePresser(menuSupported: false))
        unsupported.activator.dryRun = true
        let fallback = await menu(unsupported, link("https://example.com", element: element))
        XCTAssertEqual(fallback.outcome, .wouldShowOwnMenu)
        XCTAssertEqual(fallback.menuSupported, false)
        XCTAssertEqual(fallback.ownMenu, [.open, .copyAddress, .showOriginal])
        let detected = await menu(unsupported, link("https://example.com", kind: .detected, range: 20..<30))
        XCTAssertEqual(detected.outcome, .wouldShowOwnMenu)
        XCTAssertNil(detected.menuSupported)
        XCTAssertEqual(unsupported.presser.menus, 0)
        XCTAssertTrue(supported.presenter.shown.isEmpty)
        XCTAssertTrue(unsupported.presenter.shown.isEmpty)
    }

    func testCopyIsOfferedOnlyForAddressesPlamonicMayOpen() async {
        let cases: [(String?, Bool)] = [
            ("https://example.com/a", true), ("http://example.com", true), ("mailto:someone@example.com", true),
            ("file:///etc/hosts", false), ("slack://channel?id=C1", false), ("javascript:alert(1)", false),
            (nil, false),
        ]
        for (index, (url, offered)) in cases.enumerated() {
            let f = make()
            _ = await menu(f, link(url, kind: .detected, range: index * 10..<(index * 10 + 5)))
            XCTAssertEqual(f.presenter.actions.contains(.copyAddress), offered, url ?? "nil")
            XCTAssertEqual(f.presenter.actions.first, .open)
            XCTAssertEqual(f.presenter.actions.last, .showOriginal)
        }
    }

    func testChoosingCopyWritesTheAddress() async {
        let f = make()
        _ = await menu(f, link("https://example.com/a?b=c", kind: .detected))
        XCTAssertEqual(f.pasteboard.written, [])
        f.presenter.choose(.copyAddress)
        XCTAssertEqual(f.pasteboard.written, [URL(string: "https://example.com/a?b=c")!])
        XCTAssertEqual(f.opener.opened, [])
    }

    func testChoosingOpenDoesWhatAClickDoes() async {
        // The app has no menu for the element, but it can be pressed.
        let pressable = make(SessionFakePresser(result: .success, menuResult: .actionUnsupported))
        let pressed = expectation(description: "pressed")
        var reports: [LinkActivationReport] = []
        _ = await menu(
            pressable, link("https://example.com", element: element),
            opened: {
                reports.append($0)
                pressed.fulfill()
            })
        pressable.presenter.choose(.open)
        await fulfillment(of: [pressed], timeout: 2)
        XCTAssertEqual(reports.map(\.outcome), [.pressed])
        XCTAssertEqual(pressable.presser.presses, 1)
        XCTAssertEqual(pressable.opener.opened, [])

        // A terminal URL opens in the browser.
        let detected = make()
        let opened = expectation(description: "opened")
        _ = await menu(detected, link("https://example.com/x", kind: .detected), opened: { _ in opened.fulfill() })
        detected.presenter.choose(.open)
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(detected.opener.opened, [URL(string: "https://example.com/x")!])
    }

    func testOpenIsDisabledWhenNothingCanBeOpened() async {
        let f = make()
        _ = await menu(f, link("slack://open", kind: .detected))
        let open = f.presenter.shown.first?.entries.first { $0.action == .open }
        XCTAssertEqual(open?.isEnabled, false)
        XCTAssertEqual(f.presenter.actions, [.open, .showOriginal])
    }

    func testChoosingShowOriginalShowsTheItemsOriginal() async {
        let f = make()
        var shown = 0
        _ = await menu(f, link("https://example.com", kind: .detected), showOriginal: { shown += 1 })
        XCTAssertEqual(shown, 0)
        f.presenter.choose(.showOriginal)
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(f.opener.opened, [])
    }

    func testRequestWhileOwnMenuIsOpenIsIgnored() async {
        let f = make()
        var closed = 0
        f.activator.onOwnMenuClosed = { closed += 1 }
        _ = await menu(f, link("https://example.com", kind: .detected))
        XCTAssertTrue(f.activator.isOwnMenuOpen)
        let other = await menu(f, link("https://example.com", element: element, range: 10..<15))
        XCTAssertEqual(other.outcome, .ignored(.menuOpen))
        // The app is not asked either: that could show a second menu.
        XCTAssertEqual(f.presser.menus, 0)
        f.activator.cancelOwnMenu()
        XCTAssertEqual(f.presenter.cancels, 1)
        XCTAssertFalse(f.activator.isOwnMenuOpen)
        XCTAssertEqual(closed, 1)
        let later = await menu(f, link("https://example.com", element: element, range: 20..<25))
        XCTAssertEqual(later.outcome, .appMenu)
    }

    func testCancelWhileWaitingForTheAppShowsNoOwnMenuLater() async {
        // The app has no menu for the element; the session stops while the request waits for its answer.
        let gate = DispatchSemaphore(value: 0)
        let f = make(SessionFakePresser(menuResult: .actionUnsupported, menuGate: gate))
        let request = Task { await menu(f, link("https://example.com", element: element)) }
        while f.presser.menus == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        f.activator.cancelOwnMenu()
        gate.signal()
        let report = await request.value
        XCTAssertEqual(report.outcome, .ignored(.cancelled))
        XCTAssertTrue(f.presenter.shown.isEmpty)
        // Later requests are not affected.
        let later = await menu(f, link("https://example.com", kind: .detected, range: 10..<15))
        XCTAssertEqual(later.outcome, .ownMenu)
    }

    func testOutcomesHaveStableNames() {
        XCTAssertEqual(LinkActivator.describe(LinkMenuOutcome.appMenu), "app-menu")
        XCTAssertEqual(LinkActivator.describe(LinkMenuOutcome.ownMenu), "own-menu")
        XCTAssertEqual(LinkActivator.describe(LinkMenuOutcome.wouldShowAppMenu), "would-show-app-menu")
        XCTAssertEqual(LinkActivator.describe(LinkMenuOutcome.wouldShowOwnMenu), "would-show-own-menu")
        XCTAssertEqual(LinkActivator.describe(LinkMenuOutcome.ignored(.timedOut)), "ignored(menu-timed-out)")
    }
}

/// The session asks for the menu of a right-clicked translated link only while it runs, and the own menu's
/// entries reach the overlay and the activation report.
@MainActor
final class SessionLinkMenuWiringTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plamonic-session-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSession(
        overlay: OverlayController, links: LinkActivator, dryRun: Bool = false
    ) -> LiveTranslationSession {
        var options = LiveTranslationSession.Options()
        options.monitorsInput = false
        options.dryRunLinks = dryRun
        // Plamonic itself: never tracked, so nothing is scanned.
        options.pinnedPID = getpid()
        let settings = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"), saveDelay: 10)
        let cache = TranslationCache(capacity: 10, fileURL: nil, persistenceEnabled: false)
        let coordinator = TranslationCoordinator(backend: TranslationFakeBackend(), cache: cache) { nil }
        return LiveTranslationSession(
            settings: settings, coordinator: coordinator, overlay: overlay, options: options, links: links,
            passwordSystem: .testIdle)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testRightClickedLinkShowsItsMenuWhileRunning() async {
        let overlay = OverlayController()
        defer { overlay.removeAll() }
        let presser = SessionFakePresser()
        let presenter = SessionFakeMenuPresenter()
        let links = LinkActivator(
            presser: presser, opener: SessionFakeOpener(), menuPresenter: presenter,
            pasteboard: SessionFakePasteboard())
        let session = makeSession(overlay: overlay, links: links)
        var reports: [LinkMenuReport] = []
        session.onLinkMenuShown = { reports.append($0) }
        let key = WindowKey(pid: 42, windowID: 7)
        let element = AXElement(AXUIElementCreateApplication(getpid()))
        let link = SegmentLink(range: 0..<5, text: "guide", url: URL(string: "https://example.com"), element: element)
        let point = CGPoint(x: 10, y: 20)

        // Not running: nothing.
        overlay.onLinkContextMenu?(key, "a", link, point)
        await sleep(0.1)
        XCTAssertEqual(reports.count, 0)
        XCTAssertEqual(presser.menus, 0)

        session.start()
        let shown = expectation(description: "menu")
        session.onLinkMenuShown = {
            reports.append($0)
            shown.fulfill()
        }
        overlay.onLinkContextMenu?(key, "a", link, point)
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertEqual(reports.map(\.outcome), [.appMenu])
        XCTAssertEqual(reports.first?.window, key)
        XCTAssertEqual(reports.first?.itemID, "a")
        XCTAssertEqual(reports.first?.point, point)
        XCTAssertEqual(presser.menus, 1)
        session.stop()
    }

    func testOwnMenuEntriesReachTheActivationReportAndStopClosesIt() async {
        let overlay = OverlayController()
        defer { overlay.removeAll() }
        let opener = SessionFakeOpener()
        let presenter = SessionFakeMenuPresenter()
        let links = LinkActivator(
            presser: SessionFakePresser(), opener: opener, menuPresenter: presenter,
            pasteboard: SessionFakePasteboard())
        let session = makeSession(overlay: overlay, links: links)
        session.start()
        let key = WindowKey(pid: 42, windowID: 7)
        let link = SegmentLink(range: 0..<5, text: "guide", kind: .detected, url: URL(string: "https://example.com"))

        let shown = expectation(description: "menu")
        session.onLinkMenuShown = { _ in shown.fulfill() }
        overlay.onLinkContextMenu?(key, "a", link, CGPoint(x: 1, y: 2))
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertEqual(presenter.actions, [.open, .copyAddress, .showOriginal])
        // The item is not drawn: showing its original does nothing (and must not fail).
        presenter.choose(.showOriginal)

        let menuAgain = expectation(description: "menu again")
        session.onLinkMenuShown = { _ in menuAgain.fulfill() }
        overlay.onLinkContextMenu?(key, "b", link, CGPoint(x: 1, y: 2))
        await fulfillment(of: [menuAgain], timeout: 2)
        let activated = expectation(description: "activated")
        var outcomes: [LinkActivationOutcome] = []
        session.onLinkActivated = {
            outcomes.append($0.outcome)
            activated.fulfill()
        }
        presenter.choose(.open)
        await fulfillment(of: [activated], timeout: 2)
        XCTAssertEqual(outcomes, [.openedURL])
        XCTAssertEqual(opener.opened, [URL(string: "https://example.com")!])

        // A menu still open when the session stops is closed.
        let third = expectation(description: "third menu")
        session.onLinkMenuShown = { _ in third.fulfill() }
        overlay.onLinkContextMenu?(key, "c", link, CGPoint(x: 1, y: 2))
        await fulfillment(of: [third], timeout: 2)
        XCTAssertTrue(links.isOwnMenuOpen)
        session.stop()
        XCTAssertFalse(links.isOwnMenuOpen)
    }

    func testDryRunOptionReachesTheActivator() async {
        let overlay = OverlayController()
        defer { overlay.removeAll() }
        let presenter = SessionFakeMenuPresenter()
        let links = LinkActivator(
            presser: SessionFakePresser(), opener: SessionFakeOpener(), menuPresenter: presenter,
            pasteboard: SessionFakePasteboard())
        let session = makeSession(overlay: overlay, links: links, dryRun: true)
        session.start()
        defer { session.stop() }
        let shown = expectation(description: "menu")
        var outcome: LinkMenuOutcome?
        session.onLinkMenuShown = {
            outcome = $0.outcome
            shown.fulfill()
        }
        let link = SegmentLink(range: 0..<5, text: "guide", kind: .detected, url: URL(string: "https://example.com"))
        overlay.onLinkContextMenu?(WindowKey(pid: 42, windowID: 7), "a", link, .zero)
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertEqual(outcome, .wouldShowOwnMenu)
        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testSmokeTestParsesTheMenuAndHoverOptions() {
        let options = SmokeTestOptions(arguments: [
            "Plamonic", "--smoke-test", "com.google.Chrome", "20", "--show-overlays", "--context-menu-first-link",
            "--hover-first-link", "--hover-hold", "2",
        ])
        XCTAssertEqual(options?.contextMenuFirstLink, true)
        XCTAssertEqual(options?.hoverFirstLink, true)
        XCTAssertEqual(options?.activateFirstLink, false)
        XCTAssertEqual(options?.usesFirstLink, true)
        XCTAssertEqual(options?.hoverHold, 2)
        let plain = SmokeTestOptions(arguments: ["Plamonic", "--smoke-test", "com.apple.Terminal"])
        XCTAssertEqual(plain?.contextMenuFirstLink, false)
        XCTAssertEqual(plain?.hoverFirstLink, false)
        XCTAssertEqual(plain?.usesFirstLink, false)
    }
}
