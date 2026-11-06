import AppKit
import XCTest

@testable import Plamonic

/// Every system call of the guard, scripted. Never touches secure input, AX or the screen.
private final class FakePasswordSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var secure = false
    private var focusPID: pid_t?
    private var locked = false
    private var identities: [pid_t: ProcessIdentity] = [:]
    private var answers: [pid_t: FocusedElementAnswer] = [:]
    private var clock: TimeInterval = 1000
    private var _flagReads = 0
    private var _sessionReads = 0
    private var _fieldCalls: [(pid: pid_t, wantsCount: Bool)] = []

    var flagReads: Int { lock.withLock { _flagReads } }
    var sessionReads: Int { lock.withLock { _sessionReads } }
    var fieldCalls: [pid_t] { lock.withLock { _fieldCalls.map(\.pid) } }
    var countRequests: [Bool] { lock.withLock { _fieldCalls.map(\.wantsCount) } }

    func setSecureInput(_ on: Bool, focus: pid_t? = nil, locked: Bool = false) {
        lock.withLock {
            secure = on
            focusPID = focus
            self.locked = locked
        }
    }

    func setIdentity(_ pid: pid_t, _ identity: ProcessIdentity) { lock.withLock { identities[pid] = identity } }
    func setField(_ pid: pid_t, _ answer: FocusedElementAnswer) { lock.withLock { answers[pid] = answer } }
    func advance(_ seconds: TimeInterval) { lock.withLock { clock += seconds } }

    var system: PasswordEntrySystem {
        PasswordEntrySystem(
            secureInputEnabled: { [self] in
                lock.withLock {
                    _flagReads += 1
                    return secure
                }
            },
            secureInputSession: { [self] in
                lock.withLock {
                    _sessionReads += 1
                    return (focusPID, locked)
                }
            },
            identify: { [self] pid in lock.withLock { identities[pid] ?? ProcessIdentity() } },
            focusedElement: { [self] pid, wantsCount in
                lock.withLock {
                    _fieldCalls.append((pid, wantsCount))
                    return answers[pid] ?? .element(isSecure: false, characterCount: nil)
                }
            },
            now: { [self] in lock.withLock { clock } })
    }
}

private let safari = ProcessIdentity(bundleID: "com.apple.Safari", processName: "Safari", displayName: "Safari")
private let terminal = ProcessIdentity(
    bundleID: "com.apple.Terminal", processName: "Terminal", displayName: "ターミナル")
private let securityAgent = ProcessIdentity(
    bundleID: "com.apple.SecurityAgent", processName: "SecurityAgent", displayName: "SecurityAgent")
private let loginwindow = ProcessIdentity(
    bundleID: "com.apple.loginwindow", processName: "loginwindow", displayName: "loginwindow")

/// Rules a and b of DESIGN §4.1 (pure).
final class PasswordEntryRulesTests: XCTestCase {
    private func input(
        secure: Bool = true, focusPID: pid_t? = 10, focus: ProcessIdentity? = safari,
        front: PasswordFrontApp? = PasswordFrontApp(pid: 10, name: "Safari"), stuck: Bool = false,
        locked: Bool = false, field: PasswordFieldState = .notAsked
    ) -> PasswordEntryRules.Input {
        PasswordEntryRules.Input(
            settingOn: true, secureInput: SecureInputState(enabled: secure, focusPID: focusPID, screenLocked: locked),
            focus: focus, front: front, stuck: stuck, field: field)
    }

    func testSettingOffNeverPauses() {
        var off = input()
        off.settingOn = false
        off.field = .secure
        XCTAssertNil(PasswordEntryRules.decide(off))
    }

    func testNoSecureInputNoPause() {
        XCTAssertNil(PasswordEntryRules.decide(input(secure: false)))
    }

    func testFrontmostOwnerPauses() {
        XCTAssertEqual(
            PasswordEntryRules.decide(input()), PasswordPause(reason: .secureInput, appName: "Safari"))
    }

