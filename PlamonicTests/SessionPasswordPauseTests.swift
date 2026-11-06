import AppKit
import XCTest

@testable import Plamonic

extension PasswordEntrySystem {
    /// Secure input always off and no focused element: for session tests that are not about passwords.
    static let testIdle = PasswordEntrySystem(
        secureInputEnabled: { false }, secureInputSession: { (nil, false) }, identify: { _ in ProcessIdentity() },
        focusedElement: { _, _ in .none }, now: { ProcessInfo.processInfo.systemUptime })
}

/// Secure input, the focused element of the app in front and every window read, scripted: the session under test
/// never touches secure input, AX of a real app or the screen. The app is a pid with no process.
final class SessionPasswordWorld: @unchecked Sendable {
    static let pid = pid_t(Int32.max - 7)
    static let bundleID = "test.plamonic.password-fixture"
    static let name = "Fixture"

    private let lock = NSLock()
    private var _secure = false
    private var _field: FocusedElementAnswer = .element(isSecure: false, isTextArea: true, characterCount: 100)
    private var _prompt = false
    private var _text = "Hello there, this is a test."
    private var _reads: [Bool] = []
    private var _readTimes: [TimeInterval] = []
    private var _fieldCalls = 0
    private var _readLatency: TimeInterval = 0

    var secure: Bool {
        get { lock.withLock { _secure } }
        set { lock.withLock { _secure = newValue } }
    }
    var field: FocusedElementAnswer {
        get { lock.withLock { _field } }
        set { lock.withLock { _field = newValue } }
    }
    /// The next snapshots wait at a password prompt.
    var prompt: Bool {
        get { lock.withLock { _prompt } }
        set { lock.withLock { _prompt = newValue } }
    }
    /// The text of the window's one segment (new output when it changes).
    var text: String {
        get { lock.withLock { _text } }
        set { lock.withLock { _text = newValue } }
    }
    /// Windows read so far (true = translate-now's scan).
    var reads: [Bool] { lock.withLock { _reads } }
    /// When each window was read (system uptime): measured where it happens, not when a test looks.
    var readTimes: [TimeInterval] { lock.withLock { _readTimes } }
    var fieldCalls: Int { lock.withLock { _fieldCalls } }
    /// How long a read takes before its result goes back (an app that answers slowly, or a busy Mac).
    var readLatency: TimeInterval {
        get { lock.withLock { _readLatency } }
        set { lock.withLock { _readLatency = newValue } }
    }

    /// A terminal screen whose insertion point follows the character at `column` of `row` (cells 7 × 14 pt).
    func setScreen(count: Int, location: Int, row: Int = 23, column: Int) {
        let frame = CGRect(x: 2500 + CGFloat(column) * 7, y: 200 + CGFloat(row) * 14, width: 7, height: 14)
        field = .element(
            isSecure: false, isTextArea: true, characterCount: count,
            insertionPoint: InsertionPoint(location: location, characterFrame: frame))
    }

    var system: PasswordEntrySystem {
        PasswordEntrySystem(
            secureInputEnabled: { [self] in secure },
            secureInputSession: { (4242, false) },
            identify: { _ in
                ProcessIdentity(bundleID: "com.apple.SecurityAgent", processName: "SecurityAgent", displayName: "SecurityAgent")
            },
            focusedElement: { [self] _, _ in
                lock.withLock {
                    _fieldCalls += 1
                    return _field
                }
            },
            now: { ProcessInfo.processInfo.systemUptime })
    }

    func read(_ request: ScanRequest) -> ScanResult {
        let (prompt, text, latency) = lock.withLock {
            _reads.append(request.manual)
            _readTimes.append(ProcessInfo.processInfo.systemUptime)
            return (_prompt, _text, _readLatency)
        }
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        let key = WindowKey(pid: request.pid, windowID: 1)
        let segment = TextSegment(
            id: "1-greeting", text: text,
            axFrame: CGRect(x: 2520, y: 240, width: 300, height: 20), role: "AXStaticText", isEditable: false,
            order: 0)
        let snapshot = WindowSnapshot(
            key: key, pid: request.pid, bundleID: request.bundleID,
            axWindowFrame: CGRect(x: 2500, y: 200, width: 600, height: 400), axClipRect: nil, segments: [segment],
            nodeCount: 1, scanDuration: 0.001, truncated: false, passwordPrompt: prompt)
        return ScanResult(
            request: request, window: AXElement(AXUIElementCreateApplication(request.pid)), cgWindowID: nil,
            outcome: .scanned(snapshot), diagnostics: ExtractionDiagnostics())
    }
}

