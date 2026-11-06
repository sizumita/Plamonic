import AppKit
import Combine
import os

/// The parts of Sparkle that UpdateController drives. SparkleUpdateEngine is the real one; tests use a fake.
@MainActor
protocol UpdateEngine: AnyObject {
    /// Starts Sparkle's scheduler. Throws when Sparkle finds the build's configuration unusable.
    func start() throws
    var automaticallyChecksForUpdates: Bool { get set }
    /// A check the user asked for: Sparkle shows its window, or brings an update it found earlier to the front.
    func checkForUpdates()
    /// Reschedules Sparkle's checks after a settings change. A changed feed is checked in the background at once.
    func resetUpdateCycle()
}

/// What the engine asks UpdateController and tells it. Sparkle's delegate calls end up here.
@MainActor
protocol UpdateEngineHost: AnyObject {
    /// The feed of the next check. Asked before every check, so a channel change needs no restart.
    var feedURL: URL { get }
    /// Whether Sparkle shows an update found by a scheduled check itself. Plamonic never takes focus on its own,
    /// so it shows the update in its menu instead (Sparkle's gentle reminders).
    var sparkleShowsScheduledUpdates: Bool { get }
    /// Sparkle is about to show an update, or (`shownBySparkle` false) leaves showing it to Plamonic.
    func engineWillShowUpdate(version: String, shownBySparkle: Bool)
    /// The user looked at the update, or its session ended.
    func engineClearedUpdateReminder()
    /// False while Sparkle downloads something in the background.
    func engineCanCheckChanged(_ canCheck: Bool)
}

/// Owns the updater: starts Sparkle when the build carries its public key, picks the feed (stable or beta)
/// and keeps what the settings pane and the menu show.
@MainActor
final class UpdateController: ObservableObject, UpdateEngineHost {
    enum State: Equatable {
        /// Built without Sparkle's public key (from source): the updater is never started.
        case disabled
        /// Not started yet.
        case idle
        case running
        /// Sparkle refused to start (a malformed key, for example).
        case failed(String)
    }

    let build: BuildInfo
    @Published private(set) var state: State
    /// The update a scheduled check found, until the user looks at it.
    @Published private(set) var pendingUpdateVersion: String?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true

    let sparkleShowsScheduledUpdates = false

    private let settings: SettingsStore
    private let makeEngine: @MainActor (UpdateEngineHost) -> UpdateEngine
    private let activate: @MainActor () -> Void
    private var engine: UpdateEngine?
    private let log = Logger(subsystem: "io.smdr.Plamonic", category: "Updates")

    init(
        build: BuildInfo = .main, settings: SettingsStore,
        makeEngine: @escaping @MainActor (UpdateEngineHost) -> UpdateEngine = { SparkleUpdateEngine(host: $0) },
        activate: @escaping @MainActor () -> Void = { NSApp.activate() }
    ) {
        self.build = build
        self.settings = settings
        self.makeEngine = makeEngine
        self.activate = activate
        state = build.updatesItself ? .idle : .disabled
    }

    /// Starts Sparkle once. Does nothing for a build without the public key.
    func start() {
        guard state == .idle else { return }
        // A beta build remembers that it receives betas, so a release that arrives through the beta feed
        // keeps receiving them.
        if build.isBeta, settings.global.receiveBetaUpdates == nil {
            settings.updateGlobal { $0.receiveBetaUpdates = true }
        }
        let engine = makeEngine(self)
        do {
            try engine.start()
        } catch {
            log.error("Updater did not start: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return
        }
        self.engine = engine
        state = .running
        automaticallyChecksForUpdates = engine.automaticallyChecksForUpdates
        log.notice("Updater started: \(self.build.version, privacy: .public) (\(self.build.build, privacy: .public))")
    }

    var isRunning: Bool { state == .running }

    var channel: UpdateChannel {
        UpdateChannel.current(receiveBetaUpdates: settings.global.receiveBetaUpdates, build: build)
    }

    var feedURL: URL { channel.feedURL }

    var receivesBetaUpdates: Bool { channel == .beta }

    /// ベータ版を受け取る. The choice is stored, so it no longer follows the build.
    func setReceivesBetaUpdates(_ on: Bool) {
        let before = channel
        settings.updateGlobal { $0.receiveBetaUpdates = on }
        // With automatic checks off, nothing is checked on its own; the next 今すぐ確認 reads the new feed.
        guard channel != before, let engine, engine.automaticallyChecksForUpdates else { return }
        engine.resetUpdateCycle()
    }

    func setAutomaticallyChecksForUpdates(_ on: Bool) {
        guard let engine else { return }
        engine.automaticallyChecksForUpdates = on
        automaticallyChecksForUpdates = engine.automaticallyChecksForUpdates
    }

    /// 今すぐ確認, アップデートを確認… and the menu line of a found update: Sparkle's window, in front.
    func checkForUpdates() {
        guard let engine else { return }
        activate()
        engine.checkForUpdates()
    }

    /// The menu line of an update a scheduled check found.
    var pendingUpdateMenuTitle: String? {
        pendingUpdateVersion.map { "アップデートがあります（\($0)）" }
    }

    // MARK: - UpdateEngineHost

    func engineWillShowUpdate(version: String, shownBySparkle: Bool) {
        guard !shownBySparkle else { return }
        pendingUpdateVersion = version
    }

    func engineClearedUpdateReminder() {
        pendingUpdateVersion = nil
    }

    func engineCanCheckChanged(_ canCheck: Bool) {
        if canCheckForUpdates != canCheck { canCheckForUpdates = canCheck }
    }
}