    func testOwnerOtherThanTheFrontAppPauses() {
        // A menu-bar password manager's panel has the keyboard focus over Safari: real password entry.
        let manager = ProcessIdentity(bundleID: "com.example.vault", processName: "Vault", displayName: "Vault")
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 20, focus: manager)),
            PasswordPause(reason: .secureInput, appName: "Vault"))
    }

    func testUnknownOwnerPausesAndNamesTheFrontApp() {
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: nil, focus: nil)),
            PasswordPause(reason: .secureInput, appName: "Safari"))
    }

    func testSystemAuthOwnerPauses() {
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 30, focus: securityAgent)),
            PasswordPause(reason: .secureInput, appName: "SecurityAgent"))
        // Matched by process name when there is no bundle ID.
        let touchID = ProcessIdentity(bundleID: nil, processName: "coreautha", displayName: nil)
        XCTAssertTrue(PasswordEntryRules.isSystemAuth(touchID, screenLocked: false))
        XCTAssertFalse(PasswordEntryRules.isSystemAuth(safari, screenLocked: true))
        XCTAssertFalse(PasswordEntryRules.isSystemAuth(nil, screenLocked: true))
        // loginwindow only while the screen is locked.
        XCTAssertTrue(PasswordEntryRules.isSystemAuth(loginwindow, screenLocked: true))
        XCTAssertFalse(PasswordEntryRules.isSystemAuth(loginwindow, screenLocked: false))
        XCTAssertFalse(
            PasswordEntryRules.isSystemAuth(ProcessIdentity(processName: "loginwindow"), screenLocked: false))
    }

    func testLockScreenHasNoAppName() {
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 40, focus: loginwindow, locked: true)),
            PasswordPause(reason: .secureInput, appName: nil))
        XCTAssertEqual(
            PasswordEntryRules.decide(input(locked: true)), PasswordPause(reason: .secureInput, appName: nil))
        XCTAssertNotNil(PasswordEntryRules.decide(input(focusPID: 40, focus: loginwindow, stuck: true, locked: true)))
    }

    /// After unlock or wake, secure input some app left on is often blamed on loginwindow: an ordinary holder
    /// (no name), which the stuck guard can release.
    func testLoginWindowAfterUnlockIsAnOrdinaryHolder() {
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 40, focus: loginwindow)),
            PasswordPause(reason: .secureInput, appName: nil))
        XCTAssertNil(PasswordEntryRules.decide(input(focusPID: 40, focus: loginwindow, stuck: true)))
    }

    func testTerminalAtTheFrontIsExempt() {
        let front = PasswordFrontApp(pid: 50, name: "ターミナル", isTerminalTarget: true)
        // Secure Keyboard Entry: the terminal itself (or nobody) is named.
        XCTAssertNil(PasswordEntryRules.decide(input(focusPID: 50, focus: terminal, front: front)))
        XCTAssertNil(PasswordEntryRules.decide(input(focusPID: nil, focus: nil, front: front)))
        // A Touch ID / password dialog over the terminal (sudo) still pauses.
        let touchID = ProcessIdentity(
            bundleID: "com.apple.LocalAuthentication.UIAgent", processName: "coreautha", displayName: "coreautha")
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 60, focus: touchID, front: front)),
            PasswordPause(reason: .secureInput, appName: "coreautha"))
        // A terminal Plamonic does not read in terminal mode is not exempt (no prompt detection for it).
        let notTarget = PasswordFrontApp(pid: 50, name: "ターミナル", isTerminalTarget: false)
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 50, focus: terminal, front: notTarget)),
            PasswordPause(reason: .secureInput, appName: "ターミナル"))
    }

    /// Only the terminal's screen is exempt: another focused element of an app set to terminal mode (a password
    /// field shown as text in an Electron app, a find bar) has no secure subrole, and only rule a sees it.
    func testTerminalExemptionNeedsItsScreenFocused() {
        let front = PasswordFrontApp(pid: 50, name: "Code", isTerminalTarget: true)
        XCTAssertNil(PasswordEntryRules.decide(input(focusPID: 50, focus: terminal, front: front, field: .textArea)))
        let paused = PasswordPause(reason: .secureInput, appName: "ターミナル")
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 50, focus: terminal, front: front, field: .notSecure)), paused)
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: 50, focus: terminal, front: front, field: .timedOut)), paused)
        XCTAssertEqual(
            PasswordEntryRules.decide(input(focusPID: nil, focus: nil, front: front, field: .notSecure)),
            PasswordPause(reason: .secureInput, appName: "Code"))
    }

    func testStuckSecureInputDoesNotPauseButSystemDialogsStillDo() {
        XCTAssertNil(PasswordEntryRules.decide(input(stuck: true)))
        XCTAssertNotNil(PasswordEntryRules.decide(input(focusPID: 30, focus: securityAgent, stuck: true)))
        XCTAssertNotNil(PasswordEntryRules.decide(input(stuck: true, locked: true)))
    }

    func testSecureFocusedFieldPauses() {
        var field = input(secure: false)
        field.field = .secure
        field.fieldAppName = "Slack"
        XCTAssertEqual(PasswordEntryRules.decide(field), PasswordPause(reason: .secureField, appName: "Slack"))
        field.field = .notSecure
        XCTAssertNil(PasswordEntryRules.decide(field))
        field.field = .timedOut
        XCTAssertNil(PasswordEntryRules.decide(field))
        // Secure input wins (it names the app that takes the password).
        var both = input()
        both.field = .secure
        XCTAssertEqual(PasswordEntryRules.decide(both)?.reason, .secureInput)
    }

    func testStuckTrackerCountsDistinctAppsOfOneStretch() {
        // Going back and forth between two apps (a password manager's autofill) never counts as stuck.
        var autofill = StuckSecureInputTracker()
        for holder: pid_t in [1, 2, 1, 2, 1, 2, 1] {
            XCTAssertFalse(autofill.observe(enabled: true, holder: holder, holderIsSystemAuth: false))
        }
        XCTAssertFalse(autofill.isStuck)

        var tracker = StuckSecureInputTracker()
        XCTAssertFalse(tracker.observe(enabled: true, holder: 1, holderIsSystemAuth: false))
        XCTAssertFalse(tracker.observe(enabled: true, holder: 1, holderIsSystemAuth: false))
        XCTAssertFalse(tracker.observe(enabled: true, holder: 2, holderIsSystemAuth: false))
        // System dialogs are not counted.
        XCTAssertFalse(tracker.observe(enabled: true, holder: 9, holderIsSystemAuth: true))
        XCTAssertFalse(tracker.isStuck)
        XCTAssertTrue(tracker.observe(enabled: true, holder: 3, holderIsSystemAuth: false))
        XCTAssertTrue(tracker.isStuck)
        // Reported once.
        XCTAssertFalse(tracker.observe(enabled: true, holder: 4, holderIsSystemAuth: false))
        XCTAssertEqual(tracker.holders, [1, 2, 3, 4])
        // Seeing secure input off ends the stretch.
        XCTAssertFalse(tracker.observe(enabled: false, holder: nil, holderIsSystemAuth: false))
        XCTAssertFalse(tracker.isStuck)
        XCTAssertTrue(tracker.holders.isEmpty)
    }
}

/// The guard with a scripted system: what it asks, when, and what it tells the session.
@MainActor
final class PasswordEntryGuardTests: XCTestCase {
    private var events: [PasswordEntryGuard.Event] = []

    private func makeGuard(_ fake: FakePasswordSystem, poll: TimeInterval = 60) -> PasswordEntryGuard {
        PasswordEntryGuard(system: fake.system, pollInterval: poll) { [weak self] event in
            self?.events.append(event)
        }
    }