/// The session's side of DESIGN §4.1: what stops while a password is typed, and what comes back afterwards.
@MainActor
final class SessionPasswordPauseTests: XCTestCase {
    private var directory: URL!
    private var settings: SettingsStore!
    private var session: LiveTranslationSession?
    private var notes: [PasswordGuardNote] = []
    private let world = SessionPasswordWorld()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plamonic-session-password-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        notes = []
    }

    override func tearDown() async throws {
        session?.stop()
        session = nil
        OverlayColorSampleScheduler.setCapturesPaused(false)
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(mode: TranslationMode = .automatic, pinned: Bool = true) -> LiveTranslationSession {
        settings = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"), saveDelay: 60)
        settings.updateGlobal {
            $0.scanInterval = 0.1
            $0.backgroundScanInterval = 0.5
            $0.persistCache = false
        }
        settings.updateProfile(bundleID: SessionPasswordWorld.bundleID, appName: SessionPasswordWorld.name) {
            $0.mode = mode
        }
        var options = LiveTranslationSession.Options()
        options.showsOverlays = false
        options.monitorsInput = false
        options.passwordPollInterval = 0.02
        let world = world
        options.scanRead = { world.read($0) }
        options.testApp = LiveTranslationSession.TestApp(
            pid: SessionPasswordWorld.pid, bundleID: SessionPasswordWorld.bundleID, name: SessionPasswordWorld.name)
        if pinned { options.pinnedPID = SessionPasswordWorld.pid }
        let cache = TranslationCache(capacity: 10, fileURL: nil, persistenceEnabled: false)
        let coordinator = TranslationCoordinator(backend: TranslationFakeBackend(), cache: cache) { nil }
        let session = LiveTranslationSession(
            settings: settings, coordinator: coordinator, overlay: nil, options: options,
            passwordSystem: world.system)
        session.onPasswordGuard = { [weak self] note in self?.notes.append(note) }
        self.session = session
        session.start()
        return session
    }

    /// Waits until `condition` holds, polling on the main actor every 5 ms; fails after `timeout`.
    private func expect(
        timeout: TimeInterval = 3, _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The guard's probe answered at least once since the call and the answer reached the session. Three more asks
    /// are awaited: one under way when the pause began may have been made without the probe, the next is a probe,
    /// and the guard's queue is serial, so that answer was sent to the main queue before the third ask (which the
    /// test sees as soon as it is made); the short sleep lets the main queue deliver it. Call it once the pause the
    /// answer is for is in place (an answer reaches whatever pause the window has when it arrives).
    private func waitForTheProbe() async {
        let calls = world.fieldCalls
        await expect("the probe answers") { world.fieldCalls >= calls + 3 }
        await sleep(0.03)
    }

    /// Scans that came back at a prompt (the first one and each rescan): the sign that a scan's result, not only
    /// its read, reached the session.
    private var promptPausedNotes: Int {
        notes.filter {
            if case .promptPaused = $0 { return true }
            return false
        }.count
    }

    /// The guard's asks of the focused element once they stop: the count after it stayed the same for `quiet`
    /// (an ask under way when the state changed may still land). A guard that keeps asking does not settle, or
    /// asks again during the caller's own window, which then fails.
    private func settledFieldCalls(quiet: TimeInterval = 0.1, timeout: TimeInterval = 3) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var count = world.fieldCalls
        var since = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let now = world.fieldCalls
            if now != count {
                count = now
                since = Date()
            } else if Date().timeIntervalSince(since) >= quiet {
                break
            }
        }
        return count
    }

    private var ignoredTranslateNow: Int {
        notes.filter {
            if case .translateNowIgnored = $0 { return true }
            return false
        }.count
    }

    func testNothingIsReadWhilePausedAndEverythingIsRescannedAfter() async {
        let session = start()
        await expect("timed scans") { world.reads.count >= 2 }
        world.secure = true
        await expect { session.status.passwordPause != nil }
        XCTAssertEqual(session.status.passwordPause, PasswordPause(reason: .secureInput, appName: "SecurityAgent"))
        XCTAssertTrue(ScreenCaptureGate.shared.isPaused, "no screen captures for background colors")
        await sleep(0.05)
        let paused = world.reads.count
        await sleep(0.4)
        XCTAssertEqual(world.reads.count, paused, "no timed scans while paused")
        session.translateNow()
        await sleep(0.1)
        XCTAssertEqual(world.reads.count, paused)
        XCTAssertEqual(ignoredTranslateNow, 1)

        world.secure = false
        await expect("rescanned once it ended") { world.reads.count > paused }
        XCTAssertNil(session.status.passwordPause)
        XCTAssertFalse(ScreenCaptureGate.shared.isPaused)
    }

    func testEscapeMonitorIsOffWhilePausedAndClosingStillWorks() async {
        let session = start(mode: .manual)
        session.translateNow()
        await expect("a manual translation is shown") { session.escapeMonitoringWanted }
        XCTAssertEqual(world.reads, [true])

        world.secure = true
        await expect { session.status.passwordPause != nil }
        XCTAssertFalse(session.escapeMonitoringWanted)
        world.secure = false
        await expect { session.status.passwordPause == nil && session.escapeMonitoringWanted }

        // Paused again: translate-now still closes what is shown (nothing is read), and then reads nothing.
        world.secure = true
        await expect { session.status.passwordPause != nil }
        let reads = world.reads.count
        session.translateNow()
        XCTAssertFalse(session.status.manualActive)
        XCTAssertEqual(ignoredTranslateNow, 0)
        session.translateNow()
        XCTAssertEqual(ignoredTranslateNow, 1)
        await sleep(0.1)
        XCTAssertEqual(world.reads.count, reads)
    }

    /// The default manual mode reads nothing until translate-now: rule b is not polled then, only asked by the
    /// gate right before translate-now's scan.
    func testIdleManualAppIsAskedOnlyRightBeforeAScan() async {
        world.field = .element(isSecure: true)
        let session = start(mode: .manual)
        await sleep(0.2)
        XCTAssertEqual(world.fieldCalls, 0)
        XCTAssertNil(session.status.passwordPause)

        session.translateNow()
        await expect { session.status.passwordPause?.reason == .secureField }
        await expect { self.ignoredTranslateNow == 1 }
        XCTAssertTrue(world.reads.isEmpty, "the gate stopped the scan")

        // The field loses the focus: the pause ends (asked while paused), and nothing is read or asked after.
        world.field = .element(isSecure: false)
        await expect { session.status.passwordPause == nil }
        let calls = await settledFieldCalls()
        await sleep(0.2)
        XCTAssertEqual(world.fieldCalls, calls)
        XCTAssertTrue(world.reads.isEmpty)
    }

    /// While Plamonic's own window is in front the session keeps following the previous app, which keys nothing
    /// in: rule b is not asked of it.
    func testFocusedFieldIsNotAskedWhileOwnWindowIsInFront() async {
        world.field = .element(isSecure: true)
        let session = start(pinned: false)
        await expect { session.status.passwordPause?.reason == .secureField }

        session.applicationActivated(pid: getpid(), bundleID: "io.smdr.Plamonic", name: "Plamonic")
        XCTAssertEqual(session.status.frontmostAppName, SessionPasswordWorld.name)
        await expect { session.status.passwordPause == nil }
        let calls = await settledFieldCalls()
        let reads = world.reads.count
        await sleep(0.3)
        XCTAssertEqual(world.fieldCalls, calls)
        await expect("reading goes on") { world.reads.count > reads }

        session.applicationActivated(
            pid: SessionPasswordWorld.pid, bundleID: SessionPasswordWorld.bundleID, name: SessionPasswordWorld.name)
        await expect { session.status.passwordPause?.reason == .secureField }
    }

    func testPinnedSessionAsksItsAppWhateverIsInFront() async {
        world.field = .element(isSecure: true)
        let session = start(pinned: true)
        await expect { session.status.passwordPause?.reason == .secureField }
        session.applicationActivated(pid: getpid(), bundleID: "io.smdr.Plamonic", name: "Plamonic")
        await sleep(0.2)
        XCTAssertEqual(session.status.passwordPause?.reason, .secureField)
    }

    /// Rule c: the window at the prompt gets no timed scans; output seen by the probe gives one scan.
    func testPromptPausesTheWindowUntilTheProbeSeesOutput() async {
        world.prompt = true
        world.field = .element(isSecure: false, isTextArea: true, characterCount: 500)
        let session = start()
        await expect { session.status.passwordPause?.reason == .terminalPrompt }
        XCTAssertEqual(session.status.passwordPause?.appName, SessionPasswordWorld.name)
        await waitForTheProbe()
        let reads = world.reads.count
        await sleep(0.5)
        XCTAssertEqual(world.reads.count, reads, "no timed scans at the prompt")

        world.text = "Sorry, try again."
        world.field = .element(isSecure: false, isTextArea: true, characterCount: 560)
        await expect { world.reads.count == reads + 1 }
        await sleep(0.3)
        XCTAssertEqual(world.reads.count, reads + 1, "still at a prompt: paused again")
        XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)

        // Any AX event of the app resumes it when the probe does not see the insertion point.
        session.handleEvents([SessionPasswordWorld.pid: [.valueChanged]])
        await expect { world.reads.count == reads + 2 }
    }

    /// sudo's pwfeedback echoes a mark per key: neither the text events nor the probe cause a scan while the
    /// insertion point moves along the prompt's row. Output after Return does.
    func testMarksTypedAtAPromptAreNotRead() async {
        world.prompt = true
        world.setScreen(count: 1000, location: 999, column: 25)
        let session = start()
        await expect { session.status.passwordPause?.reason == .terminalPrompt }
        await waitForTheProbe()
        let reads = world.reads.count
        for typed in 1...6 {
            world.setScreen(count: 1000 + typed, location: 999 + typed, column: 25 + typed)
            session.handleEvents([SessionPasswordWorld.pid: [.valueChanged, .selectedTextChanged]])
            await sleep(0.05)
        }
        await sleep(0.2)
        XCTAssertEqual(world.reads.count, reads, "marks typed are not read")
        XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)

        // A window change still resumes it at once.
        let paused = promptPausedNotes
        session.handleEvents([SessionPasswordWorld.pid: [.focusedWindowChanged]])
        await expect { world.reads.count == reads + 1 }
        // The rescan's result (still at the prompt: a new pause) reached the session, and the probe took the screen
        // before Return as the new pause's baseline.
        await expect("the rescan's result reached the session") { self.promptPausedNotes > paused }
        XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)
        await waitForTheProbe()

        // Return at the bottom row: the screen scrolls and "$ " is on the same row at column 1.
        world.prompt = false
        world.setScreen(count: 1009, location: 1008, column: 1)
        session.handleEvents([SessionPasswordWorld.pid: [.valueChanged]])
        await expect { world.reads.count >= reads + 2 }
        await expect { session.status.passwordPause == nil }
    }

    /// The pause stays while the window is scanned again: the Esc monitor (a keyDown monitor) does not come back
    /// between a change at the prompt and the scan that tells whether the prompt is gone.
    func testPromptPauseStaysUntilTheRescanSeesThePromptGone() async {
        world.prompt = true
        let session = start(mode: .manual)
        session.translateNow()
        await expect { session.status.passwordPause?.reason == .terminalPrompt }
        XCTAssertTrue(session.status.manualActive)
        XCTAssertFalse(session.escapeMonitoringWanted)
        XCTAssertEqual(world.reads, [true])

        session.handleEvents([SessionPasswordWorld.pid: [.focusedWindowChanged]])
        XCTAssertFalse(session.escapeMonitoringWanted, "no keyDown monitor before the rescan")
        XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)
        await expect { world.reads.count == 2 }
        await sleep(0.05)
        XCTAssertFalse(session.escapeMonitoringWanted, "still at the prompt")
        XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)

        world.prompt = false
        world.text = "Done."
        session.handleEvents([SessionPasswordWorld.pid: [.valueChanged]])
        XCTAssertFalse(session.escapeMonitoringWanted)
        await expect { world.reads.count == 3 }
        await expect { session.status.passwordPause == nil && session.escapeMonitoringWanted }
    }

    /// A prompt that echoes a mark per key, where the probe does not see the insertion point: the extraction
    /// blanks the marks, so a rescan finds the same texts. Its text changes are then read at most every 2 s.
    func testEchoedMarksAreReadAtMostEveryFallbackInterval() async {
        world.prompt = true
        world.field = .element(isSecure: false, isTextArea: true, characterCount: 500)
        let session = start()
        await expect { session.status.passwordPause?.reason == .terminalPrompt }
        await waitForTheProbe()
        let reads = world.reads.count
        let paused = promptPausedNotes

        // The first mark is read once: same texts as before, so the prompt echoes marks.
        world.field = .element(isSecure: false, isTextArea: true, characterCount: 501)
        session.handleEvents([SessionPasswordWorld.pid: [.valueChanged, .selectedTextChanged]])
        await expect { world.reads.count == reads + 1 }
        let firstRescan = Date()
        // Its result reaches the session: the window waits at the prompt again, now known to echo marks (a change
        // while a scan is in flight gets one more scan: it may be output).
        await expect("the rescan's result reached the session") { self.promptPausedNotes > paused }
        for typed in 2...6 {
            world.field = .element(isSecure: false, isTextArea: true, characterCount: 500 + typed)
            session.handleEvents([SessionPasswordWorld.pid: [.valueChanged, .selectedTextChanged]])
            XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)
            await sleep(0.1)
        }
        await sleep(max(0, 1.4 - Date().timeIntervalSince(firstRescan)))
        XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)
        await expect("read once the interval is over") { world.reads.count >= reads + 2 }
        guard world.readTimes.count >= reads + 2 else { return }
        // Measured between the reads themselves, so a late wake-up of the test does not count.
        let interval = world.readTimes[reads + 1] - world.readTimes[reads]
        XCTAssertGreaterThan(interval, 1.8, "marks are not read one by one: the next read waits for the interval")
        // Once per interval: the marks' deferred scan and the window's timed fallback are one read, not two.
        await sleep(0.3)
        XCTAssertEqual(world.reads.count, reads + 2, "one read per interval, not one more right after it")

        // A window change is read at once, not deferred like the marks (the next interval ends 2 s after the read
        // above, about 1.7 s from here).
        let windowChanged = ProcessInfo.processInfo.systemUptime
        session.handleEvents([SessionPasswordWorld.pid: [.focusedWindowChanged]])
        await expect { world.reads.count >= reads + 3 }
        guard world.readTimes.count >= reads + 3 else { return }
        XCTAssertLessThan(world.readTimes[reads + 2] - windowChanged, 1, "read at once")
        XCTAssertEqual(session.status.passwordPause?.reason, .terminalPrompt)
    }

    func testEchoedMarksAreReadOncePerIntervalWhenReadsAreSlow() async {
        world.prompt = true
        world.field = .element(isSecure: false, isTextArea: true, characterCount: 500)
        let session = start()
        await expect { session.status.passwordPause?.reason == .terminalPrompt }
        await waitForTheProbe()
        // Each read now takes longer than the timer's leeway: the marks' deferred scan and the window's timed
        // fallback must still come due together, or the window is read twice in a row.
        world.readLatency = 0.08
        let reads = world.reads.count
        let paused = promptPausedNotes
        world.field = .element(isSecure: false, isTextArea: true, characterCount: 501)
        session.handleEvents([SessionPasswordWorld.pid: [.valueChanged, .selectedTextChanged]])
        await expect { world.reads.count == reads + 1 }
        await expect("the rescan's result reached the session") { self.promptPausedNotes > paused }
        for typed in 2...4 {
            world.field = .element(isSecure: false, isTextArea: true, characterCount: 500 + typed)
            session.handleEvents([SessionPasswordWorld.pid: [.valueChanged, .selectedTextChanged]])
            await sleep(0.1)
        }
        await expect("read once the interval is over") { world.reads.count >= reads + 2 }
        await sleep(0.4)
        XCTAssertEqual(world.reads.count, reads + 2, "one read per interval, not one more right after it")
    }

    func testTurningTheSettingOffClearsPromptPauses() async {
        world.prompt = true
        let session = start()
        await expect { session.status.passwordPause?.reason == .terminalPrompt }
        await sleep(0.05)
        let reads = world.reads.count
        settings.updateGlobal { $0.pauseDuringPasswordEntry = false }
        session.settingsDidChange()
        XCTAssertNil(session.status.passwordPause)
        await expect("timed scans again") { world.reads.count >= reads + 3 }
        XCTAssertNil(session.status.passwordPause)
        let calls = world.fieldCalls
        await sleep(0.1)
        XCTAssertEqual(world.fieldCalls, calls, "the guard asks nothing with the setting off")
    }

    func testRuleBAsksOnlyTheAppInFront() {
        XCTAssertTrue(LiveTranslationSession.asksFocusedField(of: 10, realFront: 10, pinned: false))
        XCTAssertFalse(LiveTranslationSession.asksFocusedField(of: 10, realFront: 99, pinned: false))
        XCTAssertTrue(LiveTranslationSession.asksFocusedField(of: 10, realFront: 99, pinned: true))
        XCTAssertTrue(LiveTranslationSession.asksFocusedField(of: 10, realFront: nil, pinned: false))
    }
}
