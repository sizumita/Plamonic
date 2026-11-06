import AppKit
import XCTest

@testable import Plamonic

/// Records calls; answers every rect with fixed colors (once the test lets it, while `holdsAnswers`).
private final class FakeColorSampler: ScreenColorSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String: CGRect]] = []
    private var _callTimes: [TimeInterval] = []
    private var _holdsAnswers = false
    private var running = 0
    private var _maxConcurrent = 0
    var authorized = true
    var colors = SampledColors(
        background: RGBAColor(red: 0.15, green: 0.15, blue: 0.14), text: RGBAColor(red: 0.9, green: 0.9, blue: 0.88))
    /// Ids the sampler cannot measure.
    var unmeasurable: Set<String> = []
    /// The first `failedCalls` calls measure nothing (a failed capture).
    var failedCalls = 0
    /// Each call answers a different background (call n: red = n / 10), to tell answers apart.
    var differsPerCall = false
    /// Answers for particular ids (instead of `colors`).
    var byID: [String: SampledColors] = [:]

    private var _authorizedChecks = 0
    var authorizedChecks: Int { lock.withLock { _authorizedChecks } }

    var isAuthorized: Bool {
        lock.withLock { _authorizedChecks += 1 }
        return authorized
    }
    var calls: [[String: CGRect]] { lock.withLock { _calls } }
    /// When each call started (system uptime, the clock of the scheduler and of `Task.sleep`).
    var callTimes: [TimeInterval] { lock.withLock { _callTimes } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }
    /// While true, calls do not answer: a request stays in flight exactly as long as the test needs.
    var holdsAnswers: Bool {
        get { lock.withLock { _holdsAnswers } }
        set { lock.withLock { _holdsAnswers = newValue } }
    }

    static func colors(ofCall n: Int) -> SampledColors {
        SampledColors(background: RGBAColor(red: Double(n) / 10, green: 0.1, blue: 0.1), text: nil)
    }

    func sampleColors(windowID: UInt32, rects: [String: CGRect]) async -> [String: SampledColors] {
        let call: Int = lock.withLock {
            _calls.append(rects)
            _callTimes.append(ProcessInfo.processInfo.systemUptime)
            running += 1
            _maxConcurrent = max(_maxConcurrent, running)
            return _calls.count
        }
        while holdsAnswers { try? await Task.sleep(nanoseconds: 2_000_000) }
        lock.withLock { running -= 1 }
        if call <= failedCalls { return [:] }
        var result: [String: SampledColors] = [:]
        let byID = lock.withLock { self.byID }
        for id in rects.keys where !unmeasurable.contains(id) {
            result[id] = byID[id] ?? (differsPerCall ? Self.colors(ofCall: call) : colors)
        }
        return result
    }
}

final class OverlayColorTests: XCTestCase {
    private let dark = RGBAColor(red: 0.12, green: 0.12, blue: 0.12)
    private let light = RGBAColor(red: 0.98, green: 0.98, blue: 0.97)