    private func context(
        front: PasswordFrontApp? = PasswordFrontApp(pid: 10, name: "Safari"), field: pid_t? = nil,
        probes: Bool = false, polls: Bool = true, pollsField: Bool = true
    ) -> PasswordEntryGuard.Context {
        var context = PasswordEntryGuard.Context()
        context.isOn = true
        context.polls = polls
        context.front = front
        context.fieldCheckPID = field
        context.fieldCheckName = field.map { "app\($0)" }
        context.pollsField = pollsField
        context.probesFocusedText = probes
        return context
    }

    /// Lets the guard's queue and then the main queue run what they were given.
    private func settle(_ passwordGuard: PasswordEntryGuard) async {
        passwordGuard.queue.sync {}
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }

    private var pauses: [PasswordPause?] {
        events.compactMap { event in
            if case .pauseChanged(let pause) = event { return .some(pause) }
            return nil
        }
    }

    private var stuckReports: [[String]] {
        events.compactMap { event in
            if case .stuckSecureInput(let names) = event { return names }
            return nil
        }
    }

    private var probes: [Int?] {
        events.compactMap { event in
            if case .focusedText(_, let probe) = event { return .some(probe.characterCount) }
            return nil
        }
    }

    private var probeAnswers: [PromptProbe] {
        events.compactMap { event in
            if case .focusedText(_, let probe) = event { return probe }
            return nil
        }
    }

    override func setUp() async throws {
        events = []
    }

    func testSettingOffAsksNothing() async {
        let fake = FakePasswordSystem()
        fake.setSecureInput(true, focus: 10)
        let passwordGuard = makeGuard(fake)
        var off = context(field: 10)
        off.isOn = false
        passwordGuard.update(off)
        passwordGuard.checkSoon()
        XCTAssertNil(passwordGuard.gate())
        await settle(passwordGuard)
        XCTAssertEqual(fake.flagReads, 0)
        XCTAssertTrue(fake.fieldCalls.isEmpty)
        XCTAssertTrue(pauses.isEmpty)
    }

