import Foundation
import Sparkle

/// Sparkle's updater with its standard windows. An update found by a scheduled check is handed to the host
/// (gentle reminders) instead of opening a window; a check the user starts shows Sparkle's usual window.
@MainActor
final class SparkleUpdateEngine: NSObject, UpdateEngine {
    private weak var host: UpdateEngineHost?
    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var canCheckObservation: NSKeyValueObservation?

    init(host: UpdateEngineHost) {
        self.host = host
        super.init()
        let bundle = Bundle.main
        // Both keep their delegate weakly; this object owns them.
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        self.userDriver = userDriver
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: self)
    }

    func start() throws {
        guard let updater else { return }
        try updater.start()
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            MainActor.assumeIsolated { self?.host?.engineCanCheckChanged(updater.canCheckForUpdates) }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    func resetUpdateCycle() {
        // Waits a second and replaces an earlier pending reset, so quick toggling costs one check.
        updater?.resetUpdateCycleAfterShortDelay()
    }
}

extension SparkleUpdateEngine: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        host?.feedURL.absoluteString
    }
}

// SPUStandardUserDriverDelegate is not main-actor isolated; Sparkle calls it on the main thread.
extension SparkleUpdateEngine: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated { host?.sparkleShowsScheduledUpdates ?? false }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { host?.engineWillShowUpdate(version: version, shownBySparkle: handleShowingUpdate) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { host?.engineClearedUpdateReminder() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { host?.engineClearedUpdateReminder() }
    }
}
