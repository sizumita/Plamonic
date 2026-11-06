import XCTest

@testable import Plamonic

/// UpdateController with a fake engine: never Sparkle, never the network.
@MainActor
final class UpdateControllerTests: XCTestCase {
    private final class FakeEngine: UpdateEngine {
        weak var host: UpdateEngineHost?
        var startError: Error?
        var starts = 0
        var checks = 0
        var resets = 0
        var automaticallyChecksForUpdates = true

        init(host: UpdateEngineHost) {
            self.host = host
        }

        func start() throws {
            starts += 1
            if let startError { throw startError }
        }

        func checkForUpdates() {
            checks += 1
        }

        func resetUpdateCycle() {
            resets += 1
        }
    }

    private var directory: URL!
    private var settings: SettingsStore!
    private var engines: [FakeEngine] = []
    private var activations = 0
    private var startError: Error?

    private let release = BuildInfo(version: "0.2.0", build: "41", sparklePublicKey: "key")
    private let beta = BuildInfo(version: "0.2.1-beta.3", build: "44", sparklePublicKey: "key")
    private let fromSource = BuildInfo(version: "0.1.0", build: "1", sparklePublicKey: "")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"), saveDelay: 10)
        engines = []
        activations = 0
        startError = nil
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(_ build: BuildInfo) -> UpdateController {
        UpdateController(
            build: build, settings: settings,
            makeEngine: { [unowned self] host in
                let engine = FakeEngine(host: host)
                engine.startError = self.startError
                self.engines.append(engine)
                return engine
            },
            activate: { [unowned self] in self.activations += 1 })
    }

    // MARK: - Builds from source

    func testABuildWithoutAKeyNeverCreatesTheUpdater() {
        let updates = makeController(fromSource)
        XCTAssertEqual(updates.state, .disabled)
        updates.start()
        updates.start()
        XCTAssertEqual(updates.state, .disabled)
        XCTAssertTrue(engines.isEmpty, "Sparkle is not even created")
        XCTAssertFalse(updates.isRunning)

        updates.checkForUpdates()
        updates.setAutomaticallyChecksForUpdates(false)
        XCTAssertEqual(activations, 0, "nothing to show, so the app is not activated")
        XCTAssertNil(updates.pendingUpdateMenuTitle)
        XCTAssertNil(settings.global.receiveBetaUpdates, "nothing is written")
    }

    // MARK: - Starting

    func testStartsOnce() throws {
        let updates = makeController(release)
        XCTAssertEqual(updates.state, .idle)
        XCTAssertTrue(engines.isEmpty, "created only when started")
        updates.start()
        updates.start()
        XCTAssertEqual(updates.state, .running)
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(try XCTUnwrap(engines.first).starts, 1)
        XCTAssertTrue(updates.automaticallyChecksForUpdates)
    }