    /// Without apps to read nothing is stopped and nothing is asked: only the flag (shared memory, no IPC) is
    /// looked at, so that a stuck holder's count restarts when it goes off.
    func testWithoutAppsToReadOnlyTheGateAsks() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(10, safari)
        fake.setSecureInput(true, focus: 10)
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context(field: 10, polls: false))
        passwordGuard.checkSoon()
        await settle(passwordGuard)
        XCTAssertEqual(fake.sessionReads, 0)
        XCTAssertTrue(fake.fieldCalls.isEmpty)
        XCTAssertTrue(pauses.isEmpty)
        XCTAssertEqual(passwordGuard.gate(), PasswordPause(reason: .secureInput, appName: "Safari"))
        XCTAssertEqual(fake.sessionReads, 1)
    }

    func testGateSeesSecureInputAtOnceAndTellsTheSession() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(10, safari)
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context())
        await settle(passwordGuard)
        XCTAssertEqual(fake.sessionReads, 0, "the session dictionary is read only while secure input is on")

        fake.setSecureInput(true, focus: 10)
        XCTAssertEqual(passwordGuard.gate(), PasswordPause(reason: .secureInput, appName: "Safari"))
        XCTAssertEqual(fake.sessionReads, 1)
        await settle(passwordGuard)
        XCTAssertEqual(pauses, [PasswordPause(reason: .secureInput, appName: "Safari")])

        fake.setSecureInput(false)
        XCTAssertNil(passwordGuard.gate())
        await settle(passwordGuard)
        XCTAssertEqual(pauses, [PasswordPause(reason: .secureInput, appName: "Safari"), nil])
    }

    func testSystemDialogOwnerPauses() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(30, securityAgent)
        fake.setSecureInput(true, focus: 30)
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context())
        XCTAssertEqual(passwordGuard.gate(), PasswordPause(reason: .secureInput, appName: "SecurityAgent"))
    }

    func testUnknownOwnerNamesTheFrontApp() async {
        let fake = FakePasswordSystem()
        fake.setSecureInput(true, focus: nil)
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context())
        XCTAssertEqual(passwordGuard.gate(), PasswordPause(reason: .secureInput, appName: "Safari"))
    }

    func testTerminalAtTheFrontDoesNotPause() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(50, terminal)
        fake.setSecureInput(true, focus: 50)
        fake.setField(50, .element(isSecure: false, isTextArea: true))
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(
            context(front: PasswordFrontApp(pid: 50, name: "ターミナル", isTerminalTarget: true), field: 50))
        XCTAssertNil(passwordGuard.gate())
    }

    private static let fronts = [
        PasswordFrontApp(pid: 10, name: "Safari"), PasswordFrontApp(pid: 11, name: "Notes"),
        PasswordFrontApp(pid: 12, name: "Mail"), PasswordFrontApp(pid: 13, name: "Chat"),
    ]

    /// The window server keeps naming the app that was in front when secure input was turned on, so a holder
    /// that keeps it on is recognised by the front apps: three different ones, then no pause for it, logged once.
    func testSecureInputHeldInTheBackgroundIsIgnoredAndLoggedOnce() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(77, ProcessIdentity(bundleID: "com.example.editor", processName: "Editor", displayName: "Editor"))
        fake.setSecureInput(true, focus: 77)
        let passwordGuard = makeGuard(fake)
        for (index, front) in Self.fronts.enumerated() {
            passwordGuard.update(context(front: front))
            let decision = passwordGuard.gate()
            if index < 2 {
                // Named after the app that holds it, not the front app.
                XCTAssertEqual(decision, PasswordPause(reason: .secureInput, appName: "Editor"), "\(index)")
            } else {
                XCTAssertNil(decision, "\(index)")
            }
        }
        await settle(passwordGuard)
        XCTAssertEqual(stuckReports, [["Safari", "Notes", "Mail"]])
        // Secure input seen off: the next stretch counts afresh.
        fake.setSecureInput(false)
        XCTAssertNil(passwordGuard.gate())
        fake.setSecureInput(true, focus: 10)
        passwordGuard.update(context(front: Self.fronts[0]))
        XCTAssertNotNil(passwordGuard.gate())
        await settle(passwordGuard)
        XCTAssertEqual(stuckReports.count, 1)
    }

    func testGoingBackAndForthBetweenTwoAppsKeepsPausing() async {
        let fake = FakePasswordSystem()
        fake.setSecureInput(true, focus: 77)
        let passwordGuard = makeGuard(fake)
        for round in 0..<5 {
            for front in Self.fronts.prefix(2) {
                passwordGuard.update(context(front: front))
                XCTAssertNotNil(passwordGuard.gate(), "round \(round)")
            }
        }
        await settle(passwordGuard)
        XCTAssertTrue(stuckReports.isEmpty)
    }

    /// Apps Plamonic does not read (mode off) in between do not restart the count: only the flag seen off does.
    func testStuckCountIsKeptWhileNothingIsRead() async {
        let fake = FakePasswordSystem()
        fake.setSecureInput(true, focus: 77)
        let passwordGuard = makeGuard(fake)
        let off = PasswordFrontApp(pid: 20, name: "Off")
        var decisions: [PasswordPause?] = []
        for front in Self.fronts.prefix(3) {
            passwordGuard.update(context(front: front, field: front.pid))
            decisions.append(passwordGuard.gate())
            let read = (fake.sessionReads, fake.fieldCalls.count)
            passwordGuard.update(context(front: off, polls: false))
            passwordGuard.checkSoon()
            await settle(passwordGuard)
            XCTAssertEqual(fake.sessionReads, read.0, "nothing but the flag is read while nothing is read")
            XCTAssertEqual(fake.fieldCalls.count, read.1)
        }
        XCTAssertNotNil(decisions[0])
        XCTAssertNotNil(decisions[1])
        XCTAssertNil(decisions[2])
        XCTAssertEqual(stuckReports, [["Safari", "Notes", "Mail"]])

        // The flag goes off while nothing is read: seen at the next check, so the count restarts.
        fake.setSecureInput(false)
        passwordGuard.checkSoon()
        await settle(passwordGuard)
        fake.setSecureInput(true, focus: 77)
        passwordGuard.update(context(front: Self.fronts[2]))
        XCTAssertNotNil(passwordGuard.gate())
    }

    /// loginwindow named after unlock (secure input left on): released by the stuck guard; never while locked.
    func testLoginWindowAfterUnlockIsReleasedByTheStuckGuard() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(40, loginwindow)
        fake.setSecureInput(true, focus: 40)
        let passwordGuard = makeGuard(fake)
        var decisions: [PasswordPause?] = []
        for front in Self.fronts.prefix(3) {
            passwordGuard.update(context(front: front))
            decisions.append(passwordGuard.gate())
        }
        let unnamed = PasswordPause(reason: .secureInput, appName: nil)
        XCTAssertEqual(decisions, [unnamed, unnamed, nil])

        let locked = FakePasswordSystem()
        locked.setIdentity(40, loginwindow)
        locked.setSecureInput(true, focus: 40, locked: true)
        let lockGuard = makeGuard(locked)
        for front in Self.fronts {
            lockGuard.update(context(front: front))
            XCTAssertEqual(lockGuard.gate(), PasswordPause(reason: .secureInput, appName: nil))
        }
        await settle(passwordGuard)
        XCTAssertEqual(stuckReports, [["Safari", "Notes", "Mail"]])
    }

    func testFocusedFieldIsAskedOnlyForTheAppPlamonicReads() async {
        let fake = FakePasswordSystem()
        fake.setField(10, .element(isSecure: true, characterCount: nil))
        let passwordGuard = makeGuard(fake)
        // The front app is not a target: nobody is asked.
        passwordGuard.update(context(field: nil))
        XCTAssertNil(passwordGuard.gate())
        await settle(passwordGuard)
        XCTAssertTrue(fake.fieldCalls.isEmpty)

        passwordGuard.update(context(field: 10))
        await settle(passwordGuard)
        XCTAssertEqual(passwordGuard.gate(), PasswordPause(reason: .secureField, appName: "app10"))
        XCTAssertEqual(Set(fake.fieldCalls), [10])
    }

    /// While nothing is read without a key press (an idle manual app), the poll and focus events do not ask rule b:
    /// only the gate right before a scan does, and the poll while that keeps reading stopped (to see the end).
    func testIdleAppsFieldIsAskedOnlyByTheGate() async {
        let fake = FakePasswordSystem()
        fake.setField(10, .element(isSecure: true))
        let passwordGuard = makeGuard(fake)
        let idle = context(field: 10, pollsField: false)
        passwordGuard.update(idle)
        passwordGuard.checkSoon()
        await settle(passwordGuard)
        XCTAssertTrue(fake.fieldCalls.isEmpty)
        XCTAssertTrue(pauses.isEmpty)

        XCTAssertEqual(passwordGuard.gate(), PasswordPause(reason: .secureField, appName: "app10"))
        XCTAssertEqual(fake.fieldCalls, [10])
        // Paused: the checks ask until the field loses the focus.
        fake.advance(1)
        passwordGuard.checkSoon()
        await settle(passwordGuard)
        XCTAssertEqual(fake.fieldCalls, [10, 10])
        XCTAssertEqual(pauses, [PasswordPause(reason: .secureField, appName: "app10")])
        fake.advance(1)
        fake.setField(10, .element(isSecure: false))
        passwordGuard.checkSoon()
        await settle(passwordGuard)
        XCTAssertEqual(pauses, [PasswordPause(reason: .secureField, appName: "app10"), nil])
        fake.advance(1)
        passwordGuard.checkSoon()
        await settle(passwordGuard)
        XCTAssertEqual(fake.fieldCalls.count, 3, "not asked once reading resumed")
    }

    func testPollAsksTheFieldWhileSomethingIsRead() async throws {
        let fake = FakePasswordSystem()
        let passwordGuard = makeGuard(fake, poll: 0.02)
        passwordGuard.update(context(field: 10, pollsField: false))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(fake.fieldCalls.isEmpty)
        passwordGuard.update(context(field: 10, pollsField: true))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertGreaterThan(fake.fieldCalls.count, 0)
        passwordGuard.update(context(field: nil, polls: false))
        await settle(passwordGuard)
    }

    /// A terminal read in terminal mode with Secure Keyboard Entry on: no pause while its screen has the focus; a
    /// password field shown as text (or any other element) does pause.
    func testTerminalExemptionAsksTheFocusedElement() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(50, terminal)
        fake.setSecureInput(true, focus: 50)
        fake.setField(50, .element(isSecure: false, isTextArea: true))
        let passwordGuard = makeGuard(fake)
        let front = PasswordFrontApp(pid: 50, name: "ターミナル", isTerminalTarget: true)
        passwordGuard.update(context(front: front, field: 50))
        XCTAssertNil(passwordGuard.gate())
        fake.advance(1)
        fake.setField(50, .element(isSecure: false, isTextArea: false))
        XCTAssertEqual(passwordGuard.gate(), PasswordPause(reason: .secureInput, appName: "ターミナル"))
        // No answer: the terminal screen seen last is kept.
        fake.advance(1)
        fake.setField(50, .element(isSecure: false, isTextArea: true))
        XCTAssertNil(passwordGuard.gate())
        fake.advance(1)
        fake.setField(50, .timedOut)
        XCTAssertNil(passwordGuard.gate())
    }

    func testIdleTerminalWithSecureKeyboardEntryIsNotPausedByThePoll() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(50, terminal)
        fake.setSecureInput(true, focus: 50)
        fake.setField(50, .element(isSecure: false, isTextArea: false))
        let passwordGuard = makeGuard(fake)
        let front = PasswordFrontApp(pid: 50, name: "ターミナル", isTerminalTarget: true)
        passwordGuard.update(context(front: front, field: 50, pollsField: false))
        passwordGuard.checkSoon()
        await settle(passwordGuard)
        XCTAssertTrue(fake.fieldCalls.isEmpty)
        XCTAssertTrue(pauses.isEmpty)
        // Translate-now's scan: the gate asks, and a focused element other than the screen pauses.
        XCTAssertEqual(passwordGuard.gate()?.reason, .secureInput)
        XCTAssertEqual(fake.fieldCalls, [50])
    }

    func testFocusedFieldIsNotAskedWhileSecureInputPauses() async {
        let fake = FakePasswordSystem()
        fake.setSecureInput(true, focus: 10)
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context(field: 10))
        XCTAssertEqual(passwordGuard.gate()?.reason, .secureInput)
        XCTAssertTrue(fake.fieldCalls.isEmpty)
    }

    func testFieldAnswerIsReusedBrieflyAndKeptWhenTheAppDoesNotAnswer() async {
        let fake = FakePasswordSystem()
        fake.setField(10, .element(isSecure: true, characterCount: nil))
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context(field: 10))
        await settle(passwordGuard)
        let asked = fake.fieldCalls.count
        // Several gate checks of one scan batch: one AX call.
        XCTAssertNotNil(passwordGuard.gate())
        XCTAssertNotNil(passwordGuard.gate())
        XCTAssertEqual(fake.fieldCalls.count, asked)

        // The app stops answering: the last answer stands, and it is left alone for a while.
        fake.advance(0.1)
        fake.setField(10, .timedOut)
        XCTAssertEqual(passwordGuard.gate()?.reason, .secureField)
        let afterTimeout = fake.fieldCalls.count
        fake.advance(PasswordEntryGuard.fieldRetryAfterTimeout / 2)
        XCTAssertEqual(passwordGuard.gate()?.reason, .secureField)
        XCTAssertEqual(fake.fieldCalls.count, afterTimeout)
        // Asked again later; a field that is no longer secure ends the pause.
        fake.advance(PasswordEntryGuard.fieldRetryAfterTimeout)
        fake.setField(10, .element(isSecure: false, characterCount: nil))
        XCTAssertNil(passwordGuard.gate())
        XCTAssertEqual(fake.fieldCalls.count, afterTimeout + 1)
    }

    func testTimeoutWithoutAnEarlierAnswerDoesNotPause() async {
        let fake = FakePasswordSystem()
        fake.setField(10, .timedOut)
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context(field: 10))
        XCTAssertNil(passwordGuard.gate())
    }

    func testProbeReportsTheCharacterCountOnlyWhenAsked() async {
        let fake = FakePasswordSystem()
        let caret = InsertionPoint(location: 119, characterFrame: CGRect(x: 100, y: 200, width: 7, height: 14))
        fake.setField(10, .element(isSecure: false, isTextArea: true, characterCount: 120, insertionPoint: caret))
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context(field: 10))
        await settle(passwordGuard)
        XCTAssertTrue(probes.isEmpty)
        XCTAssertEqual(fake.countRequests, [false])

        fake.advance(1)
        passwordGuard.update(context(field: 10, probes: true))
        await settle(passwordGuard)
        fake.advance(1)
        fake.setField(10, .element(isSecure: false, characterCount: 180))
        _ = passwordGuard.gate()
        await settle(passwordGuard)
        XCTAssertEqual(probes, [120, 180])
        XCTAssertEqual(probeAnswers.first?.insertionPoint, caret)
        XCTAssertEqual(fake.countRequests.last, true)
        // An app that does not tell: nil.
        fake.advance(1)
        fake.setField(10, .none)
        _ = passwordGuard.gate()
        await settle(passwordGuard)
        XCTAssertEqual(probeAnswers.last, PromptProbe())
        // A password field: nothing about it is passed on.
        fake.advance(1)
        fake.setField(10, .element(isSecure: true, characterCount: 9, insertionPoint: caret))
        _ = passwordGuard.gate()
        await settle(passwordGuard)
        XCTAssertEqual(probeAnswers.last, PromptProbe())
    }

    func testPollRunsOnlyWhileThereAreAppsToRead() async throws {
        let fake = FakePasswordSystem()
        let passwordGuard = makeGuard(fake, poll: 0.02)
        passwordGuard.update(context())
        try await Task.sleep(nanoseconds: 200_000_000)
        let polled = fake.flagReads
        XCTAssertGreaterThan(polled, 2)
        var idle = context()
        idle.polls = false
        passwordGuard.update(idle)
        await settle(passwordGuard)
        let stopped = fake.flagReads
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fake.flagReads, stopped)
    }

    func testReportsNameReasonsAndAppsOnly() async {
        let fake = FakePasswordSystem()
        fake.setIdentity(10, safari)
        fake.setSecureInput(true, focus: 10)
        let passwordGuard = makeGuard(fake)
        passwordGuard.update(context(field: 10))
        await settle(passwordGuard)
        let reports = events.compactMap { event -> PasswordGuardReport? in
            if case .report(let report) = event { return report }
            return nil
        }
        XCTAssertEqual(
            reports.last?.line,
            "secure-input=on focus=Safari front=Safari field=not-asked -> paused(secureInput, Safari)")
    }
}

