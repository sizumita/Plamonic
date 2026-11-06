import XCTest

@testable import Plamonic

/// ポインタとリンク settings (`GlobalSettings.interaction`): defaults, round trip, lenient loading,
/// clamping and when they apply (DESIGN §6.1).
@MainActor
final class SettingsInteractionTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsInteractionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ json: String) throws -> SettingsStore {
        try Data(json.utf8).write(to: fileURL)
        return SettingsStore(fileURL: fileURL, saveDelay: 10)
    }

    // MARK: - Footer

    /// The footer says the hover look differs for links that are underlined already (they only change color).
    func testLinksDescriptionMentionsAlreadyUnderlinedLinks() {
        let text = DisplaySettingsPane.linksDescription
        XCTAssertTrue(text.contains("カーソルが指の形になり、下線が出ます"))
        XCTAssertTrue(text.contains("もともと下線のあるリンクは色が少し変わります"))
        XCTAssertFalse(text.contains("濃く"))
    }

    // MARK: - Defaults

    func testDefaults() {
        let d = OverlayInteractionSettings()
        XCTAssertEqual(d.hoverOriginal, .popup)
        XCTAssertEqual(d.hoverDelay, 0.4)
        XCTAssertTrue(d.clickableLinks)
        XCTAssertEqual(GlobalSettings().interaction, d)
        XCTAssertTrue(SettingsLimits.hoverDelay.contains(d.hoverDelay))
        XCTAssertEqual(SettingsLimits.hoverDelay, 0.1...1.5)
        XCTAssertEqual(SettingsNormalizer.normalized(d), d)
        XCTAssertEqual(SettingsNormalizer.normalized(GlobalSettings()), GlobalSettings())
    }

    func testResetRestoresDefaults() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal {
            $0.interaction = OverlayInteractionSettings(hoverOriginal: .off, hoverDelay: 1, clickableLinks: false)
        }
        XCTAssertNotEqual(store.global.interaction, OverlayInteractionSettings())
        store.resetAll()
        XCTAssertEqual(store.global.interaction, OverlayInteractionSettings())
    }

    // MARK: - Round trip

    func testRoundTrip() throws {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal {
            $0.interaction = OverlayInteractionSettings(hoverOriginal: .popup, hoverDelay: 1.2, clickableLinks: false)
        }
        store.flush()

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let global = try XCTUnwrap(json["global"] as? [String: Any])
        let interaction = try XCTUnwrap(global["interaction"] as? [String: Any])
        XCTAssertEqual(interaction["hoverOriginal"] as? String, "popup")
        XCTAssertEqual(interaction["hoverDelay"] as? Double, 1.2)
        XCTAssertEqual(interaction["clickableLinks"] as? Bool, false)

        let reloaded = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(reloaded.loadReport.source, .file)
        XCTAssertEqual(reloaded.document, store.document)
        XCTAssertEqual(
            reloaded.global.interaction,
            OverlayInteractionSettings(hoverOriginal: .popup, hoverDelay: 1.2, clickableLinks: false))
    }

    func testEveryModeRoundTrips() throws {
        for mode in HoverOriginalMode.allCases {
            var doc = SettingsDocument()
            doc.global.interaction.hoverOriginal = mode
            let decoded = try JSONDecoder().decode(SettingsDocument.self, from: SettingsStore.encode(doc))
            XCTAssertEqual(decoded.global.interaction.hoverOriginal, mode)
        }
    }

    // MARK: - Lenient loading

    func testMissingKeysUseDefaults() throws {
        XCTAssertEqual(try load("{}").global.interaction, OverlayInteractionSettings())
        XCTAssertEqual(try load(#"{"global": {}}"#).global.interaction, OverlayInteractionSettings())
        XCTAssertEqual(try load(#"{"global": {"interaction": {}}}"#).global.interaction, OverlayInteractionSettings())

        let partial = try load(#"{"global": {"interaction": {"clickableLinks": false}}}"#)
        XCTAssertEqual(partial.loadReport.source, .file)
        XCTAssertEqual(partial.loadReport.problems, [])
        var expected = OverlayInteractionSettings()
        expected.clickableLinks = false
        XCTAssertEqual(partial.global.interaction, expected)
    }

    func testUnknownModeFallsBackToTheDefaultAndKeepsTheRest() throws {
        // A file from a newer version (or a typo) must not throw the other values away.
        let store = try load(
            #"{"global": {"targetLanguage": "ko", "interaction": {"hoverOriginal": "tooltip", "hoverDelay": 0.8, "clickableLinks": false}}}"#
        )
        XCTAssertEqual(store.loadReport.source, .file)
        XCTAssertEqual(store.global.targetLanguage, "ko")
        XCTAssertEqual(
            store.global.interaction,
            OverlayInteractionSettings(hoverOriginal: .popup, hoverDelay: 0.8, clickableLinks: false))
    }

    func testDamagedInteractionIsDroppedAlone() throws {
        let store = try load(#"{"global": {"targetLanguage": "ko", "interaction": {"hoverDelay": "slow"}}}"#)
        XCTAssertEqual(store.loadReport.source, .salvaged)
        XCTAssertTrue(store.loadReport.problems.contains("global.interaction"))
        XCTAssertEqual(store.global.targetLanguage, "ko")
        XCTAssertEqual(store.global.interaction, OverlayInteractionSettings())
    }

    func testOutOfRangeDelayIsClampedOnLoad() throws {
        XCTAssertEqual(try load(#"{"global": {"interaction": {"hoverDelay": 5}}}"#).global.interaction.hoverDelay, 1.5)
        XCTAssertEqual(try load(#"{"global": {"interaction": {"hoverDelay": 0}}}"#).global.interaction.hoverDelay, 0.1)
        XCTAssertEqual(try load(#"{"global": {"interaction": {"hoverDelay": -2}}}"#).global.interaction.hoverDelay, 0.1)
        let kept = try load(#"{"global": {"interaction": {"hoverOriginal": "off", "hoverDelay": 9}}}"#)
        XCTAssertEqual(kept.global.interaction.hoverOriginal, .off, "clamping keeps the other fields")
    }

    // MARK: - Normalization

    func testDelayIsClampedAndRounded() {
        func normalized(_ delay: Double) -> Double {
            var g = GlobalSettings()
            g.interaction.hoverDelay = delay
            return SettingsNormalizer.normalized(g).interaction.hoverDelay
        }
        XCTAssertEqual(normalized(0.01), 0.1)
        XCTAssertEqual(normalized(60), 1.5)
        XCTAssertEqual(normalized(.nan), SettingsLimits.hoverDelay.lowerBound)
        XCTAssertEqual(normalized(.infinity), SettingsLimits.hoverDelay.lowerBound)
        // Stepping by 0.1 accumulates binary noise; the file keeps the value the pane shows.
        XCTAssertEqual(normalized(0.7 + 0.1), 0.8)
        XCTAssertEqual(normalized(0.45), 0.45, "a hand-edited value inside the range stays")
        for tenth in 1...15 {
            let value = Double(tenth) / 10
            XCTAssertEqual(normalized(value), value)
        }
    }

    func testStoreClampsEdits() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal { $0.interaction.hoverDelay = 3 }
        XCTAssertEqual(store.global.interaction.hoverDelay, 1.5)
        store.updateGlobal { $0.interaction.hoverDelay = 0.6000000000000001 }
        XCTAssertEqual(store.global.interaction.hoverDelay, 0.6)
    }

    // MARK: - When the settings apply

    func testReplaceStyleInUse() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertTrue(store.snapshot.isReplaceStyleInUse)

        store.updateGlobal { $0.displayStyle = .hover }
        XCTAssertFalse(store.snapshot.isReplaceStyleInUse, "hover everywhere: the pointer and link settings do nothing")
        XCTAssertEqual(store.snapshot.appsOverridingDisplayStyle(to: .replace), [])

        store.updateProfile(bundleID: AppPresets.slackBundleID) { $0.displayStyleOverride = .replace }
        store.updateProfile(bundleID: "com.example.zeta", appName: "Zeta") { $0.displayStyleOverride = .replace }
        store.updateProfile(bundleID: "com.example.alpha", appName: "Alpha") { $0.displayStyleOverride = .hover }
        XCTAssertTrue(store.snapshot.isReplaceStyleInUse, "an app that draws over the original uses them")
        XCTAssertEqual(
            store.snapshot.appsOverridingDisplayStyle(to: .replace).map(\.bundleID),
            [AppPresets.slackBundleID, "com.example.zeta"])
        XCTAssertEqual(store.snapshot.appsOverridingDisplayStyle(to: .hover).map(\.displayName), ["Alpha"])

        XCTAssertTrue(store.resetToPreset(bundleID: AppPresets.slackBundleID))
        store.removeProfile(bundleID: "com.example.zeta")
        XCTAssertFalse(store.snapshot.isReplaceStyleInUse)
    }

    // MARK: - Labels

    func testLabels() {
        XCTAssertEqual(HoverOriginalMode.inPlace.settingsLabel, "その場で原文を見せる")
        XCTAssertEqual(HoverOriginalMode.popup.settingsLabel, "吹き出しで原文を見せる")
        XCTAssertEqual(HoverOriginalMode.off.settingsLabel, "何もしない")
        let descriptions = HoverOriginalMode.allCases.map(\.settingsDescription)
        XCTAssertEqual(Set(descriptions).count, HoverOriginalMode.allCases.count)
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
    }
}
