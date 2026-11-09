import XCTest

@testable import Plamonic

private typealias F = TranslationTestFixtures
private typealias Item = TranslationCoordinator.ExternalItem
private typealias Key = TranslationCoordinator.ExternalDocumentKey

/// Browser extension documents in TranslationCoordinator (DESIGN §9).
final class TranslationDocumentTests: XCTestCase {
    private let key = Key(client: "chrome", id: "yt:video")

    private func items(_ texts: [String]) -> [Item] {
        texts.enumerated().map { Item(id: "c\($0.offset)", text: $0.element) }
    }

    private func captionSettings(draft: ModelSize? = .b0_8) -> EffectiveSettings {
        BridgeService.documentSettings(
            global: F.settings(draft: draft).global, kind: "captions", context: "", sourceLanguage: nil)
    }

    private static let captions = [
        "So in college, I was a government major.",
        "Which means I had to write a lot of papers.",
        "Now, when a normal student writes a paper,",
        "they might spread the work out a little like this.",
        "So, you know, you get started maybe a little slowly,",
        "but you get enough done in the first week.",
    ]

    @MainActor
    func testUrgentCaptionsGoFirstAndReadingAheadWaitsForTheScreen() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        XCTAssertTrue(
            coordinator.updateDocument(
                key, items: items(Self.captions), focus: "c2", urgentCount: 2, settings: captionSettings()))
        let window = F.snapshot(["Window text number one", "Window text number two"])
        coordinator.process(snapshot: window, settings: F.settings())

