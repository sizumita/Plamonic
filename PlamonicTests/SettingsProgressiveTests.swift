import PlamoKit
import XCTest

@testable import Plamonic

/// 段階翻訳 and 混雑時の一時停止 settings: file migration, normalization, per-app overrides and the
/// Models pane status.
@MainActor
final class SettingsProgressiveTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsProgressiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ json: String) throws -> SettingsStore {
        try Data(json.utf8).write(to: fileURL)
        return SettingsStore(fileURL: fileURL, saveDelay: 10)
    }

    // MARK: - Migration of the legacy "draftModel" key

    func testLegacyNullDraftModelTurnsProgressiveOff() throws {
        let store = try load(#"{"global": {"finalModel": "8b", "draftModel": null}}"#)
        XCTAssertEqual(store.loadReport.source, .file)
        XCTAssertFalse(store.global.progressive.isEnabled)
        XCTAssertEqual(store.global.progressive.draftModel, ProgressiveTranslationSettings().draftModel)
        XCTAssertEqual(store.global.progressive.burstControl, BurstControlSettings())
        XCTAssertNil(store.global.draftModel)
        XCTAssertEqual(store.global.finalModel, .b8)
    }

    func testLegacyNullDraftWithTheSmallestFinalModelKeepsProgressiveOn() throws {
        // The old normaliser wrote null whenever the final model was 0.8B, whatever the user wanted.
        let store = try load(#"{"global": {"finalModel": "0.8b", "draftModel": null}}"#)
        XCTAssertTrue(store.global.progressive.isEnabled)
        XCTAssertEqual(store.global.finalModel, .b0_8)
        store.updateGlobal { $0.finalModel = .b2 }
        XCTAssertTrue(store.global.progressive.isEnabled)
        XCTAssertEqual(store.global.draftModel, .b0_8, "two-stage once the final model grows")
    }

    func testLegacyDraftModelTurnsProgressiveOn() throws {
        let store = try load(#"{"global": {"finalModel": "8b", "draftModel": "0.8b"}}"#)
        XCTAssertTrue(store.global.progressive.isEnabled)
        XCTAssertEqual(store.global.progressive.draftModel, .b0_8)
        XCTAssertEqual(store.global.draftModel, .b0_8)

        let larger = try load(#"{"global": {"finalModel": "8b", "draftModel": "2b"}}"#)
        XCTAssertEqual(larger.global.progressive.draftModel, .b2)
        XCTAssertTrue(larger.global.progressive.isEnabled)
    }

    func testLegacyDraftAsLargeAsFinalIsMovedBelowIt() throws {
        let store = try load(#"{"global": {"finalModel": "2b", "draftModel": "8b"}}"#)
        XCTAssertTrue(store.global.progressive.isEnabled)
        XCTAssertEqual(store.global.progressive.draftModel, .b0_8)
    }

    func testNewKeyWinsOverLegacyKey() throws {
        let store = try load(#"{"global": {"progressive": {"isEnabled": false}, "draftModel": "0.8b"}}"#)
        XCTAssertFalse(store.global.progressive.isEnabled)
    }

    func testMissingKeysUseDefaults() throws {
        XCTAssertEqual(try load(#"{"global": {}}"#).global.progressive, ProgressiveTranslationSettings())
        XCTAssertEqual(try load(#"{"global": {"progressive": {}}}"#).global.progressive, ProgressiveTranslationSettings())
        XCTAssertEqual(try load("{}").global.progressive, ProgressiveTranslationSettings())

        let partial = try load(#"{"global": {"progressive": {"burstControl": {"threshold": 12}}}}"#)
        var expected = ProgressiveTranslationSettings()
        expected.burstControl.threshold = 12
        XCTAssertEqual(partial.global.progressive, expected)
        XCTAssertEqual(partial.loadReport.problems, [])

        let profile = try XCTUnwrap(
            try load(#"{"profiles": [{"bundleID": "a.b"}]}"#).userProfile(for: "a.b"))
        XCTAssertNil(profile.progressiveOverride)
    }

    func testDamagedProgressiveIsDroppedAlone() throws {
        let store = try load(#"{"global": {"targetLanguage": "ko", "progressive": {"isEnabled": "yes"}}}"#)
        XCTAssertEqual(store.loadReport.source, .salvaged)
        XCTAssertTrue(store.loadReport.problems.contains("global.progressive"))
        XCTAssertEqual(store.global.targetLanguage, "ko")
        XCTAssertEqual(store.global.progressive, ProgressiveTranslationSettings())
    }

    func testDefaultsAreWithinLimits() {
        let burst = BurstControlSettings()
        XCTAssertTrue(SettingsLimits.burstThreshold.contains(burst.threshold))
        XCTAssertTrue(SettingsLimits.burstQuietSeconds.contains(burst.quietSeconds))
        XCTAssertEqual(SettingsNormalizer.normalized(GlobalSettings()), GlobalSettings())
    }

    // MARK: - Round trip

    func testProgressiveRoundTrip() async throws {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 0.05)
        store.updateGlobal {
            $0.finalModel = .b8
            $0.progressive = ProgressiveTranslationSettings(
                isEnabled: false, draftModel: .b2,
                burstControl: BurstControlSettings(isEnabled: false, threshold: 20, quietSeconds: 3))
        }
        store.updateProfile(bundleID: AppPresets.terminalBundleID) { $0.progressiveOverride = true }
        store.updateProfile(bundleID: "com.example.chat", appName: "Chat") { $0.progressiveOverride = false }
        store.flush()

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let global = try XCTUnwrap(json["global"] as? [String: Any])
        XCTAssertNotNil(global["progressive"])
        XCTAssertNil(global["draftModel"], "the legacy key is read, never written")

        let reloaded = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(reloaded.loadReport.source, .file)
        XCTAssertEqual(reloaded.document, store.document)
        XCTAssertEqual(reloaded.global.progressive.draftModel, .b2)
        XCTAssertFalse(reloaded.global.progressive.isEnabled)
        XCTAssertEqual(reloaded.global.progressive.burstControl.threshold, 20)
        XCTAssertEqual(reloaded.global.progressive.burstControl.quietSeconds, 3)
        XCTAssertFalse(reloaded.global.progressive.burstControl.isEnabled)
        XCTAssertEqual(reloaded.profile(for: AppPresets.terminalBundleID).progressiveOverride, true)
        XCTAssertEqual(reloaded.profile(for: "com.example.chat").progressiveOverride, false)
    }

    // MARK: - Normalization

    func testBurstControlIsClamped() {
        func normalized(threshold: Int, quiet: Double) -> BurstControlSettings {
            var g = GlobalSettings()
            g.progressive.burstControl.threshold = threshold
            g.progressive.burstControl.quietSeconds = quiet
            return SettingsNormalizer.normalized(g).progressive.burstControl
        }
        XCTAssertEqual(normalized(threshold: 1, quiet: 0.1).threshold, 3)
        XCTAssertEqual(normalized(threshold: 1, quiet: 0.1).quietSeconds, 0.5)
        XCTAssertEqual(normalized(threshold: 100, quiet: 60).threshold, 40)
        XCTAssertEqual(normalized(threshold: 100, quiet: 60).quietSeconds, 10)
        XCTAssertEqual(normalized(threshold: 8, quiet: .nan).quietSeconds, SettingsLimits.burstQuietSeconds.lowerBound)
        XCTAssertEqual(normalized(threshold: 12, quiet: 2.5), BurstControlSettings(isEnabled: true, threshold: 12, quietSeconds: 2.5))
    }

    func testDraftModelStaysSmallerThanFinalModel() {
        func draft(_ draft: ModelSize, final: ModelSize, enabled: Bool = true) -> ProgressiveTranslationSettings {
            var g = GlobalSettings()
            g.finalModel = final
            g.progressive.draftModel = draft
            g.progressive.isEnabled = enabled
            return SettingsNormalizer.normalized(g).progressive
        }
        XCTAssertEqual(draft(.b8, final: .b2).draftModel, .b0_8)
        XCTAssertEqual(draft(.b31, final: .b31).draftModel, .b8, "the largest smaller size")
        XCTAssertEqual(draft(.b8, final: .b8).draftModel, .b2)
        XCTAssertEqual(draft(.b2, final: .b8).draftModel, .b2, "an already smaller draft is kept")
        XCTAssertEqual(draft(.b0_8, final: .b31).draftModel, .b0_8)
        // Nothing is smaller than 0.8B: same size, so the plan is single stage.
        XCTAssertEqual(draft(.b2, final: .b0_8).draftModel, .b0_8)
        // The switch is never flipped.
        XCTAssertTrue(draft(.b2, final: .b0_8).isEnabled)
        XCTAssertFalse(draft(.b8, final: .b2, enabled: false).isEnabled)
        XCTAssertEqual(draft(.b8, final: .b2, enabled: false).draftModel, .b0_8, "fixed even while off")

        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal {
            $0.finalModel = .b8
            $0.progressive.draftModel = .b2
        }
        store.updateGlobal { $0.finalModel = .b2 }
        XCTAssertEqual(store.global.progressive.draftModel, .b0_8)
        XCTAssertTrue(store.global.progressive.isEnabled)
        store.updateGlobal { $0.finalModel = .b0_8 }
        store.updateGlobal { $0.finalModel = .b8 }
        XCTAssertEqual(store.global.progressive.draftModel, .b0_8, "two-stage again once the final model grows")
        XCTAssertEqual(store.global.draftModel, .b0_8)
    }

    /// The compact 0.8B is the same model as the 0.8B: neither can be the other's draft.
    func testCompactModelRanksWithTheOfficialSize() {
        func draft(_ draft: ModelSize, final: ModelSize) -> ModelSize {
            var g = GlobalSettings()
            g.finalModel = final
            g.progressive.draftModel = draft
            return SettingsNormalizer.normalized(g).progressive.draftModel
        }
        XCTAssertFalse(SettingsNormalizer.isSmaller(.b0_8Compact, than: .b0_8))
        XCTAssertFalse(SettingsNormalizer.isSmaller(.b0_8, than: .b0_8Compact))
        XCTAssertEqual(SettingsNormalizer.draftChoices(below: .b2), [.b0_8, .b0_8Compact])
        XCTAssertEqual(SettingsNormalizer.draftChoices(below: .b0_8Compact), [])
        XCTAssertEqual(draft(.b0_8Compact, final: .b2), .b0_8Compact, "a smaller draft is kept")
        XCTAssertEqual(draft(.b8, final: .b2), .b0_8, "the official model when both rank the same")

        var g = GlobalSettings()
        g.finalModel = .b0_8Compact
        g = SettingsNormalizer.normalized(g)
        XCTAssertEqual(ProgressiveStatus.issue(global: g, isInstalled: { _ in true }), .finalIsSmallest(final: .b0_8Compact))
        let single = TranslationModelPlan.make(global: g, isInstalled: { _ in true })
        XCTAssertNil(single.draft)
        XCTAssertEqual(single.final, .b0_8Compact)

        g.finalModel = .b2
        g.progressive.draftModel = .b0_8Compact
        let twoStage = TranslationModelPlan.make(global: g, isInstalled: { _ in true })
        XCTAssertEqual(twoStage.draft, .b0_8Compact)
        XCTAssertEqual(twoStage.final, .b2)
    }

    func testEveryModelSizeMapsToAPlamoVariant() {
        for size in ModelSize.allCases {
            let variant = PlamoBackend.variant(size)
            XCTAssertEqual(variant.rawValue, size.rawValue)
            XCTAssertEqual(variant.repoID, size.repoID)
            XCTAssertEqual(variant.displayName, size.displayName)
            XCTAssertEqual(PlamoBackend.size(variant), size)
        }
    }

    // MARK: - Per-app override

    func testEffectiveSettingsFollowTheOverride() {
        var global = GlobalSettings()
        global.progressive = ProgressiveTranslationSettings(
            isEnabled: true, draftModel: .b0_8,
            burstControl: BurstControlSettings(isEnabled: true, threshold: 15, quietSeconds: 2))
        var profile = AppProfile(bundleID: "a.b", displayName: "A")

        XCTAssertTrue(EffectiveSettings(profile: profile, global: global).progressive.isEnabled)
        XCTAssertEqual(EffectiveSettings(profile: profile, global: global).draftModel, .b0_8)

        profile.progressiveOverride = false
        XCTAssertFalse(EffectiveSettings(profile: profile, global: global).progressive.isEnabled)
        XCTAssertNil(EffectiveSettings(profile: profile, global: global).draftModel)

        global.progressive.isEnabled = false
        profile.progressiveOverride = true
        let effective = EffectiveSettings(profile: profile, global: global)
        XCTAssertTrue(effective.progressive.isEnabled)
        XCTAssertEqual(effective.draftModel, .b0_8)
        XCTAssertEqual(effective.progressive.burstControl.threshold, 15, "burst control stays global")
    }

    func testAppsOverridingProgressive() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertTrue(store.snapshot.appsOverridingProgressive(to: true).isEmpty, "presets follow the global switch")
        XCTAssertTrue(store.snapshot.appsOverridingProgressive(to: false).isEmpty)
        XCTAssertTrue(store.snapshot.isProgressiveInUse)

        store.updateGlobal { $0.progressive.isEnabled = false }
        XCTAssertFalse(store.snapshot.isProgressiveInUse)

        store.updateProfile(bundleID: AppPresets.slackBundleID) { $0.progressiveOverride = true }
        store.updateProfile(bundleID: "com.example.zed", appName: "Zed") { $0.progressiveOverride = true }
        store.updateProfile(bundleID: AppPresets.terminalBundleID) { $0.progressiveOverride = false }
        XCTAssertEqual(store.snapshot.appsOverridingProgressive(to: true).map(\.bundleID), [AppPresets.slackBundleID, "com.example.zed"])
        XCTAssertEqual(store.snapshot.appsOverridingProgressive(to: false).map(\.bundleID), [AppPresets.terminalBundleID])
        XCTAssertTrue(store.snapshot.isProgressiveInUse, "an app turns it on for itself")

        // Back to "follow the global setting": the preset copy is dropped again.
        store.updateProfile(bundleID: AppPresets.slackBundleID) { $0.progressiveOverride = nil }
        XCTAssertEqual(store.profileSource(for: AppPresets.slackBundleID), .preset)
    }

    func testOverrideLabels() {
        XCTAssertEqual(ProgressiveOverrideLabel.label(nil, global: true), "全体の設定に従う（使う）")
        XCTAssertEqual(ProgressiveOverrideLabel.label(nil, global: false), "全体の設定に従う（使わない）")
        XCTAssertEqual(ProgressiveOverrideLabel.label(true, global: false), "使う")
        XCTAssertEqual(ProgressiveOverrideLabel.label(false, global: true), "使わない")
    }

    // MARK: - Models pane status

    func testIssueWhenProgressiveCannotRun() {
        var g = GlobalSettings()
        g.finalModel = .b2
        g.progressive.draftModel = .b0_8
        let all: (ModelSize) -> Bool = { _ in true }
        XCTAssertNil(ProgressiveStatus.issue(global: g, isInstalled: all))

        XCTAssertEqual(
            ProgressiveStatus.issue(global: g, isInstalled: { $0 == .b2 }),
            .draftNotInstalled(draft: .b0_8, final: .b2, downloading: false))
        XCTAssertEqual(
            ProgressiveStatus.issue(global: g, isInstalled: { $0 == .b2 }, isDownloading: { $0 == .b0_8 }),
            .draftNotInstalled(draft: .b0_8, final: .b2, downloading: true))
        XCTAssertEqual(
            ProgressiveStatus.issue(global: g, isInstalled: { $0 == .b0_8 }),
            .finalNotInstalled(draft: .b0_8, final: .b2, downloading: false))
        XCTAssertNil(ProgressiveStatus.issue(global: g, isInstalled: { _ in false }), "the final model's own note covers it")

        g.finalModel = .b0_8
        g = SettingsNormalizer.normalized(g)
        XCTAssertEqual(ProgressiveStatus.issue(global: g, isInstalled: all), .finalIsSmallest(final: .b0_8))

        for issue in [
            ProgressiveIssue.finalIsSmallest(final: .b0_8),
            .draftNotInstalled(draft: .b0_8, final: .b2, downloading: false),
            .draftNotInstalled(draft: .b0_8, final: .b2, downloading: true),
            .finalNotInstalled(draft: .b0_8, final: .b8, downloading: false),
            .finalNotInstalled(draft: .b0_8, final: .b8, downloading: true),
        ] {
            XCTAssertFalse(issue.message.isEmpty)
        }
        XCTAssertTrue(
            ProgressiveIssue.draftNotInstalled(draft: .b0_8, final: .b2, downloading: false).message.contains("0.8B"))
    }

    func testModelsInUse() {
        var doc = SettingsDocument()
        doc.global.finalModel = .b8
        doc.global.progressive.draftModel = .b2
        XCTAssertEqual(ProgressiveStatus.modelsInUse(SettingsSnapshot(document: doc)), [.b2, .b8])

        doc.global.progressive.isEnabled = false
        XCTAssertEqual(ProgressiveStatus.modelsInUse(SettingsSnapshot(document: doc)), [.b8])

        var app = AppProfile(bundleID: "a.b", displayName: "A")
        app.progressiveOverride = true
        doc.profiles = [app]
        XCTAssertEqual(ProgressiveStatus.modelsInUse(SettingsSnapshot(document: doc)), [.b2, .b8])

        doc.global.finalModel = .b0_8
        doc.global = SettingsNormalizer.normalized(doc.global)
        XCTAssertEqual(ProgressiveStatus.modelsInUse(SettingsSnapshot(document: doc)), [.b0_8])
    }
}
