import XCTest

@testable import Plamonic

final class TranslationCacheTests: XCTestCase {
    private func key(_ text: String, model: ModelSize = .b2) -> TranslationKey {
        TranslationKey(text: text, targetLanguage: "ja", form: nil, context: "", glossaryFingerprint: "", model: model)
    }

    private func waitForFile(_ url: URL, exists: Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) == exists { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: url.path) == exists
    }

    func testPersistenceRoundTrip() throws {
        let url = TranslationTestFixtures.temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = TranslationCache(capacity: 10, fileURL: url, persistenceEnabled: true, writeDelay: 0.05)
        let glossary = [GlossaryTerm(source: "PR", target: "プルリクエスト")]
        let subject = TranslationSubject(
            text: "Hello", targetLanguage: "ja", form: "polite", context: "chat",
            glossaryFingerprint: TranslationSubject.fingerprint(of: glossary))
        let other = TranslationSubject(text: "Bye", targetLanguage: "ja", form: nil, context: "", glossaryFingerprint: "")
        var fromEnglish = other
        fromEnglish.sourceLanguage = "en"
        cache.store("こんにちは（下書き）", for: subject.key(for: .b0_8))
        cache.store("こんにちは。", for: subject.key(for: .b2))
        cache.store("さようなら", for: other.key(for: .b2))
        cache.store("さようなら（英語から）", for: fromEnglish.key(for: .b2))
        _ = cache.lookup(subject.key(for: .b0_8))

        XCTAssertTrue(waitForFile(url, exists: true), "debounced write")
        cache.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reloaded = TranslationCache(capacity: 10, fileURL: url, persistenceEnabled: true)
        reloaded.waitUntilLoaded()
        XCTAssertEqual(reloaded.count, 4)
        XCTAssertEqual(reloaded.peek(fromEnglish.key(for: .b2))?.translation, "さようなら（英語から）")
        XCTAssertEqual(reloaded.peek(other.key(for: .b2))?.translation, "さようなら", "source language is part of the key")
        XCTAssertEqual(reloaded.allEntries().map(\.key), cache.allEntries().map(\.key), "LRU order preserved")
        let best = try XCTUnwrap(reloaded.best(for: subject, finalModel: .b2, draftModel: .b0_8))
        XCTAssertEqual(best.translation, "こんにちは。")
        XCTAssertTrue(best.isFinal)
        let draft = try XCTUnwrap(reloaded.best(for: subject, finalModel: .b8, draftModel: .b0_8))
        XCTAssertEqual(draft.model, .b0_8)
        XCTAssertFalse(draft.isFinal)
        XCTAssertEqual(
            try XCTUnwrap(reloaded.peek(other.key(for: .b2))).timestamp.timeIntervalSince1970,
            try XCTUnwrap(cache.peek(other.key(for: .b2))).timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testFlushClearAndDisablingPersistence() {
        let url = TranslationTestFixtures.temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = TranslationCache(capacity: 10, fileURL: url, persistenceEnabled: true, writeDelay: 60)
        cache.store("a", for: key("a"))
        cache.flush()
        let reader = TranslationCache(capacity: 10, fileURL: url)
        reader.waitUntilLoaded()
        XCTAssertEqual(reader.count, 1, "flush writes immediately")

        cache.clear()
        cache.flush()
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        cache.store("b", for: key("b"))
        cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        cache.isPersistenceEnabled = false
        cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "turning persistence off deletes the file")
        cache.store("c", for: key("c"))
        cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoadDoesNotOverrideNewerEntries() {
        let url = TranslationTestFixtures.temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = TranslationCache(capacity: 10, fileURL: url, writeDelay: 60)
        writer.store("old", for: key("a"))
        writer.store("kept", for: key("b"))
        writer.flush()

        // The background load started by init may run before or after this store; either way the
        // newer entry wins, and so it does for the explicit load.
        let cache = TranslationCache(capacity: 10, fileURL: url, writeDelay: 60)
        cache.store("new", for: key("a"))
        cache.load()
        cache.waitUntilLoaded()
        XCTAssertEqual(cache.peek(key("a"))?.translation, "new")
        XCTAssertEqual(cache.peek(key("b"))?.translation, "kept")
    }

    func testStartingWithPersistenceOffDeletesTheFile() {
        let url = TranslationTestFixtures.temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = TranslationCache(capacity: 10, fileURL: url, writeDelay: 60)
        writer.store("a", for: key("a"))
        writer.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // E.g. the setting was turned off and the app quit before the cache saw the change.
        let cache = TranslationCache(capacity: 10, fileURL: url, persistenceEnabled: false)
        cache.waitUntilLoaded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(cache.count, 0)
    }

    func testClearWinsOverThePendingInitialLoad() {
        let url = TranslationTestFixtures.temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = TranslationCache(capacity: 10, fileURL: url, writeDelay: 60)
        writer.store("a", for: key("a"))
        writer.flush()

        let cache = TranslationCache(capacity: 10, fileURL: url, writeDelay: 60)
        cache.clear()
        cache.waitUntilLoaded()
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLRUEvictionAndCapacity() {
        let cache = TranslationCache(capacity: 2, fileURL: nil)
        cache.store("a", for: key("a"))
        cache.store("b", for: key("b"))
        _ = cache.lookup(key("a"))
        cache.store("c", for: key("c"))
        XCTAssertTrue(cache.contains(key("a")))
        XCTAssertFalse(cache.contains(key("b")))
        XCTAssertTrue(cache.contains(key("c")))
        cache.capacity = 1
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.contains(key("c")))
    }

    func testBestPrefersFinalThenDraftThenLargestOther() {
        let cache = TranslationCache(capacity: 10, fileURL: nil)
        let subject = key("x").subject
        cache.store("small", for: subject.key(for: .b0_8))
        cache.store("large", for: subject.key(for: .b8))
        XCTAssertEqual(cache.best(for: subject, finalModel: .b2, draftModel: nil)?.translation, "large")
        XCTAssertEqual(cache.best(for: subject, finalModel: .b2, draftModel: .b0_8)?.translation, "small")
        cache.store("final", for: subject.key(for: .b2))
        let best = cache.best(for: subject, finalModel: .b2, draftModel: .b0_8)
        XCTAssertEqual(best?.translation, "final")
        XCTAssertEqual(best?.isFinal, true)
    }

    func testThreadSafety() {
        let cache = TranslationCache(capacity: 500, fileURL: nil)
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            cache.store("t\(index)", for: key("k\(index % 700)"))
            _ = cache.lookup(key("k\((index * 7) % 700)"))
        }
        XCTAssertEqual(cache.count, 500)
        XCTAssertEqual(cache.allEntries().count, 500)
    }

    func testGlossaryFingerprintIsStableAndOrderSensitive() {
        let a = GlossaryTerm(source: "PR", target: "プルリクエスト")
        let b = GlossaryTerm(source: "deploy", target: "デプロイ")
        XCTAssertEqual(TranslationSubject.fingerprint(of: []), "")
        XCTAssertEqual(TranslationSubject.fingerprint(of: [a, b]), TranslationSubject.fingerprint(of: [a, b]))
        XCTAssertNotEqual(TranslationSubject.fingerprint(of: [a, b]), TranslationSubject.fingerprint(of: [b, a]))
        // Fixed FNV-1a value: persisted keys must keep matching across launches.
        XCTAssertEqual(TranslationSubject.fingerprint(of: [a]), "b6a8c08b2cc23d41")
    }
}
