import XCTest

@testable import Plamonic

private typealias F = TranslationTestFixtures

/// Several jobs at a time (`maxConcurrentJobs`), so the engine can generate them in one batch.
final class TranslationConcurrencyTests: XCTestCase {
    @MainActor
    private func coordinator(
        _ backend: TranslationFakeBackend, concurrency: Int = 4, frontmost: pid_t? = 100
    ) -> TranslationCoordinator {
        var configuration = F.configuration()
        configuration.maxConcurrentJobs = concurrency
        return TranslationCoordinator(
            backend: backend, cache: TranslationCache(capacity: 1000, fileURL: nil), configuration: configuration,
            frontmostPID: { frontmost })
    }

    private static let texts = (1...6).map { "Concurrent message number \($0) for the batch" }

    @MainActor
    func testJobsWithOneModelRunTogether() async throws {
        let backend = TranslationFakeBackend(latency: [.b2: 0.08])
        let coordinator = coordinator(backend)
        let snapshot = F.snapshot(Self.texts)
        coordinator.process(snapshot: snapshot, settings: F.settings(draft: nil))
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.maxConcurrentCalls, 4)
        // Started in reading order, each text once (calls run on detached tasks, so they arrive in any order).
        let texts = backend.calls.map(\.request.text)
        XCTAssertEqual(texts.count, Self.texts.count)
        XCTAssertEqual(Set(texts.prefix(4)), Set(Self.texts.prefix(4)))
        XCTAssertEqual(Set(texts), Set(Self.texts))
        for item in coordinator.items(for: snapshot.key) {
            XCTAssertEqual(item.translation, TranslationFakeBackend.output(for: item.original, model: .b2))
        }
        XCTAssertFalse(coordinator.activity.isBusy)
    }

    @MainActor
    func testDraftsAndUpgradesNeverRunTogether() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.03, .b2: 0.06])
        let coordinator = coordinator(backend)
        let snapshot = F.snapshot(Self.texts)
        coordinator.process(snapshot: snapshot, settings: F.settings())
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)
        XCTAssertFalse(backend.ranModelsTogether, "one batch, one model")
        XCTAssertEqual(backend.maxConcurrentCalls, 4)
        XCTAssertEqual(backend.calls.map(\.model), Array(repeating: .b0_8, count: 6) + Array(repeating: .b2, count: 6))
    }

    @MainActor
    func testNewTextIsDraftedBeforeMoreUpgradesStart() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.02, .b2: 0.15])
        let coordinator = coordinator(backend, concurrency: 2)
        let settings = F.settings()
        let first = Array(Self.texts.prefix(4))
        coordinator.process(snapshot: F.snapshot(first), settings: settings)
        let upgrading = await F.waitUntil { backend.calls.contains { $0.model == .b2 } }
        XCTAssertTrue(upgrading)
        let added = "A brand new message that arrived during the upgrades"
        coordinator.process(snapshot: F.snapshot(first + [added]), settings: settings)
        let drafted = await F.waitUntil { !backend.completedCalls.filter { $0.request.text == added }.isEmpty }
        XCTAssertTrue(drafted)
        // The running upgrades finish, but no further upgrade starts before the new text's draft.
        let calls = backend.calls
        let draftIndex = try XCTUnwrap(calls.firstIndex { $0.request.text == added })
        XCTAssertLessThanOrEqual(calls[..<draftIndex].filter { $0.model == .b2 }.count, 2, "\(calls.map(\.model))")
        XCTAssertFalse(backend.ranModelsTogether)
        coordinator.cancelAll()
    }

    @MainActor
    func testWindowWithHistoryTranslatesInOrder() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = coordinator(backend)
        let settings = F.settings(draft: nil) { $0.profile.useConversationHistory = true }
        let texts = Array(Self.texts.prefix(3))
        let snapshot = F.snapshot(texts)
        coordinator.process(snapshot: snapshot, settings: settings)
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)
        func pair(_ text: String) -> TranslationHistoryPair {
            TranslationHistoryPair(source: text, translation: TranslationFakeBackend.output(for: text, model: .b2))
        }
        XCTAssertEqual(backend.calls.map(\.request.history), [[], [pair(texts[0])], [pair(texts[0]), pair(texts[1])]])
        XCTAssertEqual(backend.maxConcurrentCalls, 1)
    }

    @MainActor
    func testManualRequestOfAnotherModelPreemptsTheBatch() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.3, .b2: 0.02])
        let coordinator = coordinator(backend)
        let snapshot = F.snapshot(Self.texts)
        let settings = F.settings()
        coordinator.process(snapshot: snapshot, settings: settings)
        let running = await F.waitUntil { backend.calls.count == 4 }
        XCTAssertTrue(running)

        let started = Date()
        let result = await coordinator.translateOnce(text: "Manual selection text", settings: settings)
        XCTAssertEqual(result, "[2b] Manual selection text")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "the drafts were cancelled, not awaited")
        XCTAssertFalse(backend.ranModelsTogether)

        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done, "the cancelled drafts run again")
    }

    @MainActor
    func testManualRequestJoinsARunningBatchOfItsModel() async throws {
        let backend = TranslationFakeBackend(latency: [.b2: 0.2])
        let coordinator = coordinator(backend)
        let snapshot = F.snapshot(Array(Self.texts.prefix(2)))
        let settings = F.settings(draft: nil)
        coordinator.process(snapshot: snapshot, settings: settings)
        _ = await F.waitUntil { backend.calls.count == 2 }

        let result = await coordinator.translateOnce(text: "Manual selection text", settings: settings)
        XCTAssertEqual(result, "[2b] Manual selection text")
        XCTAssertEqual(backend.maxConcurrentCalls, 3)
        XCTAssertEqual(backend.calls.count, 3, "nothing was cancelled")
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls.count, 3)
    }
}
