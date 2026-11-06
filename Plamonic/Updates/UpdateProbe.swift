import AppKit
import Sparkle

/// `--update-probe <feed>`: runs one background update check against `<feed>` (a URL, or `stable` / `beta` for the
/// published feeds) with this build's public key (SUPublicEDKey) and a user driver without windows. It downloads the
/// update it finds and lets Sparkle verify it (EdDSA signature, bundle, code signature) up to "ready to install",
/// then cancels the installation and exits. Nothing is installed, the app never activates or shows a window, and the
/// translation session, onboarding and permission prompts are never started.
/// `--timeout <seconds>` ends the run (default 120).
/// It logs the build, the feed Sparkle asked for, the update found (version, build, channel, size, archive URL) and
/// each step. Exit status: 0 an update was found and verified, 1 no update, 2 an updater error (feed, download,
/// signature), 3 the probe could not start (no public key, a bad argument, automatic downloads on), 4 timeout.
/// Run it from a copy of the app with a bundle ID of its own: Sparkle keeps its state (last check, downloads) per
/// bundle ID.
struct UpdateProbeOptions {
    var feedURL: URL?
    /// "stable", "beta" or "custom".
    var feedName: String
    var timeout: Double = 120
    /// Why the arguments cannot be used.
    var problem: String?

    /// nil when `--update-probe` is not given.
    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--update-probe") else { return nil }
        let value = arguments.count > index + 1 ? arguments[index + 1] : ""
        switch value {
        case "stable":
            feedURL = UpdateChannel.stable.feedURL
            feedName = "stable"
        case "beta":
            feedURL = UpdateChannel.beta.feedURL
            feedName = "beta"
        default:
            feedName = "custom"
            if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                url.host != nil
            {
                feedURL = url
            } else {
                problem = "--update-probe needs a feed URL, stable or beta, not \(value.isEmpty ? "nothing" : value)"
            }
        }
        if let t = arguments.firstIndex(of: "--timeout"), arguments.count > t + 1, let seconds = Double(arguments[t + 1])
        {
            timeout = min(max(seconds, 5), 3600)
        }
    }
}

@MainActor
final class UpdateProbe: NSObject {
    enum Status: Int32 {
        case verified = 0
        case noUpdate = 1
        case updaterError = 2
        case cannotStart = 3
        case timeout = 4
    }

    private let options: UpdateProbeOptions
    private let build = BuildInfo.main
    private let start = Date()
    private var updater: SPUUpdater?
    private var outcome: Status?
    private var downloadedBytes: UInt64 = 0
    private var finishing = false
    private var loggedFeed = false

    private static var current: UpdateProbe?