    func testAFailedStartLeavesTheUpdaterOff() {
        startError = NSError(
            domain: "SUSparkleErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad key"])
        let updates = makeController(release)
        updates.start()
        XCTAssertEqual(updates.state, .failed("bad key"))
        XCTAssertFalse(updates.isRunning)
        updates.checkForUpdates()
        XCTAssertEqual(engines.first?.checks, 0)
        XCTAssertEqual(activations, 0)
        updates.start()
        XCTAssertEqual(engines.count, 1, "not retried")
        XCTAssertEqual(
            UpdateSettingsSection.footer(state: updates.state, build: release, automaticChecks: true),
            "アップデートの確認を始められませんでした: bad key")
    }

    // MARK: - Channel

    func testReleaseBuildReadsTheStableFeedUntilBetaIsTurnedOn() {
        let updates = makeController(release)
        updates.start()
        XCTAssertNil(settings.global.receiveBetaUpdates, "a release build leaves the setting unset")
        XCTAssertEqual(updates.channel, .stable)
        XCTAssertEqual(updates.feedURL, UpdateChannel.stableFeedURL)
        XCTAssertFalse(updates.receivesBetaUpdates)

        updates.setReceivesBetaUpdates(true)
        XCTAssertEqual(settings.global.receiveBetaUpdates, true)
        XCTAssertEqual(updates.feedURL, UpdateChannel.betaFeedURL, "the next check reads the beta feed")
        XCTAssertEqual(engines.count, 1, "no restart")
    }

    func testBetaBuildRemembersItReceivesBetas() {
        let updates = makeController(beta)
        XCTAssertEqual(updates.channel, .beta, "unset follows the build")
        updates.start()
        XCTAssertEqual(settings.global.receiveBetaUpdates, true)
        XCTAssertEqual(updates.feedURL, UpdateChannel.betaFeedURL)

        // A release that arrived through the beta feed keeps reading it.
        let later = UpdateController(build: release, settings: settings, makeEngine: { FakeEngine(host: $0) })
        XCTAssertEqual(later.channel, .beta)
    }

    func testBetaBuildKeepsAnExplicitChoice() {
        settings.updateGlobal { $0.receiveBetaUpdates = false }
        let updates = makeController(beta)
        updates.start()
        XCTAssertEqual(settings.global.receiveBetaUpdates, false)
        XCTAssertEqual(updates.channel, .stable)
        XCTAssertEqual(updates.feedURL, UpdateChannel.stableFeedURL)
    }

    func testChangingTheChannelResetsTheUpdateCycle() throws {
        let updates = makeController(release)
        updates.start()
        let engine = try XCTUnwrap(engines.first)
        updates.setReceivesBetaUpdates(false)
        XCTAssertEqual(engine.resets, 0, "same channel")
        updates.setReceivesBetaUpdates(true)
        XCTAssertEqual(engine.resets, 1, "the beta feed is checked now, not at the next daily check")
        updates.setReceivesBetaUpdates(true)
        XCTAssertEqual(engine.resets, 1, "same channel")

        updates.setAutomaticallyChecksForUpdates(false)
        updates.setReceivesBetaUpdates(false)
        XCTAssertEqual(engine.resets, 1, "no background check while automatic checks are off")
        XCTAssertEqual(updates.feedURL, UpdateChannel.stableFeedURL, "the next 今すぐ確認 reads the new feed")
        XCTAssertEqual(engine.checks, 0)
    }

    func testChangingTheChannelBeforeTheUpdaterRunsResetsNothing() {
        let updates = makeController(fromSource)
        updates.start()
        updates.setReceivesBetaUpdates(true)
        XCTAssertEqual(settings.global.receiveBetaUpdates, true)
        XCTAssertTrue(engines.isEmpty)

        let idle = makeController(release)
        idle.setReceivesBetaUpdates(false)
        XCTAssertTrue(engines.isEmpty, "not started yet")
    }

    func testTheEngineAsksTheHostForTheFeedAtEachCheck() throws {
        let updates = makeController(release)
        updates.start()
        let host = try XCTUnwrap(engines.first?.host)
        XCTAssertEqual(host.feedURL, UpdateChannel.stableFeedURL)
        settings.updateGlobal { $0.receiveBetaUpdates = true }
        XCTAssertEqual(host.feedURL, UpdateChannel.betaFeedURL, "settings edited elsewhere apply too")
    }

    // MARK: - Checks and reminders

    func testUserChecksBringTheAppForward() throws {
        let updates = makeController(release)
        updates.start()
        updates.checkForUpdates()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(try XCTUnwrap(engines.first).checks, 1)
    }

    func testAutomaticChecksSwitch() throws {
        let updates = makeController(release)
        updates.start()
        updates.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(try XCTUnwrap(engines.first).automaticallyChecksForUpdates)
        XCTAssertFalse(updates.automaticallyChecksForUpdates)
        updates.setAutomaticallyChecksForUpdates(true)
        XCTAssertTrue(try XCTUnwrap(engines.first).automaticallyChecksForUpdates)
        XCTAssertTrue(updates.automaticallyChecksForUpdates)
    }

    func testScheduledUpdatesAreShownInTheMenuNotBySparkle() throws {
        let updates = makeController(release)
        updates.start()
        let host = try XCTUnwrap(engines.first?.host)
        XCTAssertFalse(host.sparkleShowsScheduledUpdates, "a scheduled check never opens a window")

        host.engineWillShowUpdate(version: "0.3.0", shownBySparkle: false)
        XCTAssertEqual(updates.pendingUpdateVersion, "0.3.0")
        XCTAssertEqual(updates.pendingUpdateMenuTitle, "アップデートがあります（0.3.0）")
        XCTAssertEqual(activations, 0, "finding an update does not take focus")

        host.engineClearedUpdateReminder()
        XCTAssertNil(updates.pendingUpdateMenuTitle)
    }

    func testUpdatesSparkleShowsNeedNoMenuLine() throws {
        let updates = makeController(release)
        updates.start()
        try XCTUnwrap(engines.first?.host).engineWillShowUpdate(version: "0.3.0", shownBySparkle: true)
        XCTAssertNil(updates.pendingUpdateVersion)
    }

    func testCanCheckFollowsTheEngine() throws {
        let updates = makeController(release)
        updates.start()
        let host = try XCTUnwrap(engines.first?.host)
        host.engineCanCheckChanged(true)
        XCTAssertTrue(updates.canCheckForUpdates)
        host.engineCanCheckChanged(false)
        XCTAssertFalse(updates.canCheckForUpdates)
    }

    // MARK: - Sparkle's optional delegate methods

    /// Sparkle calls these by selector and skips the ones it does not find; a misspelled one would fail silently.
    func testSparkleFindsTheDelegateMethods() {
        for selector in [
            "feedURLStringForUpdater:", "supportsGentleScheduledUpdateReminders",
            "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
            "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
            "standardUserDriverDidReceiveUserAttentionForUpdate:", "standardUserDriverWillFinishUpdateSession",
        ] {
            XCTAssertTrue(SparkleUpdateEngine.instancesRespond(to: NSSelectorFromString(selector)), selector)
        }
        for selector in [
            "feedURLStringForUpdater:", "updaterDidNotFindUpdate:error:", "updater:didAbortWithError:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:",
        ] {
            XCTAssertTrue(UpdateProbe.instancesRespond(to: NSSelectorFromString(selector)), selector)
        }
    }

    // MARK: - Settings footer

    func testFooters() {
        XCTAssertEqual(
            UpdateSettingsSection.footer(state: .disabled, build: fromSource, automaticChecks: true),
            "このビルドは自動アップデートしません（ソースからビルドしたため）")

        let stable = UpdateSettingsSection.footer(state: .running, build: release, automaticChecks: true)
        XCTAssertTrue(stable.contains("1 日に 1 回確認"))
        XCTAssertTrue(stable.contains("メニューバーのメニューに表示します"))
        XCTAssertTrue(stable.contains("新しい正式版が出ればそちらにアップデートします"))
        XCTAssertFalse(stable.contains("今使っているのはベータ版です"))

        let manual = UpdateSettingsSection.footer(state: .running, build: release, automaticChecks: false)
        XCTAssertFalse(manual.contains("1 日に 1 回確認"), "nothing is checked on its own")
        XCTAssertTrue(manual.contains("新しい正式版が出ればそちらにアップデートします"))

        let betaFooter = UpdateSettingsSection.footer(state: .running, build: beta, automaticChecks: true)
        XCTAssertTrue(betaFooter.hasPrefix(stable))
        XCTAssertTrue(betaFooter.contains("オフにしても、このベータ版はそのまま使えます"))
        XCTAssertTrue(betaFooter.contains("これより新しい正式版が出たときに"))
    }

    // MARK: - Probe arguments

    func testProbeArguments() throws {
        XCTAssertNil(UpdateProbeOptions(arguments: ["Plamonic"]))

        let custom = try XCTUnwrap(
            UpdateProbeOptions(arguments: ["Plamonic", "--update-probe", "http://127.0.0.1:8123/appcast.xml"]))
        XCTAssertEqual(custom.feedURL?.absoluteString, "http://127.0.0.1:8123/appcast.xml")
        XCTAssertEqual(custom.feedName, "custom")
        XCTAssertNil(custom.problem)
        XCTAssertEqual(custom.timeout, 120)

        let beta = try XCTUnwrap(UpdateProbeOptions(arguments: ["Plamonic", "--update-probe", "beta", "--timeout", "30"]))
        XCTAssertEqual(beta.feedURL, UpdateChannel.betaFeedURL)
        XCTAssertEqual(beta.timeout, 30)
        XCTAssertEqual(
            try XCTUnwrap(UpdateProbeOptions(arguments: ["Plamonic", "--update-probe", "stable"])).feedURL,
            UpdateChannel.stableFeedURL)

        for bad in [["--update-probe"], ["--update-probe", "appcast.xml"], ["--update-probe", "file:///tmp/a.xml"]] {
            let options = try XCTUnwrap(UpdateProbeOptions(arguments: ["Plamonic"] + bad), "\(bad)")
            XCTAssertNil(options.feedURL, "\(bad)")
            XCTAssertNotNil(options.problem, "\(bad)")
        }
    }

    func testProbeMasksTheKey() {
        XCTAssertEqual(UpdateProbe.mask(""), "none")
        XCTAssertEqual(
            UpdateProbe.mask("pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="), "pfIS… (44 characters)")
    }
}