/// Rule c: per-window pause of a terminal at a password prompt (pure).
final class PasswordTerminalPromptTests: XCTestCase {
    private func count(_ count: Int?) -> PromptProbe { PromptProbe(characterCount: count) }

    /// The insertion point at `location`, after the character at `column` of `row` (cells 7 × 14 pt).
    private func caret(_ count: Int, location: Int, row: Int, column: Int, cell: CGFloat = 7) -> PromptProbe {
        let frame = CGRect(x: 100 + CGFloat(column) * 7, y: 300 + CGFloat(row) * 14, width: cell, height: 14)
        return PromptProbe(
            characterCount: count, insertionPoint: InsertionPoint(location: location, characterFrame: frame))
    }

    func testProbeTakesABaselineThenNoticesChanges() {
        var pause = TerminalPromptPause(since: 0)
        XCTAssertNil(pause.probeWorks)
        XCTAssertFalse(pause.probe(count(500)))
        XCTAssertEqual(pause.baseline?.characterCount, 500)
        XCTAssertEqual(pause.probeWorks, true)
        XCTAssertFalse(pause.seesInsertionPoint)
        // Typing a password that is not echoed changes nothing.
        XCTAssertFalse(pause.probe(count(500)))
        // Output after Return.
        XCTAssertTrue(pause.probe(count(560)))
    }

