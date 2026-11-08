import AppKit
import Combine
import os

/// The real-time loop: tracks the frontmost app, scans its window on a background queue, passes the
/// snapshots to the TranslationCoordinator and draws its items with the OverlayController.
///
/// All state lives on the main actor; every AX call runs on `SessionScanner.queue`.
/// One scan batch is in flight at a time. Windows of apps that were translated before stay tracked
/// at the background interval when `keepTranslatingWhenInactive` is on.
@MainActor
final class LiveTranslationSession {
    struct Options {
        /// false = headless (no overlay panels, no popups).
        var showsOverlays = true
        /// Track only this process, as if it were frontmost; app switches are ignored (smoke test).
        var pinnedPID: pid_t?
        /// Replaces the mode of every app (smoke test).
        var forcedMode: TranslationMode?
        /// Replaces the target language of every app (smoke test).
        var forcedTargetLanguage: String?
        /// Install global mouse / keyboard monitors (scroll hiding, reveal original, hover, Esc).
        var monitorsInput = true
        /// Links clicked or right-clicked in translations are only reported, never pressed or opened, and no
        /// menu is shown (smoke test).
        var dryRunLinks = false
        /// How often the password guard polls while there are apps to read (DESIGN §4.1).
        var passwordPollInterval: TimeInterval = PasswordEntryGuard.defaultPollInterval
        /// Tests: windows are read by this instead of AX (the password gate still asks first).
        var scanRead: (@Sendable (ScanRequest) -> ScanResult)?
        /// Tests: this app is in front at the start (it need not exist). Workspace notifications are not followed
        /// (`applicationActivated` switches apps) and no AX observers are registered (`handleEvents` delivers).
        var testApp: TestApp?

        init() {}
    }

    struct TestApp {
        var pid: pid_t
        var bundleID: String
        var name: String
    }

    /// After every scanned window (also the skipped ones). Items are nil when the snapshot was not used.
    var onScanned: ((ScanResult, [OverlayItem]?) -> Void)?
    /// After the items of a window were redrawn because a translation changed.
    var onItemsRedrawn: ((WindowKey, [OverlayItem]) -> Void)?
    /// Selection / manual popup results (text, translation or nil).
    var onPopupTranslated: ((String, String?) -> Void)?
    var onStatusChanged: ((SessionStatus) -> Void)?
    /// After a link in a translation was activated (pressed, opened, or ignored).
    var onLinkActivated: ((LinkActivationReport) -> Void)?
    /// After a link in a translation was right-clicked: which menu was shown (or would be, or none).
    var onLinkMenuShown: ((LinkMenuReport) -> Void)?
    /// Password pause changes, guard evaluations and terminal prompt pauses (names and window numbers only).
    var onPasswordGuard: ((PasswordGuardNote) -> Void)?
    private(set) var status = SessionStatus()

    /// Process whose windows get priority in the translation queue.
    var activePID: pid_t? { options.pinnedPID ?? frontmost?.pid }

    private struct AppIdentity: Equatable {
        var pid: pid_t
        var bundleID: String
        var name: String
    }

    private struct WindowTrack {
        var key: WindowKey
        var element: AXElement
        var cgWindowID: CGWindowID?
        var lastScan: CFAbsoluteTime = 0
        var axFrame: CGRect = .zero
        var clip: CGRect?
        /// Areas that scroll on their own (`WindowSnapshot.scrollRegions`); empty = the whole window.
        var scrollRegions: [CGRect] = []
        /// Segments of the last snapshot passed to the coordinator.
        var segmentCount = 0
        var truncatedStreak = 0
        /// The coordinator and the overlay have state for this window.
        var shown = false
        /// Segment ids and window-relative frames of a manual translation, to notice content changes.
        var manualSignature: [String: CGRect]?
        /// The terminal waits for a password in this window: no timed scans (DESIGN §4.1, rule c).
        var promptPause: TerminalPromptPause?
    }

    /// The selection (or manual selection) popup of an app.
    private struct SelectionPopup {
        var text: String
        /// Frame of the selected text (AX); the popup sits next to it.
        var anchor: CGRect
        /// Window the selection is in; scrolling in it hides the popup until the next scan moves it.
        var window: WindowKey
        var translation = ""
        var state: OverlayItemState = .pending
    }

    private final class AppTarget {
        let app: AppIdentity
        var settings: EffectiveSettings
        var isActive = false
        var windows: [WindowKey: WindowTrack] = [:]
        var focusedKey: WindowKey?
        var lastActiveScan: CFAbsoluteTime = 0
        /// Rescan after AX notifications or mouse moves (debounced).
        var eventDue: CFAbsoluteTime?
        var lastEventScan: CFAbsoluteTime = 0
        /// Scan every window of the app at the next tick.
        var forceScan = false
        /// The translate-now hotkey asked for a manual scan.
        var pendingManual = false
        /// Repeat the manual scan at this time: the app was still building its accessibility tree.
        var manualRetryAt: CFAbsoluteTime?
        var observed = false
        var observeRetryAt: CFAbsoluteTime = 0
        /// The app did not answer its last scans: none until this time. All scans share one queue, so a hung
        /// app would otherwise hold up every other app's scans for its AX timeouts on every tick.
        var scanBackoffUntil: CFAbsoluteTime?
        var unavailableStreak = 0
        var manualKeys: Set<WindowKey> = []
        /// The selection shown in the popup.
        var selection: SelectionPopup?
        /// Selection whose popup the user closed; it is not shown again until the selection changes.
        var dismissedSelectionText: String?

        var selectionText: String? { selection?.text }

        init(app: AppIdentity, settings: EffectiveSettings) {
            self.app = app
            self.settings = settings
        }
    }

    private static let eventDebounce: CFAbsoluteTime = 0.08
    private static let minEventSpacing: CFAbsoluteTime = 0.15
    private static let scrollQuietDelay: CFAbsoluteTime = 0.15
    private static let mouseScanDebounce: CFAbsoluteTime = 0.12
    private static let hoverUpdateInterval: CFAbsoluteTime = 0.03
    private static let manualWarmUpRetry: CFAbsoluteTime = 0.5
    /// First wait after an unanswered scan; doubles per unanswered scan up to `maxUnavailableBackoff`.
    private static let unavailableBackoff: CFAbsoluteTime = 0.5
    private static let maxUnavailableBackoff: CFAbsoluteTime = 4

    private let settingsStore: SettingsStore
    private let coordinator: TranslationCoordinator
    private let overlay: OverlayController?
    private let options: Options
    /// Loads the models of an app's plan ahead of its first translation.
    private let preload: (EffectiveSettings) -> Void
    private let scanner: SessionScanner
    /// Tells when a password is being typed; the scanner asks it right before reading (DESIGN §4.1).
    private let passwordGuard: PasswordEntryGuard
    private let input = InputMonitor()
    /// Opens the links clicked in translations and shows the menus of right-clicked ones. DESIGN §6.1.
    private let links: LinkActivator
    private let ownPID = getpid()
    private let log = Logger(subsystem: "io.smdr.Plamonic", category: "Session")

