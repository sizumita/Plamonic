import ApplicationServices
import XCTest

@testable import Plamonic

/// The smoke test's menu watch (`--context-menu-first-link`) closes every menu the request brings up, also a late
/// one, and ends the run when it cannot. All fakes: no window list, no AX call, no menu.
@MainActor
final class SessionSmokeMenuWatchTests: XCTestCase {
    private let target: pid_t = 4242
    private let frame = CGRect(x: 500, y: 300, width: 240, height: 180)

    @MainActor
    private final class FakeEnvironment: SmokeMenuEnvironment {
        var now: CFAbsoluteTime = 1000
        var frontmostPID: pid_t? = 77
        var isPlamonicActive = false
        var windows: [SmokeMenuWindow] = []
        /// Probes that find the AXMenu.
        var finds: (SmokeMenuProbe) -> Bool = { _ in false }
        var cancelResult: AXError = .success
        /// AXCancel closes the menu window.
        var cancelCloses = true
        var asked: [SmokeMenuProbe] = []
        var cancels = 0

        func menuWindows(of pids: Set<pid_t>) -> [SmokeMenuWindow] {
            windows.filter { pids.contains($0.pid) }
        }

        func menu(of pid: pid_t, probe: SmokeMenuProbe, deadline: CFAbsoluteTime) -> SmokeFoundMenu? {
            asked.append(probe)
            guard finds(probe) else { return nil }
            return SmokeFoundMenu(itemCount: 9) { [unowned self] in
                self.cancels += 1
                if self.cancelResult == .success, self.cancelCloses { self.windows.removeAll() }
                return self.cancelResult
            }
        }
    }

    @MainActor
    private final class Recorder {
        var reports: [SmokeMenuWatch.Result] = []
        var leftOpen: [SmokeMenuWatch.Result] = []
        var ownCancels = 0
    }

    @MainActor
    private struct Fixture {
        var watch: SmokeMenuWatch
        var environment: FakeEnvironment
        var recorder: Recorder

        func reports() -> [SmokeMenuWatch.Result] { recorder.reports }
        func leftOpen() -> [SmokeMenuWatch.Result] { recorder.leftOpen }
        func ownCancels() -> Int { recorder.ownCancels }
    }

    private func make(_ environment: FakeEnvironment? = nil) -> Fixture {
        let environment = environment ?? FakeEnvironment()
        let recorder = Recorder()
        let watch = SmokeMenuWatch(
            targetPID: target, environment: environment, cancelOwnMenu: { recorder.ownCancels += 1 },
            ownMenuItemCount: { 3 }, reported: { recorder.reports.append($0) },
            leftOpen: { recorder.leftOpen.append($0) })
        watch.start(timer: false)
        return Fixture(watch: watch, environment: environment, recorder: recorder)
    }

    private func appMenu(id: CGWindowID = 900) -> SmokeMenuWindow {
        SmokeMenuWindow(id: id, pid: target, bounds: frame)
    }

    /// Ticks every 10 ms for `seconds`.
    private func run(_ f: Fixture, for seconds: TimeInterval) {
        let end = f.environment.now + seconds
        while f.environment.now < end {
            f.environment.now += 0.01
            f.watch.tick()
        }
    }

    // MARK: - Finding the AXMenu

    func testAppMenuFoundOnlyNearItsBottomIsCancelled() throws {
        let f = make()
        // Only the lower part of the menu is exposed (the top items are not).
        f.environment.finds = { probe in
            if case .systemWide(let point) = probe { return point.y > self.frame.maxY - 20 }
            return false
        }
        run(f, for: 0.1)
        f.environment.windows = [appMenu()]
        run(f, for: 0.2)
        XCTAssertEqual(f.environment.cancels, 1)
        XCTAssertTrue(f.leftOpen().isEmpty)
        XCTAssertEqual(f.reports().count, 1)
        let result = try XCTUnwrap(f.reports().first)
        XCTAssertEqual(result.owner, .app)
        XCTAssertTrue(result.foundAXMenu)
        XCTAssertEqual(result.itemCount, 9)
        XCTAssertEqual(result.cancelError, .success)
        XCTAssertFalse(result.late)
        XCTAssertNotNil(result.visibleFor)
    }

    func testAppMenuFoundThroughTheFocusedElementIsCancelled() {
        let f = make()
        f.environment.finds = { $0 == .focusedElement }
        f.environment.windows = [appMenu()]
        run(f, for: 0.05)
        XCTAssertEqual(f.environment.cancels, 1)
        XCTAssertEqual(f.reports().first?.foundBy, .focusedElement)
    }

    func testAppMenuFoundOnlyByTheAppsHitTestIsCancelled() {
        let f = make()
        f.environment.finds = { probe in
            if case .application = probe { return true }
            return false
        }
        f.environment.windows = [appMenu()]
        run(f, for: 0.05)
        XCTAssertEqual(f.environment.cancels, 1)
        XCTAssertTrue(f.leftOpen().isEmpty)
    }

