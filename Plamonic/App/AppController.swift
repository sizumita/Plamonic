import AppKit
import Combine
import ServiceManagement
import SwiftUI
import os

/// Composition root of the app: owns the settings, the PLaMo backend, the translation pipeline,
/// the overlay and the session, and wires settings changes, hotkeys and windows together.
@MainActor
final class AppController: ObservableObject {
    let settings: SettingsStore
    let backend: PlamoBackend
    let models: ModelLibrary
    let cache: TranslationCache
    let coordinator: TranslationCoordinator
    let overlay: OverlayController
    let session: LiveTranslationSession
    /// Sparkle updates (started only in builds that carry its public key).
    let updates: UpdateController
    let inspector = AXInspector()
    /// Answers the Safari and Chrome extensions (DESIGN §9).
    let bridge: BridgeService
    /// Matches overlay colors to the target window (only with Screen Recording permission).
    let colorSampler = ScreenColorSampler()

    @Published private(set) var sessionStatus = SessionStatus()
    @Published private(set) var activity = TranslationActivity()
    @Published private(set) var loadActivity = ModelLoadActivity()
    @Published private(set) var accessibilityTrusted = AccessibilityPermission.isTrusted
    /// Screen Recording (optional): refreshed while the onboarding window is open and after asking for it.
    @Published private(set) var screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    @Published private(set) var hotkeyError: String?
    @Published private(set) var launchAtLoginError: String?

    static let toggleHotkeyID = "toggle"
    static let translateNowHotkeyID = "translateNow"

    private var cancellables: Set<AnyCancellable> = []
    private var appliedGlobal: GlobalSettings?
    private var started = false
    private var trustTimer: Timer?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var bridgeServer: BridgeSocketServer?
    private let log = Logger(subsystem: "io.smdr.Plamonic", category: "App")

    init() {
        let settings = SettingsStore()
        let global = settings.global
        let backend = PlamoBackend(idleUnloadMinutes: global.idleUnloadMinutes)
        let cache = TranslationCache(capacity: global.cacheCapacity, persistenceEnabled: global.persistCache)
        let box = SessionBox()
        let coordinator = TranslationCoordinator(backend: backend, cache: cache) { box.session?.activePID }
        let overlay = OverlayController()
        let session = LiveTranslationSession(settings: settings, coordinator: coordinator, overlay: overlay) {
            settings in
            Self.preloadModels(backend: backend, settings: settings)
        }
        box.session = session

        self.settings = settings
        self.backend = backend
        self.models = ModelLibrary(backend: backend)
        self.cache = cache
        self.coordinator = coordinator
        self.overlay = overlay
        self.session = session
        self.updates = UpdateController(settings: settings)
        self.bridge = BridgeService(
            coordinator: coordinator,
            settings: { settings.snapshot },
            isReady: { TranslationModelPlan.make(settings: $0) { backend.isModelInstalled($0) }.hasModel },
            setSiteMode: { mode, url in settings.setSiteMode(mode, for: url) },
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        overlay.colorSampler = colorSampler

        coordinator.onActivityChanged = { [weak self] activity in self?.activity = activity }
        session.onStatusChanged = { [weak self] status in self?.sessionStatus = status }
        backend.onLoadActivityChanged = { [weak self] activity in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.loadActivity = activity }
            }
        }
        // Settings text fields commit on Return, on focus loss, when their window resigns key, on disappear
        // and when SettingsStore.flush() posts willFlushNotification; toggles and steppers commit at once.
        // Coalesce bursts (a stepper held down, an import) so session state is rebuilt once per burst.
        settings.changes
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Called once the app finished launching.
    func start() {
        guard !started else { return }
        started = true
        applyGlobalSettings(force: true)
        updates.start()
        Task { await models.refresh() }
        if AccessibilityPermission.isTrusted {
            accessibilityTrusted = true
            session.start()
            if !hasUsableModel { showOnboarding() }
        } else {
            accessibilityTrusted = false
            showOnboarding()
        }
        // Also while trusted: the permission can be revoked while the app runs.
        waitForAccessibility()
        // Coming back from System Settings: pick up a Screen Recording change without waiting for the sampler.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshScreenRecording() }
            .store(in: &cancellables)
    }