    static func run(_ options: UpdateProbeOptions) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        // No Dock icon, no menu bar item, never active, no windows.
        app.setActivationPolicy(.prohibited)
        let probe = UpdateProbe(options: options)
        current = probe
        DispatchQueue.main.async { MainActor.assumeIsolated { probe.begin() } }
        app.run()
    }

    private init(options: UpdateProbeOptions) {
        self.options = options
    }

    private func say(_ line: String) {
        print(String(format: "[%6.2fs] ", Date().timeIntervalSince(start)) + line)
    }

    private func begin() {
        say("update probe: \(Bundle.main.bundleIdentifier ?? "?") \(build.displayVersion), beta build: \(build.isBeta)")
        guard let feedURL = options.feedURL else {
            say("ERROR: \(options.problem ?? "no feed")")
            exit(Status.cannotStart.rawValue)
        }
        guard build.updatesItself else {
            say("ERROR: this build has no SUPublicEDKey (PLAMONIC_SPARKLE_PUBLIC_KEY was empty); it never updates")
            exit(Status.cannotStart.rawValue)
        }
        say("public key: \(Self.mask(build.sparklePublicKey)); feed (\(options.feedName)): \(feedURL.absoluteString)")

        let bundle = Bundle.main
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
        } catch {
            say("ERROR: the updater did not start: \(Self.describe(error))")
            exit(Status.cannotStart.rawValue)
        }
        // With automatic downloads Sparkle installs at quit without asking the user driver.
        guard !updater.automaticallyDownloadsUpdates else {
            say("ERROR: automatic downloads are on for this bundle ID; the probe would install the update")
            exit(Status.cannotStart.rawValue)
        }
        updater.checkForUpdatesInBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout) {
            MainActor.assumeIsolated {
                guard let probe = UpdateProbe.current, !probe.finishing else { return }
                probe.say("ERROR: no result after \(Int(probe.options.timeout)) s")
                exit(Status.timeout.rawValue)
            }
        }
    }

    /// Ends the run once Sparkle closed its session. The pause lets a cancelled installer receive the cancellation
    /// before this process is gone (an installer whose app quit would install).
    private func finish() {
        guard !finishing else { return }
        finishing = true
        let status = outcome ?? .updaterError
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                UpdateProbe.current?.say("result: \(status) (exit \(status.rawValue))")
                exit(status.rawValue)
            }
        }
    }

    private func record(_ status: Status) {
        if outcome == nil { outcome = status }
    }

    /// The first characters only: enough to tell keys apart in a log.
    nonisolated static func mask(_ key: String) -> String {
        key.isEmpty ? "none" : "\(key.prefix(4))… (\(key.count) characters)"
    }

    nonisolated static func noUpdateReason(_ reason: Int32?) -> String {
        switch reason.flatMap(SPUNoUpdateFoundReason.init(rawValue:)) {
        case .onLatestVersion: "this is the latest version"
        case .onNewerThanLatestVersion: "this build is newer than the feed's latest"
        case .systemIsTooOld: "the update needs a newer macOS"
        case .systemIsTooNew: "the update needs an older macOS"
        case .hardwareDoesNotSupportARM64: "the update needs Apple silicon"
        default: "unknown reason"
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code): \(underlying.localizedDescription))"
        }
        return text
    }
}

extension UpdateProbe: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        if !loggedFeed {
            loggedFeed = true
            say("Sparkle asked for the feed: \(options.feedURL?.absoluteString ?? "-")")
        }
        return options.feedURL?.absoluteString
    }

    // A background check reports "no update" and its errors here, not through the user driver.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        say("no update: \(Self.noUpdateReason(reason?.int32Value)) (\((error as NSError).localizedDescription))")
        record(.noUpdate)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        guard !(ns.domain == SUSparkleErrorDomain && ns.code == Int(SUError.noUpdateError.rawValue)) else { return }
        // The user driver may have reported it already.
        guard outcome == nil else { return }
        say("ERROR: \(Self.describe(error))")
        record(.updaterError)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finish()
    }
}

extension UpdateProbe: SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        say("unexpected: Sparkle asked for permission to check (SUEnableAutomaticChecks missing?)")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        say(
            "found: version \(appcastItem.displayVersionString), build \(appcastItem.versionString), "
                + "channel \(appcastItem.channel ?? "default"), size \(appcastItem.contentLength) bytes, "
                + "archive \(appcastItem.fileURL?.absoluteString ?? "none")")
        if appcastItem.isInformationOnlyUpdate {
            say("ERROR: an information-only update has no archive to verify")
            record(.updaterError)
            reply(.dismiss)
        } else if state.stage == .installing {
            // An installation armed by an earlier run: cancel it rather than let it install.
            // Skip here also marks the build as skipped, and later background checks honor that.
            say(
                "ERROR: an earlier installation of this update was waiting; cancelled. Sparkle now skips build "
                    + "\(appcastItem.versionString): defaults delete \(Bundle.main.bundleIdentifier ?? "<bundle id>") "
                    + "SUSkippedVersion")
            record(.updaterError)
            reply(.skip)
        } else {
            say(state.stage == .downloaded ? "already downloaded; verifying" : "downloading")
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        say("no update: \(Self.describe(error))")
        record(.noUpdate)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        say("ERROR: \(Self.describe(error))")
        record(.updaterError)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadedBytes = 0
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        say("download size: \(expectedContentLength) bytes")
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedBytes += length
    }

    func showDownloadDidStartExtractingUpdate() {
        say("downloaded \(downloadedBytes) bytes; Sparkle extracts and verifies the archive")
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        say("verified: ready to install; cancelling the installation")
        record(.verified)
        // Skip cancels the installation (dismiss would install at quit); the version is not marked as skipped.
        reply(.skip)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
    ) {
        say("ERROR: unexpected installation step")
        record(.updaterError)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        finish()
    }
}
