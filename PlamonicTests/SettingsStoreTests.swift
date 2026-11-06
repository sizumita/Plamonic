import Combine
import XCTest

@testable import Plamonic

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func quarantinedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("settings.corrupt-") }
    }

    func testMissingFileUsesDefaultsAndDoesNotWrite() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 0.05)
        XCTAssertEqual(store.loadReport.source, .defaults)
        XCTAssertEqual(store.document, SettingsDocument())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRoundTripAndDebouncedSave() async throws {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 0.05)
        store.updateGlobal {
            $0.targetLanguage = "en"
            $0.draftModel = nil
            $0.toggleHotkey = nil
            $0.glossary = [GlossaryTerm(source: "PLaMo", target: "PLaMo")]
        }
        var custom = store.profile(for: "com.example.editor", appName: "Editor")
        custom.mode = .automatic
        custom.targetLanguageOverride = "ja(easy)"
        store.upsert(custom)
        store.updateProfile(bundleID: AppPresets.slackBundleID) { $0.context = "edited" }

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "debounced save should have written")

        let reloaded = SettingsStore(fileURL: fileURL, saveDelay: 0.05)
        XCTAssertEqual(reloaded.loadReport.source, .file)
        XCTAssertEqual(reloaded.document, store.document)
        XCTAssertNil(reloaded.global.draftModel)
        XCTAssertNil(reloaded.global.toggleHotkey)
        XCTAssertEqual(reloaded.profile(for: "com.example.editor").targetLanguageOverride, "ja(easy)")
        XCTAssertEqual(reloaded.profile(for: AppPresets.slackBundleID).context, "edited")
    }

    func testFirstSaveOfSessionKeepsBackup() throws {
        let first = SettingsStore(fileURL: fileURL, saveDelay: 10)
        first.updateGlobal { $0.targetLanguage = "en" }
        first.flush()

        let second = SettingsStore(fileURL: fileURL, saveDelay: 10)
        second.updateGlobal { $0.targetLanguage = "fr" }
        second.flush()

        let backup = try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: second.backupURL))
        XCTAssertEqual(backup.global.targetLanguage, "en")
    }

    func testCorruptFileFallsBackToBackup() async throws {
        let first = SettingsStore(fileURL: fileURL, saveDelay: 10)
        first.updateGlobal { $0.targetLanguage = "en" }
        first.flush()
        let second = SettingsStore(fileURL: fileURL, saveDelay: 10)
        second.updateGlobal { $0.targetLanguage = "de" }
        second.flush()  // backs up the "en" file

        try Data("{ \"global\": { broken".utf8).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL, saveDelay: 0.05)
        XCTAssertEqual(store.loadReport.source, .backup)
        XCTAssertEqual(store.global.targetLanguage, "en")
        XCTAssertNotNil(store.loadReport.quarantinedFileURL)
        XCTAssertEqual(quarantinedFiles().count, 1)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "settings.json is re-created")
    }

    func testUnreadableFileIsNeverOverwritten() throws {
        let first = SettingsStore(fileURL: fileURL, saveDelay: 10)
        first.updateGlobal { $0.targetLanguage = "en" }
        first.flush()
        let second = SettingsStore(fileURL: fileURL, saveDelay: 10)
        second.updateGlobal {
            $0.targetLanguage = "de"
            $0.glossary = [GlossaryTerm(source: "PR", target: "プルリクエスト")]
        }
        second.flush()  // settings.json = de + glossary, settings.json.bak = en
        let original = try Data(contentsOf: fileURL)
        let originalBackup = try Data(contentsOf: second.backupURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: fileURL.path), "running with root privileges")

        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(store.loadReport.source, .unreadable)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.lastSaveError)
        XCTAssertEqual(store.global.targetLanguage, "en", "the backup is used while settings.json cannot be read")
        store.updateGlobal { $0.minTextLength = 7 }
        store.flush()
        XCTAssertNotNil(store.lastSaveError)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), originalBackup)
    }

    func testFailedBackupKeepsPreviousBackup() throws {
        let first = SettingsStore(fileURL: fileURL, saveDelay: 10)
        first.updateGlobal { $0.targetLanguage = "en" }
        first.flush()
        let second = SettingsStore(fileURL: fileURL, saveDelay: 10)
        second.updateGlobal { $0.targetLanguage = "de" }
        second.flush()  // settings.json.bak = en

        let third = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(third.loadReport.source, .file)
        // settings.json becomes unreadable after launch, so it cannot be copied to the backup.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: fileURL.path), "running with root privileges")
        third.updateGlobal { $0.targetLanguage = "fr" }
        third.flush()
        XCTAssertNil(third.lastSaveError)
        // The atomic write keeps the replaced file's permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let backup = try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: third.backupURL))
        XCTAssertEqual(backup.global.targetLanguage, "en")
        let saved = try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(saved.global.targetLanguage, "fr")
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.backupURL.appendingPathExtension("tmp").path))
    }

    func testGarbageWithoutBackupResetsToDefaults() throws {
        try Data("garbage".utf8).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(store.loadReport.source, .reset)
        XCTAssertEqual(store.document, SettingsDocument())
        XCTAssertEqual(quarantinedFiles().count, 1)
    }

    func testPartiallyValidFileIsSalvaged() throws {
        let json = """
            {"version": 1,
             "global": {"targetLanguage": "ko", "defaultMode": "sometimes", "minTextLength": 4},
             "profiles": [
               {"bundleID": "com.good.app", "displayName": "Good", "mode": "off"},
               {"bundleID": "com.bad.app", "mode": "never", "context": "kept"},
               {"displayName": "no bundle id"},
               42
             ]}
            """
        try Data(json.utf8).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(store.loadReport.source, .salvaged)
        XCTAssertEqual(store.global.targetLanguage, "ko")
        XCTAssertEqual(store.global.minTextLength, 4)
        XCTAssertEqual(store.global.defaultMode, GlobalSettings().defaultMode)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.userProfile(for: "com.good.app")?.mode, .off)
        XCTAssertEqual(store.userProfile(for: "com.bad.app")?.context, "kept")
        XCTAssertTrue(store.loadReport.problems.contains("global.defaultMode"))
    }

    func testPartialNestedObjectsKeepTheirOtherFields() throws {
        // Hand-edited (or written before a field existed): missing keys of rules and appearance take defaults.
        let json = """
            {"profiles": [{"bundleID": "a.b", "scope": "rules",
                           "rules": {"items": [{"domClassPrefixes": ["msg_"]}]}}],
             "global": {"appearance": {"theme": "dark"}}}
            """
        try Data(json.utf8).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(store.loadReport.source, .file)
        XCTAssertEqual(store.loadReport.problems, [])
        XCTAssertTrue(quarantinedFiles().isEmpty)
        let profile = try XCTUnwrap(store.userProfile(for: "a.b"))
        XCTAssertEqual(profile.scope, .rules)
        XCTAssertEqual(profile.rules.items, [ElementMatcher(domClassPrefixes: ["msg_"])])
        XCTAssertEqual(profile.rules.containers, [])
        XCTAssertEqual(profile.rules.excludes, [])
        XCTAssertEqual(store.global.appearance.theme, .dark)
        var expected = OverlayAppearance()
        expected.theme = .dark
        XCTAssertEqual(store.global.appearance, expected)
    }

    func testCornerRadiusFromOlderFileIsClampedToWhatIsDrawn() throws {
        // Older versions offered 0–12 pt and stored 3 by default; overlays draw at most 2 pt.
        try Data(#"{"global": {"appearance": {"cornerRadius": 3}}}"#.utf8).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(store.global.appearance.cornerRadius, 2)
        XCTAssertEqual(SettingsLimits.cornerRadius, 0...2)
        XCTAssertTrue(SettingsLimits.cornerRadius.contains(OverlayAppearance().cornerRadius), "the default is drawn as is")
    }

    func testProfileResolutionOrder() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)

        // Unknown app -> default profile from the global settings.
        let unknown = store.profile(for: "com.unknown.app", appName: "Unknown")
        XCTAssertEqual(store.profileSource(for: "com.unknown.app"), .defaults)
        XCTAssertEqual(unknown.mode, store.global.defaultMode)
        XCTAssertEqual(unknown.scope, store.global.defaultScope)
        XCTAssertEqual(unknown.displayName, "Unknown")
        store.updateGlobal {
            $0.defaultMode = .off
            $0.defaultScope = .underMouse
        }
        XCTAssertEqual(store.profile(for: "com.unknown.app").mode, .off)
        XCTAssertEqual(store.profile(for: "com.unknown.app").scope, .underMouse)

        // Preset app -> preset.
        XCTAssertEqual(store.profileSource(for: AppPresets.slackBundleID), .preset)
        XCTAssertEqual(store.profile(for: AppPresets.slackBundleID), AppPresets.slack.profile)
        XCTAssertEqual(store.profile(for: "COM.TINYSPECK.SLACKMACGAP").bundleID, AppPresets.slackBundleID)

        // User profile wins over the preset.
        var edited = AppPresets.slack.profile
        edited.mode = .manual
        store.upsert(edited)
        XCTAssertEqual(store.profileSource(for: AppPresets.slackBundleID), .user)
        XCTAssertEqual(store.profile(for: AppPresets.slackBundleID).mode, .manual)

        XCTAssertTrue(store.resetToPreset(bundleID: AppPresets.slackBundleID))
        XCTAssertEqual(store.profileSource(for: AppPresets.slackBundleID), .preset)

        // Storing a profile identical to the preset keeps nothing.
        store.upsert(AppPresets.slack.profile)
        XCTAssertTrue(store.profiles.isEmpty)

        store.upsert(store.profile(for: "com.unknown.app", appName: "Unknown"))
        XCTAssertEqual(store.profileSource(for: "com.unknown.app"), .user)
        store.removeProfile(bundleID: "com.unknown.app")
        XCTAssertEqual(store.profileSource(for: "com.unknown.app"), .defaults)
    }

    func testEffectiveSettings() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateProfile(bundleID: AppPresets.discordBundleID) {
            $0.targetLanguageOverride = "ja(easy)"
            $0.glossary = [GlossaryTerm(source: "server", target: "サーバー")]
        }
        store.updateGlobal { $0.glossary = [GlossaryTerm(source: "server", target: "鯖")] }
        let effective = store.effectiveSettings(bundleID: AppPresets.discordBundleID)
        XCTAssertEqual(effective.targetLanguage, "ja(easy)")
        XCTAssertEqual(effective.glossary.map(\.target), ["サーバー"])
        XCTAssertEqual(effective.mode, .automatic)

        // An unfinished app term (no target) neither reaches PLaMo nor hides the global term.
        store.updateProfile(bundleID: AppPresets.discordBundleID) {
            $0.glossary = [GlossaryTerm(source: "server", target: " "), GlossaryTerm(source: "deploy", target: "")]
        }
        XCTAssertEqual(
            store.effectiveSettings(bundleID: AppPresets.discordBundleID).glossary.map(\.target), ["鯖"])

        store.updateGlobal { $0.isEnabled = false }
        XCTAssertEqual(store.effectiveSettings(bundleID: AppPresets.discordBundleID).mode, .off)
    }

    func testChangePublisher() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        var received: [SettingsSnapshot] = []
        let subscription = store.changes.sink { received.append($0) }
        store.updateGlobal { $0.targetLanguage = "fr" }
        store.updateGlobal { $0.targetLanguage = "fr" }  // no-op
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.global.targetLanguage, "fr")

        var modes: [TranslationMode] = []
        let effective = store.effectiveSettingsPublisher(bundleID: AppPresets.discordBundleID)
            .sink { modes.append($0.mode) }
        store.updateProfile(bundleID: AppPresets.discordBundleID) { $0.mode = .manual }
        store.updateGlobal { $0.minTextLength = 5 }  // does not change Discord's effective mode
        XCTAssertEqual(modes.first, .automatic)
        XCTAssertTrue(modes.contains(.manual))
        subscription.cancel()
        effective.cancel()
    }

    func testNormalization() {
        var g = GlobalSettings()
        g.finalModel = .b0_8
        g.draftModel = .b2
        g.targetLanguage = "xx"
        g.sourceLanguage = "ja(easy)"
        g.appearance.minFontSize = 30
        g.appearance.maxFontSize = 10
        g.appearance.cornerRadius = 10
        g.scanInterval = .nan
        g.cacheCapacity = 0
        let n = SettingsNormalizer.normalized(g)
        // Nothing is smaller than 0.8B: the draft becomes 0.8B (single stage) and the switch stays on.
        XCTAssertEqual(n.progressive.draftModel, .b0_8)
        XCTAssertTrue(n.progressive.isEnabled)
        XCTAssertEqual(n.targetLanguage, "ja")
        XCTAssertNil(n.sourceLanguage)
        XCTAssertGreaterThanOrEqual(n.appearance.maxFontSize, n.appearance.minFontSize)
        XCTAssertEqual(n.appearance.cornerRadius, 2, "overlays never draw a rounder corner")
        XCTAssertEqual(n.scanInterval, SettingsLimits.scanInterval.lowerBound)
        XCTAssertEqual(n.cacheCapacity, SettingsLimits.cacheCapacity.lowerBound, "a cache too small to hold the screen")
        XCTAssertGreaterThanOrEqual(SettingsLimits.cacheCapacity.lowerBound, 1_000)
        XCTAssertEqual(SettingsNormalizer.normalized(GlobalSettings()), GlobalSettings())

        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal { $0.finalModel = .b0_8 }
        XCTAssertEqual(store.global.progressive.draftModel, .b0_8, "the draft is never larger than the final model")
        XCTAssertTrue(store.global.progressive.isEnabled, "段階翻訳 stays on for when the final model grows again")
    }
}