    /// Synchronous cleanup at termination.
    func shutdown() {
        trustTimer?.invalidate()
        trustTimer = nil
        bridgeServer?.stop()
        bridgeServer = nil
        session.stop()
        overlay.removeAll()
        HotkeyCenter.shared.unregisterAll()
        // Turns AXManualAccessibility / AXEnhancedUserInterface back off where Plamonic switched them on.
        AppAccessibilityEnabler.shared.restoreAll()
        // The settings change may still be in its debounce; never write text the user chose not to keep.
        cache.isPersistenceEnabled = settings.global.persistCache
        cache.flush()
        settings.flush()
    }

    /// Menu "終了": stops translating, frees the models, then terminates.
    func quit() {
        session.stop()
        let backend = self.backend
        Task {
            // An unload waits for a running generation to notice its cancellation; do not hang on it.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await backend.unloadAll() }
                group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                await group.next()
                group.cancelAll()
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: - Menu commands

    /// Some model can translate the frontmost app (its 段階翻訳 setting decides whether the draft model counts).
    var hasUsableModel: Bool {
        TranslationModelPlan.make(settings: frontmostSettings) { backend.isModelInstalled($0) }.hasModel
    }

    /// The frontmost app's settings, or the defaults for an unknown app when none is known yet.
    private var frontmostSettings: EffectiveSettings {
        let status = sessionStatus
        guard let bundleID = status.frontmostBundleID else {
            return EffectiveSettings(profile: AppProfile(bundleID: "", displayName: ""), global: settings.global)
        }
        return settings.effectiveSettings(bundleID: bundleID, appName: status.frontmostAppName)
    }

    func toggleEnabled() {
        settings.updateGlobal { $0.isEnabled.toggle() }
        settingsChanged()
    }

    func setFrontmostMode(_ mode: TranslationMode) {
        guard let bundleID = sessionStatus.frontmostBundleID else { return }
        settings.updateProfile(bundleID: bundleID, appName: sessionStatus.frontmostAppName) { $0.mode = mode }
        settingsChanged()
    }

    func translateNow() {
        session.translateNow()
    }

    // MARK: - Settings

    private func settingsChanged() {
        applyGlobalSettings(force: false)
        session.settingsDidChange()
    }

    private func applyGlobalSettings(force: Bool) {
        let global = settings.global
        let previous = appliedGlobal
        appliedGlobal = global
        if force || previous?.toggleHotkey != global.toggleHotkey
            || previous?.translateNowHotkey != global.translateNowHotkey
        {
            registerHotkeys(global)
        }
        if force || previous?.idleUnloadMinutes != global.idleUnloadMinutes {
            backend.setIdleUnloadMinutes(global.idleUnloadMinutes)
        }
        // Applied here, not only when the next translation runs: quitting first would otherwise
        // rewrite the cache file (other apps' text) after the user turned saving off. Turning saving off
        // deletes the file; TranslationCache.init deletes one left from an earlier run at launch.
        // The coordinator keeps the capacity at least as large as what is on screen.
        if force || previous?.persistCache != global.persistCache
            || previous?.cacheCapacity != global.cacheCapacity
        {
            coordinator.applyCacheSettings(global)
        }
        if previous?.launchAtLogin != global.launchAtLogin {
            applyLaunchAtLogin(global.launchAtLogin, atLaunch: force)
        }
        if previous?.isEnabled == true, !global.isEnabled {
            coordinator.cancelAll()
        }
        if force || previous?.acceptBrowserExtensions != global.acceptBrowserExtensions {
            setBridgeRunning(global.acceptBrowserExtensions)
        }
    }

    /// Listens on the bridge socket only while the extensions are allowed; turning it off also forgets their
    /// documents.
    private func setBridgeRunning(_ running: Bool) {
        if running {
            guard bridgeServer == nil else { return }
            let bridge = self.bridge
            let server = BridgeSocketServer(path: BridgeLocation.socketURL().path) { line in
                await bridge.handle(line: line)
            }
            do {
                try server.start()
                bridgeServer = server
            } catch {
                log.error("Bridge failed to start: \(String(describing: error), privacy: .public)")
            }
        } else {
            bridgeServer?.stop()
            bridgeServer = nil
            coordinator.closeAllDocuments()
        }
    }

    private func registerHotkeys(_ global: GlobalSettings) {
        let center = HotkeyCenter.shared
        var problems: [String] = []
        func register(_ id: String, _ spec: HotkeySpec?, label: String, _ handler: @escaping HotkeyCenter.Handler) {
            guard let spec else {
                center.unregister(id: id)
                return
            }
            do {
                try center.register(id: id, spec: spec, handler: handler)
            } catch {
                problems.append("\(label)（\(spec.displayString)）: \(error.localizedDescription)")
            }
        }
        register(Self.toggleHotkeyID, global.toggleHotkey, label: "翻訳のオン・オフ") { [weak self] in
            self?.toggleEnabled()
        }
        register(Self.translateNowHotkeyID, global.translateNowHotkey, label: "今すぐ翻訳") { [weak self] in
            self?.translateNow()
        }
        hotkeyError = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private func applyLaunchAtLogin(_ enabled: Bool, atLaunch: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, !atLaunch, service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            launchAtLoginError = nil
        } catch {
            log.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginError = "ログイン時の起動を設定できませんでした: \(error.localizedDescription)"
            if enabled {
                appliedGlobal?.launchAtLogin = false
                settings.updateGlobal { $0.launchAtLogin = false }
            }
        }
    }

    /// Loads the models of one app's plan (its 段階翻訳 override decides whether the draft model is part of it):
    /// the draft model first, the final model once the engine is idle (see PlamoBackend.preload).
    nonisolated static func preloadModels(backend: PlamoBackend, settings: EffectiveSettings) {
        let plan = TranslationModelPlan.make(settings: settings) { backend.isModelInstalled($0) }
        backend.preload([plan.draft, plan.final].compactMap { $0 })
    }

    // MARK: - Accessibility

    func requestAccessibility() {
        AccessibilityPermission.prompt()
        AccessibilityPermission.openSystemSettings()
        waitForAccessibility()
    }

    /// Polls the permission for as long as the app runs, in both directions.
    private func waitForAccessibility() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
    }

    private func checkAccessibility() {
        if onboardingWindow?.isVisible == true { refreshScreenRecording() }
        let trusted = AccessibilityPermission.isTrusted
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        if trusted {
            session.start()
        } else {
            // Revoked: every AX call now fails and would leave the overlays frozen in place.
            log.notice("Accessibility permission was revoked; translation stopped")
            session.stop()
        }
    }

    // MARK: - Screen Recording

    /// Optional permission: only used to measure the target window's colors (never saved or sent).
    /// macOS shows its prompt the first time; the settings page is opened as well, since the prompt does not
    /// come back after it was answered once. A grant may only take effect after Plamonic restarts.
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess(),
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
        refreshScreenRecording()
    }

