import XCTest

@testable import Plamonic

private typealias F = TranslationTestFixtures

/// The pure 混雑時の一時停止 state machine, driven with explicit times.
final class TranslationBurstControlTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func control(threshold: Int = 8, quiet: Double = 1.5) -> BurstControl {
        BurstControl(settings: BurstControlSettings(isEnabled: true, threshold: threshold, quietSeconds: quiet))
    }

    func testEntersWhenTheBacklogReachesTheThreshold() {
        var burst = control()
        XCTAssertFalse(burst.evaluate(backlog: 7, isActive: true, now: at(0)))
        XCTAssertFalse(burst.isPaused)
        XCTAssertTrue(burst.evaluate(backlog: 8, isActive: true, now: at(0.1)))
        XCTAssertTrue(burst.isPaused)
    }

    func testEntersOnArrivalsWithinTwoSeconds() {
        var burst = control()
        burst.recordArrivals(5, at: at(0))
        burst.recordArrivals(3, at: at(1.5))
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(1.5)))

        var spread = control()
        spread.recordArrivals(5, at: at(0))
        spread.recordArrivals(3, at: at(2.1))
        XCTAssertFalse(spread.evaluate(backlog: 0, isActive: true, now: at(2.1)), "the first five are older than 2 s")
        XCTAssertEqual(spread.arrivalCount(within: 2, now: at(2.1)), 3)
    }

    func testExitNeedsAQuietPeriodAndEveryTextDrafted() {
        var burst = control()
        burst.recordArrivals(8, at: at(0))
        XCTAssertTrue(burst.evaluate(backlog: 8, isActive: true, now: at(0)))
        XCTAssertFalse(burst.evaluate(backlog: 0, isActive: true, now: at(1.0)), "still within the quiet period")
        XCTAssertFalse(burst.evaluate(backlog: 2, isActive: true, now: at(1.6)), "drafts are still missing")
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(1.6)))
        XCTAssertFalse(burst.isPaused)
    }

    func testOneSlowArrivalDoesNotHoldThePauseButTwoDo() {
        var slow = control()
        slow.recordArrivals(8, at: at(0))
        slow.evaluate(backlog: 0, isActive: true, now: at(0))
        slow.recordArrivals(1, at: at(1.0))
        XCTAssertTrue(slow.evaluate(backlog: 0, isActive: true, now: at(1.6)), "one arrival counts as slowed down")

        var steady = control()
        steady.recordArrivals(8, at: at(0))
        steady.evaluate(backlog: 0, isActive: true, now: at(0))
        steady.recordArrivals(1, at: at(1.0))
        steady.recordArrivals(1, at: at(1.2))
        XCTAssertFalse(steady.evaluate(backlog: 0, isActive: true, now: at(1.6)))
        XCTAssertEqual(steady.nextEvaluation(now: at(1.6)), at(2.5), "when the arrival at 1.0 s ages out")
        XCTAssertTrue(steady.evaluate(backlog: 0, isActive: true, now: at(2.5)))
    }

    func testNextEvaluationIsTheEndOfTheQuietPeriod() {
        var burst = control()
        XCTAssertNil(burst.nextEvaluation(now: at(0)), "not paused")
        burst.recordArrivals(8, at: at(0))
        burst.evaluate(backlog: 8, isActive: true, now: at(0))
        XCTAssertEqual(burst.nextEvaluation(now: at(0)), at(1.5))
        XCTAssertEqual(burst.nextEvaluation(now: at(1.4)), at(1.5))
        // Quiet now, but drafts are missing: their completion re-evaluates, so no timer is needed.
        XCTAssertFalse(burst.evaluate(backlog: 3, isActive: true, now: at(1.5)))
        XCTAssertNil(burst.nextEvaluation(now: at(1.5)))
    }

    func testArrivalsThatCausedAPauseDoNotStartAnotherOne() {
        var burst = control(quiet: 0.5)
        burst.recordArrivals(8, at: at(0))
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(0)))
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(0.6)))
        XCTAssertFalse(burst.isPaused)
        XCTAssertFalse(burst.evaluate(backlog: 0, isActive: true, now: at(0.7)), "the same eight are not counted again")
        burst.recordArrivals(8, at: at(0.8))
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(0.8)), "a new flood pauses again")
    }

    func testInactiveNeverPausesAndEndsAPause() {
        var burst = control()
        burst.recordArrivals(50, at: at(0))
        XCTAssertFalse(burst.evaluate(backlog: 50, isActive: false, now: at(0)))
        XCTAssertTrue(burst.evaluate(backlog: 50, isActive: true, now: at(0)))
        XCTAssertTrue(burst.evaluate(backlog: 50, isActive: false, now: at(0.1)))
        XCTAssertFalse(burst.isPaused)
    }

    func testClockSteppingBackDoesNotHoldThePause() {
        var burst = control()
        burst.recordArrivals(10, at: at(300))
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(300)))
        // Set back five minutes: the earlier arrivals now look like they are in the future.
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(0)), "they are forgotten, not kept forever")
        XCTAssertFalse(burst.isPaused)
        XCTAssertNil(burst.nextEvaluation(now: at(0)))
        burst.recordArrivals(8, at: at(0.5))
        XCTAssertTrue(
            burst.evaluate(backlog: 0, isActive: true, now: at(0.5)), "a new flood after the step still pauses")
    }

    func testThresholdBelowOneActsAsOne() {
        var burst = control(threshold: 0, quiet: 0)
        XCTAssertFalse(burst.evaluate(backlog: 0, isActive: true, now: at(0)), "an empty backlog never pauses")
        XCTAssertTrue(burst.evaluate(backlog: 1, isActive: true, now: at(0)))
        XCTAssertTrue(burst.evaluate(backlog: 0, isActive: true, now: at(0.1)))
        XCTAssertFalse(burst.evaluate(backlog: 0, isActive: true, now: at(0.2)), "no flapping")
    }
}