        let done = await F.waitUntil {
            coordinator.documentResults(self.key, ids: ["c5"])?.first?.state == .final
                && coordinator.items(for: window.key).allSatisfy { $0.state == .final }
        }
        XCTAssertTrue(done)
        // Captions with history are tried again without it when the fake's English output "looks wrong" for
        // Japanese (TranslationRequestFactory.looksWrong), so count each job once.
        var order: [String] = []
        for call in backend.calls {
            let job = "\(call.model.rawValue) \(call.request.text)"
            if order.last != job { order.append(job) }
        }
        XCTAssertEqual(
            order,
            [
                "\(ModelSize.b0_8.rawValue) \(Self.captions[2])",
                "\(ModelSize.b0_8.rawValue) \(Self.captions[3])",
                "\(ModelSize.b0_8.rawValue) Window text number one",
                "\(ModelSize.b0_8.rawValue) Window text number two",
                "\(ModelSize.b2.rawValue) Window text number one",
                "\(ModelSize.b2.rawValue) Window text number two",
                "\(ModelSize.b2.rawValue) \(Self.captions[2])",
                "\(ModelSize.b2.rawValue) \(Self.captions[3])",
                "\(ModelSize.b2.rawValue) \(Self.captions[4])",
                "\(ModelSize.b2.rawValue) \(Self.captions[5])",
            ])
        // Texts before the focus have been shown already; nobody needs them.
        XCTAssertEqual(coordinator.documentResults(key, ids: ["c0", "c1"])?.map(\.state), [.pending, .pending])
        XCTAssertEqual(coordinator.documentProgress(key), .init(done: 4, total: 4))
    }

    @MainActor
    func testMovingTheFocusMovesTheUrgentTexts() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.05, .b2: 0.05])
        let coordinator = F.coordinator(backend)
        let settings = captionSettings(draft: nil)
        coordinator.updateDocument(key, items: items(Self.captions), focus: "c0", urgentCount: 1, settings: settings)
        let ready1 = await F.waitUntil { backend.calls.count == 1 }
        XCTAssertTrue(ready1)
        // Seek: the focus moves without sending the texts again.
        XCTAssertTrue(coordinator.updateDocument(key, items: nil, focus: "c4", urgentCount: 1, settings: settings))
        let ready2 = await F.waitUntil { backend.calls.count >= 2 }
        XCTAssertTrue(ready2)
        XCTAssertEqual(backend.calls.map(\.request.text).prefix(2), [Self.captions[0], Self.captions[4]])
    }

    /// A page says which paragraphs are on screen (a sticky header and the middle of the article, say): those go
    /// first in that order, then the rest after the first one, then the part above it.
    @MainActor
    func testAPageTranslatesWhatIsOnScreenFirstThenAllTheRest() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let settings = BridgeService.documentSettings(
            global: F.settings(draft: nil).global, kind: "page", context: "", sourceLanguage: nil)
        let paragraphs = (0..<8).map { "Paragraph number \($0) of the article." }
        coordinator.updateDocument(
            key, items: items(paragraphs), focus: "c0", urgentCount: 3, visible: ["c0", "c5", "c6"], readsAll: true,
            settings: settings)
        let done = await F.waitUntil { coordinator.documentResults(self.key)?.allSatisfy { $0.state == .final } == true }
        XCTAssertTrue(done)
        XCTAssertEqual(backend.calls.map(\.request.text), [0, 5, 6, 1, 2, 3, 4, 7].map { paragraphs[$0] })

        // Scrolled down: what is on screen now goes first, and the paragraphs above are read last.
        let other = Key(client: "chrome", id: "page-2")
        backend.respond { text, _ in "訳: \(text)" }
        let more = (0..<6).map { "Another page, paragraph \($0)." }
        coordinator.updateDocument(
            other, items: items(more), focus: "c3", urgentCount: 3, visible: ["c3", "c4"], readsAll: true,
            settings: settings)
        let all = await F.waitUntil { coordinator.documentResults(other)?.allSatisfy { $0.state == .final } == true }
        XCTAssertTrue(all)
        XCTAssertEqual(backend.calls.suffix(6).map(\.request.text), [3, 4, 5, 0, 1, 2].map { more[$0] })
        XCTAssertEqual(coordinator.documentProgress(other), .init(done: 6, total: 6))
    }

    @MainActor
    func testResultsCarryStatesAndSkipTextsInTheTargetLanguage() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let texts = ["This one is translated first.", "", "これは日本語の字幕です。翻訳は不要です。"]
        coordinator.updateDocument(key, items: items(texts), focus: nil, urgentCount: 3, settings: captionSettings())
        XCTAssertEqual(coordinator.documentResults(key)?.map(\.state), [.pending, .skipped, .skipped])
        let ready3 = await F.waitUntil { coordinator.documentResults(self.key)?.first?.state == .final }
        XCTAssertTrue(ready3)
        let first = try XCTUnwrap(coordinator.documentResults(key, ids: ["c0"])?.first)
        XCTAssertEqual(first.translation, TranslationFakeBackend.output(for: texts[0], model: .b2))
        XCTAssertEqual(backend.calls.map(\.request.text), [texts[0], texts[0]])
    }

    @MainActor
    func testAnUnknownDocumentNeedsItsTexts() {
        let coordinator = F.coordinator(TranslationFakeBackend())
        XCTAssertFalse(coordinator.updateDocument(key, items: nil, focus: nil, urgentCount: 1, settings: captionSettings()))
        XCTAssertNil(coordinator.documentResults(key))
        XCTAssertTrue(
            coordinator.updateDocument(key, items: items(["Hello there"]), focus: nil, urgentCount: 1, settings: captionSettings()))
        XCTAssertTrue(coordinator.updateDocument(key, items: nil, focus: nil, urgentCount: 1, settings: captionSettings()))
        // Documents of another browser are separate.
        XCTAssertNil(coordinator.documentResults(Key(client: "safari", id: key.id)))
    }

    @MainActor
    func testClosingADocumentStopsItsWork() async throws {
        let backend = TranslationFakeBackend(latency: [.b0_8: 0.3, .b2: 0.3])
        let coordinator = F.coordinator(backend)
        coordinator.updateDocument(key, items: items(Self.captions), focus: nil, urgentCount: 6, settings: captionSettings())
        let ready4 = await F.waitUntil { backend.calls.count == 1 }
        XCTAssertTrue(ready4)
        coordinator.closeDocument(key)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(backend.calls.count, 1)
        XCTAssertTrue(backend.completedCalls.isEmpty)
        XCTAssertNil(coordinator.documentResults(key))
    }

    @MainActor
    func testCaptionsSendThePreviousLinesAsHistoryAndPagesDoNot() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let settings = captionSettings(draft: nil)
        coordinator.updateDocument(key, items: items(Array(Self.captions.prefix(3))), focus: nil, urgentCount: 3, settings: settings)
        let ready5 = await F.waitUntil { coordinator.documentResults(self.key)?.allSatisfy { $0.state == .final } == true }
        XCTAssertTrue(ready5)
        let third = try XCTUnwrap(backend.calls(for: Self.captions[2]).first)
        XCTAssertEqual(third.request.history.map(\.source), Array(Self.captions.prefix(2)))

        let page = Key(client: "chrome", id: "page")
        let pageSettings = BridgeService.documentSettings(
            global: F.settings(draft: nil).global, kind: "page", context: "", sourceLanguage: nil)
        let paragraphs = ["First paragraph of the page.", "Second paragraph of the page."]
        coordinator.updateDocument(page, items: items(paragraphs), focus: nil, urgentCount: 2, settings: pageSettings)
        let ready6 = await F.waitUntil { coordinator.documentResults(page)?.allSatisfy { $0.state == .final } == true }
        XCTAssertTrue(ready6)
        XCTAssertEqual(try XCTUnwrap(backend.calls(for: paragraphs[1]).first).request.history, [])
    }

    @MainActor
    func testTheSourceLanguageAndContextReachTheModel() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let settings = BridgeService.documentSettings(
            global: F.settings(draft: nil).global, kind: "captions", context: "TED: Tim Urban", sourceLanguage: "en-US")
        coordinator.updateDocument(key, items: items(["Hello there, everyone."]), focus: nil, urgentCount: 1, settings: settings)
        let ready7 = await F.waitUntil { !backend.completedCalls.isEmpty }
        XCTAssertTrue(ready7)
        let request = try XCTUnwrap(backend.calls.first?.request)
        XCTAssertEqual(request.sourceLanguage, "en")
        XCTAssertEqual(request.context, "TED: Tim Urban")
    }
}