    func testNoAXMenuEndsTheWatchAsLeftOpenWithin600ms() throws {
        let f = make()
        f.environment.windows = [appMenu()]
        run(f, for: 0.55)
        XCTAssertTrue(f.leftOpen().isEmpty)
        run(f, for: 0.1)
        XCTAssertEqual(f.leftOpen().count, 1)
        let result = try XCTUnwrap(f.leftOpen().first)
        XCTAssertTrue(result.leftOpen)
        XCTAssertFalse(result.foundAXMenu)
        XCTAssertTrue(result.error?.hasPrefix("menu left open") ?? false)
        XCTAssertGreaterThan(result.probesTried, SmokeMenuWatch.probes(for: frame).count)
        XCTAssertTrue(f.reports().isEmpty)
        XCTAssertTrue(f.watch.isFinished)
        // Nothing more is asked once it gave up.
        let asked = f.environment.asked.count
        run(f, for: 0.2)
        XCTAssertEqual(f.environment.asked.count, asked)
    }

    func testCancelledMenuThatStaysOpenIsLeftOpenAt900ms() {
        let f = make()
        f.environment.finds = { _ in true }
        f.environment.cancelCloses = false
        f.environment.windows = [appMenu()]
        run(f, for: 0.85)
        XCTAssertTrue(f.leftOpen().isEmpty)
        run(f, for: 0.1)
        XCTAssertEqual(f.leftOpen().count, 1)
        XCTAssertEqual(f.leftOpen().first?.foundAXMenu, true)
        XCTAssertEqual(f.environment.cancels, 1)
    }

    func testFailedCancelIsTriedAgain() {
        let f = make()
        f.environment.finds = { _ in true }
        f.environment.cancelResult = .cannotComplete
        f.environment.windows = [appMenu()]
        run(f, for: 0.05)
        XCTAssertGreaterThan(f.environment.cancels, 1)
        f.environment.cancelResult = .success
        run(f, for: 0.05)
        XCTAssertTrue(f.leftOpen().isEmpty)
        XCTAssertEqual(f.reports().first?.cancelError, .success)
    }

    // MARK: - Late menus

    func testMenuOpeningAfterTheNoMenuReportIsStillClosed() {
        let f = make()
        f.environment.finds = { _ in true }
        run(f, for: SmokeMenuWatch.appearTimeout + 0.1)
        XCTAssertEqual(f.reports().count, 1)
        XCTAssertNil(f.reports().first?.owner)
        // The app answers late (AXShowMenu timed out, the app still shows its menu).
        run(f, for: 2)
        f.environment.windows = [appMenu()]
        run(f, for: 0.1)
        XCTAssertEqual(f.environment.cancels, 1)
        XCTAssertEqual(f.reports().count, 2)
        XCTAssertEqual(f.reports().last?.late, true)
        XCTAssertEqual(f.reports().last?.owner, .app)
        XCTAssertTrue(f.leftOpen().isEmpty)
    }

    func testSecondMenuAfterTheFirstClosedIsClosedToo() {
        let f = make()
        f.environment.finds = { _ in true }
        f.environment.windows = [appMenu(id: 900)]
        run(f, for: 0.1)
        XCTAssertEqual(f.reports().count, 1)
        f.environment.windows = [appMenu(id: 901)]
        run(f, for: 0.1)
        XCTAssertEqual(f.environment.cancels, 2)
        XCTAssertEqual(f.reports().count, 2)
        XCTAssertEqual(f.reports().last?.late, true)
    }

    func testLateMenuWithoutAXMenuIsLeftOpen() {
        let f = make()
        run(f, for: SmokeMenuWatch.appearTimeout + 0.1)
        f.environment.windows = [appMenu()]
        run(f, for: 0.7)
        XCTAssertEqual(f.leftOpen().count, 1)
        XCTAssertEqual(f.leftOpen().first?.late, true)
    }

    func testMenusThatWereOpenBeforeTheRequestAreIgnored() {
        let environment = FakeEnvironment()
        environment.windows = [appMenu(id: 800)]
        let f = make(environment)
        run(f, for: SmokeMenuWatch.appearTimeout + 1)
        XCTAssertTrue(f.environment.asked.isEmpty)
        XCTAssertTrue(f.leftOpen().isEmpty)
        XCTAssertEqual(f.reports().count, 1)
        XCTAssertNil(f.reports().first?.owner)
    }

    // MARK: - Plamonic's own menu, stop, probes

    func testOwnMenuIsCancelledAndCounted() {
        let f = make()
        f.environment.windows = [SmokeMenuWindow(id: 950, pid: getpid(), bounds: frame)]
        run(f, for: 0.02)
        XCTAssertEqual(f.ownCancels(), 1)
        XCTAssertTrue(f.environment.asked.isEmpty)
        f.environment.windows = []
        run(f, for: 0.02)
        XCTAssertEqual(f.reports().first?.owner, .plamonic)
        XCTAssertEqual(f.reports().first?.itemCount, 3)
    }