/// 混雑時の一時停止 inside the coordinator, with a fake backend and real time.
final class TranslationBurstCoordinatorTests: XCTestCase {
    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func burstSettings(
        threshold: Int = 4, quiet: Double = 0.2, configure: (inout EffectiveSettings) -> Void = { _ in }
    ) -> EffectiveSettings {
        F.settings {
            $0.global.progressive.burstControl = BurstControlSettings(
                isEnabled: true, threshold: threshold, quietSeconds: quiet)
            configure(&$0)
        }
    }

    private func texts(_ prefix: String, _ count: Int) -> [String] {
        (0..<count).map { "\(prefix) message number \($0) just arrived" }
    }

    /// `F.coordinator` for a `HoldingBackend`.
    @MainActor
    private func makeCoordinator(_ backend: HoldingBackend) -> TranslationCoordinator {
        TranslationCoordinator(
            backend: backend, cache: TranslationCache(capacity: 1000, fileURL: nil), configuration: F.configuration(),
            frontmostPID: { 100 })
    }

    @MainActor
    func testUpgradesWaitWhileNewTextKeepsArrivingThenResumeWithoutAScan() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.01, .b2: 0.05])
        let coordinator = F.coordinator(backend)
        // Far longer than the 50 ms between scans, so a scan that comes late on a loaded machine still holds it.
        let quiet = 1.0
        let settings = burstSettings(threshold: 4, quiet: quiet)
        var transitions = [false]
        coordinator.onActivityChanged = { activity in
            if transitions.last != activity.refinementPaused { transitions.append(activity.refinementPaused) }
        }
        var onScreen = texts("Burst", 6)
        let key = F.snapshot([]).key
        coordinator.process(snapshot: F.snapshot(onScreen), settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused, "six new texts at once")
        XCTAssertNotNil(coordinator.activity.refinementPauseNotice)

        // Two new texts every 50 ms: more than one per quiet period, so the pause holds.
        var lastArrival = Date()
        for round in 0..<10 {
            try await sleep(0.05)
            onScreen += texts("Follow-up \(round)", 2)
            lastArrival = Date()
            coordinator.process(snapshot: F.snapshot(onScreen), settings: settings)
            XCTAssertTrue(coordinator.activity.refinementPaused, "round \(round)")
        }
        XCTAssertTrue(backend.calls.allSatisfy { $0.model == .b0_8 }, "no upgrade starts while text keeps arriving")

        let resumed = await F.waitUntil { !coordinator.activity.refinementPaused }
        XCTAssertTrue(resumed, "the pause ends after the quiet period without a new scan")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(lastArrival), quiet - 0.05)
        let done = await F.waitUntil(timeout: 10) { coordinator.items(for: key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)
        XCTAssertEqual(transitions, [false, true, false])
        // After the pause the upgrades run top to bottom.
        XCTAssertEqual(backend.calls.filter { $0.model == .b2 }.map(\.request.text), onScreen)
        XCTAssertNil(coordinator.activity.refinementPauseNotice)
    }

    @MainActor
    func testDraftsGoNewestFirstWhilePaused() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.05, .b2: 0.01])
        let coordinator = F.coordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.3)
        let old = texts("Old", 6)
        let new = texts("New", 3)
        coordinator.process(snapshot: F.snapshot(old), settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        // While the first draft runs, more text arrives below: it is drafted before the older texts,
        // which are the ones a flood scrolls away first.
        coordinator.process(snapshot: F.snapshot(old + new), settings: settings)
        let drafted = await F.waitUntil(timeout: 5) {
            backend.calls.filter { $0.model == .b0_8 }.count == old.count + new.count
        }
        XCTAssertTrue(drafted)
        XCTAssertEqual(
            backend.calls.filter { $0.model == .b0_8 }.map(\.request.text),
            [old[0]] + new + Array(old.dropFirst()))
        // Without a pause the order is the reading order again (the upgrades after it run top to bottom).
        let done = await F.waitUntil(timeout: 10) {
            coordinator.items(for: F.snapshot([]).key).allSatisfy { $0.state == .final }
        }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls.filter { $0.model == .b2 }.map(\.request.text), old + new)
    }

    @MainActor
    func testPauseLastsUntilEveryTextHasADraft() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.04, .b2: 0.01])
        let coordinator = F.coordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.1)
        let snapshot = F.snapshot(texts("Slow draft", 12))
        var draftedAtResume: Bool?
        coordinator.onActivityChanged = { activity in
            guard !activity.refinementPaused, draftedAtResume == nil else { return }
            draftedAtResume = coordinator.items(for: snapshot.key).allSatisfy { $0.state == .draft || $0.state == .final }
        }
        let start = Date()
        coordinator.process(snapshot: snapshot, settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        let resumed = await F.waitUntil { !coordinator.activity.refinementPaused }
        XCTAssertTrue(resumed)
        XCTAssertEqual(draftedAtResume, true)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.4, "twelve drafts take longer than the quiet period")
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)
    }

    @MainActor
    func testRunningUpgradeIsCancelledWhenThePauseStarts() async throws {
        let backend = HoldingBackend(latency: [.b0_8: 0.01, .b2: 0.05])
        let coordinator = makeCoordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.15)
        let first = "The first message before the flood"
        // The upgrade runs until something cancels it, so the flood arrives while it runs however slow the machine.
        backend.hold(first, model: .b2)
        coordinator.process(snapshot: F.snapshot([first]), settings: settings)
        let upgrading = await F.waitUntil { backend.calls.contains { $0.model == .b2 } }
        XCTAssertTrue(upgrading)

        let snapshot = F.snapshot([first] + texts("Flood", 6))
        // Recorded when the last draft lands: one job runs at a time, so a finished upgrade means they waited for it.
        var upgradedBeforeTheDrafts: Bool?
        coordinator.onItemsChanged = { [weak coordinator] key in
            guard let coordinator, upgradedBeforeTheDrafts == nil,
                coordinator.items(for: key).dropFirst().allSatisfy({ $0.state == .draft })
            else { return }
            upgradedBeforeTheDrafts = backend.completedCalls.contains { $0.model == .b2 }
        }
        coordinator.process(snapshot: snapshot, settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        let drafted = await F.waitUntil { upgradedBeforeTheDrafts != nil }
        XCTAssertTrue(drafted)
        XCTAssertEqual(upgradedBeforeTheDrafts, false, "the drafts did not wait for it: the running upgrade was cancelled")

        let done = await F.waitUntil(timeout: 10) {
            coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final }
        }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls(for: first).map(\.model), [.b0_8, .b2, .b2], "started over after the pause")
        XCTAssertNil(coordinator.activity.lastError, "a cancelled upgrade is not a failure")
    }

    @MainActor
    func testInterruptedMultiChunkUpgradeResumesAfterThePause() async throws {
        let backend = HoldingBackend(latency: [.b0_8: 0.01, .b2: 0.05])
        let coordinator = makeCoordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.15)
        let paragraphs = ["Alpha", "Bravo", "Charlie"].map {
            String(repeating: "\($0) paragraph sentence for the burst test. ", count: 10)
                .trimmingCharacters(in: .whitespaces)
        }
        let long = paragraphs.joined(separator: "\n\n")
        // The upgrade's second chunk runs until something cancels it, so the flood below arrives while it runs.
        backend.hold(paragraphs[1], model: .b2)
        coordinator.process(snapshot: F.snapshot([long]), settings: settings)
        // Three draft chunks, then the upgrade: wait until its second chunk is running.
        let upgrading = await F.waitUntil { backend.calls.count >= 5 }
        XCTAssertTrue(upgrading)
        XCTAssertEqual(backend.completedCalls.last.map { "\($0.model.rawValue) \($0.request.text.prefix(5))" }, "2b Alpha")

        let flood = texts("Flood", 6)
        let snapshot = F.snapshot([long] + flood)
        coordinator.process(snapshot: snapshot, settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        let done = await F.waitUntil(timeout: 10) {
            coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final }
        }
        XCTAssertTrue(done)

        let calls = backend.calls.map { "\($0.model.rawValue) \($0.request.text.prefix(5))" }
        XCTAssertEqual(
            calls,
            ["0.8b Alpha", "0.8b Bravo", "0.8b Charl", "2b Alpha", "2b Bravo"]
                + Array(repeating: "0.8b Flood", count: 6)
                + ["2b Bravo", "2b Charl"]  // resumed after the finished chunk
                + Array(repeating: "2b Flood", count: 6))
        XCTAssertEqual(
            coordinator.items(for: snapshot.key).first?.translation,
            paragraphs.map { TranslationFakeBackend.output(for: $0, model: .b2) }.joined(separator: "\n\n"))
    }

    @MainActor
    func testNoPauseWhenDisabledOrSingleStage() async throws {
        let cases: [(String, Set<ModelSize>, EffectiveSettings)] = [
            ("burst control off", [.b0_8, .b2], burstSettings { $0.global.progressive.burstControl.isEnabled = false }),
            ("段階翻訳 off", [.b0_8, .b2], burstSettings { $0.global.progressive.isEnabled = false }),
            ("app override off", [.b0_8, .b2], burstSettings { $0.profile.progressiveOverride = false }),
            ("draft only", [.b0_8], burstSettings()),
        ]
        for (name, installed, settings) in cases {
            let backend = TranslationFakeBackend(installed: installed, latency: [.b0_8: 0.003, .b2: 0.003])
            let coordinator = F.coordinator(backend)
            var paused = false
            coordinator.onActivityChanged = { if $0.refinementPaused { paused = true } }
            let snapshot = F.snapshot(texts("Plenty", 12))
            coordinator.process(snapshot: snapshot, settings: settings)
            let done = await F.waitUntil {
                coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final || $0.state == .draft }
                    && !coordinator.activity.isBusy
            }
            XCTAssertTrue(done, name)
            XCTAssertFalse(paused, name)
            coordinator.cancelAll()
        }
    }

    @MainActor
    func testOnlyTwoStageWindowsCountTowardThePause() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.05, .b2: 0.05])
        let coordinator = F.coordinator(backend, frontmost: 100)
        let twoStage = burstSettings(threshold: 4, quiet: 0.2)
        let singleStage = burstSettings(threshold: 4, quiet: 0.2) { $0.profile.progressiveOverride = false }
        coordinator.process(snapshot: F.snapshot(["A quiet two-stage window"], pid: 100, window: 1), settings: twoStage)
        coordinator.process(snapshot: F.snapshot(texts("Terminal", 10), pid: 200, window: 2), settings: singleStage)
        XCTAssertFalse(coordinator.activity.refinementPaused, "the single-stage window has no drafts to protect")
        coordinator.process(
            snapshot: F.snapshot(["A quiet two-stage window"] + texts("Chat", 10), pid: 100, window: 1),
            settings: twoStage)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        coordinator.forget(window: WindowKey(pid: 100, windowID: 1))
        XCTAssertFalse(coordinator.activity.refinementPaused, "no two-stage window left")
        coordinator.cancelAll()
    }

    @MainActor
    func testOneStreamingReplyIsNotAFlood() async throws {
        // Only the draft model at first, so the earlier texts have drafts and wait for their upgrades.
        let backend = TranslationFakeBackend(installed: [.b0_8], latency: [.b0_8: 0.01, .b2: 0.05])
        let coordinator = F.coordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.3)
        var paused = false
        coordinator.onActivityChanged = { if $0.refinementPaused { paused = true } }
        let earlier = texts("Earlier", 6)
        let key = F.snapshot([]).key
        coordinator.process(snapshot: F.snapshot(earlier), settings: settings)
        let drafted = await F.waitUntil { coordinator.items(for: key).allSatisfy { $0.state == .draft } }
        XCTAssertTrue(drafted)
        backend.installed = [.b0_8, .b2]

        // The reply grows on every scan: a new text each time, but the same paragraph.
        var reply = "The assistant reply starts streaming here"
        for round in 0..<15 {
            reply += " word\(round)"
            coordinator.process(snapshot: F.snapshot(earlier + [reply]), settings: settings)
            try await sleep(0.1)
        }
        XCTAssertFalse(paused, "one text changing in place is not a flood")
        XCTAssertEqual(
            coordinator.items(for: key).prefix(earlier.count).map(\.state),
            Array(repeating: .final, count: earlier.count), "the upgrades went on while the reply streamed")
        coordinator.cancelAll()
    }

    @MainActor
    func testStreamingReplyNeitherHoldsThePauseNorGoesBeforeFinishedTexts() async throws {
        // Drafts take longer than the reply takes to change, so its drafts are always cancelled.
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.12, .b2: 0.02])
        let coordinator = F.coordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.3)
        let flood = texts("Flood", 6)
        let key = F.snapshot([]).key
        var reply = "The assistant reply starts streaming here"
        coordinator.process(snapshot: F.snapshot(flood + [reply]), settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused)

        var draftedWhileStreaming = false
        var resumedWhileStreaming = false
        for round in 0..<20 {
            try await sleep(0.1)
            reply += " word\(round)"
            coordinator.process(snapshot: F.snapshot(flood + [reply]), settings: settings)
            let states = coordinator.items(for: key).prefix(flood.count).map(\.state)
            if states.allSatisfy({ $0 == .draft || $0 == .final }) { draftedWhileStreaming = true }
            if !coordinator.activity.refinementPaused { resumedWhileStreaming = true }
        }
        XCTAssertTrue(draftedWhileStreaming, "the newest text that keeps changing does not go first")
        XCTAssertTrue(resumedWhileStreaming, "a text still changing does not keep the pause going")
        coordinator.cancelAll()
    }

    @MainActor
    func testTextCutAtTheTopKeepsItsArrivalAndIsDraftedLast() async throws {
        let backend = HoldingBackend(latency: [.b0_8: 0.05, .b2: 0.01])
        let coordinator = makeCoordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 1)
        let paragraphs = (0..<6).map { "Paragraph \($0) of the log has several words to translate" }
        // The first draft runs until the scroll below takes its text off the screen (and cancels it), so the
        // scroll arrives while it runs however slow the machine.
        backend.hold(paragraphs[0], model: .b0_8)
        coordinator.process(snapshot: F.snapshot(paragraphs), settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        let started = await F.waitUntil { backend.calls.count == 1 }
        XCTAssertTrue(started)

        // The terminal scrolls by a row: the top paragraph loses its first row and a new one appears below.
        let fragment = "several words to translate"
        let newest = "Paragraph 6 is new at the bottom of the screen"
        coordinator.process(
            snapshot: F.snapshot([fragment] + paragraphs.dropFirst() + [newest]), settings: settings)
        let drafted = await F.waitUntil { backend.calls.filter { $0.model == .b0_8 }.count == 8 }
        XCTAssertTrue(drafted)
        XCTAssertEqual(
            backend.calls.filter { $0.model == .b0_8 }.map(\.request.text),
            [paragraphs[0], newest] + paragraphs.dropFirst() + [fragment])
        coordinator.cancelAll()
    }

    @MainActor
    func testFloodInABackgroundAppDoesNotHoldTheAppInFront() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.01, .b2: 0.03])
        let coordinator = F.coordinator(backend, frontmost: 100)
        // Far longer than the 0.1 s between scans, so a scan that comes late on a loaded machine still holds it.
        let settings = burstSettings(threshold: 4, quiet: 1)
        let front = WindowKey(pid: 100, windowID: 1)
        let chat = texts("Front chat", 3)
        var log = texts("Background log", 10)
        coordinator.process(snapshot: F.snapshot(log, pid: 200, window: 2), settings: settings)
        coordinator.process(snapshot: F.snapshot(chat, pid: 100, window: 1), settings: settings)
        XCTAssertFalse(coordinator.activity.refinementPaused, "the status describes the app in front")

        // The log keeps flowing (3 lines per scan), so the background app stays paused throughout.
        for round in 0..<15 {
            try await sleep(0.1)
            log += texts("Log line \(round)", 3)
            coordinator.process(snapshot: F.snapshot(log, pid: 200, window: 2), settings: settings)
            coordinator.process(snapshot: F.snapshot(chat, pid: 100, window: 1), settings: settings)
        }
        XCTAssertFalse(backend.calls.contains { $0.model == .b2 && !chat.contains($0.request.text) })
        // Well within the background app's quiet period: held by its pause, they would still be drafts.
        _ = await F.waitUntil(timeout: 0.5) { coordinator.items(for: front).allSatisfy { $0.state == .final } }
        XCTAssertEqual(coordinator.items(for: front).map(\.state), [.final, .final, .final])
        XCTAssertFalse(coordinator.activity.refinementPaused)
        coordinator.cancelAll()
    }

    @MainActor
    func testSingleStageAppIsNotHeldByAnotherAppsPause() async throws {
        let backend = TranslationFakeBackend(installed: [.b0_8], latency: [.b0_8: 0.01, .b2: 0.03])
        let coordinator = F.coordinator(backend, frontmost: 100)
        // Far longer than the 0.1 s between scans, so a scan that comes late on a loaded machine still holds it.
        let twoStage = burstSettings(threshold: 4, quiet: 1)
        let singleStage = burstSettings(threshold: 4, quiet: 1) { $0.profile.progressiveOverride = false }
        let chatKey = WindowKey(pid: 100, windowID: 1)
        let terminal = WindowKey(pid: 200, windowID: 2)
        // A draft of the line from when only the draft model was installed.
        let shared = "A line both apps have shown before"
        coordinator.process(snapshot: F.snapshot([shared], pid: 100, window: 1), settings: twoStage)
        let drafted = await F.waitUntil { coordinator.items(for: chatKey).first?.state == .draft }
        XCTAssertTrue(drafted)
        backend.installed = [.b0_8, .b2]

        var chat = texts("Chat", 10)
        coordinator.process(snapshot: F.snapshot(chat, pid: 100, window: 1), settings: twoStage)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        coordinator.process(snapshot: F.snapshot([shared], pid: 200, window: 2), settings: singleStage)
        for round in 0..<8 {
            try await sleep(0.1)
            chat += texts("More chat \(round)", 3)
            coordinator.process(snapshot: F.snapshot(chat, pid: 100, window: 1), settings: twoStage)
            coordinator.process(snapshot: F.snapshot([shared], pid: 200, window: 2), settings: singleStage)
            XCTAssertTrue(coordinator.activity.refinementPaused, "round \(round)")
        }
        XCTAssertFalse(backend.calls.contains { $0.model == .b2 && $0.request.text != shared }, "the chat app's wait")
        // Well within the chat app's quiet period: held by its pause, the line would still be a draft.
        _ = await F.waitUntil(timeout: 0.5) { coordinator.items(for: terminal).first?.state == .final }
        XCTAssertEqual(coordinator.items(for: terminal).first?.state, .final, "its upgrade was not held")
        coordinator.cancelAll()
    }

    @MainActor
    func testManualTranslationRunsDuringThePause() async throws {
        // Slow drafts cost nothing here (the manual request cancels the running one, and the test ends after it),
        // but they put waiting behind the ten of them far above the bound below.
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.2, .b2: 0.05])
        let coordinator = F.coordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.2)
        coordinator.process(snapshot: F.snapshot(texts("Busy", 10)), settings: settings)
        XCTAssertTrue(coordinator.activity.refinementPaused)
        let started = Date()
        let manual = await coordinator.translateOnce(text: "A selected sentence to translate", settings: settings)
        XCTAssertEqual(manual, TranslationFakeBackend.output(for: "A selected sentence to translate", model: .b2))
        // About 0.05 s: it goes ahead of the drafts. Held by the pause, it would wait for all ten (2 s or more).
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(coordinator.activity.refinementPaused, "only background upgrades are held")
        coordinator.cancelAll()
        XCTAssertFalse(coordinator.activity.refinementPaused)
    }

    // MARK: - Partial scans

    private func partial(_ texts: [String]) -> WindowSnapshot {
        var snapshot = F.snapshot(texts)
        snapshot.truncated = true
        return snapshot
    }

    /// A slow app answers only part of a scan: the texts it did not reach are still on screen.
    @MainActor
    func testPartialScanKeepsTheRunningDraftOfATextItDidNotReach() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.3, .b2: 0.05])
        let coordinator = F.coordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.2)
        let onScreen = ["The first paragraph on the screen", "The second paragraph on the screen"]
        coordinator.process(snapshot: F.snapshot(onScreen), settings: settings)
        _ = await F.waitUntil { backend.calls.contains { $0.request.text == onScreen[0] } }

        coordinator.process(snapshot: partial([]), settings: settings)
        let drafted = await F.waitUntil { backend.completedCalls.contains { $0.request.text == onScreen[0] } }
        XCTAssertTrue(drafted, "the running draft was not cancelled")

        coordinator.process(snapshot: F.snapshot(onScreen), settings: settings)
        let done = await F.waitUntil(timeout: 10) {
            coordinator.items(for: F.snapshot([]).key).allSatisfy { $0.state == .final }
        }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls(for: onScreen[0]).map(\.model), [.b0_8, .b2], "translated once per model")
        coordinator.cancelAll()
    }

    /// Texts that come back after a partial scan missed them are not a flood.
    @MainActor
    func testTextsBackAfterAPartialScanAreNotNew() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.3, .b2: 0.05])
        let coordinator = F.coordinator(backend)
        let settings = burstSettings(threshold: 4, quiet: 0.2)
        let onScreen = texts("Steady", 3)
        coordinator.process(snapshot: F.snapshot(onScreen), settings: settings)
        XCTAssertFalse(coordinator.activity.refinementPaused, "three texts are below the threshold")
        for _ in 0..<3 {
            coordinator.process(snapshot: partial([]), settings: settings)
            coordinator.process(snapshot: F.snapshot(onScreen), settings: settings)
        }
        XCTAssertFalse(coordinator.activity.refinementPaused, "the same three texts did not arrive again")
        coordinator.cancelAll()

        // A complete scan forgets what it does not show: those texts are new when they come back.
        let fresh = F.coordinator(backend)
        fresh.process(snapshot: F.snapshot(onScreen), settings: settings)
        fresh.process(snapshot: F.snapshot([]), settings: settings)
        fresh.process(snapshot: F.snapshot(onScreen), settings: settings)
        fresh.process(snapshot: F.snapshot([]), settings: settings)
        fresh.process(snapshot: F.snapshot(onScreen), settings: settings)
        XCTAssertTrue(fresh.activity.refinementPaused, "complete scans count returning untranslated texts")
        fresh.cancelAll()
    }
}