    private func components(_ color: NSColor) -> [CGFloat] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { ($0 * 1000).rounded() / 1000 }
    }

    // MARK: - Resolution

    func testMeasuredColorsComeFirst() {
        let sampled = SampledColors(background: RGBAColor(red: 0.2, green: 0.1, blue: 0.3), text: light)
        var appearance = OverlayAppearance()
        appearance.backgroundOpacity = 0.9
        let resolved = OverlayPalette.resolve(
            OverlayItemColors(sampled: sampled, originalText: RGBAColor(red: 1, green: 1, blue: 0)),
            appearance: appearance, systemIsDark: false)
        XCTAssertTrue(resolved.isDark)
        XCTAssertEqual(components(resolved.background), [0.2, 0.1, 0.3, 0.9])
        XCTAssertEqual(components(resolved.solidBackground), [0.2, 0.1, 0.3, 1])
        XCTAssertEqual(components(resolved.text), [0.98, 0.98, 0.97, 1])
    }

    func testTextFallsBackToTheOriginalColorThenThePalette() {
        // The measured text color barely differs from the background: the app's own color is used.
        let sampled = SampledColors(background: dark, text: RGBAColor(red: 0.16, green: 0.16, blue: 0.16))
        let original = RGBAColor(red: 0.85, green: 0.8, blue: 0.6)
        let appearance = OverlayAppearance()
        let withOriginal = OverlayPalette.resolve(
            OverlayItemColors(sampled: sampled, originalText: original), appearance: appearance, systemIsDark: false)
        XCTAssertEqual(components(withOriginal.text), [0.85, 0.8, 0.6, 1])
        // Neither contrasts: the palette's text for a dark background.
        let neither = OverlayPalette.resolve(
            OverlayItemColors(sampled: sampled, originalText: dark), appearance: appearance, systemIsDark: false)
        XCTAssertGreaterThanOrEqual(OverlayPalette.contrastRatio(neither.text, neither.solidBackground), 7)
        XCTAssertTrue(neither.isDark)
    }

    func testWithoutMeasurementsTheOriginalTextColorPicksDarkOrLight() {
        let appearance = OverlayAppearance()  // theme: system
        let lightText = OverlayPalette.resolve(
            OverlayItemColors(originalText: RGBAColor(red: 0.9, green: 0.9, blue: 0.9)), appearance: appearance,
            systemIsDark: false)
        XCTAssertTrue(lightText.isDark, "light text means a dark app, whatever the system theme")
        XCTAssertEqual(components(lightText.text), [0.9, 0.9, 0.9, 1])
        let darkText = OverlayPalette.resolve(
            OverlayItemColors(originalText: RGBAColor(red: 0.1, green: 0.1, blue: 0.1)), appearance: appearance,
            systemIsDark: true)
        XCTAssertFalse(darkText.isDark)
        // Nothing known: the system appearance.
        XCTAssertTrue(OverlayPalette.resolve(OverlayItemColors(), appearance: appearance, systemIsDark: true).isDark)
        XCTAssertFalse(OverlayPalette.resolve(OverlayItemColors(), appearance: appearance, systemIsDark: false).isDark)
    }

    func testAnExplicitThemeWinsOverTheTextColor() {
        var appearance = OverlayAppearance()
        appearance.theme = .light
        let resolved = OverlayPalette.resolve(
            OverlayItemColors(originalText: RGBAColor(red: 0.95, green: 0.95, blue: 0.95)), appearance: appearance,
            systemIsDark: true)
        XCTAssertFalse(resolved.isDark)
        // White text on the light palette does not contrast: the palette's text is used.
        XCTAssertGreaterThanOrEqual(OverlayPalette.contrastRatio(resolved.text, resolved.solidBackground), 7)
    }

    func testStreamingTextIsDimmerAndTranslucentColorsAreFlattened() {
        let resolved = OverlayPalette.resolve(
            OverlayItemColors(
                sampled: SampledColors(background: light, text: nil),
                originalText: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5)),
            appearance: OverlayAppearance(), systemIsDark: false)
        XCTAssertEqual(resolved.streamingText.alphaComponent, OverlayPalette.streamingTextAlpha, accuracy: 0.001)
        XCTAssertEqual(resolved.text.alphaComponent, 1)
        // Half-transparent black on near-white: mid gray.
        XCTAssertEqual(components(resolved.text)[0], 0.49, accuracy: 0.01)
    }

    func testPaletteBackgroundsKeepTheUserOpacity() {
        var appearance = OverlayAppearance()
        appearance.backgroundOpacity = 0.8
        let resolved = OverlayPalette.resolve(OverlayItemColors(), appearance: appearance, systemIsDark: false)
        XCTAssertEqual(resolved.background.alphaComponent, 0.8, accuracy: 0.001)
        XCTAssertEqual(resolved.solidBackground.alphaComponent, 1)
    }

    // MARK: - Sampling schedule

    private func target(_ y: CGFloat, _ text: String = "original") -> OverlayColorSampleScheduler.Target {
        OverlayColorSampleScheduler.Target(axRect: CGRect(x: 10, y: y, width: 200, height: 20), original: text)
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// System uptime: the clock of the scheduler, of `Task.sleep` and of `FakeColorSampler.callTimes`.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Polls `condition` every 10 ms until it holds (true) or `timeout` passes (false).
    @MainActor
    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = now + timeout
        while !condition() {
            guard now < deadline else { return false }
            await sleep(0.01)
        }
        return true
    }

    /// Waits until `condition` holds, and fails the test when it does not within `timeout`. The scheduler's
    /// timers and the sampler's answers are tasks that can run well after their delay on a loaded machine (or a
    /// CI VM), so what they bring about is waited for rather than expected after a fixed sleep. When it matters
    /// when something happened, the test measures it (`callTimes`) instead.
    @MainActor
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async -> Bool {
        if await poll(timeout: timeout, condition) { return true }
        XCTFail("still not so after \(timeout) s", file: file, line: line)
        return false
    }

    @MainActor
    func testRequestsAreDebouncedAndBatched() async {
        let sampler = FakeColorSampler()
        let scheduler = OverlayColorSampleScheduler(debounce: 0.05)
        var changes = 0
        scheduler.onColorsChanged = { changes += 1 }
        let targets = ["a": target(0), "b": target(30)]
        for _ in 0..<20 {
            scheduler.update(targets: targets, windowID: 7, sampler: sampler)
        }
        XCTAssertTrue(sampler.calls.isEmpty, "nothing is sampled before the debounce")
        guard await waitUntil({ changes == 1 }) else { return }
        // Nothing else is pending: no request follows.
        await sleep(0.1)
        XCTAssertEqual(sampler.calls.count, 1)
        XCTAssertEqual(Set(sampler.calls[0].keys), ["a", "b"])
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(scheduler.colors(for: "a"), sampler.colors)
    }

    @MainActor
    func testUnchangedItemsAreNotSampledAgain() async {
        let sampler = FakeColorSampler()
        let scheduler = OverlayColorSampleScheduler(debounce: 0.05, refreshInterval: 0.9)
        var answers = 0
        scheduler.onColorsChanged = { answers += 1 }
        scheduler.update(targets: ["a": target(0), "b": target(30)], windowID: 7, sampler: sampler)
        await waitUntil { answers == 1 }
        XCTAssertEqual(sampler.calls.count, 1)
        // Streaming updates with the same items: no new request.
        for _ in 0..<10 {
            scheduler.update(targets: ["a": target(0), "b": target(30)], windowID: 7, sampler: sampler)
            await sleep(0.01)
        }
        await sleep(0.15)
        XCTAssertEqual(sampler.calls.count, 1)
        // b moved to a place not measured yet, c is new: only those two are measured.
        let moved = now
        scheduler.update(targets: ["a": target(0), "b": target(50), "c": target(90)], windowID: 7, sampler: sampler)
        guard await waitUntil({ answers == 2 }) else { return }
        XCTAssertEqual(sampler.calls.count, 2)
        XCTAssertEqual(Set(sampler.calls[1].keys), ["b", "c"])
        XCTAssertEqual(sampler.calls[1]["b"], target(50).axRect)
        // A changed original text at the same place keeps its colors and is measured again later, not at once:
        // `refreshInterval` after the last request (made at least `debounce` after `moved`).
        scheduler.update(
            targets: ["a": target(0, "edited"), "b": target(50), "c": target(90)], windowID: 7, sampler: sampler)
        XCTAssertEqual(scheduler.colors(for: "a"), sampler.colors)
        await sleep(0.3)
        XCTAssertEqual(scheduler.colors(for: "a"), sampler.colors)
        guard await waitUntil({ sampler.calls.count >= 3 }) else { return }
        XCTAssertGreaterThanOrEqual(sampler.callTimes[2] - moved, 0.9, "measured again later, not at once")
        XCTAssertEqual(sampler.calls.count, 3)
        XCTAssertEqual(Set(sampler.calls[2].keys), ["a"])
        await sleep(1.2)
        XCTAssertEqual(sampler.calls.count, 3)
    }

    @MainActor
    func testStreamingAndScrollingReuseTheColorsOfTheirPlace() async {
        let sampler = FakeColorSampler()
        let scheduler = OverlayColorSampleScheduler(debounce: 0.03, refreshInterval: 0.8)
        // The first request comes after `start`, so nothing can be refreshed before `start` + `refreshInterval`.
        let start = now
        scheduler.update(targets: ["p0": target(0, "Hel"), "b": target(30)], windowID: 7, sampler: sampler)
        await waitUntil { scheduler.colors(for: "p0") != nil }
        XCTAssertEqual(sampler.calls.count, 1)
        // A streaming paragraph gets a new id with every scan; the window scrolls a little meanwhile.
        var step = 0
        var checked = 0
        while now - start < 0.5 {
            step += 1
            let shift = CGFloat(step % 4)
            let targets = [
                "p\(step)": target(shift, "Hel" + String(repeating: "lo", count: step)), "b": target(30 + shift),
            ]
            scheduler.update(targets: targets, windowID: 7, sampler: sampler)
            // The new id has the colors of its place at once.
            XCTAssertEqual(scheduler.colors(for: "p\(step)"), sampler.colors)
            await sleep(0.03)
            // Counted before the refresh can be due (a wake-up late past it proves nothing).
            let calls = sampler.calls.count
            if now - start < 0.8 {
                XCTAssertEqual(calls, 1, "no capture while the text streams in measured places")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "nothing was checked before the refresh was due")
        // Measured again once the refresh interval has passed, for what is there now; then not again.
        guard await waitUntil({ sampler.calls.count >= 2 }) else { return }
        XCTAssertGreaterThanOrEqual(sampler.callTimes[1] - start, 0.8)
        XCTAssertEqual(sampler.calls.count, 2)
        XCTAssertEqual(Set(sampler.calls[1].keys), ["p\(step)", "b"])
        await sleep(1.0)
        XCTAssertEqual(sampler.calls.count, 2)
    }

    @MainActor
    func testItemsThatMoveDuringTheCaptureKeepItsAnswer() async {
        let sampler = FakeColorSampler()
        sampler.differsPerCall = true
        sampler.holdsAnswers = true
        let scheduler = OverlayColorSampleScheduler(debounce: 0.03, refreshInterval: 1.0)
        // The request comes after `start`, so its refresh is not due before `start` + `refreshInterval`.
        let start = now
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        await waitUntil { sampler.calls.count == 1 }
        // Moves a little while it is measured (auto-scroll): the answer still describes where it is. The
        // capture ends well after the debounce for the moved item ran out (one still running at the answer would
        // capture again at once).
        scheduler.update(targets: ["a": target(4)], windowID: 7, sampler: sampler)
        await sleep(0.5)
        sampler.holdsAnswers = false
        await waitUntil { scheduler.colors(for: "a") != nil }
        XCTAssertEqual(scheduler.colors(for: "a"), FakeColorSampler.colors(ofCall: 1))
        // Not captured again at once: refreshed later (after `refreshInterval`, not a failure's retry delay
        // of 2 s), at its current place.
        guard await waitUntil({ sampler.calls.count >= 2 }) else { return }
        XCTAssertGreaterThanOrEqual(sampler.callTimes[1] - start, 1.0, "not captured again at once")
        XCTAssertLessThan(sampler.callTimes[1] - start, 1.8)
        XCTAssertEqual(sampler.calls.count, 2)
        XCTAssertEqual(sampler.calls[1]["a"], target(4).axRect)
    }

    @MainActor
    func testAnswersNothingCanUseBackOff() async {
        let sampler = FakeColorSampler()
        sampler.holdsAnswers = true
        let scheduler = OverlayColorSampleScheduler(debounce: 0.03, retryDelay: 0.6)
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        await waitUntil { sampler.calls.count == 1 }
        // Everything is replaced while the capture runs: its answer describes nothing on screen. The capture
        // ends well after the debounce for z ran out (one still running at the answer would capture at once).
        scheduler.update(targets: ["z": target(300)], windowID: 7, sampler: sampler)
        await sleep(0.5)
        let answered = now
        sampler.holdsAnswers = false
        // Waits (`retryDelay` from the answer) before capturing again.
        guard await waitUntil({ sampler.calls.count >= 2 }) else { return }
        XCTAssertGreaterThanOrEqual(sampler.callTimes[1] - answered, 0.595, "waits before capturing again")
        XCTAssertLessThan(sampler.callTimes[1] - answered, 1.1)
        XCTAssertEqual(sampler.calls.count, 2)
        XCTAssertEqual(Set(sampler.calls[1].keys), ["z"])
    }

    @MainActor
    func testBackOffHoldsATimerThatWasRunningAtTheAnswer() async {
        let sampler = FakeColorSampler()
        sampler.holdsAnswers = true
        let scheduler = OverlayColorSampleScheduler(debounce: 0.3, retryDelay: 0.8)
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        await waitUntil { sampler.calls.count == 1 }
        // Everything is replaced while the capture runs, and its answer comes while the debounce for z (started
        // during the capture) still runs: that timer must not capture before the retry delay.
        scheduler.update(targets: ["z": target(300)], windowID: 7, sampler: sampler)
        let answered = now
        sampler.holdsAnswers = false
        guard await waitUntil({ sampler.calls.count >= 2 }) else { return }
        XCTAssertGreaterThanOrEqual(sampler.callTimes[1] - answered, 0.75, "waits for the retry delay")
        XCTAssertEqual(Set(sampler.calls[1].keys), ["z"])
    }

    @MainActor
    func testSuspendedWhileHidden() async {
        let sampler = FakeColorSampler()
        let scheduler = OverlayColorSampleScheduler(debounce: 0.03)
        scheduler.isSuspended = true
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        await sleep(0.2)
        XCTAssertTrue(sampler.calls.isEmpty)
        scheduler.isSuspended = false
        await waitUntil { sampler.calls.count == 1 }
        XCTAssertEqual(sampler.calls.count, 1)
    }

    @MainActor
    func testUnmeasurableItemsAreNotRetriedUntilTheyChange() async {
        let sampler = FakeColorSampler()
        sampler.unmeasurable = ["a"]
        let scheduler = OverlayColorSampleScheduler(debounce: 0.05, retryDelay: 0.1)
        for _ in 0..<5 {
            scheduler.update(targets: ["a": target(0), "b": target(30)], windowID: 7, sampler: sampler)
            await sleep(0.1)
        }
        // b was measured, a could not be: neither is asked for again.
        XCTAssertEqual(sampler.calls.count, 1)
        XCTAssertEqual(scheduler.colors(for: "b"), sampler.colors)
    }

    @MainActor
    func testFailedCaptureIsRetriedWithBackoff() async {
        let sampler = FakeColorSampler()
        sampler.failedCalls = 3
        let scheduler = OverlayColorSampleScheduler(debounce: 0.03, retryDelay: 0.1, maximumRetryDelay: 0.4)
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        // The first three captures fail; the waits before the next request double: 0.1, 0.2, 0.4 s (each from
        // the failed answer, which comes after its call started). The fourth measures it.
        guard await waitUntil({ sampler.calls.count >= 4 }) else { return }
        let times = sampler.callTimes
        for (n, wait) in [0.1, 0.2, 0.4].enumerated() {
            let gap = times[n + 1] - times[n]
            XCTAssertGreaterThanOrEqual(gap, wait - 0.005, "wait \(n + 1)")
            XCTAssertLessThan(gap, wait + 0.25, "wait \(n + 1)")
        }
        await waitUntil { scheduler.colors(for: "a") == sampler.colors }
        XCTAssertEqual(sampler.calls.count, 4)
        // Measured: no more retries.
        await sleep(0.5)
        XCTAssertEqual(sampler.calls.count, 4)
    }

    @MainActor
    func testOneRequestInFlightAndItemsInNewPlacesAskedAgain() async {
        let sampler = FakeColorSampler()
        sampler.holdsAnswers = true
        let scheduler = OverlayColorSampleScheduler(debounce: 0.03, retryDelay: 0.1)
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        await waitUntil { sampler.calls.count == 1 }
        // a moves far while its request is in flight; b appears. The request ends well after their debounce ran
        // out (one still running at the answer would ask at once).
        scheduler.update(targets: ["a": target(40), "b": target(80)], windowID: 7, sampler: sampler)
        await sleep(0.5)
        XCTAssertEqual(sampler.calls.count, 1, "waits for the request in flight")
        let answered = now
        sampler.holdsAnswers = false
        // The answer for a's old place does not describe its new one: a is asked for again there (after the
        // retry delay, since nothing on screen could use that answer).
        guard await waitUntil({ sampler.calls.count >= 2 }) else { return }
        XCTAssertGreaterThanOrEqual(sampler.callTimes[1] - answered, 0.095, "after the retry delay")
        XCTAssertEqual(sampler.calls.count, 2)
        XCTAssertEqual(sampler.calls[1]["a"], target(40).axRect)
        XCTAssertEqual(Set(sampler.calls[1].keys), ["a", "b"])
        XCTAssertEqual(sampler.maxConcurrent, 1)
        XCTAssertNotNil(scheduler.colors(for: "a"))
    }

    @MainActor
    func testKeepsMovingItemsWaitingButNotForever() async {
        let sampler = FakeColorSampler()
        // A short retry delay: an answer that arrives just after a move describes nothing on screen.
        let debounce = 0.08
        let maximumWait = 0.3
        let scheduler = OverlayColorSampleScheduler(
            debounce: debounce, maximumWait: maximumWait, retryDelay: 0.05, maximumRetryDelay: 0.1)
        // Moving fast: every 20 ms to a place not measured yet, for 0.8 s.
        let start = now
        var lastUpdate = start
        // Pauses of at least the debounce between two updates (a loaded machine): each may let a capture through.
        var pauses = 0
        var y: CGFloat = 0
        while now - start < 0.8 {
            y += 25
            let before = now
            scheduler.update(targets: ["a": target(y)], windowID: 7, sampler: sampler)
            if now - lastUpdate >= debounce { pauses += 1 }
            lastUpdate = before
            await sleep(0.02)
        }
        let duringScroll = sampler.calls.count
        let elapsed = now - start
        if elapsed - (lastUpdate - start) >= debounce { pauses += 1 }
        XCTAssertGreaterThanOrEqual(duringScroll, 1, "samples at least every maximumWait")
        // Otherwise a capture ends a wait of more than maximumWait - debounce (one after another), plus one.
        let allowed = Int(elapsed / (maximumWait - debounce)) + 1 + pauses
        XCTAssertLessThanOrEqual(duringScroll, allowed, "but not on every update (\(pauses) pauses)")
        // The final position is measured once the movement stops.
        await waitUntil { sampler.calls.last?["a"] == target(y).axRect }
    }

    @MainActor
    func testUnmeasuredItemsBorrowTheNearestMeasurement() async {
        let sampler = FakeColorSampler()
        let scheduler = OverlayColorSampleScheduler(debounce: 0.05)
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        await waitUntil { scheduler.colors(for: "a") != nil }
        scheduler.update(targets: ["a": target(0), "b": target(30)], windowID: 7, sampler: sampler)
        // Before b's own measurement arrives it shows a's colors, not the theme's.
        XCTAssertEqual(scheduler.colors(for: "b"), sampler.colors)
        XCTAssertNil(scheduler.colors(for: "unknown"))
    }

    /// The text around an item's links is measured on its own: it never stands in for an item's colors, and
    /// never takes over a paragraph's measurement (whose text color may be a link's).
    @MainActor
    func testTextAroundLinksIsMeasuredApart() async {
        let sampler = FakeColorSampler()
        let gray = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)
        let textID = OverlayController.nonLinkSampleID("a")
        sampler.byID[textID] = SampledColors(background: sampler.colors.background, text: gray)
        let scheduler = OverlayColorSampleScheduler(debounce: 0.05)
        var aroundLinks = target(28)
        aroundLinks.axRect = CGRect(x: 10, y: 28, width: 60, height: 20)
        aroundLinks.isNonLinkText = true
        scheduler.update(targets: ["a": target(0), textID: aroundLinks], windowID: 7, sampler: sampler)
        XCTAssertNil(scheduler.colors(for: textID))
        await waitUntil { scheduler.colors(for: "a") != nil }
        XCTAssertEqual(Set(sampler.calls.first?.keys.map { $0 } ?? []), ["a", textID])
        XCTAssertEqual(scheduler.colors(for: textID)?.text, gray)
        XCTAssertEqual(scheduler.colors(for: "a"), sampler.colors)
        // A new item next to it borrows the paragraph's measurement, not the one around the links.
        scheduler.update(targets: ["a": target(0), textID: aroundLinks, "b": target(30)], windowID: 7, sampler: sampler)
        XCTAssertEqual(scheduler.colors(for: "b"), sampler.colors)
        // Moved inside the paragraph's measured place: it keeps its own colors until measured there.
        var moved = aroundLinks
        moved.axRect = CGRect(x: 10, y: 2, width: 60, height: 16)
        scheduler.update(targets: ["a": target(0), textID: moved], windowID: 7, sampler: sampler)
        XCTAssertEqual(scheduler.colors(for: textID)?.text, gray)
    }

    @MainActor
    func testStopForgetsAndCancels() async {
        let sampler = FakeColorSampler()
        let scheduler = OverlayColorSampleScheduler(debounce: 0.05)
        scheduler.update(targets: ["a": target(0)], windowID: 7, sampler: sampler)
        await waitUntil { scheduler.colors(for: "a") != nil }
        XCTAssertNotNil(scheduler.colors(for: "a"))
        scheduler.update(targets: ["a": target(10)], windowID: 7, sampler: nil)
        await sleep(0.2)
        XCTAssertNil(scheduler.colors(for: "a"))
        XCTAssertEqual(sampler.calls.count, 1)
    }

    // MARK: - What the controller asks for

    func testSampleTargetsAreTheVisibleOriginals() {
        let window = CGRect(x: 100, y: 100, width: 600, height: 400)
        let items = [
            OverlayItem(
                id: "lines", axFrame: CGRect(x: 110, y: 120, width: 500, height: 60), original: "a", translation: "訳",
                state: .final,
                lineFrames: [CGRect(x: 120, y: 125, width: 300, height: 17), CGRect(x: 110, y: 145, width: 200, height: 17)]),
            OverlayItem(
                id: "pending", axFrame: CGRect(x: 110, y: 200, width: 300, height: 20), original: "b", translation: "",
                state: .pending),
            OverlayItem(
                id: "failed", axFrame: CGRect(x: 110, y: 240, width: 300, height: 20), original: "c", translation: "",
                state: .failed),
            OverlayItem(
                id: "partly", axFrame: CGRect(x: 110, y: 470, width: 300, height: 60), original: "d", translation: "訳",
                state: .draft),
            OverlayItem(
                id: "hidden", axFrame: CGRect(x: 110, y: 600, width: 300, height: 20), original: "e", translation: "訳",
                state: .final),
        ]
        let targets = OverlayController.colorSampleTargets(
            items: items, axClipRect: CGRect(x: 100, y: 110, width: 600, height: 390), axWindowFrame: window)
        XCTAssertEqual(Set(targets.keys), ["lines", "pending", "partly"])
        // The original's lines, not the element frame.
        XCTAssertEqual(targets["lines"]?.axRect, CGRect(x: 110, y: 125, width: 310, height: 37))
        XCTAssertEqual(targets["partly"]?.axRect, CGRect(x: 110, y: 470, width: 300, height: 30))
        XCTAssertEqual(targets["pending"]?.original, "b")
        // Fractions of a point (scan-to-scan jitter) do not change what is measured.
        var jittered = items
        jittered[0].lineFrames = jittered[0].lineFrames.map { $0.offsetBy(dx: 0.2, dy: -0.3) }
        let again = OverlayController.colorSampleTargets(
            items: jittered, axClipRect: CGRect(x: 100, y: 110, width: 600, height: 390), axWindowFrame: window)
        XCTAssertEqual(again["lines"], targets["lines"])
    }

    // MARK: - Controller wiring

    /// A plain window of this process, placed outside every display.
    @MainActor
    private func offscreenWindow() async throws -> (NSWindow, CGWindowID) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let id = CGWindowID(window.windowNumber)
        // The window server lists it a moment later (much later on a loaded machine).
        guard await poll(timeout: 2, { OverlayWindowServer.info(for: id)?.isOnScreen == true }) else {
            window.orderOut(nil)
            throw XCTSkip("no window server")
        }
        return (window, id)
    }

    @MainActor
    func testControllerSamplesOnceAndRedrawsWithMeasuredColors() async throws {
        let (window, id) = try await offscreenWindow()
        defer { window.orderOut(nil) }
        let controller = OverlayController()
        defer { controller.removeAll() }
        let sampler = FakeColorSampler()
        controller.colorSampler = sampler
        let key = WindowKey(pid: getpid(), windowID: id)
        let axFrame = CoordinateSpace.axRect(fromCocoa: window.frame)
        let style = OverlayStyle(displayStyle: .replace, appearance: OverlayAppearance())
        var item = OverlayItem(
            id: "a", axFrame: CGRect(x: axFrame.minX + 10, y: axFrame.minY + 10, width: 200, height: 20),
            original: "Hello", translation: "", state: .streaming,
            style: TextStyleHint(fontSize: 14, textColor: RGBAColor(red: 0.1, green: 0.1, blue: 0.1)))
        // Streaming: twenty updates of the same item.
        for i in 0..<20 {
            item.translation = String(repeating: "こ", count: i + 1)
            controller.update(
                window: key, axWindowFrame: axFrame, axClipRect: nil, cgWindowID: id, items: [item], style: style,
                targetIsFrontmost: false)
            await sleep(0.01)
        }
        // The original's color is passed along (used until a measurement arrives).
        XCTAssertEqual(
            controller.contentItems(window: key).first?.colors.originalText, item.style.textColor)
        // The measured colors are drawn without another update; nothing else is measured (longer than the
        // controller's debounce, 0.25 s).
        await waitUntil { controller.contentItems(window: key).first?.colors.sampled == sampler.colors }
        await sleep(0.35)
        XCTAssertEqual(sampler.calls.count, 1, "one measurement for the whole stream")
        XCTAssertEqual(controller.contentItems(window: key).first?.colors.sampled, sampler.colors)
        XCTAssertEqual(controller.contentItems(window: key).first?.text, String(repeating: "こ", count: 20))
        // The permission (a slow call) is asked once per update, and not again for the redraw.
        XCTAssertEqual(sampler.authorizedChecks, 20)
    }

    @MainActor
    func testControllerDoesNotSampleWhileTheWindowScrolls() async throws {
        let (window, id) = try await offscreenWindow()
        defer { window.orderOut(nil) }
        let controller = OverlayController()
        defer { controller.removeAll() }
        let sampler = FakeColorSampler()
        controller.colorSampler = sampler
        let key = WindowKey(pid: getpid(), windowID: id)
        let axFrame = CoordinateSpace.axRect(fromCocoa: window.frame)
        let item = OverlayItem(
            id: "a", axFrame: CGRect(x: axFrame.minX + 10, y: axFrame.minY + 10, width: 200, height: 20),
            original: "Hello", translation: "こんにちは", state: .final)
        controller.setTemporarilyHidden(true, window: key)
        controller.update(
            window: key, axWindowFrame: axFrame, axClipRect: nil, cgWindowID: id, items: [item],
            style: OverlayStyle(displayStyle: .replace, appearance: OverlayAppearance()), targetIsFrontmost: false)
        await sleep(0.5)
        XCTAssertTrue(sampler.calls.isEmpty)
        controller.setTemporarilyHidden(false, window: key)
        await waitUntil { sampler.calls.count == 1 }
        XCTAssertEqual(sampler.calls.count, 1)
    }

    @MainActor
    func testControllerDoesNotSampleWhenOffOrNotAllowed() async throws {
        let (window, id) = try await offscreenWindow()
        defer { window.orderOut(nil) }
        let axFrame = CoordinateSpace.axRect(fromCocoa: window.frame)
        let item = OverlayItem(
            id: "a", axFrame: CGRect(x: axFrame.minX + 10, y: axFrame.minY + 10, width: 200, height: 20),
            original: "Hello", translation: "こんにちは", state: .final)
        for allowed in [false, true] {
            let controller = OverlayController()
            let sampler = FakeColorSampler()
            sampler.authorized = allowed
            controller.colorSampler = sampler
            var appearance = OverlayAppearance()
            appearance.matchBackgroundFromScreen = !allowed  // off when allowed, on when not allowed
            controller.update(
                window: WindowKey(pid: getpid(), windowID: id), axWindowFrame: axFrame, axClipRect: nil,
                cgWindowID: id, items: [item], style: OverlayStyle(displayStyle: .replace, appearance: appearance),
                targetIsFrontmost: false)
            await sleep(0.4)
            XCTAssertTrue(sampler.calls.isEmpty)
            controller.removeAll()
        }
    }

    /// The follow-up request in a terminal: the app reports no colors, the long URL is colored and is the most
    /// common text color. The translation's text takes the color measured around the URL; only the URL is a link.
    @MainActor
    func testControllerMeasuresTheTextAroundLinks() async throws {
        let (window, id) = try await offscreenWindow()
        defer { window.orderOut(nil) }
        let controller = OverlayController()
        defer { controller.removeAll() }
        let background = RGBAColor(red: 0.1, green: 0.1, blue: 0.1)
        let urlColor = RGBAColor(red: 0.22, green: 0.74, blue: 0.97)
        let textColor = RGBAColor(red: 0.85, green: 0.85, blue: 0.85)
        let sampler = FakeColorSampler()
        sampler.colors = SampledColors(background: background, text: urlColor)
        sampler.byID[OverlayController.nonLinkSampleID("a")] = SampledColors(background: background, text: textColor)
        controller.colorSampler = sampler
        let key = WindowKey(pid: getpid(), windowID: id)
        let axFrame = CoordinateSpace.axRect(fromCocoa: window.frame)
        let url = "https://example.com/a/very/long/path"
        let translation = "詳しくは \(url) を見て"
        let urlRange = (translation as NSString).range(of: url)
        let line = CGRect(x: axFrame.minX + 10, y: axFrame.minY + 10, width: 380, height: 17)
        let item = OverlayItem(
            id: "a", axFrame: line, original: "See \(url) for details.", translation: translation, state: .final,
            style: TextStyleHint(fontSize: 13, lineHeight: 17, isMonospaced: true), lineFrames: [line],
            originalLinks: [
                SegmentLink(
                    range: 4..<(4 + url.utf16.count), text: url, kind: .detected, url: URL(string: url),
                    frames: [CGRect(x: line.minX + 32, y: line.minY, width: 290, height: 17)])
            ],
            links: [OverlayLink(range: urlRange.location..<NSMaxRange(urlRange), linkIndex: 0)])
        controller.update(
            window: key, axWindowFrame: axFrame, axClipRect: nil, cgWindowID: id, items: [item],
            style: OverlayStyle(displayStyle: .replace, appearance: OverlayAppearance()), targetIsFrontmost: false)
        await waitUntil { controller.contentItems(window: key).first?.colors.sampled?.text == textColor }
        XCTAssertEqual(sampler.calls.count, 1)
        let asked = try XCTUnwrap(sampler.calls.first)
        XCTAssertEqual(Set(asked.keys), ["a", OverlayController.nonLinkSampleID("a")])
        let around = try XCTUnwrap(asked[OverlayController.nonLinkSampleID("a")])
        XCTAssertTrue(around.intersection(item.originalLinks[0].frames[0]).isEmpty)
        let drawn = try XCTUnwrap(controller.contentItems(window: key).first)
        XCTAssertEqual(drawn.colors.sampled?.text, textColor)
        XCTAssertEqual(drawn.colors.sampled?.background, background)
        XCTAssertEqual(drawn.links.count, 1)
        XCTAssertNil(drawn.links.first?.color)
    }

    // MARK: - Drawing with colors

    @MainActor
    func testCanvasDrawsMeasuredBackgroundWithoutBorder() throws {
        let fitter = TextFitter()
        var appearance = OverlayAppearance()
        appearance.theme = .light
        let bg = RGBAColor(red: 0.2, green: 0.4, blue: 0.6)
        let layout = try XCTUnwrap(
            OverlayLayout.layoutItem(
                id: "a", text: "訳", frame: CGRect(x: 10, y: 10, width: 80, height: 20),
                clip: CGRect(x: 0, y: 0, width: 100, height: 40), appearance: appearance, fitter: fitter))
        let canvas = OverlayCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        canvas.setContent(
            [
                OverlayDrawItem(
                    layout: layout, text: "訳", state: .final,
                    colors: OverlayItemColors(sampled: SampledColors(background: bg, text: nil)))
            ], appearance: appearance, crossfade: false)
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil, width: 100, height: 40, bitsPerComponent: 8, bytesPerRow: 400,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.translateBy(x: 0, y: 40)
        bitmap.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(data[y * 400 + x * 4 + $0]) } }
        // The edge pixels of the background are the measured color (no hairline border), inside the corner.
        XCTAssertEqual(pixel(50, 10), [51, 102, 153, 255])
        XCTAssertEqual(pixel(9, 20), [51, 102, 153, 255])
        XCTAssertEqual(pixel(88, 29), [51, 102, 153, 255])
        // Nothing outside the original's area.
        XCTAssertEqual(pixel(50, 5)[3], 0)
        XCTAssertEqual(pixel(50, 35)[3], 0)
    }
}
