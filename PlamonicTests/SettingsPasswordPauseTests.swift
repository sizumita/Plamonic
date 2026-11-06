import XCTest

@testable import Plamonic

/// パスワード入力中は読み取らない (`GlobalSettings.pauseDuringPasswordEntry`): default, round trip, lenient
/// loading of older files and the footer (DESIGN §4.1).
@MainActor
final class SettingsPasswordPauseTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsPasswordPauseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ json: String) throws -> SettingsStore {
        try Data(json.utf8).write(to: fileURL)
        return SettingsStore(fileURL: fileURL, saveDelay: 10)
    }

    func testOnByDefault() {
        XCTAssertTrue(GlobalSettings().pauseDuringPasswordEntry)
        XCTAssertTrue(SettingsStore(fileURL: fileURL, saveDelay: 10).global.pauseDuringPasswordEntry)
        XCTAssertTrue(SettingsNormalizer.normalized(GlobalSettings()).pauseDuringPasswordEntry)
    }

    func testOlderFilesWithoutTheKeyTurnItOn() throws {
        XCTAssertTrue(try load("{}").global.pauseDuringPasswordEntry)
        XCTAssertTrue(try load(#"{"global": {}}"#).global.pauseDuringPasswordEntry)
        let older = try load(#"{"global": {"targetLanguage": "ko", "hideWhileScrolling": false}}"#)
        XCTAssertEqual(older.loadReport.source, .file)
        XCTAssertEqual(older.loadReport.problems, [])
        XCTAssertTrue(older.global.pauseDuringPasswordEntry)
        XCTAssertEqual(older.global.targetLanguage, "ko")
        XCTAssertFalse(older.global.hideWhileScrolling)
    }

    func testOffRoundTrips() throws {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal { $0.pauseDuringPasswordEntry = false }
        store.flush()

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let global = try XCTUnwrap(json["global"] as? [String: Any])
        XCTAssertEqual(global["pauseDuringPasswordEntry"] as? Bool, false)

        let reloaded = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(reloaded.loadReport.source, .file)
        XCTAssertEqual(reloaded.document, store.document)
        XCTAssertFalse(reloaded.global.pauseDuringPasswordEntry)
    }

    func testBothValuesRoundTripThroughTheEncoder() throws {
        for value in [true, false] {
            var doc = SettingsDocument()
            doc.global.pauseDuringPasswordEntry = value
            let decoded = try JSONDecoder().decode(SettingsDocument.self, from: SettingsStore.encode(doc))
            XCTAssertEqual(decoded.global.pauseDuringPasswordEntry, value)
            XCTAssertEqual(decoded, doc)
        }
    }

    func testDamagedValueIsDroppedAloneAndStaysOn() throws {
        let store = try load(#"{"global": {"targetLanguage": "ko", "pauseDuringPasswordEntry": "sometimes"}}"#)
        XCTAssertEqual(store.loadReport.source, .salvaged)
        XCTAssertTrue(store.loadReport.problems.contains("global.pauseDuringPasswordEntry"))
        XCTAssertEqual(store.global.targetLanguage, "ko")
        XCTAssertTrue(store.global.pauseDuringPasswordEntry)
    }

    func testNormalizerAndResetKeepTheDefault() {
        var off = GlobalSettings()
        off.pauseDuringPasswordEntry = false
        XCTAssertFalse(SettingsNormalizer.normalized(off).pauseDuringPasswordEntry, "a choice is not a range")

        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal { $0.pauseDuringPasswordEntry = false }
        XCTAssertFalse(store.global.pauseDuringPasswordEntry)
        store.resetAll()
        XCTAssertTrue(store.global.pauseDuringPasswordEntry)
    }

    /// The footer says what counts as password entry, that translations stay and that the menu shows it.
    func testFooterExplainsWhatStops() {
        let text = GeneralSettingsPane.passwordPauseDescription
        XCTAssertTrue(text.contains("パスワード欄に入力しているとき"))
        XCTAssertTrue(text.contains("システムのパスワード画面"))
        XCTAssertTrue(text.contains("ターミナルでは、パスワードを待っているウインドウ"))
        XCTAssertTrue(text.contains("表示中の訳文はそのまま残ります。"))
        XCTAssertTrue(text.contains("止めていることは、メニューバーのメニューに表示します"))
        XCTAssertTrue(text.contains("パスワード欄の中身は、この設定に関係なく読み取りません"))
    }
}