/// `TranslationFakeBackend` (same answers, same call records) with held calls: a held call runs until it is
/// cancelled, so a test can act while it runs however slow the machine is. A held call nobody cancels ends after
/// `holdDuration`, so a coordinator that fails to cancel it fails the test instead of hanging it.
private final class HoldingBackend: TranslationBackend, @unchecked Sendable {
    typealias Call = TranslationFakeBackend.Call

    static let holdDuration: TimeInterval = 3

    private let lock = NSLock()
    private let latency: [ModelSize: TimeInterval]
    private var held: [(text: String, model: ModelSize)] = []
    private var _calls: [Call] = []
    private var _completed: [Call] = []

    init(latency: [ModelSize: TimeInterval]) {
        self.latency = latency
    }

    /// Holds the next call for `text` with `model`.
    func hold(_ text: String, model: ModelSize) {
        locked { held.append((text, model)) }
    }

    var calls: [Call] { locked { _calls } }
    var completedCalls: [Call] { locked { _completed } }

    func calls(for text: String) -> [Call] { calls.filter { $0.request.text == text } }

    func translate(
        _ request: TranslationBackendRequest, model: ModelSize, onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let call = Call(request: request, model: model)
        let delay: TimeInterval = locked {
            _calls.append(call)
            guard let index = held.firstIndex(where: { $0.text == request.text && $0.model == model }) else {
                return latency[model] ?? 0.01
            }
            held.remove(at: index)
            return Self.holdDuration
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        locked { _completed.append(call) }
        return TranslationFakeBackend.output(for: request.text, model: model)
    }

    func isModelInstalled(_ model: ModelSize) -> Bool { true }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