    func refreshScreenRecording() {
        // Also refreshes the sampler's stored answer, so the overlays follow a change at once.
        let authorized = colorSampler.refreshPermission()
        if authorized != screenRecordingAuthorized { screenRecordingAuthorized = authorized }
    }

    // MARK: - Windows

    func showSettings(pane: SettingsPane? = nil) {
        let actions = SettingsUIActions(
            clearCache: { [weak self] in self?.coordinator.clearCache() },
            cacheSummary: { [weak self] in "\(self?.cache.count ?? 0) 件" },
            screenRecordingAuthorized: { [weak self] in
                self?.colorSampler.refreshPermission() ?? CGPreflightScreenCaptureAccess()
            },
            requestScreenRecording: { [weak self] in self?.requestScreenRecording() })
        if settingsWindow == nil || pane != nil {
            let root = SettingsRootView(
                store: settings, models: models, inspector: inspector, runningApps: Self.runningApps,
                actions: actions, updates: updates, initialPane: pane ?? .general)
            let controller = NSHostingController(rootView: root)
            if let window = settingsWindow {
                window.contentViewController = controller
            } else {
                let window = NSWindow(contentViewController: controller)
                window.title = "Plamonic の設定"
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.setContentSize(NSSize(width: 860, height: 600))
                window.isReleasedWhenClosed = false
                window.setFrameAutosaveName("PlamonicSettings")
                window.center()
                settingsWindow = window
            }
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        refreshScreenRecording()
        if onboardingWindow == nil {
            let controller = NSHostingController(rootView: OnboardingView(controller: self))
            let window = NSWindow(contentViewController: controller)
            window.title = "Plamonic へようこそ"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    /// Starts downloading the default draft and final models and selects them.
    func downloadDefaultModels() {
        settings.updateGlobal {
            $0.finalModel = .b2
            $0.progressive.isEnabled = true
            $0.progressive.draftModel = .b0_8
        }
        for size in [ModelSize.b0_8, .b2] where !models.isInstalled(size) && !models.isDownloading(size) {
            models.download(size)
        }
    }

    private static func runningApps() -> [SettingsRunningApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own && $0.bundleIdentifier != nil }
            .map { (bundleID: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "", icon: $0.icon) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Lets the coordinator ask the session for the active app before both exist.
@MainActor
private final class SessionBox {
    weak var session: LiveTranslationSession?
}