    private var running = false
    private var eventHub: AXEventHub?
    private var coalescer: AXEventCoalescer?
    private var frontmost: AppIdentity?
    private var targets: [pid_t: AppTarget] = [:]
    private var scanInFlight = false
    private var timer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Windows with translations hidden by a scroll: the whole overlay, or the areas in `scrollHiddenRegions`.
    private var scrollHidden: Set<WindowKey> = []
    /// Areas of a window whose translations are left out while they scroll (ScrollHidePolicy).
    private var scrollHiddenRegions: [WindowKey: [CGRect]] = [:]
    /// Windows scrolled outside every area they translate: nothing is hidden, but they are rescanned once
    /// the scroll stops, in case something moved after all (a divider dragged between two panels).
    private var scrollRescan: Set<WindowKey> = []
    private var scrollQuietDeadline: CFAbsoluteTime?
    private var unhideRequested: Set<WindowKey> = []
    /// Mouse moves passed to the overlay (hover popups, originals shown in place, click panels).
    private lazy var hoverMoves = MouseMoveForwarder(interval: Self.hoverUpdateInterval) { [weak self] point in
        guard let self, running else { return }
        overlay?.updateMouseLocation(ax: point)
    }
    private var popupGeneration = 0
    /// Translation of the selection popup; cancelled when the popup is replaced or closed.
    private var popupTask: Task<Void, Never>?
    /// Rules a and b hold (secure input, a focused password field): nothing is read. DESIGN §4.1.
    private var passwordPause: PasswordPause?
    /// The frontmost app as NSWorkspace says (also while the session follows a pinned app or its own windows).
    private var realFront: (pid: pid_t, name: String?)?