    /// sudo's pwfeedback echoes a mark per key: the insertion point moves along the prompt's row by the marks
    /// typed or erased. Output after Return moves it to another row, or, when the screen scrolls and the new line
    /// is on the same row, to a column that does not match.
    func testMarksTypedAtThePromptAreNotOutput() {
        var pause = TerminalPromptPause(since: 0)
        // "[sudo] password for user: " ends at column 25 of the bottom row (row 23).
        XCTAssertFalse(pause.probe(caret(1000, location: 999, row: 23, column: 25)))
        XCTAssertTrue(pause.seesInsertionPoint)
        XCTAssertFalse(pause.probe(caret(1001, location: 1000, row: 23, column: 26)))
        XCTAssertFalse(pause.probe(caret(1004, location: 1003, row: 23, column: 29)))
        // Erased: blanks may stay behind the insertion point.
        XCTAssertFalse(pause.probe(caret(1004, location: 1002, row: 23, column: 28)))
        XCTAssertFalse(pause.probe(caret(1002, location: 1001, row: 23, column: 27)))
        // Return: "\n$ " on the next row.
        var next = pause
        XCTAssertTrue(next.probe(caret(1007, location: 1006, row: 24, column: 1)))
        // Return at the bottom: the screen scrolls, "\n$ " is on the same row at column 1.
        var scrolled = pause
        XCTAssertTrue(scrolled.probe(caret(1007, location: 1006, row: 23, column: 1)))
        // More output than the characters typed, on the same row.
        var more = pause
        XCTAssertTrue(more.probe(caret(1010, location: 1005, row: 23, column: 31)))
    }

    /// Numbers measured on Terminal (a fixture printing marks the way pwfeedback echoes them; cells 9 × 17 pt): a
    /// line break before the insertion point is as wide as the rest of its row.
    func testMeasuredTerminalMarksAndReturn() {
        func probe(_ count: Int, _ location: Int, x: CGFloat, y: CGFloat, width: CGFloat = 9) -> PromptProbe {
            PromptProbe(
                characterCount: count,
                insertionPoint: InsertionPoint(
                    location: location, characterFrame: CGRect(x: x, y: y, width: width, height: 17)))
        }
        // Mid-screen: six marks, one erased (the count stays), one more, then Return.
        var pause = TerminalPromptPause(since: 0)
        XCTAssertFalse(pause.probe(probe(87, 64, x: 2702, y: 245)))
        for typed in 1...6 {
            XCTAssertFalse(pause.probe(probe(87 + typed, 64 + typed, x: 2702 + CGFloat(typed) * 9, y: 245)), "\(typed)")
        }
        XCTAssertFalse(pause.probe(probe(93, 69, x: 2747, y: 245)))
        XCTAssertFalse(pause.probe(probe(93, 70, x: 2756, y: 245)))
        XCTAssertTrue(pause.probe(probe(93, 71, x: 2765, y: 245, width: 405)))
        // Bottom row: Return before the screen scrolls (same row), then after it.
        var bottom = TerminalPromptPause(since: 0)
        XCTAssertFalse(bottom.probe(probe(2107, 2106, x: 2702, y: 619)))
        XCTAssertFalse(bottom.probe(probe(2113, 2112, x: 2756, y: 619)))
        XCTAssertFalse(bottom.probe(probe(2113, 2111, x: 2747, y: 619)))
        var beforeScroll = bottom
        XCTAssertTrue(beforeScroll.probe(probe(2114, 2113, x: 2765, y: 619, width: 405)))
        XCTAssertTrue(bottom.probe(probe(2149, 2148, x: 2594, y: 619)))
        // Return right after the prompt (no marks): the line break alone is not taken for a mark.
        var plain = TerminalPromptPause(since: 0)
        XCTAssertFalse(plain.probe(probe(87, 64, x: 2702, y: 245)))
        XCTAssertTrue(plain.probe(probe(88, 65, x: 2711, y: 245, width: 459)))
    }

