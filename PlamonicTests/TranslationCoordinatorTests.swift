import XCTest

@testable import Plamonic

private typealias F = TranslationTestFixtures

final class TranslationCoordinatorTests: XCTestCase {
    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    func testDraftAppearsBeforeFinalAndFinalReplacesIt() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let texts = ["Hello, how are you today?", "The deploy finished without errors.", "Please review the pull request."]
        let snapshot = F.snapshot(texts)
        var states: [String: [OverlayItemState]] = [:]
        var seen: [String: [String]] = [:]
        let record: @MainActor () -> Void = {
            for item in coordinator.items(for: snapshot.key) {
                if states[item.id]?.last != item.state { states[item.id, default: []].append(item.state) }
                if !item.translation.isEmpty, seen[item.id]?.last != item.translation {
                    seen[item.id, default: []].append(item.translation)
                }
            }
        }
        coordinator.onItemsChanged = { _ in record() }

        let initial = coordinator.process(snapshot: snapshot, settings: F.settings())
        XCTAssertEqual(initial.map(\.state), [.pending, .pending, .pending])
        record()
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)

        for item in coordinator.items(for: snapshot.key) {
            let sequence = states[item.id] ?? []
            let draftIndex = try XCTUnwrap(sequence.firstIndex(of: .draft), "\(sequence)")
            let finalIndex = try XCTUnwrap(sequence.firstIndex(of: .final), "\(sequence)")
            XCTAssertLessThan(draftIndex, finalIndex)
            XCTAssertEqual(
                seen[item.id],
                [
                    TranslationFakeBackend.output(for: item.original, model: .b0_8),
                    TranslationFakeBackend.output(for: item.original, model: .b2),
                ])
        }
        XCTAssertEqual(backend.calls.map(\.model), [.b0_8, .b0_8, .b0_8, .b2, .b2, .b2])
        XCTAssertEqual(backend.calls.prefix(3).map(\.request.text), texts)
        XCTAssertEqual(backend.maxConcurrentCalls, 1)
    }

    @MainActor
    func testCachedResultsReturnImmediatelyOnNextScan() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let snapshot = F.snapshot(["Cached sentence one", "Cached sentence two"])
        coordinator.process(snapshot: snapshot, settings: F.settings())
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        let callCount = backend.calls.count

        let again = coordinator.process(snapshot: snapshot, settings: F.settings())
        XCTAssertEqual(again.map(\.state), [.final, .final])
        try await sleep(0.15)
        XCTAssertEqual(backend.calls.count, callCount)

        let other = TranslationCoordinator(
            backend: backend, cache: coordinator.cache, configuration: F.configuration(), frontmostPID: { 100 })
        XCTAssertEqual(other.process(snapshot: snapshot, settings: F.settings()).map(\.state), [.final, .final])
    }

    @MainActor
    func testStaleJobsAreDroppedWhenSegmentsDisappear() async throws {
        let backend = TranslationFakeBackend(latency: [.b2: 0.08])
        let coordinator = F.coordinator(backend)
        let settings = F.settings(draft: nil)
        let texts = [
            "Alpha message number one", "Bravo message number two", "Charlie message number three",
            "Delta message number four", "Echo message number five",
        ]
        coordinator.process(snapshot: F.snapshot(texts), settings: settings)
        _ = await F.waitUntil { backend.calls.count >= 1 }
        let scrolled = F.snapshot([texts[4]])
        coordinator.process(snapshot: scrolled, settings: settings)
        let done = await F.waitUntil { coordinator.items(for: scrolled.key).first?.state == .final }
        XCTAssertTrue(done)
        try await sleep(0.25)

        XCTAssertEqual(backend.calls.map(\.request.text), [texts[0], texts[4]])
        XCTAssertEqual(backend.completedCalls.map(\.request.text), [texts[4]], "in-flight stale job is cancelled")
        XCTAssertEqual(coordinator.cache.count, 1)
        XCTAssertFalse(coordinator.activity.isBusy)
    }

    @MainActor
    func testIdenticalTextsAcrossWindowsAreTranslatedOnce() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend, frontmost: 100)
        let shared = "Shared announcement for everyone"
        let first = F.snapshot([shared, "Only in the first window"], pid: 100, window: 1)
        let second = F.snapshot(["Only in the second window", shared], pid: 200, window: 2)
        coordinator.process(snapshot: first, settings: F.settings())
        coordinator.process(snapshot: second, settings: F.settings())
        let done = await F.waitUntil {
            (coordinator.items(for: first.key) + coordinator.items(for: second.key)).allSatisfy { $0.state == .final }
        }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls(for: shared).map(\.model), [.b0_8, .b2])
        XCTAssertEqual(backend.calls.count, 6)
        // The frontmost app's window is drafted first even though the other one was scanned later.
        XCTAssertEqual(
            backend.calls.prefix(3).map(\.request.text),
            [shared, "Only in the first window", "Only in the second window"])
    }

    @MainActor
    func testMostRecentlyScannedWindowFirstWhenNoneIsFrontmost() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.03, .b2: 0.03])
        let coordinator = F.coordinator(backend, frontmost: nil)
        coordinator.process(snapshot: F.snapshot(["Warm up text for the backend"], pid: 300, window: 3), settings: F.settings())
        coordinator.process(snapshot: F.snapshot(["Older window text here"], pid: 100, window: 1), settings: F.settings())
        coordinator.process(snapshot: F.snapshot(["Newer window text here"], pid: 200, window: 2), settings: F.settings())
        _ = await F.waitUntil { backend.calls.count >= 3 }
        XCTAssertEqual(backend.calls[1].request.text, "Newer window text here")
        coordinator.cancelAll()
    }

    @MainActor
    func testSameLanguageTextIsSkippedUnlessPolicyTranslates() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let ja = "今日は良い天気ですね。散歩に行きましょう。"
        let en = "The weather is nice today, let's go for a walk."

        let skip = coordinator.process(snapshot: F.snapshot([ja, en], window: 1), settings: F.settings())
        XCTAssertEqual(skip.map(\.original), [en])
        let easy = coordinator.process(
            snapshot: F.snapshot([ja, en], window: 2), settings: F.settings(target: "ja(easy)"))
        XCTAssertEqual(easy.map(\.original), [en])

        let chinese = "我们明天开会讨论这个问题"
        let mixed = coordinator.process(
            snapshot: F.snapshot(["了解です", "確認済", en, chinese], window: 3), settings: F.settings())
        XCTAssertEqual(mixed.map(\.original), [en, chinese], "kanji-only Japanese near kana is skipped, Chinese is not")

        let translate = coordinator.process(
            snapshot: F.snapshot([ja, en], window: 4), settings: F.settings { $0.global.sameLanguagePolicy = .translate })
        XCTAssertEqual(translate.map(\.original), [ja, en])
        let done = await F.waitUntil {
            coordinator.items(for: WindowKey(pid: 100, windowID: 4)).allSatisfy { $0.state == .final }
        }
        XCTAssertTrue(done)
        XCTAssertFalse(backend.calls(for: ja).isEmpty)
        XCTAssertTrue(backend.calls(for: "確認済").isEmpty)
        coordinator.cancelAll()
    }

    @MainActor
    func testFiltersDropUntranslatableSegments() {
        let coordinator = F.coordinator(TranslationFakeBackend())
        let texts = [
            "https://example.com/a/b", "12:30", "👍🎉", "x", "~/Projects/app/main.swift", "fetchUserProfile()",
            "a1b2c3d4e5f6", "Real sentence to translate", "secret-token-abc",
        ]
        let items = coordinator.process(
            snapshot: F.snapshot(texts), settings: F.settings { $0.profile.ignorePatterns = ["^secret-"] })
        XCTAssertEqual(items.map(\.original), ["Real sentence to translate"])
        coordinator.cancelAll()
    }

    @MainActor
    func testConversationHistoryIsPassedWhenEnabled() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let settings = F.settings(draft: nil) { $0.profile.useConversationHistory = true }
        let texts = ["First message in the thread", "Second message in the thread", "Third message in the thread"]
        let snapshot = F.snapshot(texts)
        coordinator.process(snapshot: snapshot, settings: settings)
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }

        func pair(_ text: String) -> TranslationHistoryPair {
            TranslationHistoryPair(source: text, translation: TranslationFakeBackend.output(for: text, model: .b2))
        }
        let calls = backend.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.map(\.request.history), [[], [pair(texts[0])], [pair(texts[0]), pair(texts[1])]])

        let plainBackend = TranslationFakeBackend()
        let plain = F.coordinator(plainBackend)
        plain.process(snapshot: snapshot, settings: F.settings(draft: nil))
        _ = await F.waitUntil { plain.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(plainBackend.calls.allSatisfy { $0.request.history.isEmpty })
    }

    @MainActor
    func testHistoryStaysWithinCharacterLimit() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let settings = F.settings(draft: nil) { $0.profile.useConversationHistory = true }
        let body = String(repeating: "This sentence keeps the history long enough. ", count: 13)
        let texts = ["First. " + body, "Second. " + body, "Third. " + body]
        let snapshot = F.snapshot(texts)
        coordinator.process(snapshot: snapshot, settings: settings)
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }

        // The fake echoes English for target "ja", so a long input sent with history is retried
        // once without it ("looks wrong" heuristic). The first attempt carries the history.
        let thirdCalls = backend.calls.filter { $0.request.text.hasPrefix("Third.") }
        let history = try XCTUnwrap(thirdCalls.first).request.history
        XCTAssertEqual(history.map(\.source), [texts[1].trimmingCharacters(in: .whitespaces)])
        XCTAssertLessThanOrEqual(history.reduce(0) { $0 + $1.source.count + $1.translation.count }, 1500)
        XCTAssertEqual(thirdCalls.count, 2)
        XCTAssertEqual(thirdCalls.last?.request.history, [])
    }

    @MainActor
    func testPartialUpdatesAreThrottled() async throws {
        let backend = TranslationFakeBackend()
        backend.setStreaming(steps: 60, interval: 0.005)
        let coordinator = F.coordinator(backend)
        let text = "Streaming text example for the throttle test"
        let snapshot = F.snapshot([text])
        var notifications = 0
        var streamed: [String] = []
        coordinator.onItemsChanged = { key in
            notifications += 1
            if let item = coordinator.items(for: key).first, item.state == .streaming { streamed.append(item.translation) }
        }
        let start = Date()
        coordinator.process(snapshot: snapshot, settings: F.settings(draft: nil))
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(done)
        XCTAssertGreaterThanOrEqual(streamed.count, 2)
        XCTAssertLessThanOrEqual(notifications, Int(elapsed / 0.1) + 2, "60 partials in \(elapsed) s")
        let final = TranslationFakeBackend.output(for: text, model: .b2)
        XCTAssertTrue(streamed.allSatisfy { final.hasPrefix($0) })
        XCTAssertTrue(zip(streamed, streamed.dropFirst()).allSatisfy { $0.count < $1.count })
    }

    @MainActor
    func testNoPartialUpdatesWhenStreamingIsOff() async throws {
        let backend = TranslationFakeBackend()
        backend.setStreaming(steps: 20, interval: 0.005)
        let coordinator = F.coordinator(backend)
        let snapshot = F.snapshot(["Quiet streaming sentence"])
        var notifications = 0
        var sawStreaming = false
        coordinator.onItemsChanged = { key in
            notifications += 1
            if coordinator.items(for: key).contains(where: { $0.state == .streaming }) { sawStreaming = true }
        }
        coordinator.process(snapshot: snapshot, settings: F.settings(draft: nil) { $0.global.streamPartialResults = false })
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        XCTAssertEqual(notifications, 1)
        XCTAssertFalse(sawStreaming)
    }

    @MainActor
    func testModelPlanFallbacks() async throws {
        let snapshot = F.snapshot(["Model plan check sentence"])

        let finalOnly = TranslationFakeBackend(installed: [.b2])
        let a = F.coordinator(finalOnly)
        a.process(snapshot: snapshot, settings: F.settings())
        _ = await F.waitUntil { a.items(for: snapshot.key).first?.state == .final }
        XCTAssertEqual(finalOnly.calls.map(\.model), [.b2], "draft not installed: single stage")
        XCTAssertNil(a.modelPlan?.draft)
        XCTAssertNotNil(a.modelPlan?.notice)

        let draftOnly = TranslationFakeBackend(installed: [.b0_8])
        let b = F.coordinator(draftOnly)
        b.process(snapshot: snapshot, settings: F.settings())
        _ = await F.waitUntil { b.items(for: snapshot.key).first?.state == .draft }
        try await sleep(0.1)
        XCTAssertEqual(b.items(for: snapshot.key).first?.state, .draft)
        XCTAssertEqual(draftOnly.calls.map(\.model), [.b0_8])
        XCTAssertEqual(b.modelPlan?.isDraftOnly, true)
        XCTAssertEqual(b.activity.plan?.notice?.contains("仕上げモデル"), true)

        let none = TranslationFakeBackend(installed: [])
        let c = F.coordinator(none)
        XCTAssertEqual(c.process(snapshot: snapshot, settings: F.settings()).first?.state, .failed)
        XCTAssertTrue(none.calls.isEmpty)

        let noDraft = TranslationFakeBackend()
        let d = F.coordinator(noDraft)
        d.process(snapshot: snapshot, settings: F.settings(draft: nil))
        _ = await F.waitUntil { d.items(for: snapshot.key).first?.state == .final }
        XCTAssertEqual(noDraft.calls.map(\.model), [.b2])
    }

    @MainActor
    func testRetryOnceThenBackOffThenRetry() async throws {
        let backend = TranslationFakeBackend(latency: [.b2: 0.01])
        // A back-off long enough for a loaded machine to see the failed state and look for early retries inside it.
        var configuration = F.configuration()
        configuration.retryBackoff = 1
        configuration.maxRetryBackoff = 2
        let coordinator = TranslationCoordinator(
            backend: backend, cache: TranslationCache(capacity: 1000, fileURL: nil), configuration: configuration,
            frontmostPID: { 100 })
        let flaky = "Flaky sentence fails once"
        let broken = "Broken sentence fails twice"
        backend.fail(flaky, times: 1)
        backend.fail(broken, times: 2)
        let snapshot = F.snapshot([flaky, broken])
        // The latest moment `broken` was seen not failed yet; its back-off ends more than `retryBackoff` after it.
        var notFailedYet = Date()
        coordinator.process(snapshot: snapshot, settings: F.settings(draft: nil))

        _ = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        XCTAssertEqual(backend.calls(for: flaky).count, 2)
        let failed = await F.waitUntil {
            let now = Date()
            guard coordinator.items(for: snapshot.key).last?.state == .failed else {
                notFailedYet = now
                return false
            }
            return true
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(backend.calls(for: broken).count, 2)
        try await sleep(0.3)
        let attempts = backend.calls(for: broken).count
        if Date() < notFailedYet.addingTimeInterval(configuration.retryBackoff) {
            XCTAssertEqual(attempts, 2, "no attempts during back-off")
        }
        let recovered = await F.waitUntil { coordinator.items(for: snapshot.key).last?.state == .final }
        XCTAssertTrue(recovered, "retried after back-off without a new scan")
        XCTAssertNil(coordinator.activity.lastError)
    }

    @MainActor
    func testTranslateOnceUsesCacheAndJumpsTheQueue() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.02, .b2: 0.2])
        let coordinator = F.coordinator(backend)
        let settings = F.settings(draft: nil)
        let one = "Background sentence one"
        let two = "Background sentence two"
        let manual = "Manual selection text"
        let background = F.snapshot([one, two])
        // The latest moment the first background call had not reached the backend yet; it sleeps until more
        // than 0.2 s after it.
        var notCalledYet = Date()
        coordinator.process(snapshot: background, settings: settings)
        let calling = await F.waitUntil {
            let now = Date()
            guard backend.calls.isEmpty else { return true }
            notCalledYet = now
            return false
        }
        XCTAssertTrue(calling)

        let started = Date()
        let result = await coordinator.translateOnce(text: "  Manual   selection\ttext ", settings: settings)
        XCTAssertEqual(result, "[2b] Manual selection text")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // The request is queued right after `started`. Only if that is while the background call still sleeps
        // can it preempt the call instead of finding it already done.
        let preemptible = started.timeIntervalSince(notCalledYet) < 0.15
        if preemptible {
            XCTAssertEqual(
                backend.completedCalls.first?.request.text, manual, "manual request preempts background work")
        }
        let cached = await coordinator.translateOnce(text: manual, settings: settings)
        XCTAssertEqual(cached, result)
        XCTAssertEqual(backend.calls(for: manual).count, 1, "served from the cache")
        let done = await F.waitUntil { coordinator.items(for: background.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done, "preempted background work resumes")
        let texts = backend.calls.map(\.request.text)
        XCTAssertLessThan(texts.firstIndex(of: manual) ?? .max, texts.firstIndex(of: two) ?? .max, "\(texts)")
        if preemptible { XCTAssertEqual(texts, [one, manual, one, two], "the preempted call runs again") }
        let empty = await coordinator.translateOnce(text: "   ", settings: settings)
        XCTAssertNil(empty)
    }

    @MainActor
    func testLongTextIsChunkedAndJoined() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let paragraph = String(repeating: "Chunked paragraph sentence for the test. ", count: 12)
            .trimmingCharacters(in: .whitespaces)
        let snapshot = F.snapshot([[paragraph, paragraph, paragraph].joined(separator: "\n\n")])
        coordinator.process(snapshot: snapshot, settings: F.settings(draft: nil))
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        XCTAssertEqual(backend.calls.count, 3)
        XCTAssertTrue(backend.calls.allSatisfy { $0.request.text.count <= 800 })
        XCTAssertEqual(
            coordinator.items(for: snapshot.key).first?.translation,
            [String](repeating: "[2b] " + paragraph, count: 3).joined(separator: "\n\n"))
    }

    @MainActor
    func testLongUpgradeYieldsToNewTextBetweenChunksAndResumes() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.02, .b2: 0.3])
        let coordinator = F.coordinator(backend)
        let paragraphs = ["Alpha", "Bravo", "Charlie"].map {
            String(repeating: "\($0) paragraph sentence for the upgrade test. ", count: 10)
                .trimmingCharacters(in: .whitespaces)
        }
        let long = paragraphs.joined(separator: "\n\n")
        let fresh = "A fresh message that just arrived"
        coordinator.process(snapshot: F.snapshot([long]), settings: F.settings())
        // The draft takes three chunks; the fourth call is the first chunk of the final upgrade.
        _ = await F.waitUntil { backend.calls.count >= 4 }
        let snapshot = F.snapshot([long, fresh])
        coordinator.process(snapshot: snapshot, settings: F.settings())
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)

        let calls = backend.calls.map { "\($0.model.rawValue) \($0.request.text.prefix(5))" }
        XCTAssertEqual(
            calls,
            [
                "0.8b Alpha", "0.8b Bravo", "0.8b Charl", "2b Alpha",
                "0.8b A fre",  // drafted before the rest of the upgrade
                "2b Bravo", "2b Charl",  // resumed after the finished chunk
                "2b A fre",
            ])
        XCTAssertEqual(
            coordinator.items(for: snapshot.key).first?.translation,
            paragraphs.map { TranslationFakeBackend.output(for: $0, model: .b2) }.joined(separator: "\n\n"))
        XCTAssertNil(coordinator.activity.lastError)
    }

    @MainActor
    func testSourceLanguageIsPartOfTheCacheKey() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let snapshot = F.snapshot(["Source language hint sentence"])
        let automatic = F.settings(draft: nil)
        let english = F.settings(draft: nil) { $0.global.sourceLanguage = " en " }
        coordinator.process(snapshot: snapshot, settings: automatic)
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }

        XCTAssertEqual(coordinator.process(snapshot: snapshot, settings: english).map(\.state), [.pending])
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls.map(\.request.sourceLanguage), [nil, "en"])
        XCTAssertEqual(coordinator.process(snapshot: snapshot, settings: automatic).map(\.state), [.final])
        let manual = await coordinator.translateOnce(text: "Source language hint sentence", settings: english)
        XCTAssertEqual(manual, TranslationFakeBackend.output(for: "Source language hint sentence", model: .b2))
        XCTAssertEqual(backend.calls.count, 2, "both translations are cached separately")
    }

    @MainActor
    func testRequestCarriesTargetFormContextAndRelevantGlossary() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let settings = F.settings(draft: nil) {
            $0.global.japaneseForm = .polite
            $0.global.glossary = [
                GlossaryTerm(source: "PR", target: "プルリクエスト"), GlossaryTerm(source: "unused", target: "未使用"),
            ]
            $0.profile.context = "Slack conversation <|plamo:tag|> between engineers"
        }
        let snapshot = F.snapshot(["Please merge the PR today"])
        coordinator.process(snapshot: snapshot, settings: settings)
        _ = await F.waitUntil { !backend.calls.isEmpty }
        let request = try XCTUnwrap(backend.calls.first?.request)
        XCTAssertEqual(request.targetLanguage, "ja")
        XCTAssertEqual(request.form, "polite")
        XCTAssertEqual(request.glossary.map(\.source), ["PR"])
        XCTAssertEqual(request.context?.contains("<|plamo:"), false)
        XCTAssertEqual(request.context?.contains("engineers"), true)
        XCTAssertGreaterThanOrEqual(request.maxNewTokens, 64)
        coordinator.cancelAll()

        let easy = TranslationFakeBackend()
        let e = F.coordinator(easy)
        e.process(snapshot: snapshot, settings: F.settings(target: "ja(easy)", draft: nil) { $0.global.japaneseForm = .plain })
        _ = await F.waitUntil { !easy.calls.isEmpty }
        XCTAssertNil(easy.calls.first?.request.form)
        e.cancelAll()
    }

    @MainActor
    func testGlossaryTermsWithoutTargetAreNeverSent() async throws {
        // PLaMo rejects an empty glossary target, which would fail every text containing the source forever.
        let dropped = TranslationRequestFactory.sanitizedGlossary([
            GlossaryTerm(source: "deploy", target: ""), GlossaryTerm(source: "PR", target: " \n "),
            GlossaryTerm(source: "LGTM", target: "承認"),
        ])
        XCTAssertEqual(dropped.map(\.source), ["LGTM"])

        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        var settings = F.settings(draft: nil)
        settings.profile.glossary = [GlossaryTerm(source: "deploy", target: "")]
        coordinator.process(snapshot: F.snapshot(["Please redeploy the service"]), settings: settings)
        _ = await F.waitUntil { !backend.calls.isEmpty }
        XCTAssertEqual(backend.calls.first?.request.glossary.count, 0)
        coordinator.cancelAll()
    }

    @MainActor
    func testCacheCapacityCoversWhatIsOnScreen() {
        let backend = TranslationFakeBackend(latency: [.b0_8: 5, .b2: 5])
        let cache = TranslationCache(capacity: 1000, fileURL: nil)
        let coordinator = F.coordinator(backend, cache: cache)
        var settings = F.settings()
        settings.global.cacheCapacity = 1000
        settings.global.maxSegmentsPerScan = 600
        let texts = (0..<600).map { "Visible sentence number \($0) on screen" }
        coordinator.process(snapshot: F.snapshot(texts), settings: settings)
        XCTAssertGreaterThanOrEqual(cache.capacity, 2 * 600, "two models per visible text fit in the cache")
        coordinator.forget(window: F.snapshot([]).key)
        coordinator.process(snapshot: F.snapshot(["Only one sentence now"], window: 2), settings: settings)
        XCTAssertEqual(cache.capacity, 1000, "back to the setting once the texts left the screen")
        coordinator.cancelAll()
    }

    @MainActor
    func testEachWindowUsesItsAppsProgressiveSetting() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.005, .b2: 0.01])
        let front = FrontmostBox(100)
        let coordinator = TranslationCoordinator(
            backend: backend, cache: TranslationCache(capacity: 1000, fileURL: nil), configuration: F.configuration(),
            frontmostPID: { front.pid })
        let chat = "A chat message in a two-stage app"
        let terminal = "Build log line from a single-stage app"
        let optIn = "An app that turns staging on by itself"
        let twoStage = F.settings()
        let singleStage = F.settings { $0.profile.progressiveOverride = false }
        let forcedOn = F.settings(draft: nil) { $0.profile.progressiveOverride = true }
        let windows = [
            (F.snapshot([chat], pid: 100, window: 1), twoStage),
            (F.snapshot([terminal], pid: 200, window: 2), singleStage),
            (F.snapshot([optIn], pid: 300, window: 3), forcedOn),
        ]
        for (snapshot, settings) in windows { coordinator.process(snapshot: snapshot, settings: settings) }
        let done = await F.waitUntil {
            windows.allSatisfy { snapshot, _ in coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls(for: chat).map(\.model), [.b0_8, .b2])
        XCTAssertEqual(backend.calls(for: terminal).map(\.model), [.b2], "the app's override turns drafts off")
        XCTAssertEqual(backend.calls(for: optIn).map(\.model), [.b0_8, .b2], "the app's override turns drafts on")

        // The status describes the frontmost app's plan.
        XCTAssertEqual(coordinator.modelPlan?.draft, .b0_8)
        front.pid = 200
        XCTAssertNil(coordinator.modelPlan?.draft)
        XCTAssertEqual(coordinator.modelPlan?.isTwoStage, false)

        // Manual translation follows the app's plan too.
        let manual = await coordinator.translateOnce(text: "Manual text for the terminal app", settings: singleStage)
        XCTAssertEqual(manual, TranslationFakeBackend.output(for: "Manual text for the terminal app", model: .b2))
        coordinator.cancelAll()
    }

    @MainActor
    func testDraftNoticeOnlyForAppsThatDraft() {
        let backend = TranslationFakeBackend(installed: [.b2])
        let front = FrontmostBox(200)
        let coordinator = TranslationCoordinator(
            backend: backend, cache: TranslationCache(capacity: 1000, fileURL: nil), configuration: F.configuration(),
            frontmostPID: { front.pid })
        coordinator.process(snapshot: F.snapshot(["Chat text"], pid: 100, window: 1), settings: F.settings())
        coordinator.process(
            snapshot: F.snapshot(["Terminal text"], pid: 200, window: 2),
            settings: F.settings { $0.profile.progressiveOverride = false })
        XCTAssertNil(coordinator.activity.plan?.notice, "the frontmost app does not use a draft model")
        front.pid = 100
        coordinator.process(snapshot: F.snapshot(["Chat text"], pid: 100, window: 1), settings: F.settings())
        XCTAssertEqual(coordinator.activity.plan?.notice?.contains("下書きモデル"), true)
        coordinator.cancelAll()
    }

    @MainActor
    func testStyleAndLineFramesReachTheOverlayItems() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let style = TextStyleHint(
            fontSize: 14, lineHeight: 20, isMonospaced: true, textColor: RGBAColor(red: 0.9, green: 0.9, blue: 0.85))
        let lines = [CGRect(x: 10, y: 100, width: 380, height: 20), CGRect(x: 10, y: 120, width: 210, height: 20)]
        var snapshot = F.snapshot(["Styled sentence that wraps onto two lines", "Plain sentence without hints"])
        snapshot.segments[0].style = style
        snapshot.segments[0].lineFrames = lines

        let initial = coordinator.process(snapshot: snapshot, settings: F.settings())
        XCTAssertEqual(initial.first?.style, style)
        XCTAssertEqual(initial.first?.lineFrames, lines)
        XCTAssertEqual(initial.last?.style, TextStyleHint())
        XCTAssertEqual(initial.last?.lineFrames, [])
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)
        XCTAssertEqual(coordinator.items(for: snapshot.key).first?.style, style)
        XCTAssertEqual(coordinator.items(for: snapshot.key).first?.lineFrames, lines)
    }

    @MainActor
    func testSkippedTextsAndSnapshotObstaclesStayVisible() {
        let coordinator = F.coordinator(TranslationFakeBackend())
        let ja = "今日は良い天気ですね。散歩に行きましょう。"
        let en = "The weather is nice today, let's go for a walk."
        var snapshot = F.snapshot([en, ja, "12:30"])
        let lines = [CGRect(x: 0, y: 24, width: 380, height: 10), CGRect(x: 0, y: 34, width: 120, height: 10)]
        snapshot.segments[1].lineFrames = lines
        let name = CGRect(x: 0, y: 70, width: 60, height: 14)
        snapshot.obstacles = [name]

        let items = coordinator.process(snapshot: snapshot, settings: F.settings())
        XCTAssertEqual(items.map(\.original), [en])
        // The Japanese paragraph (its lines), the filtered time and the snapshot's own obstacles.
        let obstacles = coordinator.obstacles(for: snapshot.key)
        let expected = [name] + lines + [snapshot.segments[2].axFrame]
        XCTAssertEqual(obstacles.count, expected.count)
        for rect in expected { XCTAssertTrue(obstacles.contains(rect), "\(rect)") }
        // Translated texts are never obstacles.
        XCTAssertFalse(coordinator.obstacles(for: snapshot.key).contains(snapshot.segments[0].axFrame))
        coordinator.forget(window: snapshot.key)
        XCTAssertEqual(coordinator.obstacles(for: snapshot.key), [])
        coordinator.cancelAll()
    }

    @MainActor
    func testForgetAndCancelAllStopWork() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.1, .b2: 0.1])
        let coordinator = F.coordinator(backend)
        let snapshot = F.snapshot(["Forget me sentence", "Another sentence here"])
        coordinator.process(snapshot: snapshot, settings: F.settings())
        _ = await F.waitUntil { backend.calls.count >= 1 }
        coordinator.forget(window: snapshot.key)
        try await sleep(0.3)
        XCTAssertEqual(backend.calls.count, 1)
        XCTAssertTrue(backend.completedCalls.isEmpty)
        XCTAssertTrue(coordinator.items(for: snapshot.key).isEmpty)

        coordinator.process(snapshot: snapshot, settings: F.settings())
        _ = await F.waitUntil { backend.calls.count >= 2 }
        let pending = Task { await coordinator.translateOnce(text: "Queued manual text", settings: F.settings()) }
        try await sleep(0.01)
        coordinator.cancelAll()
        let manual = await pending.value
        XCTAssertNil(manual)
        try await sleep(0.3)
        XCTAssertTrue(backend.completedCalls.isEmpty)

        XCTAssertTrue(coordinator.process(snapshot: snapshot, settings: F.settings { $0.profile.mode = .off }).isEmpty)
    }
}