    init(
        settings: SettingsStore, coordinator: TranslationCoordinator, overlay: OverlayController?,
        options: Options = Options(), links: LinkActivator? = nil,
        passwordSystem: PasswordEntrySystem = .live,
        preload: @escaping (EffectiveSettings) -> Void = { _ in }
    ) {
        self.settingsStore = settings
        self.coordinator = coordinator
        self.overlay = options.showsOverlays ? overlay : nil
        self.options = options
        let links = links ?? LinkActivator()
        self.links = links
        self.preload = preload
        let ref = SessionRef()
        let passwordGuard = PasswordEntryGuard(system: passwordSystem, pollInterval: options.passwordPollInterval) {
            event in ref.session?.passwordGuardEvent(event)
        }
        self.passwordGuard = passwordGuard
        scanner = SessionScanner(gate: { passwordGuard.gate() }, read: options.scanRead)
        ref.session = self
        links.dryRun = options.dryRunLinks
        coordinator.onItemsChanged = { [weak self] key in self?.redraw(key) }
        self.overlay?.onLinkActivated = { [weak self] key, itemID, link in
            self?.activateLink(link, window: key, itemID: itemID)
        }
        self.overlay?.onLinkContextMenu = { [weak self] key, itemID, link, point in
            self?.showLinkMenu(link, window: key, itemID: itemID, at: point)
        }
        // The menu took the pointer: the pointing hand stays only if the pointer is back on a translated link.
        links.onOwnMenuClosed = { [weak overlay = self.overlay] in overlay?.revalidateCursor() }
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        let coalescer = AXEventCoalescer { [weak self] batch in self?.handleEvents(batch) }
        self.coalescer = coalescer
        eventHub = AXEventHub { event in coalescer.add(event) }
        if options.testApp == nil { installWorkspaceObservers() }
        installInputHandlers()
        makeTimer()

        if let app = options.testApp {
            realFront = (app.pid, app.name)
            activate(pid: app.pid, bundleID: app.bundleID, name: app.name)
        } else {
            realFront = NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.localizedName) }
            if let pinned = options.pinnedPID {
                if let app = NSRunningApplication(processIdentifier: pinned) { activate(app) }
            } else if let app = NSWorkspace.shared.frontmostApplication {
                activate(app)
            }
        }
        publishStatus()
        reschedule()
    }

    /// Removes every overlay and stops all work. The session can be started again.
    func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        input.stopAll()
        let hub = eventHub
        eventHub = nil
        coalescer = nil
        scanner.perform { hub?.stop() }
        for pid in Array(targets.keys) { removeTarget(pid) }
        // Translation stopped: turn back off the accessibility attributes Plamonic switched on (AX calls).
        scanner.perform { AppAccessibilityEnabler.shared.restoreAll() }
        popupTask?.cancel()
        popupTask = nil
        links.cancelOwnMenu()
        overlay?.removeAll()
        overlay?.revealOriginal = false
        coordinator.cancelAll()
        scrollHidden.removeAll()
        scrollHiddenRegions.removeAll()
        scrollRescan.removeAll()
        scrollQuietDeadline = nil
        unhideRequested.removeAll()
        hoverMoves.reset()
        frontmost = nil
        realFront = nil
        if passwordPause != nil {
            passwordPause = nil
            OverlayColorSampleScheduler.setCapturesPaused(false)
        }
        publishStatus()
    }

    /// Re-reads the settings of every tracked app. Call after the settings changed.
    func settingsDidChange() {
        guard running else { return }
        var preloadFront = false
        if !settingsStore.global.pauseDuringPasswordEntry {
            // Off: terminal prompts are scanned as before (the guard learns it from the status update below).
            for target in targets.values {
                for key in Array(target.windows.keys) { target.windows[key]?.promptPause = nil }
            }
        }
        for target in Array(targets.values) {
            let fresh = effectiveSettings(target.app)
            if fresh.mode == .off || (!target.isActive && !keepsInBackground(fresh)) {
                removeTarget(target.app.pid)
                continue
            }
            let old = target.settings
            target.settings = fresh
            if old.mode != fresh.mode || old.profile.scope != fresh.profile.scope {
                // Switching between automatic and manual, or to another scope, starts over.
                dismissManual(target)
                for key in Array(target.windows.keys) { hideWindow(key, in: target) }
            } else if Self.overlayStyle(old) != Self.overlayStyle(fresh) {
                // Display style, look or pointer / link behaviour changed: redraw now, not at the next scan.
                for (key, track) in target.windows where track.shown { redraw(key) }
            }
            target.forceScan = fresh.mode == .automatic
            // Only automatic translation needs the models up front; other edits must not undo an idle unload.
            // The draft model is the app's own (段階翻訳 can be switched per app), not the global one.
            if target.app.pid == frontmost?.pid, fresh.mode == .automatic,
                old.mode != .automatic || old.global.finalModel != fresh.global.finalModel
                    || old.draftModel != fresh.draftModel
            {
                preloadFront = true
            }
        }
        restoreAccessibilityOfAppsTurnedOff()
        if let front = frontmost, targets[front.pid] == nil,
            options.testApp?.pid == front.pid || NSRunningApplication(processIdentifier: front.pid) != nil
        {
            activate(pid: front.pid, bundleID: front.bundleID, name: front.name)
        } else if preloadFront, let front = frontmost, let target = targets[front.pid] {
            preload(target.settings)
        }
        updateInputMonitors()
        publishStatus()
        reschedule()
    }

    /// Apps whose translation is now off (their mode, or translation as a whole) get back the accessibility
    /// attributes Plamonic switched on, whether or not they are tracked: a background app stops being a
    /// target on an app switch. Not done on every app switch, since Chromium rebuilds its tree when the
    /// attribute comes back on.
    private func restoreAccessibilityOfAppsTurnedOff() {
        var turnedOff: [pid_t] = []
        for pid in AppAccessibilityEnabler.shared.trackedPIDs() {
            guard let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier else {
                continue
            }
            let identity = AppIdentity(pid: pid, bundleID: bundleID, name: app.localizedName ?? bundleID)
            if effectiveSettings(identity).mode == .off { turnedOff.append(pid) }
        }
        guard !turnedOff.isEmpty else { return }
        let pids = turnedOff
        scanner.perform {
            for pid in pids { AppAccessibilityEnabler.shared.restore(pid: pid) }
        }
    }

    // MARK: - Commands

    /// The translate-now hotkey. Manual mode: translate the focused window once, or dismiss a manual
    /// translation that is shown. Automatic mode: rescan right away and retry failed texts.
    func translateNow() {
        guard running, let pid = activePID, let target = targets[pid] else {
            NSSound.beep()
            return
        }
        switch target.settings.mode {
        case .off:
            NSSound.beep()
        case .automatic:
            if target.selectionText != nil {
                // The menu offers "close" while the selection popup is shown.
                dismissManual(target, byUser: true)
                updateInputMonitors()
                publishStatus()
                return
            }
            if passwordPauseIgnoresTranslateNow() { return }
            coordinator.retryFailed()
            target.forceScan = true
            target.scanBackoffUntil = nil
            tick()
        case .manual:
            if !target.manualKeys.isEmpty || target.selectionText != nil {
                dismissManual(target)
                updateInputMonitors()
                publishStatus()
                return
            }
            if passwordPauseIgnoresTranslateNow() { return }
            target.pendingManual = true
            // Asked explicitly: try once even if the app did not answer a moment ago.
            target.scanBackoffUntil = nil
            // Manual apps load the models only when asked to translate; the load overlaps the scan.
            // A selection popup uses only the final model, which translateOnce loads by itself.
            if target.settings.profile.scope != .selection { preload(target.settings) }
            tick()
        }
    }

    /// 今すぐ翻訳 reads nothing while a password is typed (closing what is shown still works).
    private func passwordPauseIgnoresTranslateNow() -> Bool {
        guard let pause = passwordPause else { return false }
        log.notice("translate-now ignored: password entry (\(pause.logDescription, privacy: .public))")
        onPasswordGuard?(.translateNowIgnored(pause))
        return true
    }

    /// Esc: removes manual translations and popups.
    func dismissAllManual() {
        for target in targets.values { dismissManual(target, byUser: true) }
        overlay?.hidePopup()
        updateInputMonitors()
        publishStatus()
    }

    // MARK: - Frontmost app

    /// An app came to the front (NSWorkspace; tests call it directly).
    func applicationActivated(pid: pid_t, bundleID: String?, name: String?) {
        guard running else { return }
        realFront = (pid, name)
        activate(pid: pid, bundleID: bundleID, name: name)
        // The guard sees the new front app with its next context; check now, not at the next poll.
        publishStatus()
        passwordGuard.checkSoon()
    }

    private func activate(_ app: NSRunningApplication) {
        activate(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    private func activate(pid: pid_t, bundleID: String?, name: String?) {
        guard running else { return }
        // Our own settings / onboarding windows: keep translating what was in front before.
        guard pid != ownPID else { return }
        if let pinned = options.pinnedPID, pid != pinned { return }
        guard let bundleID, !bundleID.isEmpty else { return }
        let identity = AppIdentity(pid: pid, bundleID: bundleID, name: name ?? bundleID)

        if let previous = frontmost, previous.pid != pid, let old = targets[previous.pid] {
            old.isActive = false
            dismissManual(old)
            if !keepsInBackground(old.settings) { removeTarget(previous.pid) }
        }
        frontmost = identity

        let settings = effectiveSettings(identity)
        if settings.mode == .off {
            removeTarget(pid)
        } else {
            let target = targets[pid] ?? AppTarget(app: identity, settings: settings)
            targets[pid] = target
            target.settings = settings
            target.isActive = true
            target.forceScan = settings.mode == .automatic
            target.scanBackoffUntil = nil
            observe(target)
            // Manual apps load the models on translate-now, so switching apps does not undo an idle unload.
            if settings.mode == .automatic { preload(settings) }
        }
        updateInputMonitors()
        publishStatus()
        reschedule()
    }

    private func keepsInBackground(_ settings: EffectiveSettings) -> Bool {
        settings.mode == .automatic && settings.keepTranslatingWhenInactive
            && settings.profile.scope != .underMouse && settings.profile.scope != .selection
    }

    private func effectiveSettings(_ app: AppIdentity) -> EffectiveSettings {
        var settings = settingsStore.effectiveSettings(bundleID: app.bundleID, appName: app.name)
        if let forced = options.forcedMode {
            settings.global.isEnabled = true
            settings.profile.mode = forced
        }
        if let language = options.forcedTargetLanguage { settings.profile.targetLanguageOverride = language }
        return settings
    }

    private func removeTarget(_ pid: pid_t) {
        guard let target = targets.removeValue(forKey: pid) else { return }
        for key in target.windows.keys {
            overlay?.remove(window: key)
            coordinator.forget(window: key)
            scrollHidden.remove(key)
            scrollHiddenRegions[key] = nil
            scrollRescan.remove(key)
        }
        hideSelection(target)
        if target.observed, let hub = eventHub {
            scanner.perform { hub.unobserve(pid: pid) }
        }
    }

    /// Drops the overlay and pending translations of one window but keeps tracking it.
    private func hideWindow(_ key: WindowKey, in target: AppTarget) {
        guard var track = target.windows[key] else { return }
        if track.shown {
            overlay?.remove(window: key)
            coordinator.forget(window: key)
        }
        track.shown = false
        track.segmentCount = 0
        track.manualSignature = nil
        target.windows[key] = track
        target.manualKeys.remove(key)
    }

    private func dropWindow(_ key: WindowKey, in target: AppTarget) {
        hideWindow(key, in: target)
        target.windows[key] = nil
        if target.focusedKey == key { target.focusedKey = nil }
    }

    private func observe(_ target: AppTarget) {
        guard !target.observed, let hub = eventHub else { return }
        if options.testApp != nil {
            // Tests deliver events with `handleEvents`.
            target.observed = true
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= target.observeRetryAt else { return }
        target.observed = true
        let pid = target.app.pid
        scanner.perform {
            // Blocks the scan queue until registered; refused apps are retried later.
            let accepted = hub.observe(pid: pid)
            guard accepted.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let target = self?.targets[pid] else { return }
                    target.observed = false
                    target.observeRetryAt = CFAbsoluteTimeGetCurrent() + 5
                }
            }
        }
    }

    // MARK: - Scheduling

    private func makeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        self.timer = timer
    }

    private func reschedule() {
        guard running, let timer, !scanInFlight else { return }
        guard let due = nextDueTime() else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        let delay = max(0.005, due - CFAbsoluteTimeGetCurrent())
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(10))
    }

    private func nextDueTime() -> CFAbsoluteTime? {
        let now = CFAbsoluteTimeGetCurrent()
        var due: CFAbsoluteTime?
        func consider(_ time: CFAbsoluteTime) { due = min(due ?? time, time) }
        if let deadline = scrollQuietDeadline { consider(deadline) }
        // Nothing is read while a password is typed; the end of the pause rescans everything.
        guard passwordPause == nil else { return due }
        for target in targets.values {
            if let until = target.scanBackoffUntil, until > now {
                // Its pending scans (forced, events, manual) run when the back-off ends.
                consider(until)
                continue
            }
            if target.forceScan || target.pendingManual { consider(now) }
            if let eventDue = target.eventDue { consider(eventDue) }
            if !target.observed { consider(max(target.observeRetryAt, now + 1)) }
            let global = target.settings.global
            if target.isActive {
                switch target.settings.mode {
                case .automatic:
                    if let time = focusedTimedScan(target, regular: global.scanInterval) { consider(time) }
                case .manual:
                    if let retry = target.manualRetryAt { consider(retry) }
                    if !target.manualKeys.isEmpty,
                        let time = focusedTimedScan(target, regular: global.backgroundScanInterval)
                    {
                        consider(time)
                    }
                default: break
                }
            }
            guard target.settings.mode == .automatic else { continue }
            for track in target.windows.values where track.key != target.focusedKey || !target.isActive {
                if let time = backgroundTimedScan(track, global: global) { consider(time) }
            }
        }
        return due
    }

    /// The next timed scan of the active app's focused window; nil while it waits at a password prompt that
    /// the guard's probe watches (DESIGN §4.1, rule c).
    private func focusedTimedScan(_ target: AppTarget, regular: CFAbsoluteTime) -> CFAbsoluteTime? {
        TerminalPromptPause.nextTimedScan(
            pause: target.focusedKey.flatMap { target.windows[$0]?.promptPause }, lastScan: target.lastActiveScan,
            regular: regular, background: target.settings.global.backgroundScanInterval,
            watched: probeWatchesFocusedWindow(of: target))
    }

    private func backgroundTimedScan(_ track: WindowTrack, global: GlobalSettings) -> CFAbsoluteTime? {
        TerminalPromptPause.nextTimedScan(
            pause: track.promptPause, lastScan: track.lastScan, regular: global.backgroundScanInterval,
            background: global.backgroundScanInterval, watched: false)
    }

    /// The guard probes the focused element of the app Plamonic reads at the front, so it sees new output in
    /// that app's focused window.
    private func probeWatchesFocusedWindow(of target: AppTarget) -> Bool {
        target.isActive && target.app.pid == activePID && asksFocusedField(of: target.app.pid)
    }

    private func tick() {
        guard running, !scanInFlight else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if let deadline = scrollQuietDeadline, now >= deadline {
            // Scrolling / dragging stopped: rescan the hidden windows and show them again afterwards.
            scrollQuietDeadline = nil
            unhideRequested.formUnion(scrollHidden)
            for key in scrollHidden.union(scrollRescan) { targets[key.pid]?.forceScan = true }
            scrollRescan.removeAll()
        }
        if passwordPause != nil {
            // Nothing is read while a password is typed. What is due waits: the end of the pause rescans.
            reschedule()
            return
        }

        var requests: [ScanRequest] = []
        var mouse: CGPoint?
        func mouseLocation() -> CGPoint {
            if let mouse { return mouse }
            let point = AXGeometry.mouseLocationAX()
            mouse = point
            return point
        }

        for target in targets.values {
            if let until = target.scanBackoffUntil {
                if now < until { continue }
                target.scanBackoffUntil = nil
            }
            if !target.observed { observe(target) }
            let settings = target.settings
            let global = settings.global
            let limits = ExtractionLimits(global: global)
            let eventDue = target.eventDue.map { $0 <= now } ?? false
            let force = target.forceScan
            var focusedRequested = false

            func request(_ scanTarget: ScanRequest.Target, manual: Bool = false) {
                let needsMouse = settings.profile.scope == .underMouse
                requests.append(
                    ScanRequest(
                        pid: target.app.pid, bundleID: target.app.bundleID, target: scanTarget, settings: settings,
                        limits: limits, mouseAX: needsMouse ? mouseLocation() : nil, manual: manual))
            }

            if target.isActive {
                switch settings.mode {
                case .automatic:
                    let timed = focusedTimedScan(target, regular: global.scanInterval).map { now >= $0 } ?? false
                    if force || eventDue || timed {
                        request(.focusedWindow)
                        focusedRequested = true
                    }
                case .manual:
                    let retryDue = target.manualRetryAt.map { $0 <= now } ?? false
                    if target.pendingManual || retryDue {
                        target.pendingManual = false
                        target.manualRetryAt = nil
                        request(.focusedWindow, manual: true)
                        focusedRequested = true
                    } else if !target.manualKeys.isEmpty,
                        force || eventDue
                            || focusedTimedScan(target, regular: global.backgroundScanInterval).map({ now >= $0 })
                                == true
                    {
                        request(.focusedWindow)
                        focusedRequested = true
                    }
                case .off:
                    break
                }
                if focusedRequested { target.lastActiveScan = now }
            }

            if settings.mode == .automatic {
                // The active app's other windows follow its events only at the pace used for background apps.
                let eventSpacing = max(0.5, global.backgroundScanInterval / 2)
                for (key, track) in target.windows where !(target.isActive && key == target.focusedKey) {
                    let sinceScan = now - track.lastScan
                    let eventScan = eventDue && (!target.isActive || sinceScan >= eventSpacing)
                    let timed = backgroundTimedScan(track, global: global).map { now >= $0 } ?? false
                    guard force || eventScan || timed else { continue }
                    target.windows[key]?.lastScan = now
                    request(.window(track.element))
                }
            }
            if eventDue {
                target.eventDue = nil
                target.lastEventScan = now
            }
            target.forceScan = false
        }

        guard !requests.isEmpty else {
            if !unhideRequested.isEmpty {
                let keys = unhideRequested
                unhideRequested.removeAll()
                unhideWindows(keys, refreshed: [])
            }
            reschedule()
            return
        }
        let unhide = unhideRequested
        unhideRequested.removeAll()
        scanInFlight = true
        scanner.scan(requests) { [weak self] results in
            self?.handle(results, unhide: unhide)
        }
    }

    // MARK: - Scan results

    private func handle(_ results: [ScanResult], unhide: Set<WindowKey>) {
        scanInFlight = false
        guard running else { return }
        let now = CFAbsoluteTimeGetCurrent()
        /// Windows drawn from this batch's snapshots.
        var refreshed = Set<WindowKey>()
        for result in results {
            guard let target = targets[result.request.pid] else {
                onScanned?(result, nil)
                continue
            }
            var items: [OverlayItem]?
            let isFocusedScan: Bool
            if case .focusedWindow = result.request.target { isFocusedScan = true } else { isFocusedScan = false }

            switch result.outcome {
            case .unavailable:
                // Back off exponentially while the app does not answer.
                target.unavailableStreak += 1
                let wait = Self.unavailableBackoff * pow(2, Double(min(target.unavailableStreak - 1, 8)))
                target.scanBackoffUntil = now + min(Self.maxUnavailableBackoff, wait)
            case .paused:
                // Not asked at all: the app's state is unknown.
                break
            default:
                target.unavailableStreak = 0
                target.scanBackoffUntil = nil
            }

            switch result.outcome {
            case .paused(let pause):
                // Skipped right before reading: nothing changes on screen. The end of the pause rescans.
                if result.request.manual { onPasswordGuard?(.translateNowIgnored(pause)) }

            case .unavailable:
                // Translate-now got no answer.
                if result.request.manual { NSSound.beep() }

            case .gone:
                if result.request.manual { NSSound.beep() }
                if isFocusedScan {
                    if let old = target.focusedKey { dropWindow(old, in: target) }
                } else if let element = result.window ?? requestedElement(result.request),
                    let key = target.windows.first(where: { $0.value.element == element })?.key
                {
                    dropWindow(key, in: target)
                }

            case .offScreen(let key):
                if result.request.manual { NSSound.beep() }
                if isFocusedScan, target.isActive { switchFocus(to: key, in: target) }
                if target.windows[key] == nil, let element = result.window {
                    target.windows[key] = WindowTrack(key: key, element: element, cgWindowID: result.cgWindowID)
                }
                hideWindow(key, in: target)
                target.windows[key]?.lastScan = now

            case .scanned(let snapshot):
                guard result.request.settings == target.settings else {
                    // Extracted with settings that changed meanwhile (scope, rules, mode): scan again instead.
                    switch target.settings.mode {
                    case .automatic: target.forceScan = true
                    case .manual where result.request.manual && target.isActive: target.pendingManual = true
                    default: break
                    }
                    break
                }
                let key = snapshot.key
                if isFocusedScan, target.isActive { switchFocus(to: key, in: target) }
                var track = target.windows[key] ?? WindowTrack(key: key, element: result.window!)
                if let element = result.window { track.element = element }
                track.cgWindowID = result.cgWindowID
                track.lastScan = now
                target.windows[key] = track
                if result.request.manual, result.diagnostics.warmingUp, target.isActive {
                    // The app has only just turned its accessibility tree on (Chromium) and is still building it:
                    // scan again shortly instead of reporting an empty or partial window as the result.
                    let incomplete = snapshot.segments.isEmpty || snapshot.truncated
                    if incomplete || target.settings.profile.scope != .selection {
                        target.manualRetryAt = now + Self.manualWarmUpRetry
                    }
                    if incomplete { break }
                }
                items = apply(snapshot, result: result, target: target)
                if items != nil { refreshed.insert(key) }
                notePasswordPrompt(snapshot, window: key, in: target, now: now)
            }
            onScanned?(result, items)
        }
        if scrollQuietDeadline == nil { unhideWindows(unhide, refreshed: refreshed) }
        updateInputMonitors()
        publishStatus()
        reschedule()
    }

    private func requestedElement(_ request: ScanRequest) -> AXElement? {
        if case .window(let element) = request.target { return element }
        return nil
    }

    /// The active app's focused window changed (or was seen for the first time).
    private func switchFocus(to key: WindowKey, in target: AppTarget) {
        guard let old = target.focusedKey, old != key else {
            target.focusedKey = key
            return
        }
        target.focusedKey = key
        if target.manualKeys.contains(old) { hideWindow(old, in: target) }
        if !keepsInBackground(target.settings) { dropWindow(old, in: target) }
    }

    /// Feeds a snapshot to the coordinator and the overlay. Returns the drawn items, or nil when unused.
    private func apply(_ snapshot: WindowSnapshot, result: ScanResult, target: AppTarget) -> [OverlayItem]? {
        let key = snapshot.key
        let settings = target.settings
        if result.request.manual {
            return showManual(snapshot, target: target)
        }
        if target.manualKeys.contains(key) {
            return verifyManual(snapshot, target: target)
        }
        guard settings.mode == .automatic else { return nil }
        if settings.profile.scope == .selection {
            showSelection(snapshot, target: target, manual: false)
            return nil
        }
        guard var track = target.windows[key] else { return nil }
        // A partial scan (budget hit, Chromium still building its tree) keeps the previous overlay,
        // unless that overlay is hidden after a scroll: its positions are stale, so draw what was found.
        let fewer = snapshot.segments.count < track.segmentCount
        if PartialScanPolicy.keepsPrevious(
            truncated: snapshot.truncated, fewer: fewer, streak: track.truncatedStreak,
            scrolled: scrollHidden.contains(key))
        {
            track.truncatedStreak += 1
            target.windows[key] = track
            return nil
        }
        if fewer, snapshot.segments.isEmpty, result.diagnostics.warmingUp {
            return nil
        }
        track.truncatedStreak = PartialScanPolicy.streak(
            afterApplying: snapshot.truncated, fewer: fewer, streak: track.truncatedStreak)
        track.segmentCount = snapshot.segments.count
        track.axFrame = snapshot.axWindowFrame
        track.clip = snapshot.axClipRect
        track.scrollRegions = snapshot.scrollRegions
        track.shown = true
        target.windows[key] = track
        let items = coordinator.process(snapshot: snapshot, settings: settings)
        draw(key, items: items, target: target)
        return items
    }

    private func draw(_ key: WindowKey, items: [OverlayItem], target: AppTarget) {
        guard let overlay, let track = target.windows[key], track.shown else { return }
        let settings = target.settings
        // Translations in an area that is scrolling stay out until the scan after the scroll places them anew.
        let items = ScrollHidePolicy.visible(items, hiding: scrollHiddenRegions[key] ?? [])
        overlay.update(
            window: key, axWindowFrame: track.axFrame, axClipRect: track.clip, cgWindowID: track.cgWindowID,
            items: items, obstacles: coordinator.obstacles(for: key),
            style: Self.overlayStyle(settings),
            targetIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == key.pid)
    }

    /// A translation of one of the window's texts arrived or changed.
    private func redraw(_ key: WindowKey) {
        guard let target = targets[key.pid], target.windows[key]?.shown == true else { return }
        let items = coordinator.items(for: key)
        draw(key, items: items, target: target)
        onItemsRedrawn?(key, items)
    }

    private func unhide(_ key: WindowKey) {
        guard scrollHidden.remove(key) != nil else { return }
        overlay?.setTemporarilyHidden(false, window: key)
        if scrollHiddenRegions.removeValue(forKey: key) != nil { redraw(key) }
    }

    /// Shows windows hidden while scrolling again once a scan redrew them, or once nothing of them is shown.
    /// The others keep waiting for their next regular scan: their overlay still has the positions from
    /// before the scroll (the scan was partial, kept the previous items, or the app did not answer).
    private func unhideWindows(_ keys: Set<WindowKey>, refreshed: Set<WindowKey>) {
        for key in keys {
            if refreshed.contains(key) || targets[key.pid]?.windows[key]?.shown != true {
                unhide(key)
            } else {
                unhideRequested.insert(key)
            }
        }
    }

    // MARK: - Manual mode and popups

    private func showManual(_ snapshot: WindowSnapshot, target: AppTarget) -> [OverlayItem]? {
        let key = snapshot.key
        if target.settings.profile.scope == .selection {
            showSelection(snapshot, target: target, manual: true)
            return nil
        }
        guard !snapshot.segments.isEmpty else {
            // Nothing to translate: no manual translation is shown, so the next press translates again.
            hideWindow(key, in: target)
            NSSound.beep()
            return nil
        }
        guard var track = target.windows[key] else { return nil }
        track.axFrame = snapshot.axWindowFrame
        track.clip = snapshot.axClipRect
        track.scrollRegions = snapshot.scrollRegions
        track.segmentCount = snapshot.segments.count
        track.shown = true
        track.manualSignature = Self.signature(snapshot)
        target.windows[key] = track
        target.manualKeys.insert(key)
        let items = coordinator.process(snapshot: snapshot, settings: target.settings)
        draw(key, items: items, target: target)
        return items
    }

    /// Keeps a manual translation while the window shows the same texts at the same places.
    private func verifyManual(_ snapshot: WindowSnapshot, target: AppTarget) -> [OverlayItem]? {
        let key = snapshot.key
        guard var track = target.windows[key] else { return nil }
        if snapshot.truncated {
            // A partial scan cannot confirm the translation. After a scroll its positions are most likely
            // stale, and keeping it hidden until a complete scan could take forever in a huge window.
            if scrollHidden.contains(key) { hideWindow(key, in: target) }
            return nil
        }
        guard let signature = track.manualSignature, Self.sameSignature(signature, Self.signature(snapshot)) else {
            hideWindow(key, in: target)
            return nil
        }
        // Same content; the window may have moved, so pass the new frames on.
        track.axFrame = snapshot.axWindowFrame
        track.clip = snapshot.axClipRect
        track.scrollRegions = snapshot.scrollRegions
        target.windows[key] = track
        let items = coordinator.process(snapshot: snapshot, settings: target.settings)
        draw(key, items: items, target: target)
        return items
    }

    /// Removes the app's manual translations and its selection popup.
    /// - Parameter byUser: Esc or the hotkey closed it; an automatic selection popup then stays closed
    ///   until the selection changes.
    private func dismissManual(_ target: AppTarget, byUser: Bool = false) {
        for key in target.manualKeys { hideWindow(key, in: target) }
        target.manualKeys.removeAll()
        target.manualRetryAt = nil
        if byUser, let selection = target.selection { target.dismissedSelectionText = selection.text }
        hideSelection(target)
    }

    /// Hides the selection popup and cancels its translation, which would otherwise hold the queue.
    private func hideSelection(_ target: AppTarget) {
        guard target.selection != nil else { return }
        target.selection = nil
        popupGeneration += 1
        popupTask?.cancel()
        popupTask = nil
        overlay?.hidePopup()
    }

    private func showSelection(_ snapshot: WindowSnapshot, target: AppTarget, manual: Bool) {
        let segments = snapshot.segments.sorted { $0.order < $1.order }
        let text = segments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if manual {
                NSSound.beep()
            } else {
                target.dismissedSelectionText = nil
                hideSelection(target)
            }
            return
        }
        let anchor = segments.map(\.axFrame).reduce(CGRect.null) { $0.union($1) }
        let window = snapshot.key
        // Scroll hiding looks for the window under the pointer by its frame.
        target.windows[window]?.axFrame = snapshot.axWindowFrame
        if manual {
            target.dismissedSelectionText = nil
        } else {
            guard text != target.dismissedSelectionText else { return }
            target.dismissedSelectionText = nil
            if text == target.selectionText {
                // Same selection; the window may have scrolled or moved, so the popup follows it.
                movePopup(of: target, to: anchor, in: window)
                return
            }
        }
        target.selection = SelectionPopup(text: text, anchor: anchor, window: window)
        let settings = target.settings
        overlay?.showPopup(
            translation: "", original: text, state: .pending, nearAX: anchor, style: popupStyle(target),
            window: window)
        popupGeneration += 1
        let generation = popupGeneration
        let pid = target.app.pid
        // A new selection replaces the previous one: its translation is no longer wanted.
        popupTask?.cancel()
        popupTask = Task { [weak self] in
            guard let self else { return }
            let translation = await self.coordinator.translateOnce(text: text, settings: settings)
            guard generation == self.popupGeneration else { return }
            self.popupTask = nil
            guard let target = self.targets[pid], var popup = target.selection, popup.text == text else { return }
            popup.translation = translation ?? ""
            popup.state = translation == nil ? .failed : .final
            target.selection = popup
            self.overlay?.showPopup(
                translation: popup.translation, original: text, state: popup.state, nearAX: popup.anchor,
                style: self.popupStyle(target), window: popup.window)
            self.onPopupTranslated?(text, translation)
        }
    }

    /// Shows the selection popup next to the selection's new place.
    private func movePopup(of target: AppTarget, to anchor: CGRect, in window: WindowKey) {
        guard var popup = target.selection else { return }
        let old = popup.anchor
        guard popup.window != window || abs(old.minX - anchor.minX) > 1 || abs(old.minY - anchor.minY) > 1
            || abs(old.width - anchor.width) > 1 || abs(old.height - anchor.height) > 1
        else { return }
        popup.anchor = anchor
        popup.window = window
        target.selection = popup
        overlay?.showPopup(
            translation: popup.translation, original: popup.text, state: popup.state, nearAX: anchor,
            style: popupStyle(target), window: window)
    }

    private func popupStyle(_ target: AppTarget) -> OverlayStyle {
        Self.overlayStyle(target.settings)
    }

    static func overlayStyle(_ settings: EffectiveSettings) -> OverlayStyle {
        OverlayStyle(
            displayStyle: settings.displayStyle, appearance: settings.global.appearance,
            interaction: settings.global.interaction)
    }

    private static func signature(_ snapshot: WindowSnapshot) -> [String: CGRect] {
        let origin = snapshot.axWindowFrame.origin
        var result: [String: CGRect] = [:]
        for segment in snapshot.segments {
            result[segment.id] = segment.axFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        }
        return result
    }

    private static func sameSignature(_ a: [String: CGRect], _ b: [String: CGRect]) -> Bool {
        guard a.count == b.count else { return false }
        for (id, frame) in a {
            guard let other = b[id], abs(other.minX - frame.minX) <= 2, abs(other.minY - frame.minY) <= 2,
                abs(other.width - frame.width) <= 2, abs(other.height - frame.height) <= 2
            else { return false }
        }
        return true
    }

    // MARK: - Events

    /// Events that marks typed at a prompt cause (sudo's pwfeedback echoes one per key).
    private static let promptTextEvents: Set<AXEventKind> = [.valueChanged, .selectedTextChanged, .layoutChanged]

    /// The AX events of the apps Plamonic reads, coalesced per app (internal for tests).
    func handleEvents(_ batch: [pid_t: Set<AXEventKind>]) {
        guard running else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let windowEvents: Set<AXEventKind> = [
            .windowMiniaturized, .windowDeminiaturized, .windowMoved, .windowResized, .windowCreated,
            .focusedWindowChanged, .mainWindowChanged, .applicationHidden, .applicationShown,
        ]
        let focusEvents: Set<AXEventKind> = [.focusedElementChanged, .focusedWindowChanged, .mainWindowChanged]
        if batch.values.contains(where: { !$0.isDisjoint(with: focusEvents) }) {
            // A password field may have taken the focus: the guard checks at once instead of at its next poll.
            passwordGuard.checkSoon()
        }
        var promptResumed = false
        for (pid, kinds) in batch {
            guard let target = targets[pid] else { continue }
            if probeDecidesPromptEvents(kinds, in: target) {
                // Its focused window waits at a password prompt and the probe sees the insertion point: marks typed
                // there (sudo's pwfeedback) are told from output without reading, so no scan for these events.
                passwordGuard.checkSoon()
                continue
            }
            let why = "AX event: " + kinds.map(\.rawValue).sorted().joined(separator: ",")
            let textOnly = kinds.isSubset(of: Self.promptTextEvents)
            if textOnly, let key = target.focusedKey, let time = echoedMarksRescanTime(in: target, now: now) {
                // Its focused window's prompt echoes a mark per key and the probe cannot tell marks from output:
                // read at most once per fallback interval (output after Return is read then too).
                if resumePrompt(key, in: target, why: why + ", echoed marks: deferred", textChanged: true) {
                    promptResumed = true
                }
                target.eventDue = min(target.eventDue ?? time, time)
                continue
            }
            // The app reported a change: windows waiting at a password prompt get one scan (the output changed
            // after Return, or the window or focus changed). The scan pauses them again if still at a prompt.
            for key in Array(target.windows.keys) where target.windows[key]?.promptPause != nil {
                if resumePrompt(key, in: target, why: why, textChanged: textOnly) { promptResumed = true }
            }
            let urgent = !kinds.isDisjoint(with: windowEvents)
            let spacing =
                target.isActive
                ? Self.minEventSpacing : max(0.5, target.settings.global.backgroundScanInterval / 2)
            // Window events skip the debounce, but a stream of them (live resize, moves) still keeps a gap.
            let due =
                urgent
                ? max(now, target.lastEventScan + Self.minEventSpacing)
                : max(now + Self.eventDebounce, target.lastEventScan + spacing)
            target.eventDue = min(target.eventDue ?? due, due)
        }
        if promptResumed {
            updateInputMonitors()
            publishStatus()
        }
        reschedule()
    }

    /// Text events of an app whose focused window waits at a password prompt that the probe watches, with the
    /// insertion point in sight.
    private func probeDecidesPromptEvents(_ kinds: Set<AXEventKind>, in target: AppTarget) -> Bool {
        guard kinds.isSubset(of: Self.promptTextEvents), probeWatchesFocusedWindow(of: target),
            let key = target.focusedKey, let pause = target.windows[key]?.promptPause
        else { return false }
        return pause.seesInsertionPoint
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (LiveTranslationSession, NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self, app)
                }
            }
            workspaceObservers.append(token)
        }
        on(NSWorkspace.didActivateApplicationNotification) { session, app in
            guard let app else { return }
            session.applicationActivated(
                pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { session, app in
            guard let pid = app?.processIdentifier else { return }
            session.appTerminated(pid)
        }
        on(NSWorkspace.didHideApplicationNotification) { session, app in
            guard let pid = app?.processIdentifier, let target = session.targets[pid] else { return }
            for key in Array(target.windows.keys) { session.hideWindow(key, in: target) }
            session.publishStatus()
        }
        on(NSWorkspace.didUnhideApplicationNotification) { session, app in
            guard let pid = app?.processIdentifier, let target = session.targets[pid] else { return }
            target.forceScan = true
            session.reschedule()
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { session, _ in
            for target in session.targets.values { target.forceScan = true }
            session.reschedule()
        }
    }

    private func appTerminated(_ pid: pid_t) {
        removeTarget(pid)
        scanner.invalidateCaches(pid: pid)
        AppAccessibilityEnabler.shared.forget(pid: pid)
        if frontmost?.pid == pid { frontmost = nil }
        if realFront?.pid == pid { realFront = nil }
        updateInputMonitors()
        publishStatus()
    }

    // MARK: - Input

    private func installInputHandlers() {
        input.onScrollOrDrag = { [weak self] point in self?.scrollOrDrag(at: point) }
        input.onMouseMoved = { [weak self] point in self?.mouseMoved(to: point) }
        input.onModifierFlagsChanged = { [weak self] flags in
            guard let self else { return }
            let key = self.settingsStore.global.showOriginalModifier
            self.overlay?.revealOriginal = InputMonitor.isOnlyModifierHeld(key, flags: flags)
        }
        input.onEscape = { [weak self] in self?.dismissAllManual() }
        // Translations show their original (or a cut one its full text) when the pointer rests on them.
        overlay?.onNeedsMouseMovesChanged = { [weak self] in self?.updateInputMonitors() }
    }

    /// The Esc keyDown monitor is wanted (installed only with `monitorsInput` and an overlay; tests read it).
    private(set) var escapeMonitoringWanted = false

    private func updateInputMonitors() {
        // A keyDown monitor sees every key typed in other apps: off while a password is typed (DESIGN §4.1).
        escapeMonitoringWanted =
            running && !passwordEntryActive
            && targets.values.contains { !$0.manualKeys.isEmpty || $0.selectionText != nil }
        guard running, options.monitorsInput, overlay != nil else {
            input.stopAll()
            return
        }
        let global = settingsStore.global
        let tracking = !targets.isEmpty
        input.setScrollMonitoring(tracking && global.hideWhileScrolling)
        input.setModifierMonitoring(tracking && global.showOriginalModifier != .none)
        input.setMouseMoveMonitoring(
            overlay?.needsMouseMoves == true
                || targets.values.contains {
                    $0.settings.displayStyle == .hover || ($0.isActive && $0.settings.profile.scope == .underMouse)
                })
        input.setEscapeMonitoring(escapeMonitoringWanted)
        if global.showOriginalModifier == .none { overlay?.revealOriginal = false }
    }

    private func scrollOrDrag(at point: CGPoint) {
        guard running, settingsStore.global.hideWhileScrolling else { return }
        var hit = false
        for target in targets.values {
            // The selection popup's window counts too: the popup hides until the next scan moves it.
            for (key, track) in target.windows
            where (track.shown || target.selection?.window == key) && track.axFrame.contains(point) {
                hit = true
                let popup = target.selection?.window == key
                switch popup ? .window : ScrollHidePolicy.hit(at: point, regions: track.scrollRegions) {
                case .window:
                    hideWhileScrolling(key)
                case .regions(let areas):
                    var hidden = scrollHiddenRegions[key] ?? []
                    let added = areas.filter { !hidden.contains($0) }
                    guard !added.isEmpty else { break }
                    hidden += added
                    if track.scrollRegions.allSatisfy(hidden.contains) {
                        // Every area moves (the window's only chat panel): the whole overlay goes at once.
                        hideWhileScrolling(key)
                    } else {
                        scrollHidden.insert(key)
                        scrollHiddenRegions[key] = hidden
                        redraw(key)
                    }
                case .none:
                    scrollRescan.insert(key)
                }
            }
        }
        guard hit else { return }
        scrollQuietDeadline = CFAbsoluteTimeGetCurrent() + Self.scrollQuietDelay
        reschedule()
    }

    private func hideWhileScrolling(_ key: WindowKey) {
        scrollHidden.insert(key)
        overlay?.setTemporarilyHidden(true, window: key)
    }

    private func mouseMoved(to point: CGPoint) {
        guard running else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // Throttled; a trailing update still tells the overlay where the pointer stopped.
        hoverMoves.move(to: point, at: now)
        var scheduled = false
        for target in targets.values where target.isActive && target.settings.profile.scope == .underMouse {
            target.eventDue = now + Self.mouseScanDebounce
            scheduled = true
        }
        if scheduled { reschedule() }
    }

    // MARK: - Links

    /// A link drawn in a translation was clicked: do what a click on the original link does.
    private func activateLink(_ link: SegmentLink, window: WindowKey, itemID: String) {
        guard running else { return }
        Task { [weak self, links] in
            let report = await links.activate(link, window: window, itemID: itemID)
            self?.onLinkActivated?(report)
        }
    }

    /// A link drawn in a translation was right-clicked at `point` (AX): show what right-clicking the original
    /// link shows (the app's own menu, or Plamonic's small menu).
    private func showLinkMenu(_ link: SegmentLink, window: WindowKey, itemID: String, at point: CGPoint) {
        guard running else { return }
        Task { [weak self, links] in
            let report = await links.showMenu(
                link, window: window, itemID: itemID, at: point,
                showOriginal: { [weak self] in
                    guard let self, running else { return }
                    overlay?.showOriginal(window: window, itemID: itemID)
                },
                opened: { [weak self] report in self?.onLinkActivated?(report) })
            self?.onLinkMenuShown?(report)
        }
    }

    // MARK: - Status

    private func publishStatus() {
        var next = SessionStatus()
        next.isRunning = running
        if let front = frontmost {
            next.frontmostAppName = front.name
            next.frontmostBundleID = front.bundleID
            next.frontmostMode = targets[front.pid]?.settings.mode ?? effectiveSettings(front).mode
        }
        next.activeWindowCount = targets.values.reduce(0) { $0 + $1.windows.values.filter(\.shown).count }
        next.manualActive = targets.values.contains { !$0.manualKeys.isEmpty || $0.selectionText != nil }
        next.passwordPause = passwordPause ?? activePromptPause()
        passwordGuard.update(passwordGuardContext())
        guard next != status else { return }
        status = next
        onStatusChanged?(next)
    }

    // MARK: - Password entry (DESIGN §4.1)

    /// Rules a or b hold, or the active window waits at a terminal password prompt (rule c).
    private var passwordEntryActive: Bool { passwordPause != nil || activePromptPause() != nil }

    /// The active app's focused window waits for a password.
    private func activePromptPause() -> PasswordPause? {
        guard let pid = activePID, let target = targets[pid], target.isActive, let key = target.focusedKey,
            target.windows[key]?.promptPause != nil
        else { return nil }
        return PasswordPause(reason: .terminalPrompt, appName: target.app.name)
    }

    private func passwordGuardContext() -> PasswordEntryGuard.Context {
        var context = PasswordEntryGuard.Context()
        guard running, settingsStore.global.pauseDuringPasswordEntry else { return context }
        context.isOn = true
        context.polls = !targets.isEmpty
        if let front = realFront {
            let terminal = targets[front.pid]?.settings.profile.textAreaHandling == .terminal
            context.front = PasswordFrontApp(pid: front.pid, name: front.name, isTerminalTarget: terminal)
        }
        // Rule b asks only an app Plamonic reads anyway (asking others could wake up Chromium accessibility in
        // apps the user turned off), and only while it is in front.
        if let pid = activePID, let target = targets[pid], target.isActive, asksFocusedField(of: pid) {
            context.fieldCheckPID = pid
            context.fieldCheckName = target.app.name
            context.probesFocusedText = activePromptPause() != nil
        }
        // An idle manual app (the default) reads nothing: rule b is polled only while something is read without
        // a key press. Translate-now's scan is still checked by the scanner's gate.
        context.pollsField = targets.values.contains(where: Self.readsWithoutKeyPress)
        return context
    }

    /// Rule b means something only for the app in front: while Plamonic's own window (or an app without a bundle
    /// ID) is in front, the session still follows the previous app, which keys nothing in. A pinned session
    /// treats its app as the front one (smoke test).
    private func asksFocusedField(of pid: pid_t) -> Bool {
        Self.asksFocusedField(of: pid, realFront: realFront?.pid, pinned: options.pinnedPID != nil)
    }

    static func asksFocusedField(of pid: pid_t, realFront: pid_t?, pinned: Bool) -> Bool {
        pinned || realFront.map { $0 == pid } ?? true
    }

    /// The app is read without a key press: automatic, a manual translation or popup on screen (checked on its
    /// events), or a translate-now retry.
    private static func readsWithoutKeyPress(_ target: AppTarget) -> Bool {
        target.settings.mode == .automatic || !target.manualKeys.isEmpty || target.selectionText != nil
            || target.pendingManual || target.manualRetryAt != nil
    }

    private func passwordGuardEvent(_ event: PasswordEntryGuard.Event) {
        guard running else { return }
        switch event {
        case .pauseChanged(let pause):
            setPasswordPause(pause)
        case .focusedText(let pid, let probe):
            focusedTextProbed(pid: pid, probe: probe)
        case .report(let report):
            onPasswordGuard?(.report(report))
        case .stuckSecureInput(let names):
            onPasswordGuard?(.stuckSecureInput(names))
        }
    }

    private func setPasswordPause(_ pause: PasswordPause?) {
        let old = passwordPause
        guard pause != old else { return }
        passwordPause = pause
        if pause == nil {
            // Every target is read again at once.
            for target in targets.values { target.forceScan = true }
        }
        if (old == nil) != (pause == nil) {
            // No screen captures for background colors meanwhile (overlays already drawn stay as they are).
            OverlayColorSampleScheduler.setCapturesPaused(pause != nil)
        }
        onPasswordGuard?(.pauseChanged(pause))
        updateInputMonitors()
        publishStatus()
        reschedule()
    }

    /// Rule c: a scanned terminal window waits for a password (its own scan is still used: it only read the
    /// prompt), or no longer does.
    private func notePasswordPrompt(
        _ snapshot: WindowSnapshot, window key: WindowKey, in target: AppTarget, now: CFAbsoluteTime
    ) {
        guard var track = target.windows[key] else { return }
        let waits = snapshot.passwordPrompt && target.settings.global.pauseDuringPasswordEntry
        switch (waits, track.promptPause) {
        case (true, nil):
            track.promptPause = TerminalPromptPause(since: now, texts: Self.promptTexts(snapshot))
        case (true, let pause?) where pause.rescanPending:
            // Still at the prompt after the rescan (sudo's "Sorry, try again.", or marks echoed).
            track.promptPause = pause.rescanned(texts: Self.promptTexts(snapshot))
        case (false, _?):
            track.promptPause = nil
        default:
            return
        }
        target.windows[key] = track
        if waits {
            log.notice(
                "password prompt in \(target.app.name, privacy: .public) window \(key.description, privacy: .public)")
            onPasswordGuard?(.promptPaused(key, app: target.app.name))
        } else {
            onPasswordGuard?(.promptResumed(key, why: "no longer at a prompt"))
        }
    }

    /// The segment texts of a scan at a prompt, to tell echoed marks (blanked by the extraction) from output.
    private static func promptTexts(_ snapshot: WindowSnapshot) -> Int {
        var hasher = Hasher()
        for segment in snapshot.segments { hasher.combine(segment.text) }
        return hasher.finalize()
    }

    /// The window waiting at a password prompt may have changed: scan it again. The pause (its menu line, the Esc
    /// monitor off) stays until that scan tells whether the prompt is gone. Returns false when nothing changed.
    @discardableResult
    private func resumePrompt(_ key: WindowKey, in target: AppTarget, why: String, textChanged: Bool) -> Bool {
        guard var pause = target.windows[key]?.promptPause else { return false }
        guard rescanFollows(key, in: target) else {
            // Nothing scans it on events (a manual app with no translation shown): stop showing the pause.
            target.windows[key]?.promptPause = nil
            onPasswordGuard?(.promptResumed(key, why: why + ", not rescanned"))
            return true
        }
        guard pause.requestRescan(textChanged ? .textChanged : .other) else { return false }
        target.windows[key]?.promptPause = pause
        onPasswordGuard?(.promptResumed(key, why: why))
        return true
    }

    /// An event of the app gives this window a scan (see `tick`).
    private func rescanFollows(_ key: WindowKey, in target: AppTarget) -> Bool {
        switch target.settings.mode {
        case .automatic: return true
        case .manual: return target.isActive && key == target.focusedKey && !target.manualKeys.isEmpty
        case .off: return false
        }
    }

    /// When a text change of the focused window may be read, if it waits at a prompt that echoes a mark per key
    /// (nil = at once). It counts from the same scan time as the window's timed fallback (the request time for
    /// the active app's focused window, the result time otherwise), so both come due in the same tick and the
    /// window is read once, not twice a few milliseconds apart.
    private func echoedMarksRescanTime(in target: AppTarget, now: CFAbsoluteTime) -> CFAbsoluteTime? {
        guard let key = target.focusedKey, let track = target.windows[key], let pause = track.promptPause else {
            return nil
        }
        return pause.textRescanTime(
            lastScan: target.isActive ? target.lastActiveScan : track.lastScan,
            background: target.settings.global.backgroundScanInterval, now: now)
    }

    /// Rule c's probe: the character count and insertion point of the front app's focused element (numbers and
    /// geometry, never the text).
    private func focusedTextProbed(pid: pid_t, probe: PromptProbe) {
        guard let target = targets[pid], probeWatchesFocusedWindow(of: target), let key = target.focusedKey,
            var pause = target.windows[key]?.promptPause
        else { return }
        let changed = pause.probe(probe)
        target.windows[key]?.promptPause = pause
        // A scan is already asked for; it starts the probe over when it comes back at the prompt.
        guard changed, !pause.rescanPending else { return }
        // Scanned like after the app's own event (its text events may have been left to the probe); an echoing
        // prompt at most once per fallback interval.
        let now = CFAbsoluteTimeGetCurrent()
        var due = max(now, target.lastEventScan + Self.minEventSpacing)
        let deferred = echoedMarksRescanTime(in: target, now: now)
        if let deferred { due = max(due, deferred) }
        resumePrompt(
            key, in: target, why: deferred == nil ? "text changed" : "text changed, echoed marks: deferred",
            textChanged: true)
        target.eventDue = min(target.eventDue ?? due, due)
        updateInputMonitors()
        publishStatus()
        reschedule()
    }
}

/// Lets the password guard reach the session before `init` finished.
@MainActor
private final class SessionRef {
    weak var session: LiveTranslationSession?
}