    func testMarksAfterAWideCharacterUseTheMarksCell() {
        var pause = TerminalPromptPause(since: 0)
        // "パスワード：" ends with a full-width colon (two cells).
        XCTAssertFalse(pause.probe(caret(300, location: 299, row: 5, column: 11, cell: 14)))
        XCTAssertFalse(pause.probe(caret(302, location: 301, row: 5, column: 14)))
    }

    func testWithoutTheInsertionPointAnyChangeOfLengthCounts() {
        var pause = TerminalPromptPause(since: 0)
        XCTAssertFalse(pause.probe(caret(1000, location: 999, row: 23, column: 25)))
        XCTAssertTrue(pause.probe(count(1001)))
        XCTAssertFalse(pause.seesInsertionPoint)
        var unchanged = TerminalPromptPause(since: 0)
        XCTAssertFalse(unchanged.probe(count(1000)))
        XCTAssertFalse(unchanged.probe(caret(1000, location: 999, row: 23, column: 25)))
    }

    func testAppThatDoesNotTellItsLengthFallsBackToTimedScans() {
        var pause = TerminalPromptPause(since: 0)
        XCTAssertFalse(pause.probe(count(nil)))
        XCTAssertEqual(pause.probeWorks, false)
        XCTAssertEqual(
            TerminalPromptPause.nextTimedScan(pause: pause, lastScan: 10, regular: 0.5, background: 2, watched: true),
            12)
    }

    func testTimedScans() {
        // Not paused: the usual interval.
        XCTAssertEqual(
            TerminalPromptPause.nextTimedScan(pause: nil, lastScan: 10, regular: 0.5, background: 2, watched: true),
            10.5)
        var watched = TerminalPromptPause(since: 0)
        // No probe answer yet: the fallback, never the usual 0.5 s.
        XCTAssertEqual(
            TerminalPromptPause.nextTimedScan(pause: watched, lastScan: 10, regular: 0.5, background: 2, watched: true),
            12)
        _ = watched.probe(PromptProbe(characterCount: 10))
        // The probe watches the window: no timed scans at all.
        XCTAssertNil(
            TerminalPromptPause.nextTimedScan(pause: watched, lastScan: 10, regular: 0.5, background: 2, watched: true))
        // A background window: the background interval, at least the minimum.
        XCTAssertEqual(
            TerminalPromptPause.nextTimedScan(pause: watched, lastScan: 10, regular: 1, background: 1, watched: false),
            10 + TerminalPromptPause.minimumFallbackInterval)
        XCTAssertEqual(
            TerminalPromptPause.nextTimedScan(pause: watched, lastScan: 10, regular: 5, background: 5, watched: false),
            15)
        // A rescan asked for but not done (the app did not answer) is not left to the probe.
        XCTAssertTrue(watched.requestRescan(.other))
        XCTAssertEqual(
            TerminalPromptPause.nextTimedScan(pause: watched, lastScan: 10, regular: 0.5, background: 2, watched: true),
            12)
    }

    func testRescanForATextChangeWithTheSameTextsMeansEchoedMarks() {
        var pause = TerminalPromptPause(since: 3, texts: 42)
        XCTAssertNil(pause.textRescanTime(lastScan: 10, background: 0.5, now: 10.1))
        XCTAssertTrue(pause.requestRescan(.textChanged))
        XCTAssertFalse(pause.requestRescan(.other), "one rescan at a time")
        XCTAssertTrue(pause.rescanPending)

        // Same texts after a text change: the prompt echoes marks (blanked by the extraction).
        var echoing = pause.rescanned(texts: 42)
        XCTAssertTrue(echoing.echoesInput)
        XCTAssertFalse(echoing.rescanPending)
        XCTAssertEqual(echoing.since, 3)
        // Text changes are read at most every fallback interval after the last scan.
        XCTAssertEqual(echoing.textRescanTime(lastScan: 10, background: 0.5, now: 10.1), 12)
        XCTAssertEqual(echoing.textRescanTime(lastScan: 10, background: 5, now: 10.1), 15)
        XCTAssertNil(echoing.textRescanTime(lastScan: 10, background: 0.5, now: 12))
        // A window change with the same texts keeps it echoing; new texts (output) end it.
        XCTAssertTrue(echoing.requestRescan(.other))
        echoing = echoing.rescanned(texts: 42)
        XCTAssertTrue(echoing.echoesInput)
        XCTAssertTrue(echoing.requestRescan(.textChanged))
        XCTAssertFalse(echoing.rescanned(texts: 7).echoesInput)

        // Same texts after a window change only: nothing was typed.
        var focus = TerminalPromptPause(since: 0, texts: 42)
        XCTAssertTrue(focus.requestRescan(.other))
        XCTAssertFalse(focus.rescanned(texts: 42).echoesInput)
        // Where the probe sees the insertion point a text change is output (Return before its output), not marks.
        var caretSeen = TerminalPromptPause(since: 0, texts: 42)
        XCTAssertFalse(caretSeen.probe(caret(1000, location: 999, row: 23, column: 25)))
        XCTAssertTrue(caretSeen.seesInsertionPoint)
        XCTAssertTrue(caretSeen.requestRescan(.textChanged))
        var afterRescan = caretSeen.rescanned(texts: 42)
        XCTAssertFalse(afterRescan.echoesInput)
        // Right after a rescan the probe has no baseline yet: a text event then is not taken for echoed marks either.
        XCTAssertFalse(afterRescan.seesInsertionPoint)
        XCTAssertTrue(afterRescan.insertionPointKnown)
        XCTAssertTrue(afterRescan.requestRescan(.textChanged))
        XCTAssertFalse(afterRescan.rescanned(texts: 42).echoesInput)
        // The rescan starts the probe over.
        var probed = TerminalPromptPause(since: 0, texts: 1)
        _ = probed.probe(PromptProbe(characterCount: 10))
        XCTAssertTrue(probed.requestRescan(.textChanged))
        let fresh = probed.rescanned(texts: 1)
        XCTAssertNil(fresh.baseline)
        XCTAssertNil(fresh.probeWorks)
    }

