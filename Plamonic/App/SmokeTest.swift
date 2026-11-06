import AppKit
import Foundation

/// `--smoke-test <bundleID> <seconds> [--target <lang>]`: runs the session against one running app
/// without overlays and without activating, logs scans and translations (text masked), then exits.
/// `--target` overrides the target language (e.g. `en` for an app that shows Japanese text).
/// `--show-overlays` draws the overlays for a visual check (still never activates or takes focus) and measures
/// the window's colors when Screen Recording is granted.
/// `--final <size>`, `--progressive on|off` and `--burst-threshold <n>` change the translation model and 段階翻訳
/// in the test's private copy of the settings. `--pid <pid>` picks one process of the app (a second instance
/// started for a test page) instead of the first one.
/// Links (DESIGN §6.1, need `--show-overlays`): `--activate-first-link` runs what a click on the first link drawn
/// in a translation does and reports what happened; with `--dry-run-links` nothing is pressed or opened.
/// `--context-menu-first-link` runs what a right-click on it does, reports the menu that appeared (the app's or
/// Plamonic's own: item count, time to appear, place, front app) and closes it within 1 s; with
/// `--dry-run-links` only which menu it would show. It also closes a menu that opens late. A menu it cannot close
/// ends the run at once with status 4: the caller must then close the app (a fixture, by its own pid) within 1 s.
/// `--hover-first-link` shows the hover look of that link for
/// `--hover-hold` seconds as if the pointer were on it (the real cursor is never changed). The steps run in this
/// order: hover, menu, click; `--hover-at` waits for them.
/// `--hover-at <x>,<y>` rests the pointer (AX point, fed to the overlay only) there once the item under it has
/// its final translation drawn (or after the first final one, when no item is there), reports which item shows
/// its original, and moves it away after `--hover-hold <seconds>` (default 1). Click areas are logged as they
/// change, in AX screen coordinates.
/// Password entry (DESIGN §4.1): pauses, scans skipped because of them and terminal prompt pauses are always
/// logged. `--password-guard <seconds>` also polls the guard at that interval (default 0.25) and logs every
/// change of what it sees (secure input, the app it names, the front app, the focused field, the decision).
/// Names and window numbers only.
struct SmokeTestOptions {
    var bundleID: String
    var seconds: Double
    var targetLanguage: String?
    var showsOverlays = false
    var finalModel: ModelSize?
    var progressive: Bool?
    var burstThreshold: Int?
    var pid: pid_t?
    var activateFirstLink = false
    var contextMenuFirstLink = false
    var hoverFirstLink = false
    var dryRunLinks = false
    var hoverAt: CGPoint?
    var hoverHold: Double = 1
    /// `--password-guard`: the guard's poll interval; also logs every guard evaluation that changed.
    var passwordGuardPoll: Double?

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--smoke-test"), arguments.count > index + 1 else { return nil }
        bundleID = arguments[index + 1]
        seconds = arguments.count > index + 2 ? Double(arguments[index + 2]) ?? 25 : 25
        if let t = arguments.firstIndex(of: "--target"), arguments.count > t + 1 {
            targetLanguage = arguments[t + 1]
        }
        showsOverlays = arguments.contains("--show-overlays")
        if let f = arguments.firstIndex(of: "--final"), arguments.count > f + 1 {
            finalModel = ModelSize(rawValue: arguments[f + 1].lowercased())
        }
        if let p = arguments.firstIndex(of: "--progressive"), arguments.count > p + 1 {
            progressive = arguments[p + 1] == "on"
        }
        if let b = arguments.firstIndex(of: "--burst-threshold"), arguments.count > b + 1 {
            burstThreshold = Int(arguments[b + 1])
        }
        if let p = arguments.firstIndex(of: "--pid"), arguments.count > p + 1 {
            pid = pid_t(arguments[p + 1])
        }
        activateFirstLink = arguments.contains("--activate-first-link")
        contextMenuFirstLink = arguments.contains("--context-menu-first-link")
        hoverFirstLink = arguments.contains("--hover-first-link")
        dryRunLinks = arguments.contains("--dry-run-links")
        if let h = arguments.firstIndex(of: "--hover-at"), arguments.count > h + 1 {
            hoverAt = Self.point(arguments[h + 1])
        }
        if let h = arguments.firstIndex(of: "--hover-hold"), arguments.count > h + 1, let value = Double(arguments[h + 1]) {
            hoverHold = min(max(value, 0), 30)
        }
        if let g = arguments.firstIndex(of: "--password-guard") {
            let value = arguments.count > g + 1 ? Double(arguments[g + 1]) : nil
            passwordGuardPoll = min(max(value ?? PasswordEntryGuard.defaultPollInterval, 0.05), 5)
        }
    }

    /// Some step acts on the first link drawn in a translation.
    var usesFirstLink: Bool { activateFirstLink || contextMenuFirstLink || hoverFirstLink }

    /// "x,y" in points.
    static func point(_ text: String) -> CGPoint? {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Times every backend call for the smoke test log.
final class LoggingTranslationBackend: TranslationBackend, @unchecked Sendable {
    struct Call: Sendable {
        var model: ModelSize
        var started: Date
        var latency: TimeInterval
        var source: String
        var output: String?
        var error: String?
    }

    private let inner: any TranslationBackend
    private let onCall: @Sendable (Call) -> Void

    init(_ inner: any TranslationBackend, onCall: @escaping @Sendable (Call) -> Void) {
        self.inner = inner
        self.onCall = onCall
    }

    func translate(
        _ request: TranslationBackendRequest, model: ModelSize, onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let start = Date()
        do {
            let output = try await inner.translate(request, model: model, onPartial: onPartial)
            onCall(Call(model: model, started: start, latency: Date().timeIntervalSince(start), source: request.text, output: output))
            return output
        } catch {
            onCall(
                Call(
                    model: model, started: start, latency: Date().timeIntervalSince(start), source: request.text,
                    output: nil, error: "\(error)"))
            throw error
        }
    }

    func isModelInstalled(_ model: ModelSize) -> Bool { inner.isModelInstalled(model) }
}

/// Times every color measurement for the smoke test log (counts and colors only, never pixels).
final class LoggingColorSampler: ScreenColorSampling, @unchecked Sendable {
    private let inner: any ScreenColorSampling
    /// Window ID, number of rects asked for, the result and the seconds it took.
    private let onSample: @Sendable (UInt32, Int, [String: SampledColors], Double) -> Void

    init(
        _ inner: any ScreenColorSampling,
        onSample: @escaping @Sendable (UInt32, Int, [String: SampledColors], Double) -> Void
    ) {
        self.inner = inner
        self.onSample = onSample
    }

    var isAuthorized: Bool { inner.isAuthorized }

    func sampleColors(windowID: UInt32, rects: [String: CGRect]) async -> [String: SampledColors] {
        let start = Date()
        let result = await inner.sampleColors(windowID: windowID, rects: rects)
        onSample(windowID, rects.count, result, Date().timeIntervalSince(start))
        return result
    }
}

@MainActor
final class SmokeTest {
    private let options: SmokeTestOptions
    private let start = Date()
    private var session: LiveTranslationSession?
    private var backend: PlamoBackend?
    private var settingsStore: SettingsStore?
    private var scanDurations: [Double] = []
    private var scanCount = 0
    private var maxSegments = 0
    private var calls: [LoggingTranslationBackend.Call] = []
    private var firstSeen: [String: Double] = [:]
    private var firstDraft: [String: Double] = [:]
    private var firstFinal: [String: Double] = [:]
    private var lastItems: [WindowKey: [OverlayItem]] = [:]
    private var overlay: OverlayController?
    /// Windows whose first scan was logged in detail.
    private var detailedWindows: Set<WindowKey> = []
    private var lastOverlapCount: [WindowKey: Int] = [:]
    /// Each window's last complete scan, for the style summary at the end (styles are read over several scans).
    private var lastComplete: [WindowKey: WindowSnapshot] = [:]
    private var refinementPaused = false
    private var pausedSince: Double?
    private var pauseCount = 0
    private var pausedTotal = 0.0
    private var colorSamples = 0
    /// The first-link steps (`--hover-first-link`, `--context-menu-first-link`, `--activate-first-link`) started
    /// and ended (once per test); `--hover-at` ran.
    private var firstLinkStarted = false
    private var firstLinkStepsDone = false
    private var firstLinkSteps: [FirstLinkStep] = []
    private var firstLink: (target: OverlayClickTarget, link: SegmentLink)?
    private var awaitingActivation = false
    private var hoverStarted = false
    private var linkActivations: [LinkActivationReport] = []
    private var linkMenus: [LinkMenuReport] = []
    /// The menu `--context-menu-first-link` waits for.
    private var menuWatch: SmokeMenuWatch?
    private var links: LinkActivator?
    private var targetPID: pid_t = 0
    private var windowIDs: [WindowKey: CGWindowID] = [:]
    /// Click areas last logged per window, and how many times they were logged.
    private var loggedClickAreas: [WindowKey: [OverlayHitArea]] = [:]
    private var clickAreaLogs: [WindowKey: Int] = [:]
    /// The item last seen showing its original in place (logged when it changes).
    private var loggedRevealed: String?
    /// Password pauses (rules a and b): how many, since when, how long in all; scans skipped; prompt pauses.
    private var passwordPauses = 0
    private var passwordPausedSince: Double?
    private var passwordPausedTotal = 0.0
    private var skippedScans = 0
    private var promptPauses = 0

    private static var current: SmokeTest?

    static func run(_ options: SmokeTestOptions) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        // Never take focus from the app under test. Overlay panels need a policy that may own windows.
        app.setActivationPolicy(options.showsOverlays ? .accessory : .prohibited)
        let test = SmokeTest(options: options)
        current = test
        DispatchQueue.main.async { MainActor.assumeIsolated { test.begin() } }
        app.run()
    }

    private init(options: SmokeTestOptions) {
        self.options = options
    }

    private var elapsed: Double { Date().timeIntervalSince(start) }

    private func say(_ line: String) {
        print(String(format: "[%6.2fs] ", elapsed) + line)
    }

    private func begin() {
        guard AccessibilityPermission.isTrusted else {
            say("ERROR: no Accessibility permission for this process")
            exit(2)
        }
        guard
            let target = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID)
                .first(where: { !$0.isTerminated && (options.pid == nil || $0.processIdentifier == options.pid) })
        else {
            say("ERROR: \(options.bundleID) is not running")
            exit(3)
        }

        // A private copy of the settings, so the test never writes the real file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plamonic-smoke-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        try? FileManager.default.copyItem(at: SettingsStore.defaultFileURL, to: settingsURL)
        let settings = SettingsStore(fileURL: settingsURL)
        settingsStore = settings
        if let model = options.finalModel {
            settings.updateGlobal { $0.finalModel = model }
        }
        if let progressive = options.progressive {
            settings.updateGlobal { $0.progressive.isEnabled = progressive }
            if settings.profile(for: options.bundleID).progressiveOverride != nil {
                settings.updateProfile(bundleID: options.bundleID) { $0.progressiveOverride = nil }
            }
        }
        if let threshold = options.burstThreshold {
            settings.updateGlobal { $0.progressive.burstControl.threshold = threshold }
        }

        let backend = PlamoBackend(idleUnloadMinutes: 0)
        self.backend = backend
        backend.onLoadActivityChanged = { activity in
            let line =
                activity.loading.map { "model load: \($0.displayName) started" }
                ?? "model load: done in \(String(format: "%.2f", activity.lastLoadSeconds ?? 0))s"
                    + (activity.lastError.map { " error=\($0)" } ?? "")
            DispatchQueue.main.async { MainActor.assumeIsolated { SmokeTest.current?.say(line) } }
        }
        let logging = LoggingTranslationBackend(backend) { call in
            DispatchQueue.main.async { MainActor.assumeIsolated { SmokeTest.current?.record(call) } }
        }
        // In memory only: no message text is written to disk.
        let cache = TranslationCache(capacity: 5000, fileURL: nil, persistenceEnabled: false)
        let pid = target.processIdentifier
        targetPID = pid
        let coordinator = TranslationCoordinator(backend: logging, cache: cache) { pid }
        coordinator.onActivityChanged = { [weak self] activity in self?.activityChanged(activity) }

        var sessionOptions = LiveTranslationSession.Options()
        sessionOptions.showsOverlays = options.showsOverlays
        sessionOptions.dryRunLinks = options.dryRunLinks
        let overlay = options.showsOverlays ? OverlayController() : nil
        self.overlay = overlay
        if let overlay {
            let sampler = ScreenColorSampler()
            let permission = sampler.isAuthorized ? "granted (colors are measured)" : "not granted (theme colors)"
            say("screen recording: \(permission)")
            overlay.colorSampler = LoggingColorSampler(sampler) { windowID, asked, result, seconds in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        SmokeTest.current?.colorSampled(
                            windowID: windowID, asked: asked, result: result, seconds: seconds)
                    }
                }
            }
        }
        sessionOptions.pinnedPID = pid
        sessionOptions.forcedMode = .automatic
        sessionOptions.forcedTargetLanguage = options.targetLanguage
        sessionOptions.monitorsInput = false
        if let poll = options.passwordGuardPoll { sessionOptions.passwordPollInterval = poll }
        let links = LinkActivator()
        self.links = links
        let session = LiveTranslationSession(
            settings: settings, coordinator: coordinator, overlay: overlay, options: sessionOptions, links: links
        ) { settings in
            AppController.preloadModels(backend: backend, settings: settings)
        }
        self.session = session
        session.onScanned = { [weak self] result, items in self?.scanned(result, items: items) }
        session.onItemsRedrawn = { [weak self] key, items in self?.itemsChanged(key, items) }
        session.onLinkActivated = { [weak self] report in self?.linkActivated(report) }
        session.onLinkMenuShown = { [weak self] report in self?.linkMenuShown(report) }
        session.onPasswordGuard = { [weak self] note in self?.passwordNote(note) }

        var effective = settings.effectiveSettings(bundleID: options.bundleID, appName: target.localizedName)
        if let language = options.targetLanguage { effective.profile.targetLanguageOverride = language }
        let rules = effective.profile.rules
        let plan = TranslationModelPlan.make(settings: effective) { backend.isModelInstalled($0) }
        let progressive = effective.progressive
        let burst = progressive.burstControl
        say(
            "target \(options.bundleID) pid=\(pid) profile=\(settings.profileSource(for: options.bundleID).rawValue) "
                + "scope=\(effective.profile.scope.rawValue) granularity=\(effective.profile.granularity.rawValue) "
                + "textArea=\(effective.profile.textAreaHandling.rawValue) rules(c/i/e)="
                + "\(rules.containers.count)/\(rules.items.count)/\(rules.excludes.count) "
                + "target=\(effective.targetLanguage) draft=\(plan.draft?.displayName ?? "-") "
                + "final=\(plan.final?.displayName ?? "-") duration=\(Int(options.seconds))s")
        let appearance = effective.global.appearance
        say(
            "progressive=\(progressive.isEnabled ? "on" : "off") draftModel=\(progressive.draftModel.displayName) "
                + "twoStage=\(plan.isTwoStage) burst=\(burst.isEnabled ? "on" : "off") threshold=\(burst.threshold) "
                + String(format: "quiet=%.1fs ", burst.quietSeconds)
                + "matchOriginalStyle=\(appearance.matchOriginalStyle) "
                + "matchBackgroundFromScreen=\(appearance.matchBackgroundFromScreen)")
        let interaction = effective.global.interaction
        say(
            "interaction: hoverOriginal=\(interaction.hoverOriginal.rawValue) "
                + String(format: "hoverDelay=%.2fs ", interaction.hoverDelay)
                + "clickableLinks=\(interaction.clickableLinks) activateFirstLink=\(options.activateFirstLink) "
                + "contextMenuFirstLink=\(options.contextMenuFirstLink) hoverFirstLink=\(options.hoverFirstLink) "
                + "dryRunLinks=\(options.dryRunLinks) hoverAt="
                + (options.hoverAt.map { String(format: "%.0f,%.0f", $0.x, $0.y) } ?? "-"))
        say(
            "password guard: pauseDuringPasswordEntry=\(effective.global.pauseDuringPasswordEntry) "
                + String(format: "poll=%.2fs ", sessionOptions.passwordPollInterval)
                + "details=\(options.passwordGuardPoll != nil ? "on" : "off")")
        if options.usesFirstLink || options.hoverAt != nil, !options.showsOverlays {
            say(
                "note: --activate-first-link, --context-menu-first-link, --hover-first-link and --hover-at need "
                    + "--show-overlays (they act through the overlay)")
        }
        session.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) {
            MainActor.assumeIsolated { SmokeTest.current?.finish() }
        }
    }

    private func scanned(_ result: ScanResult, items: [OverlayItem]?) {
        switch result.outcome {
        case .gone:
            say("scan: window gone / no window")
        case .unavailable:
            say("scan: app did not answer (AX timeout)")
        case .offScreen(let key):
            say("scan: window \(key) is off screen")
        case .paused(let pause):
            skippedScans += 1
            say("scan: skipped before reading, password entry (\(pause.logDescription))")
        case .scanned(let snapshot):
            scanCount += 1
            scanDurations.append(snapshot.scanDuration * 1000)
            if let id = result.cgWindowID { windowIDs[snapshot.key] = id }
            maxSegments = max(maxSegments, snapshot.segments.count)
            let d = result.diagnostics
            var line = String(
                format: "scan #%d %@ segs=%d nodes=%d %.1fms", scanCount, "\(snapshot.key)",
                snapshot.segments.count, snapshot.nodeCount, snapshot.scanDuration * 1000)
            if snapshot.truncated { line += " truncated" }
            let overlaps = Self.overlapCount(snapshot.segments.map(\.axFrame))
            if overlaps > 0 || (lastOverlapCount[snapshot.key] ?? 0) > 0 { line += " overlaps=\(overlaps)" }
            lastOverlapCount[snapshot.key] = overlaps
            if !snapshot.truncated, !snapshot.segments.isEmpty { lastComplete[snapshot.key] = snapshot }
            if d.warmingUp { line += " warming-up" }
            if d.containerCount > 0 { line += " containers=\(d.containerCount)\(d.containerCacheHit ? "(cached)" : "")" }
            line += " " + Self.linkSummary(snapshot.segments)
            if let items {
                line += " " + stateSummary(items)
                if let overlay {
                    line += " drawn=\(overlay.contentItems(window: snapshot.key).count)"
                    line += " " + Self.mappedLinkSummary(items) + " " + Self.panelSummary(overlay, window: snapshot.key)
                }
                for item in items where firstSeen[item.id] == nil { firstSeen[item.id] = elapsed }
                note(items)
                lastItems[snapshot.key] = items
                linkChecks(snapshot.key, items)
            } else {
                line += " (kept previous)"
            }
            say(line)
            // Details once per window, from its first scan that found text (Chromium may answer empty at first).
            if !snapshot.segments.isEmpty, detailedWindows.insert(snapshot.key).inserted {
                say(
                    "  " + Self.styleSummary(snapshot.segments) + " overlaps=\(overlaps)"
                        + " obstacles=\(snapshot.obstacles.count)")
                for segment in snapshot.segments.prefix(12) {
                    let f = segment.axFrame
                    say(
                        String(
                            format: "  seg %d [%.0f,%.0f %.0fx%.0f] %@%@ \"%@\"", segment.order, f.minX, f.minY,
                            f.width, f.height, segment.role, Self.styleTag(segment),
                            TextMasker.mask(segment.text, limit: 50)))
                }
                for (segment, link) in snapshot.segments.flatMap({ s in s.links.map { (s, $0) } }).prefix(12) {
                    say("  link seg \(segment.order) " + Self.linkTag(link, in: segment))
                }
            }
        }
    }

    /// Segment pairs whose frames overlap by more than a sliver (an overlay drawn there would hide text).
    static func overlapCount(_ frames: [CGRect]) -> Int {
        var count = 0
        for i in frames.indices {
            for j in frames.indices where j > i {
                let overlap = frames[i].intersection(frames[j])
                if !overlap.isNull, overlap.width > 1, overlap.height > 1 { count += 1 }
            }
        }
        return count
    }

    /// How much of the original's look extraction found (counts and sizes only, no text).
    static func styleSummary(_ segments: [TextSegment]) -> String {
        let sizes = segments.compactMap(\.style.fontSize).sorted()
        var line = "style: segs=\(segments.count) fontSize=\(sizes.count) "
            + "lineHeight=\(segments.filter { $0.style.lineHeight != nil }.count) "
            + "textColor=\(segments.filter { $0.style.textColor != nil }.count) "
            + "mono=\(segments.filter(\.style.isMonospaced).count) "
            + "lineFrames=\(segments.filter { !$0.lineFrames.isEmpty }.count)"
        if let low = sizes.first, let high = sizes.last {
            line += String(format: " sizes=%.1f-%.1fpt", low, high)
        }
        return line
    }

    private static func styleTag(_ segment: TextSegment) -> String {
        let style = segment.style
        var parts: [String] = []
        if let size = style.fontSize { parts.append(String(format: "fs=%.1f", size)) }
        if let height = style.lineHeight { parts.append(String(format: "lh=%.1f", height)) }
        if !segment.lineFrames.isEmpty { parts.append("lines=\(segment.lineFrames.count)") }
        if style.isMonospaced { parts.append("mono") }
        if let color = style.textColor { parts.append("color=" + hex(color)) }
        if !segment.links.isEmpty { parts.append("links=\(segment.links.count)") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    /// Links found in a scan: how many, in how many segments, of which kinds (no text).
    static func linkSummary(_ segments: [TextSegment]) -> String {
        let links = segments.flatMap(\.links)
        guard !links.isEmpty else { return "links=0" }
        var kinds: [SegmentLinkKind: Int] = [:]
        for link in links { kinds[link.kind, default: 0] += 1 }
        let kindText = [SegmentLinkKind.link, .button, .detected]
            .compactMap { kind in kinds[kind].map { "\(kind.rawValue)=\($0)" } }
            .joined(separator: ",")
        var line = "links=\(links.count) in \(segments.filter { !$0.links.isEmpty }.count) segs (\(kindText))"
        let linkColored = segments.filter(textTakesLinkColor).count
        if linkColored > 0 { line += " textColorIsLinkColor=\(linkColored)" }
        return line
    }

    /// The segment has text outside its links, yet its text color is one of its links' colors: the whole
    /// translation would be drawn in the link color (DESIGN §6.1). Also true where links are styled like text.
    static func textTakesLinkColor(_ segment: TextSegment) -> Bool {
        guard let color = segment.style.textColor, segment.links.contains(where: { $0.color == color }) else {
            return false
        }
        var other = Array(segment.text.utf16)
        for link in segment.links where link.range.lowerBound >= 0 && link.range.upperBound <= other.count {
            for i in link.range { other[i] = 0x20 }
        }
        let rest = String(decoding: other, as: UTF16.self)
        return !rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    /// Links of translated items that were found in their translation.
    static func mappedLinkSummary(_ items: [OverlayItem]) -> String {
        let translated = items.filter { $0.state == .draft || $0.state == .final || $0.state == .streaming }
        let original = translated.reduce(0) { $0 + $1.originalLinks.count }
        let mapped = translated.reduce(0) { $0 + $1.links.count }
        return "mapped=\(mapped)/\(original)"
    }

    private static func panelSummary(_ overlay: OverlayController, window: WindowKey) -> String {
        let counts = overlay.clickPanelCounts(window: window)
        return "panels=links:\(counts.links) blockers:\(counts.blockers)"
    }

    /// One link of a segment, masked: kind, place in the text, URL scheme and masked host, frames, element.
    static func linkTag(_ link: SegmentLink, in segment: TextSegment) -> String {
        let utf16 = segment.text.utf16
        var rangeCheck = "range-out-of-bounds"
        if link.range.lowerBound >= 0, link.range.upperBound <= utf16.count {
            let start = utf16.index(utf16.startIndex, offsetBy: link.range.lowerBound)
            let end = utf16.index(utf16.startIndex, offsetBy: link.range.upperBound)
            rangeCheck = String(utf16[start..<end]) == link.text ? "ok" : "text-mismatch"
        }
        var parts = [
            "kind=\(link.kind.rawValue)", "range=\(link.range.lowerBound)..<\(link.range.upperBound)(\(rangeCheck))",
            "text=\"\(TextMasker.mask(link.text, limit: 30))\"",
        ]
        if let url = link.url {
            parts.append("url=\(url.scheme ?? "?")://\(TextMasker.mask(url.host ?? "", limit: 30))")
        }
        parts.append(
            "frames=\(link.frames.count)"
                + (link.frames.isEmpty
                    ? ""
                    : "[" + link.frames.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) }
                        .joined(separator: " ") + "]"))
        parts.append("element=\(link.element != nil ? "yes" : "no")")
        if let color = link.color { parts.append("color=" + hex(color)) }
        if link.isUnderlined { parts.append("underline") }
        return parts.joined(separator: " ")
    }

    private static func hex(_ color: RGBAColor) -> String {
        func byte(_ c: Double) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }

    private func activityChanged(_ activity: TranslationActivity) {
        guard activity.refinementPaused != refinementPaused else { return }
        refinementPaused = activity.refinementPaused
        if refinementPaused {
            pauseCount += 1
            pausedSince = elapsed
            say("refinement paused (burst) remaining=\(activity.remainingJobs)")
        } else {
            let paused = pausedSince.map { elapsed - $0 } ?? 0
            pausedTotal += paused
            pausedSince = nil
            say(String(format: "refinement resumed after %.2fs remaining=%d", paused, activity.remainingJobs))
        }
    }

    // MARK: - Password entry (DESIGN §4.1)

    private func passwordNote(_ note: PasswordGuardNote) {
        switch note {
        case .report:
            // Every evaluation that changed: only when asked for (it can be chatty around app switches).
            guard options.passwordGuardPoll != nil else { return }
        case .pauseChanged(let pause):
            if pause != nil, passwordPausedSince == nil {
                passwordPauses += 1
                passwordPausedSince = elapsed
            } else if pause == nil, let since = passwordPausedSince {
                passwordPausedTotal += elapsed - since
                passwordPausedSince = nil
                say(String(format: "password pause lasted %.2fs", elapsed - since))
            }
        case .promptPaused:
            promptPauses += 1
        default:
            break
        }
        say(note.line)
    }

    private func colorSampled(windowID: UInt32, asked: Int, result: [String: SampledColors], seconds: Double) {
        colorSamples += 1
        let dark = result.values.filter { $0.background.luminance < 0.18 }.count
        let withText = result.values.filter { $0.text != nil }.count
        var line = String(
            format: "color sample #%d window %u: %d rects -> %d measured (%d dark bg, %d with text color) in %.0fms",
            colorSamples, windowID, asked, result.count, dark, withText, seconds * 1000)
        // The most common background, to compare with the app's theme.
        var backgrounds: [String: Int] = [:]
        for colors in result.values { backgrounds[Self.hex(colors.background), default: 0] += 1 }
        if let common = backgrounds.max(by: { $0.value < $1.value }) { line += " bg=\(common.key)x\(common.value)" }
        say(line)
    }

    private func itemsChanged(_ key: WindowKey, _ items: [OverlayItem]) {
        note(items)
        lastItems[key] = items
        linkChecks(key, items)
    }

    // MARK: - Links and hover (DESIGN §6.1)

    private func linkChecks(_ key: WindowKey, _ items: [OverlayItem]) {
        logClickAreas(key, items)
        logRevealed()
        startFirstLinkSteps(key, items)
        hoverIfTranslated(key, items)
    }

    /// The click areas that have a panel (AX screen coordinates), each time they change (at most 8 times per
    /// window), so they can be compared with the panels in the window list. Items are named by their place.
    private func logClickAreas(_ key: WindowKey, _ items: [OverlayItem], force: Bool = false) {
        guard let overlay, force || clickAreaLogs[key, default: 0] < 40 else { return }
        let areas = overlay.activeClickAreas(window: key)
        guard force || areas != loggedClickAreas[key, default: []] else { return }
        loggedClickAreas[key] = areas
        clickAreaLogs[key, default: 0] += 1
        let index = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        say("click areas \(key): \(areas.count)")
        for area in areas {
            let kind: String
            switch area.kind {
            case .link(let i): kind = "link#\(i)"
            case .blocker: kind = "blocker"
            }
            let r = area.rect
            say(
                "  \(kind) item\(index[area.itemID].map(String.init) ?? "?") "
                    + String(format: "%.1f,%.1f %.1fx%.1f", r.minX, r.minY, r.width, r.height))
        }
    }

    /// Logs when the item showing its original in place changes (the hover step, a click on a hidden original
    /// link, or the real pointer passing over a click panel).
    private func logRevealed() {
        guard let overlay else { return }
        let revealed = overlay.revealedItem
        let label = revealed.map { revealed in
            "item" + (lastItems[revealed.window]?.firstIndex { $0.id == revealed.id }.map(String.init) ?? "?")
        }
        guard label != loggedRevealed else { return }
        loggedRevealed = label
        say("original in place: " + (label ?? "none"))
    }

    private enum FirstLinkStep {
        case hover, contextMenu, activate
    }

    /// Once a link is drawn in a translation, runs the first-link steps on it, one after the other: the hover
    /// look, the context menu, then a click.
    private func startFirstLinkSteps(_ key: WindowKey, _ items: [OverlayItem]) {
        guard options.usesFirstLink, !firstLinkStarted, let overlay else { return }
        let drawn = Set(overlay.contentItems(window: key).map(\.layout.id))
        guard
            let item = items.first(where: {
                !$0.links.isEmpty && ($0.state == .final || $0.state == .draft) && drawn.contains($0.id)
            }),
            let mapped = item.links.first, item.originalLinks.indices.contains(mapped.linkIndex)
        else { return }
        firstLinkStarted = true
        let link = item.originalLinks[mapped.linkIndex]
        say(
            "first link: window \(key) item \"\(TextMasker.mask(item.original, limit: 30))\" "
                + "link #\(mapped.linkIndex) at \(mapped.range.lowerBound)..<\(mapped.range.upperBound) "
                + "of the translation " + Self.linkSummaryTag(link))
        firstLink = (OverlayClickTarget(window: key, itemID: item.id, kind: .link(mapped.linkIndex)), link)
        if options.hoverFirstLink { firstLinkSteps.append(.hover) }
        if options.contextMenuFirstLink { firstLinkSteps.append(.contextMenu) }
        if options.activateFirstLink { firstLinkSteps.append(.activate) }
        // Let the overlay put its click panels up first.
        nextFirstLinkStep(after: 0.3)
    }

    private func nextFirstLinkStep(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { SmokeTest.current?.runFirstLinkStep() }
        }
    }

    private func runFirstLinkStep() {
        guard let (target, link) = firstLink, !firstLinkSteps.isEmpty else {
            firstLinkStepsDone = true
            return
        }
        // Never hover, ask for a menu or press while a menu of the app is open (a late one, or one not closed).
        let openMenus = openAppMenuCount()
        guard openMenus == 0 else {
            say("ERROR: \(openMenus) menu window(s) of the app on screen: the remaining first-link steps are skipped")
            firstLinkSteps.removeAll()
            firstLinkStepsDone = true
            return
        }
        let step = firstLinkSteps.removeFirst()
        guard let (panel, rect) = linkPanel(target) else {
            nextFirstLinkStep(after: 0)
            return
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let place = String(format: "at %.0f,%.0f (%.0fx%.0f)", center.x, center.y, rect.width, rect.height)
        switch step {
        case .hover:
            hoverLinkPanel(panel, target: target)
        case .contextMenu:
            say("context menu on its panel " + place)
            watchMenu(link: link, point: center)
            panel.clickView.onContextMenu?(center)
        case .activate:
            say("clicking its panel " + place)
            awaitingActivation = true
            panel.clickView.onActivate?(center)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard let test = SmokeTest.current, test.awaitingActivation else { return }
                    test.awaitingActivation = false
                    test.say("  the click was not acted on (no activation report)")
                    test.nextFirstLinkStep(after: 0)
                }
            }
        }
    }

    /// The visible click panel over the link and its area (AX), or nil (logged).
    private func linkPanel(_ target: OverlayClickTarget) -> (OverlayClickPanel, CGRect)? {
        guard let overlay else { return nil }
        let window = target.window
        guard let panel = overlay.clickPanels(window: window).first(where: { $0.target == target && $0.isVisible }),
            let area = overlay.activeClickAreas(window: window).first(where: {
                $0.itemID == target.itemID && $0.kind == target.kind
            })
        else {
            let counts = overlay.clickPanelCounts(window: window)
            say("  no click panel over the first link (panels=links:\(counts.links) blockers:\(counts.blockers))")
            return nil
        }
        return (panel, area.rect)
    }

    /// `--hover-first-link`: the hover look as if the pointer entered the link's panel, for `--hover-hold`
    /// seconds, then left. The real cursor is never changed.
    private func hoverLinkPanel(_ panel: OverlayClickPanel, target: OverlayClickTarget) {
        say(String(format: "hover first link: pointer enters its panel (simulated) for %.1fs", options.hoverHold))
        panel.clickView.simulateHover(true)
        say("hover first link: hover look " + hoverLookLabel(target))
        DispatchQueue.main.asyncAfter(deadline: .now() + options.hoverHold) {
            MainActor.assumeIsolated {
                guard let test = SmokeTest.current else { return }
                if panel.target == target {
                    test.say("hover first link: before leaving, hover look " + test.hoverLookLabel(target))
                    panel.clickView.simulateHover(false)
                    test.say(
                        "hover first link: pointer left its panel (simulated), hover look "
                            + test.hoverLookLabel(target))
                } else {
                    test.say("hover first link: its panel changed before the end (scroll or redraw)")
                }
                test.nextFirstLinkStep(after: 0.3)
            }
        }
    }

    /// Whether the overlay shows the hover look on the link (and on which, if another).
    private func hoverLookLabel(_ target: OverlayClickTarget) -> String {
        guard let hovered = overlay?.hoveredLink else { return "off" }
        guard hovered.window == target.window, hovered.itemID == target.itemID,
            case .link(hovered.linkIndex) = target.kind
        else { return "on (another link)" }
        return "on (this link)"
    }

    /// `--context-menu-first-link`: watches for the menu the request brings up and closes it (within 1 s), then
    /// for a menu that opens late, until the end of the run.
    private func watchMenu(link: SegmentLink, point: CGPoint) {
        menuWatch?.stop()
        let watch = SmokeMenuWatch(
            targetPID: targetPID,
            cancelOwnMenu: { [weak self] in self?.links?.cancelOwnMenu() },
            ownMenuItemCount: { [weak self] in self?.linkMenus.last?.ownMenu.count },
            reported: { [weak self] result in self?.menuWatched(result, link: link, point: point) },
            leftOpen: { [weak self] result in self?.menuLeftOpen(result, link: link, point: point) })
        menuWatch = watch
        watch.start()
    }

    private func menuWatched(_ result: SmokeMenuWatch.Result, link: SegmentLink, point: CGPoint) {
        say(menuLine(result, link: link, point: point))
        if let error = result.error { say("ERROR: menu: \(error)") }
        // A late menu is closed and logged only: the steps went on after the first report.
        if !result.late { nextFirstLinkStep(after: 0.3) }
    }

    /// A menu could not be closed. It takes the user's next click, so the run ends at once with a non-zero
    /// status: the caller must then close the app (a fixture, by its own pid) within 1 s.
    private func menuLeftOpen(_ result: SmokeMenuWatch.Result, link: SegmentLink, point: CGPoint) {
        say(menuLine(result, link: link, point: point))
        say(
            "ERROR: \(result.error ?? "menu left open"): ending the run now with status "
                + "\(Self.menuLeftOpenStatus) (close the app)")
        exit(Self.menuLeftOpenStatus)
    }

    /// Exit status when a menu of the app was left open.
    static let menuLeftOpenStatus: Int32 = 4

    private func menuLine(_ result: SmokeMenuWatch.Result, link: SegmentLink, point: CGPoint) -> String {
        var line = result.late ? "menu (late): " : "menu: "
        if let owner = result.owner, let frame = result.frame {
            line += "\(owner.rawValue) menu appeared after \(Self.ms(result.appearedAfter))"
            line += " items=\(result.itemCount.map(String.init) ?? "?")"
            if owner == .app {
                line += " axMenu=\(result.foundAXMenu ? "found" : "not found")"
                if let probe = result.foundBy { line += " (\(probe.label))" }
                line += " probes=\(result.probesTried)"
                if let error = result.cancelError { line += " AXCancel=\(error.rawValue)" }
            }
            line += String(format: " at %.0f,%.0f %.0fx%.0f", frame.minX, frame.minY, frame.width, frame.height)
            // Where the menu sits: from the original link's center (apps choose) and from the click point.
            let linkFrame = link.frames.reduce(CGRect.null) { $0.union($1) }
            if !linkFrame.isNull {
                line += String(
                    format: " topLeft-linkCenter=%+.1f,%+.1f", frame.minX - linkFrame.midX, frame.minY - linkFrame.midY)
            }
            line += String(format: " topLeft-click=%+.1f,%+.1f", frame.minX - point.x, frame.minY - point.y)
            line += " visible=\(result.leftOpen ? "still" : Self.ms(result.visibleFor))"
        } else {
            line += "no menu window within \(Self.ms(SmokeMenuWatch.appearTimeout)) (still watching for a late one)"
        }
        line += " frontChanged=\(result.frontChanged ? "yes" : "no")"
        line += " plamonicActivated=\(result.plamonicActivated ? "yes" : "no")"
        return line
    }

    /// Number of the app's menu windows on screen (pop-up-menu level, any).
    private func openAppMenuCount() -> Int {
        LiveSmokeMenuEnvironment().menuWindows(of: [targetPID]).count
    }

    /// Before the end: no more first-link steps, no own menu, and a menu asked for just before the end (it may
    /// still appear) is closed. Never ends with a menu of the app open (it would take the user's next click):
    /// if one stays, the run ends at once with `menuLeftOpenStatus`.
    private func closeMenusForTheEnd() {
        firstLinkSteps.removeAll()
        links?.cancelOwnMenu()
        if let watch = menuWatch,
            watch.settle(timeout: SmokeMenuWatch.appearTimeout + SmokeMenuWatch.closeDeadline)
        {
            say("ERROR: a menu of the app was still being closed at the end")
        }
        guard options.contextMenuFirstLink, !waitForNoAppMenu(timeout: SmokeMenuWatch.closeDeadline) else { return }
        say(
            "ERROR: menu left open: a menu window of the app is still on screen at the end: ending the run now "
                + "with status \(Self.menuLeftOpenStatus) (close the app)")
        exit(Self.menuLeftOpenStatus)
    }

    /// Waits (blocking, the app closes its menu on its own) up to `timeout` for the app's menu windows to go.
    private func waitForNoAppMenu(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while openAppMenuCount() > 0 {
            guard Date() < end else { return false }
            usleep(20_000)
        }
        return true
    }

    private static func ms(_ seconds: TimeInterval?) -> String {
        seconds.map { String(format: "%.0fms", $0 * 1000) } ?? "?"
    }

    private func linkMenuShown(_ report: LinkMenuReport) {
        linkMenus.append(report)
        var line =
            "link menu: window \(report.window) kind=\(report.kind.rawValue) -> " + LinkActivator.describe(report.outcome)
        if let error = report.menuError { line += " AXError=\(error.rawValue)" }
        if let supported = report.menuSupported { line += " showMenuSupported=\(supported)" }
        if !report.ownMenu.isEmpty { line += " ownMenu=" + report.ownMenu.map(\.rawValue).joined(separator: ",") }
        if let scheme = report.scheme {
            line += " url=\(scheme)://\(TextMasker.mask(report.host ?? "", limit: 30))"
        }
        say(line)
    }

    private static func linkSummaryTag(_ link: SegmentLink) -> String {
        var text = "kind=\(link.kind.rawValue) element=\(link.element != nil ? "yes" : "no")"
        if let url = link.url { text += " url=\(url.scheme ?? "?")://\(TextMasker.mask(url.host ?? "", limit: 30))" }
        return text
    }

    private func linkActivated(_ report: LinkActivationReport) {
        linkActivations.append(report)
        if awaitingActivation {
            awaitingActivation = false
            nextFirstLinkStep(after: 0.3)
        }
        var line = "link activated: window \(report.window) kind=\(report.kind.rawValue) -> "
            + LinkActivator.describe(report.outcome)
        if let error = report.pressError { line += " AXError=\(error.rawValue)" }
        if let supported = report.pressSupported { line += " pressSupported=\(supported)" }
        if let scheme = report.scheme {
            line += " url=\(scheme)://\(TextMasker.mask(report.host ?? "", limit: 30))"
        }
        say(line)
    }

    /// `--hover-at`: once the item under the point has its final translation drawn (after the first final
    /// translation when no item is there), rests the pointer at the point (fed to the overlay only, the real
    /// pointer does not move), reports which item shows its original, then moves it away after `--hover-hold`.
    private func hoverIfTranslated(_ key: WindowKey, _ items: [OverlayItem]) {
        guard let point = options.hoverAt, !hoverStarted, let overlay, items.contains(where: { $0.state == .final })
        else { return }
        // A click on a panel ends any wait on the pointer: hover only after the first-link steps are done.
        if options.usesFirstLink, !firstLinkStepsDone { return }
        let under = items.filter { $0.axFrame.standardized.contains(point) }
            .min { $0.axFrame.width * $0.axFrame.height < $1.axFrame.width * $1.axFrame.height }
        if let under {
            // Wait until that item itself is drawn in its final state.
            let drawn = overlay.contentItems(window: key).contains { $0.layout.id == under.id }
            guard under.state == .final, drawn else { return }
        }
        hoverStarted = true
        // The original is shown only where no other window covers the target (the fixture is usually behind).
        let covered = windowIDs[key].map {
            OverlayWindowServer.isPoint(point, coveredAbove: $0, ignoringPID: getpid()) ? "yes" : "no"
        }
        say(
            String(format: "hover at %.0f,%.0f: ", point.x, point.y)
                + (under.map { "over item \"\(TextMasker.mask($0.original, limit: 30))\" (\($0.state.rawValue))" }
                    ?? "over no item")
                + ", covered by another window: \(covered ?? "unknown")")
        overlay.updateMouseLocation(ax: point)
        let delay = settingsStore?.global.interaction.hoverDelay ?? OverlayInteractionSettings().hoverDelay
        let rested = delay + 0.3
        let hold = max(options.hoverHold, rested)
        DispatchQueue.main.asyncAfter(deadline: .now() + rested) {
            MainActor.assumeIsolated {
                SmokeTest.current?.reportHover("rested \(String(format: "%.1f", rested))s")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            MainActor.assumeIsolated {
                guard let test = SmokeTest.current, let overlay = test.overlay else { return }
                if hold > rested { test.reportHover("rested \(String(format: "%.1f", hold))s") }
                // Away from every window: the original should give way to the translation again.
                test.say("hover: pointer moved away")
                overlay.updateMouseLocation(ax: CGPoint(x: -100_000, y: -100_000))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    MainActor.assumeIsolated { SmokeTest.current?.reportHover("0.8s after leaving") }
                }
            }
        }
    }

    private func reportHover(_ label: String) {
        guard let overlay else { return }
        var line = "hover (\(label)): "
        if let revealed = overlay.revealedItem {
            line += "original shown in place for " + itemLabel(revealed.window, revealed.id)
        } else {
            line += "no original shown in place"
        }
        if let popup = overlay.hoverPopupItem {
            line += ", popup for " + itemLabel(popup.window, popup.id)
        } else {
            line += ", no popup"
        }
        say(line)
    }

    private func itemLabel(_ window: WindowKey, _ id: String) -> String {
        guard let item = lastItems[window]?.first(where: { $0.id == id }) else { return "an unknown item" }
        return "\"\(TextMasker.mask(item.original, limit: 30))\""
    }

    private func note(_ items: [OverlayItem]) {
        let now = elapsed
        for item in items {
            switch item.state {
            case .draft where firstDraft[item.id] == nil: firstDraft[item.id] = now
            case .final where firstFinal[item.id] == nil:
                firstFinal[item.id] = now
                if firstDraft[item.id] == nil { firstDraft[item.id] = now }
            default: break
            }
        }
    }

    private func record(_ call: LoggingTranslationBackend.Call) {
        calls.append(call)
        let status = call.output != nil ? "ok" : "failed(\(call.error ?? "?"))"
        say(
            String(
                format: "translate %@ %.0fms %@ src(%d)=\"%@\" -> \"%@\"", call.model.displayName,
                call.latency * 1000, status, call.source.count, TextMasker.mask(call.source, limit: 40),
                TextMasker.mask(call.output ?? "", limit: 40)))
    }

    private func stateSummary(_ items: [OverlayItem]) -> String {
        var counts: [OverlayItemState: Int] = [:]
        for item in items { counts[item.state, default: 0] += 1 }
        return "items=\(items.count) pending=\(counts[.pending] ?? 0) streaming=\(counts[.streaming] ?? 0) "
            + "draft=\(counts[.draft] ?? 0) final=\(counts[.final] ?? 0) failed=\(counts[.failed] ?? 0)"
    }

    private func finish() {
        closeMenusForTheEnd()
        let items = lastItems.values.flatMap { $0 }
        say("---- summary ----")
        let sorted = scanDurations.sorted()
        if !sorted.isEmpty {
            say(
                String(
                    format: "scans=%d median=%.1fms p90=%.1fms max=%.1fms maxSegments=%d", sorted.count,
                    sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 9 / 10)],
                    sorted.last ?? 0, maxSegments))
        }
        for model in ModelSize.allCases {
            let latencies = calls.filter { $0.model == model && $0.output != nil }.map(\.latency).sorted()
            let failures = calls.filter { $0.model == model && $0.output == nil }.count
            guard !latencies.isEmpty || failures > 0 else { continue }
            let median = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
            let p90 = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, latencies.count * 9 / 10)]
            say(
                String(
                    format: "%@: calls=%d failed=%d median=%.0fms p90=%.0fms first=%.0fms", model.displayName,
                    latencies.count, failures, median * 1000, p90 * 1000,
                    (calls.first { $0.model == model }?.latency ?? 0) * 1000))
        }
        let ids = Set(items.map(\.id))
        let draftDelays = ids.compactMap { id in firstDraft[id].flatMap { d in firstSeen[id].map { d - $0 } } }.sorted()
        let finalDelays = ids.compactMap { id in firstFinal[id].flatMap { f in firstSeen[id].map { f - $0 } } }.sorted()
        if !draftDelays.isEmpty {
            say(
                String(
                    format: "time to first translation (seen -> draft/final): median=%.2fs max=%.2fs (%d items)",
                    draftDelays[draftDelays.count / 2], draftDelays.last ?? 0, draftDelays.count))
        }
        if !finalDelays.isEmpty {
            say(
                String(
                    format: "time to final: median=%.2fs max=%.2fs (%d items)", finalDelays[finalDelays.count / 2],
                    finalDelays.last ?? 0, finalDelays.count))
        }
        if let since = pausedSince { pausedTotal += elapsed - since }
        say(
            String(
                format: "burst: refinement paused %d time(s), %.2fs in total%@", pauseCount, pausedTotal,
                refinementPaused ? " (still paused)" : ""))
        for (key, snapshot) in lastComplete.sorted(by: { $0.key.windowID < $1.key.windowID }) {
            let overlaps = Self.overlapCount(snapshot.segments.map(\.axFrame))
            say("last complete scan \(key): " + Self.styleSummary(snapshot.segments) + " overlaps=\(overlaps)")
        }
        if let since = passwordPausedSince { passwordPausedTotal += elapsed - since }
        say(
            String(
                format: "password: paused %d time(s), %.2fs in total%@; scans skipped %d; prompt pauses %d",
                passwordPauses, passwordPausedTotal, passwordPausedSince != nil ? " (still paused)" : "",
                skippedScans, promptPauses))
        say("final state: " + stateSummary(items))
        if overlay != nil {
            logRevealed()
            say("at the end:")
            for (key, items) in lastItems.sorted(by: { $0.key.description < $1.key.description }) {
                logClickAreas(key, items, force: true)
            }
        }
        if options.activateFirstLink {
            say(
                linkActivations.isEmpty
                    ? "link activation: none (no link was drawn in a translation)"
                    : "link activations: "
                        + linkActivations.map { LinkActivator.describe($0.outcome) }.joined(separator: ", "))
        }
        if options.contextMenuFirstLink {
            say(
                linkMenus.isEmpty
                    ? "link menu: none (no link was drawn in a translation)"
                    : "link menus: " + linkMenus.map { LinkActivator.describe($0.outcome) }.joined(separator: ", "))
        }
        menuWatch = nil
        session?.stop()
        overlay?.removeAll()
        let backend = self.backend
        Task {
            await backend?.unloadAll()
            exit(0)
        }
    }
}