    func testStopWhileClosingTriesOnceMoreAndSaysSo() {
        let f = make()
        f.environment.windows = [appMenu()]
        run(f, for: 0.05)
        f.environment.finds = { _ in true }
        XCTAssertTrue(f.watch.stop())
        XCTAssertEqual(f.environment.cancels, 1)
        XCTAssertTrue(f.watch.isFinished)
        XCTAssertFalse(f.watch.stop())
    }

    func testStopWhileLingeringFindsNothingOpen() {
        let f = make()
        run(f, for: SmokeMenuWatch.appearTimeout + 0.1)
        XCTAssertFalse(f.watch.stop())
        f.environment.windows = [appMenu()]
        run(f, for: 1)
        XCTAssertTrue(f.environment.asked.isEmpty)
    }

    // MARK: - The end of the run

    func testSettleClosesAMenuAskedForJustBeforeTheEnd() {
        let f = make()
        f.environment.finds = { _ in true }
        let start = f.environment.now
        var sleeps = 0
        let open = f.watch.settle(timeout: SmokeMenuWatch.appearTimeout + SmokeMenuWatch.closeDeadline) { seconds in
            sleeps += 1
            f.environment.now += seconds
            // The app shows its menu 0.4 s after the request.
            if f.environment.now - start > 0.4, f.environment.cancels == 0 { f.environment.windows = [self.appMenu()] }
        }
        XCTAssertFalse(open)
        XCTAssertEqual(f.environment.cancels, 1)
        XCTAssertEqual(f.reports().count, 1)
        XCTAssertEqual(f.reports().first?.owner, .app)
        XCTAssertTrue(f.watch.isFinished)
        XCTAssertLessThan(Double(sleeps) * 0.01, 0.6, "settle ends once the menu closed")
    }

    func testSettleEndsAtOnceWhenNothingIsPending() {
        let f = make()
        run(f, for: SmokeMenuWatch.appearTimeout + 0.1)
        var sleeps = 0
        XCTAssertFalse(f.watch.settle(timeout: 2) { _ in sleeps += 1 })
        XCTAssertEqual(sleeps, 0)
        XCTAssertTrue(f.watch.isFinished)
    }

    func testSettleEndsTheRunWhenTheAppMenuCannotBeClosed() {
        let f = make()
        f.environment.windows = [appMenu()]
        f.watch.settle(timeout: SmokeMenuWatch.appearTimeout + SmokeMenuWatch.closeDeadline) { seconds in
            f.environment.now += seconds
        }
        XCTAssertEqual(f.leftOpen().count, 1)
        XCTAssertTrue(f.watch.isFinished)
    }

    func testProbesCoverTheWholeMenuWindow() {
        let probes = SmokeMenuWatch.probes(for: frame)
        let first = CGPoint(x: frame.midX, y: frame.minY + 14)
        XCTAssertEqual(probes.first, .systemWide(first))
        XCTAssertTrue(probes.contains(.application(first)))
        XCTAssertTrue(probes.contains(.focusedElement))
        XCTAssertTrue(probes.contains(.children))
        XCTAssertEqual(Set(probes).count, probes.count)
        let points = probes.compactMap { probe -> CGPoint? in
            if case .systemWide(let point) = probe { return point }
            return nil
        }
        XCTAssertTrue(points.allSatisfy { frame.contains($0) })
        XCTAssertTrue(points.contains { $0.y > frame.maxY - 10 }, "the bottom of the menu is probed")
        XCTAssertTrue(points.contains { $0.x < frame.minX + 20 } && points.contains { $0.x > frame.maxX - 20 })
        XCTAssertLessThanOrEqual(probes.count, 60)
        // A tiny window still gets a probe inside it.
        let tiny = CGRect(x: 10, y: 10, width: 4, height: 4)
        let tinyPoints = SmokeMenuWatch.probes(for: tiny).compactMap { probe -> CGPoint? in
            if case .systemWide(let point) = probe { return point }
            return nil
        }
        XCTAssertFalse(tinyPoints.isEmpty)
        XCTAssertTrue(tinyPoints.allSatisfy { tiny.contains($0) })
    }

    func testOneTickAsksEachProbeAtMostOnce() {
        let f = make()
        f.environment.windows = [appMenu()]
        f.environment.now += 0.01
        f.watch.tick()
        let count = SmokeMenuWatch.probes(for: frame).count
        // The first pass ran when the window was seen; the clock does not move inside a tick here.
        XCTAssertEqual(f.environment.asked.count, count)
        XCTAssertEqual(Set(f.environment.asked).count, count)
    }

    func testFrontChangeIsReported() {
        let f = make()
        f.environment.finds = { _ in true }
        f.environment.frontmostPID = target
        f.environment.windows = [appMenu()]
        run(f, for: 0.05)
        XCTAssertEqual(f.reports().first?.frontChanged, true)
        XCTAssertEqual(f.reports().first?.plamonicActivated, false)
    }
}