    func testMenuLines() {
        XCTAssertEqual(
            PasswordPause(reason: .secureInput, appName: "Safari").menuLine,
            "パスワード入力中のため、読み取りを止めています（Safari）")
        XCTAssertEqual(
            PasswordPause(reason: .secureField, appName: nil).menuLine, "パスワード入力中のため、読み取りを止めています")
        XCTAssertEqual(
            PasswordPause(reason: .terminalPrompt, appName: "ターミナル").menuLine,
            "ターミナル がパスワードを待っているため、このウインドウの読み取りを止めています")
        XCTAssertEqual(
            PasswordPause(reason: .terminalPrompt, appName: nil).menuLine,
            "パスワードを待っているため、このウインドウの読み取りを止めています")
    }
}

/// The scanner asks the gate right before each window's reads; a pause skips the window without any AX call.
final class PasswordScannerGateTests: XCTestCase {
    func testPausedRequestsAreNotRead() {
        let asked = NSLock()
        nonisolated(unsafe) var calls = 0
        let pause = PasswordPause(reason: .secureField, appName: "app")
        let scanner = SessionScanner(gate: {
            asked.withLock { calls += 1 }
            return pause
        })
        let settings = EffectiveSettings(profile: AppProfile(bundleID: "x", displayName: "x"), global: GlobalSettings())
        // No such process: had the gate let it through, the scan would end as gone / unavailable.
        let request = ScanRequest(
            pid: 999_999, bundleID: "x", target: .focusedWindow, settings: settings,
            limits: ExtractionLimits(global: settings.global))
        let done = expectation(description: "scanned")
        nonisolated(unsafe) var outcomes: [ScanResult.Outcome] = []
        scanner.scan([request, request, request]) { results in
            outcomes = results.map(\.outcome)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(asked.withLock { calls }, 3)
        XCTAssertEqual(outcomes.count, 3)
        for outcome in outcomes {
            guard case .paused(let got) = outcome else {
                XCTFail("not paused: \(outcome)")
                continue
            }
            XCTAssertEqual(got, pause)
        }
    }
}

/// No screen captures for background colors while a password is typed.
@MainActor
final class PasswordCapturePauseTests: XCTestCase {
    private final class CountingSampler: ScreenColorSampling, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        var isAuthorized: Bool { true }
        func sampleColors(windowID: UInt32, rects: [String: CGRect]) async -> [String: SampledColors] {
            lock.withLock { _calls += 1 }
            let colors = SampledColors(background: RGBAColor(red: 0.1, green: 0.1, blue: 0.1), text: nil)
            return rects.mapValues { _ in colors }
        }
    }

    override func tearDown() async throws {
        OverlayColorSampleScheduler.setCapturesPaused(false)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testSchedulerRequestsNothingWhilePausedAndResumesAfter() async {
        let sampler = CountingSampler()
        let scheduler = OverlayColorSampleScheduler(debounce: 0.01, maximumWait: 0.05, retryDelay: 5)
        OverlayColorSampleScheduler.setCapturesPaused(true)
        XCTAssertTrue(ScreenCaptureGate.shared.isPaused)
        let target = OverlayColorSampleScheduler.Target(
            axRect: CGRect(x: 0, y: 0, width: 100, height: 20), original: "a")
        scheduler.update(targets: ["a": target], windowID: 7, sampler: sampler)
        await sleep(0.15)
        XCTAssertEqual(sampler.calls, 0)
        XCTAssertEqual(scheduler.requestCount, 0)

        OverlayColorSampleScheduler.setCapturesPaused(false)
        XCTAssertFalse(ScreenCaptureGate.shared.isPaused)
        await sleep(0.15)
        XCTAssertEqual(sampler.calls, 1)
        XCTAssertNotNil(scheduler.colors(for: "a"))
    }

    func testSamplerCapturesNothingWhileItsGateIsPaused() async {
        let gate = ScreenCaptureGate()
        let measured = NSLock()
        nonisolated(unsafe) var measures = 0
        let sampler = ScreenColorSampler(captureInterval: 0, gate: gate, authorized: { true }) { _, rects in
            measured.withLock { measures += 1 }
            let colors = SampledColors(background: RGBAColor(red: 0.1, green: 0.1, blue: 0.1), text: nil)
            return rects.mapValues { _ in colors }
        }
        let rects = ["a": CGRect(x: 0, y: 0, width: 10, height: 10)]
        gate.isPaused = true
        let paused = await sampler.sampleColors(windowID: 3, rects: rects)
        XCTAssertTrue(paused.isEmpty)
        XCTAssertEqual(measured.withLock { measures }, 0)
        gate.isPaused = false
        let resumed = await sampler.sampleColors(windowID: 3, rects: rects)
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(measured.withLock { measures }, 1)
    }
}
