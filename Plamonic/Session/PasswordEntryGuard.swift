import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import os

// MARK: - What the guard reads

/// What the window server says about secure keyboard input. No app's text is read.
struct SecureInputState: Equatable, Sendable {
    var enabled = false
    /// `kCGSSessionSecureInputPID`: the app that was frontmost when secure input was turned on, not the process
    /// that turned it on (measured: a background helper's secure input named the front app). It stays the same
    /// while the user switches apps (OpenRadar 48953777), and after unlock or wake it is often loginwindow.
    var focusPID: pid_t?
    var screenLocked = false
}

/// Who a process is: for the list of system password dialogs, the menu and logs (names only).
struct ProcessIdentity: Equatable, Sendable {
    var bundleID: String?
    var processName: String?
    var displayName: String?

    var name: String? { displayName ?? processName ?? bundleID }
}

/// The insertion point of a text element: where it is and the frame of the character before it (AX
/// coordinates). Numbers and geometry only, never the text.
struct InsertionPoint: Equatable, Sendable {
    var location: Int
    var characterFrame: CGRect
}

/// Rule c's probe of the focused element (nil = the app does not tell).
struct PromptProbe: Equatable, Sendable {
    var characterCount: Int?
    var insertionPoint: InsertionPoint?
}

/// The focused element of an app, as rule b sees it.
enum FocusedElementAnswer: Equatable, Sendable {
    /// `isTextArea`: role AXTextArea (a terminal's screen). `characterCount` and `insertionPoint` are read only
    /// when asked for, and never for a secure element.
    case element(
        isSecure: Bool, isTextArea: Bool = false, characterCount: Int? = nil, insertionPoint: InsertionPoint? = nil)
    /// No focused element, or the app does not tell (background Chrome and WebKit answer noValue).
    case none
    /// The app did not answer within the timeout.
    case timedOut
}

/// The system calls behind the guard. Unit tests replace every one; `.live` is the real system.
struct PasswordEntrySystem: Sendable {
    /// `IsSecureEventInputEnabled()`: one shared-memory read.
    var secureInputEnabled: @Sendable () -> Bool
    /// The secure-input pid and the screen-lock flag of the session dictionary (a window-server call of about
    /// 0.5 ms; only read while secure input is on).
    var secureInputSession: @Sendable () -> (focusPID: pid_t?, screenLocked: Bool)
    var identify: @Sendable (pid_t) -> ProcessIdentity
    /// Rule b: the app's focused element (role and subrole only, plus rule c's probe when asked: character count
    /// and insertion point). AX with a short timeout; called on the guard's queue only.
    var focusedElement: @Sendable (_ pid: pid_t, _ probe: Bool) -> FocusedElementAnswer
    /// Seconds since boot.
    var now: @Sendable () -> TimeInterval

    /// The dictionary is read only while the flag is on.
    func readSecureInput() -> SecureInputState {
        guard secureInputEnabled() else { return SecureInputState() }
        let session = secureInputSession()
        return SecureInputState(enabled: true, focusPID: session.focusPID, screenLocked: session.screenLocked)
    }

    /// AX messaging timeout of the focused-element check.
    static let focusTimeout: Float = 0.1

    static let live = PasswordEntrySystem(
        secureInputEnabled: { IsSecureEventInputEnabled() },
        secureInputSession: {
            guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return (nil, false) }
            // Not in any header; present only while secure input is on / the screen is locked.
            let pid = (dict["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
            let locked = (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
            return (pid.flatMap { $0 > 0 ? $0 : nil }, locked)
        },
        identify: { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            var buffer = [CChar](repeating: 0, count: 256)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            return ProcessIdentity(
                bundleID: app?.bundleIdentifier, processName: length > 0 ? String(cString: buffer) : nil,
                displayName: app?.localizedName)
        },
        focusedElement: { pid, probe in FocusQueryElements.shared.focusedElement(pid: pid, probe: probe) },
        now: { ProcessInfo.processInfo.systemUptime })
}

/// Application elements with the short timeout, one per pid (each new element pays a first-call setup).
private final class FocusQueryElements: @unchecked Sendable {
    static let shared = FocusQueryElements()
    private let lock = NSLock()
    private var apps: [pid_t: AXUIElement] = [:]
    private let names = [AXAttr.role, AXAttr.subrole] as CFArray
    private let namesWithProbe =
        [AXAttr.role, AXAttr.subrole, AXAttr.numberOfCharacters, AXAttr.selectedTextRange] as CFArray

    private func app(_ pid: pid_t) -> AXUIElement {
        lock.withLock {
            if let app = apps[pid] { return app }
            if apps.count >= 32 { apps.removeAll() }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, PasswordEntrySystem.focusTimeout)
            apps[pid] = app
            return app
        }
    }

    /// One AXFocusedUIElement read and one multi-attribute read (role, subrole[, number of characters, selected
    /// range]); with the probe, also AXBoundsForRange of the character before the insertion point. Never reads the
    /// value or any text: a password field's masked value still tells the password's length. A secure element's
    /// numbers are dropped unused.
    func focusedElement(pid: pid_t, probe: Bool) -> FocusedElementAnswer {
        var focused: AnyObject?
        switch AXUIElementCopyAttributeValue(app(pid), AXAttr.focusedUIElement as CFString, &focused) {
        case .success: break
        case .cannotComplete: return .timedOut
        default: return .none
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .none }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        // The timeout belongs to each element ref; the returned one has the process-wide default.
        AXUIElementSetMessagingTimeout(element, PasswordEntrySystem.focusTimeout)
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element, probe ? namesWithProbe : names, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if err == .cannotComplete { return .timedOut }
        guard err == .success, let array = values as? [AnyObject] else { return .none }
        func value(_ index: Int) -> AnyObject? {
            guard index < array.count, !AXDecode.isErrorOrNull(array[index]) else { return nil }
            return array[index]
        }
        let role = AXDecode.string(value(0)) ?? ""
        let subrole = AXDecode.string(value(1))
        let isSecure = ExtractionRoles.isSecure(role: role, subrole: subrole)
        let isTextArea = role == "AXTextArea"
        guard probe, !isSecure else { return .element(isSecure: isSecure, isTextArea: isTextArea) }
        let count = (value(2) as? NSNumber)?.intValue
        var insertionPoint: InsertionPoint?
        if let range = AXDecode.range(value(3)), range.length == 0, range.location > 0,
            let parameter = AXDecode.makeValue(CFRange(location: range.location - 1, length: 1))
        {
            var bounds: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element, AXParamAttr.boundsForRange as CFString, parameter, &bounds) == .success,
                let frame = AXDecode.rect(bounds), frame.width > 0, frame.height > 0
            {
                insertionPoint = InsertionPoint(location: range.location, characterFrame: frame)
            }
        }
        return .element(isSecure: false, isTextArea: isTextArea, characterCount: count, insertionPoint: insertionPoint)
    }
}

// MARK: - Rules

/// The front app as the session knows it (from NSWorkspace, on the main thread).
struct PasswordFrontApp: Equatable, Sendable {
    var pid: pid_t
    var name: String?
    /// Plamonic reads it in terminal mode. Terminals keep Secure Keyboard Entry on for good and never echo
    /// passwords, so secure input reported for them does not pause while their screen has the focus (rule c
    /// covers their prompts).
    var isTerminalTarget = false
}

/// What rule b found about the focused element of the app Plamonic reads.
enum PasswordFieldState: String, Equatable, Sendable {
    case notAsked = "not-asked"
    /// Neither a password field nor a text area.
    case notSecure = "not-secure"
    /// Not a password field: role AXTextArea (a terminal's screen).
    case textArea = "text-area"
    case secure
    /// No answer in time (and no earlier answer that is kept).
    case timedOut = "timed-out"
}

/// When reading stops because a password is typed (DESIGN §4.1). Pure; the guard feeds it.
enum PasswordEntryRules {
    /// System password dialogs and the lock screen. Matched by bundle ID, then by process name.
    static let systemAuthBundleIDs: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.authorizationhost",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.ScreenSaver.Engine",
        "com.apple.ScreenSaver.Engine.legacyScreenSaver", "com.apple.NetAuthAgent", "com.apple.wifi.WiFiAgent",
        "com.apple.UserNotificationCenter", "com.apple.authkit.AuthKitHeadlessUIHelper",
        "com.apple.security.Keychain-Circle-Notification", "com.apple.BluetoothUIServer",
        "com.apple.EscrowSecurityAlert",
    ]
    static let systemAuthProcessNames: Set<String> = [
        "loginwindow", "SecurityAgent", "authorizationhost", "coreautha", "ScreenSaverEngine", "legacyScreenSaver",
        "NetAuthAgent", "WiFiAgent", "UserNotificationCenter", "AuthKitUIMacService", "Keychain Circle Notification",
        "BluetoothUIServer", "EscrowSecurityAlert",
    ]

    static func isLoginWindow(_ identity: ProcessIdentity?) -> Bool {
        identity?.bundleID == "com.apple.loginwindow" || identity?.processName == "loginwindow"
    }

    /// loginwindow counts only while the screen is locked: after unlock or wake it is often named for secure
    /// input that some app left on.
    static func isSystemAuth(_ identity: ProcessIdentity?, screenLocked: Bool) -> Bool {
        guard let identity else { return false }
        if isLoginWindow(identity) { return screenLocked }
        if let bundleID = identity.bundleID, systemAuthBundleIDs.contains(bundleID) { return true }
        if let name = identity.processName, systemAuthProcessNames.contains(name) { return true }
        return false
    }

    struct Input: Equatable, Sendable {
        var settingOn = true
        var secureInput = SecureInputState()
        /// Identity of `secureInput.focusPID`.
        var focus: ProcessIdentity?
        var front: PasswordFrontApp?
        /// Secure input stayed on across app switches (held by a background app): rule a does not pause.
        var stuck = false
        /// Rule b's answer about the focused element of the app Plamonic reads (the front app).
        var field: PasswordFieldState = .notAsked
        var fieldAppName: String?
    }

    /// Rule a. Secure input is on and the window server names a process for it:
    /// - the screen is locked, or a system password dialog is named: pause;
    /// - a terminal Plamonic reads in terminal mode is at the front, the terminal (or nobody) is named, and its
    ///   screen (AXTextArea) has the focus, or rule b was not asked: no pause. Another focused element (a password
    ///   field shown as text, a find bar) pauses;
    /// - secure input stuck on across app switches: no pause;
    /// - anything else (the front app, a menu-bar password manager, an agent's password panel, loginwindow after
    ///   unlock): pause.
    static func secureInputPause(_ input: Input) -> PasswordPause? {
        guard input.settingOn, input.secureInput.enabled else { return nil }
        if input.secureInput.screenLocked { return PasswordPause(reason: .secureInput, appName: nil) }
        // loginwindow is not an app the user knows by name.
        let name = isLoginWindow(input.focus) ? nil : input.focus?.name ?? input.front?.name
        if isSystemAuth(input.focus, screenLocked: false) { return PasswordPause(reason: .secureInput, appName: name) }
        if let front = input.front, front.isTerminalTarget,
            input.secureInput.focusPID == nil || input.secureInput.focusPID == front.pid,
            input.field == .textArea || input.field == .notAsked
        {
            return nil
        }
        if input.stuck { return nil }
        return PasswordPause(reason: .secureInput, appName: name)
    }

    /// Rules a and b.
    static func decide(_ input: Input) -> PasswordPause? {
        guard input.settingOn else { return nil }
        if let pause = secureInputPause(input) { return pause }
        if input.field == .secure { return PasswordPause(reason: .secureField, appName: input.fieldAppName) }
        return nil
    }
}

/// Secure input that stays on while the user switches between apps is held by some background app (older
/// Chrome / Electron, password managers): apps that hold it for a password field drop it when they deactivate.
/// The window server keeps naming the app that was in front when it was turned on (or loginwindow), so the
/// front apps are counted: without this a stuck holder would stop reading for good.
struct StuckSecureInputTracker: Equatable, Sendable {
    /// Different front apps seen during one stretch of secure input that make it "stuck" (A → B → C; going back
    /// and forth between two apps does not count: a password manager's autofill is A → manager → A).
    static let appsToCallStuck = 3

    private(set) var holders: [pid_t] = []
    private(set) var isStuck = false

    /// `holder` is the front app. Not counted while a system password dialog is named (or the screen is
    /// locked). Returns true when it just became stuck (log it once).
    mutating func observe(enabled: Bool, holder: pid_t?, holderIsSystemAuth: Bool) -> Bool {
        guard enabled else {
            holders.removeAll()
            isStuck = false
            return false
        }
        guard let holder, !holderIsSystemAuth else { return false }
        if !holders.contains(holder) { holders.append(holder) }
        guard !isStuck, holders.count >= Self.appsToCallStuck else { return false }
        isStuck = true
        return true
    }
}

/// Rule c: a terminal window whose prompt line waits for a password (`WindowSnapshot.passwordPrompt`) gets no
/// timed scans. The password is not echoed, so typing it changes nothing and causes no reads. The window is
/// scanned again on the app's next AX event, on activation, focus and window changes, on 今すぐ翻訳, and when the
/// probe of the focused element sees new output. A window the probe cannot watch (a background window, an app
/// that does not tell its length) is scanned at most every `fallbackInterval`.
///
/// Prompts that echo a mark per key (sudo's pwfeedback): while the probe sees the insertion point, a mark typed or
/// erased on the prompt line is told apart from output by geometry (same row, moved by exactly the characters
/// added), and the app's text events do not resume the window (the session asks the probe instead). Otherwise a
/// rescan for a text change that finds the same texts at the prompt (the extraction blanks the marks) marks the
/// prompt as echoing, and its text changes are then read at most every `fallbackInterval`.
///
/// A rescan keeps the pause (the menu line, the Esc monitor off) until its scan tells whether the prompt is gone.
struct TerminalPromptPause: Equatable, Sendable {
    static let minimumFallbackInterval: CFAbsoluteTime = 2
    /// More marks than this on one prompt line is not a password being typed.
    static let maximumTypedMarks = 256

    /// Why a rescan was asked for.
    enum Rescan: Equatable, Sendable {
        /// The text changed (text events, or the probe's count): maybe marks typed at the prompt.
        case textChanged
        /// A window or focus change, 今すぐ翻訳.
        case other
    }

    var since: CFAbsoluteTime
    /// Hash of the segment texts of the last scan at the prompt (in memory only).
    private(set) var texts: Int
    /// A scan of the window was asked for and has not come back at the prompt yet.
    private(set) var rescan: Rescan?
    /// A rescan for a text change found the same texts: the prompt echoes a mark per key.
    private(set) var echoesInput = false
    /// The probe has seen the insertion point of this window (kept across rescans).
    private(set) var insertionPointKnown = false
    /// The focused element at the first probe after the pause began.
    private(set) var baseline: PromptProbe?
    /// nil = no probe answer yet; false = the app does not tell its length.
    private(set) var probeWorks: Bool?
    /// The last probe saw the insertion point: marks typed at the prompt can be told from output.
    private(set) var seesInsertionPoint = false
    /// How far right of the baseline the insertion point has been (marks erased may leave blanks behind it).
    private(set) var furthest = 0

    init(since: CFAbsoluteTime, texts: Int = 0) {
        self.since = since
        self.texts = texts
    }

    var rescanPending: Bool { rescan != nil }

    /// Asks for one scan. Returns false when one is already pending.
    mutating func requestRescan(_ why: Rescan) -> Bool {
        guard rescan == nil else { return false }
        // Where the probe sees the insertion point, marks typed are told from output: a change there is output (a
        // Return before its output keeps the texts) or came before the probe's new baseline, not echoed marks.
        rescan = why == .textChanged && insertionPointKnown ? .other : why
        return true
    }

    /// The asked scan found the prompt still there: a new pause with a new probe baseline.
    func rescanned(texts: Int) -> TerminalPromptPause {
        var next = TerminalPromptPause(since: since, texts: texts)
        next.echoesInput = texts == self.texts && (echoesInput || rescan == .textChanged)
        next.insertionPointKnown = insertionPointKnown
        return next
    }

    /// When a text change of an echoing prompt may be read (nil = at once): at most once per fallback interval.
    func textRescanTime(lastScan: CFAbsoluteTime, background: CFAbsoluteTime, now: CFAbsoluteTime) -> CFAbsoluteTime? {
        guard echoesInput else { return nil }
        let time = lastScan + Self.fallbackInterval(background: background)
        return time > now ? time : nil
    }

    /// One probe answer. Returns true when the focused element changed since the first answer other than by
    /// marks typed or erased at the prompt: new output, scan again.
    mutating func probe(_ answer: PromptProbe) -> Bool {
        guard let count = answer.characterCount else {
            probeWorks = false
            seesInsertionPoint = false
            return false
        }
        probeWorks = true
        if answer.insertionPoint != nil { insertionPointKnown = true }
        guard let baseline, let baseCount = baseline.characterCount else {
            self.baseline = answer
            seesInsertionPoint = answer.insertionPoint != nil
            return false
        }
        guard let from = baseline.insertionPoint, let to = answer.insertionPoint else {
            // The insertion point is not known: any change of the length counts.
            seesInsertionPoint = false
            return count != baseCount
        }
        seesInsertionPoint = true
        guard Self.onlyMarksTyped(from: from, to: to, countChange: count - baseCount, furthest: furthest) else {
            return true
        }
        furthest = max(furthest, to.location - from.location)
        return false
    }

    /// The insertion point moved along its row by exactly the characters added or removed before it, and
    /// nothing else changed. Output after Return moves it to another row, or (when the screen scrolls and the
    /// new line is on the same row) to a column that does not match. `furthest`: how far right it has been.
    static func onlyMarksTyped(from: InsertionPoint, to: InsertionPoint, countChange: Int, furthest: Int) -> Bool {
        let moved = to.location - from.location
        guard abs(moved) <= maximumTypedMarks else { return false }
        // Typing adds as many characters as the insertion point moves; erasing may leave blanks behind it.
        guard countChange >= moved, countChange <= max(moved, furthest, 0) else { return false }
        let a = from.characterFrame
        let b = to.characterFrame
        guard abs(a.midY - b.midY) <= min(a.height, b.height) / 2 else { return false }
        // One cell: a mark just typed, or the mark just erased. A line break after the insertion point's row is
        // as wide as the rest of the row (measured, Terminal), so a character wider than the prompt's is not a mark.
        let cell = moved > 0 ? b.width : a.width
        guard cell > 0, moved <= 0 || b.width <= a.width * 1.5 + 0.5 else { return false }
        return abs((b.maxX - a.maxX) - CGFloat(moved) * cell) <= cell / 2
    }

    static func fallbackInterval(background: CFAbsoluteTime) -> CFAbsoluteTime {
        max(minimumFallbackInterval, background)
    }

    /// When a window's next timed scan is due (nil = none). `regular` is its usual interval; `watched` = the
    /// probe watches this window (the focused window of the app Plamonic reads at the front).
    static func nextTimedScan(
        pause: TerminalPromptPause?, lastScan: CFAbsoluteTime, regular: CFAbsoluteTime,
        background: CFAbsoluteTime, watched: Bool
    ) -> CFAbsoluteTime? {
        guard let pause else { return lastScan + regular }
        // A pending rescan that did not happen (the app did not answer) is not left to the probe.
        if watched, pause.probeWorks == true, !pause.rescanPending { return nil }
        return lastScan + fallbackInterval(background: background)
    }
}

// MARK: - Guard

/// One evaluation, for the smoke test log (names only).
struct PasswordGuardReport: Equatable, Sendable {
    var secureInput = false
    var screenLocked = false
    /// The process the window server names for secure input.
    var secureInputApp: String?
    var frontApp: String?
    var stuck = false
    var field: PasswordFieldState = .notAsked
    var fieldApp: String?
    var decision: PasswordPause?

    var line: String {
        var parts = ["secure-input=\(secureInput ? "on" : "off")"]
        if screenLocked { parts.append("screen-locked") }
        if secureInput { parts.append("focus=\(secureInputApp ?? "-")") }
        parts.append("front=\(frontApp ?? "-")")
        if stuck { parts.append("stuck") }
        parts.append("field=\(field.rawValue)" + (fieldApp.map { "(\($0))" } ?? ""))
        parts.append("-> " + (decision.map { "paused(\($0.logDescription))" } ?? "reading"))
        return parts.joined(separator: " ")
    }
}

/// Decides whether a password is being typed (rules a and b of DESIGN §4.1), without reading any app's text.
///
/// Everything runs on one serial utility queue: a light poll (`pollInterval`) while the session has apps to
/// read, immediate checks on focus and activation events, and the scanner's gate, which asks right before each
/// window's AX reads so that correctness never depends on the poll. Changes reach the main actor through
/// `deliver`.
final class PasswordEntryGuard: @unchecked Sendable {
    /// What the session tells the guard (main actor).
    struct Context: Equatable, Sendable {
        /// The setting is on and the session runs: the gate checks.
        var isOn = false
        /// Also poll (the session has apps to read).
        var polls = false
        var front: PasswordFrontApp?
        /// Rule b asks this app (the active one, when Plamonic reads it and it is in front); nil = nobody.
        var fieldCheckPID: pid_t?
        var fieldCheckName: String?
        /// Something is read without a key press (an automatic app, a translation or popup on screen, a retry):
        /// the poll and the checks on events ask rule b too. Otherwise only the gate (right before a scan) asks
        /// it, and the poll only while reading is stopped (to see the end).
        var pollsField = true
        /// Also report the focused element's character count and insertion point of `fieldCheckPID` (rule c's
        /// probe).
        var probesFocusedText = false
    }

    enum Event: Sendable {
        case pauseChanged(PasswordPause?)
        /// Rule c's probe of the focused element.
        case focusedText(pid: pid_t, probe: PromptProbe)
        case report(PasswordGuardReport)
        /// Secure input stayed on across app switches; names of the apps seen.
        case stuckSecureInput([String])
    }

    static let defaultPollInterval: TimeInterval = 0.25
    /// A rule-b answer is reused this long (several gate checks of one scan batch).
    static let fieldFreshness: TimeInterval = 0.05
    /// After an app did not answer rule b, it is asked again only after this long (a hung app costs 100–240 ms
    /// per check); the previous answer is kept meanwhile.
    static let fieldRetryAfterTimeout: TimeInterval = 1.5

    let queue = DispatchQueue(label: "io.smdr.Plamonic.password", qos: .utility)
    private let system: PasswordEntrySystem
    private let pollInterval: TimeInterval
    private let deliver: @MainActor (Event) -> Void
    private let log = Logger(subsystem: "io.smdr.Plamonic", category: "Password")

    private let lock = NSLock()
    // Guarded by `lock`.
    private var context = Context()

    // Touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var decision: PasswordPause?
    private var lastReport: PasswordGuardReport?
    private var stuck = StuckSecureInputTracker()
    /// Names of the front apps the tracker counted (logs).
    private var stuckNames: [pid_t: String] = [:]
    private var identities: [pid_t: ProcessIdentity] = [:]
    /// The last rule-b answer; `probed` = rule c's probe was sent with it.
    private var field:
        (pid: pid_t, state: PasswordFieldState, checkedAt: TimeInterval, retryAfter: TimeInterval, probed: Bool)?

    init(
        system: PasswordEntrySystem = .live, pollInterval: TimeInterval = PasswordEntryGuard.defaultPollInterval,
        deliver: @escaping @MainActor (Event) -> Void
    ) {
        self.system = system
        self.pollInterval = max(0.02, pollInterval)
        self.deliver = deliver
    }

    deinit {
        timer?.cancel()
    }

    /// Main actor, whenever the session's state may have changed. Cheap when nothing changed.
    func update(_ new: Context) {
        let changed: Bool = lock.withLock {
            guard context != new else { return false }
            context = new
            return true
        }
        guard changed else { return }
        queue.async { [self] in
            setPolling(new.isOn && new.polls)
            evaluate()
        }
    }

    /// Checks soon on the guard's queue (the focus changed, an app was activated).
    func checkSoon() {
        guard lock.withLock({ context.isOn }) else { return }
        queue.async { [self] in evaluate() }
    }

    /// The scanner's gate: checks now and returns the decision. Never call it on `queue`.
    func gate() -> PasswordPause? {
        guard lock.withLock({ context.isOn }) else { return nil }
        return queue.sync { evaluate(forGate: true) }
    }

    // MARK: - Private

    private func setPolling(_ on: Bool) {
        if on, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + pollInterval, repeating: pollInterval,
                leeway: .milliseconds(Int(max(5, pollInterval * 200))))
            timer.setEventHandler { [weak self] in self?.evaluate() }
            timer.resume()
            self.timer = timer
        } else if !on, let timer {
            timer.cancel()
            self.timer = nil
        }
    }

    /// Without apps to read nothing is stopped, and nothing is asked (only a scan's gate asks then), except
    /// the flag itself (shared memory, no IPC): a stuck holder's count is kept until the flag is seen off.
    @discardableResult
    private func evaluate(forGate: Bool = false) -> PasswordPause? {
        let context = lock.withLock { self.context }
        guard context.isOn, context.polls || forGate else {
            if !context.isOn || !system.secureInputEnabled() { resetStuck() }
            identities.removeAll()
            field = nil
            lastReport = nil
            publish(nil)
            return nil
        }
        let now = system.now()
        let secure = system.readSecureInput()
        var focus: ProcessIdentity?
        if secure.enabled, let pid = secure.focusPID {
            focus = identities[pid] ?? system.identify(pid)
            identities[pid] = focus
        } else if !secure.enabled {
            identities.removeAll()
        }
        // The named app does not follow app switches, so the front apps are counted.
        let front = context.front
        if secure.enabled, let front { stuckNames[front.pid] = front.name ?? "pid \(front.pid)" }
        let systemAuth =
            secure.screenLocked || PasswordEntryRules.isSystemAuth(focus, screenLocked: secure.screenLocked)
        if stuck.observe(enabled: secure.enabled, holder: front?.pid, holderIsSystemAuth: systemAuth) {
            let names = stuck.holders.map { stuckNames[$0] ?? "pid \($0)" }
            let list = names.joined(separator: ", ")
            log.notice("secure input stays on across app switches (held in the background?): \(list, privacy: .public)")
            send(.stuckSecureInput(names))
        }
        if !secure.enabled { stuckNames.removeAll() }

        var input = PasswordEntryRules.Input(
            settingOn: true, secureInput: secure, focus: focus, front: front, stuck: stuck.isStuck)
        // Rule b only when rule a does not already pause, or leaves it to the focused element (a terminal): one AX
        // call saved, and the probe stops meanwhile. Not on the poll while nothing is read without a key press.
        let asksField = forGate || context.pollsField || context.probesFocusedText || self.decision != nil
        if asksField, PasswordEntryRules.secureInputPause(input) == nil, let pid = context.fieldCheckPID {
            input.field = checkField(pid: pid, now: now, probe: context.probesFocusedText)
            input.fieldAppName = context.fieldCheckName
        }
        let decision = PasswordEntryRules.decide(input)
        publish(decision)
        let report = PasswordGuardReport(
            secureInput: secure.enabled, screenLocked: secure.screenLocked, secureInputApp: focus?.name,
            frontApp: context.front?.name, stuck: stuck.isStuck, field: input.field,
            fieldApp: input.field == .notAsked ? nil : context.fieldCheckName, decision: decision)
        if report != lastReport {
            lastReport = report
            send(.report(report))
        }
        return decision
    }

    private func resetStuck() {
        stuck = StuckSecureInputTracker()
        stuckNames.removeAll()
    }

    /// Rule b for one app: is its focused element a password field (or a terminal's screen)?
    private func checkField(pid: pid_t, now: TimeInterval, probe: Bool) -> PasswordFieldState {
        if let last = field, last.pid == pid,
            now < last.retryAfter || (now - last.checkedAt < Self.fieldFreshness && (last.probed || !probe))
        {
            return last.state
        }
        switch system.focusedElement(pid, probe) {
        case .element(let isSecure, let isTextArea, let count, let insertionPoint):
            let state: PasswordFieldState = isSecure ? .secure : isTextArea ? .textArea : .notSecure
            field = (pid, state, now, 0, probe)
            if probe {
                let answer = isSecure ? PromptProbe() : PromptProbe(characterCount: count, insertionPoint: insertionPoint)
                send(.focusedText(pid: pid, probe: answer))
            }
            return state
        case .none:
            field = (pid, .notSecure, now, 0, probe)
            if probe { send(.focusedText(pid: pid, probe: PromptProbe())) }
            return .notSecure
        case .timedOut:
            // Keep a previous password field or terminal screen for this app and leave it alone for a while.
            var kept = PasswordFieldState.timedOut
            if let previous = field.flatMap({ $0.pid == pid ? $0.state : nil }),
                previous == .secure || previous == .textArea
            {
                kept = previous
            }
            field = (pid, kept, now, now + Self.fieldRetryAfterTimeout, false)
            return kept
        }
    }

    private func publish(_ decision: PasswordPause?) {
        guard decision != self.decision else { return }
        self.decision = decision
        if let decision {
            log.notice("password entry: reading stops (\(decision.logDescription, privacy: .public))")
        } else {
            log.notice("password entry ended: reading resumes")
        }
        send(.pauseChanged(decision))
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { deliver(event) }
        }
    }
}

// MARK: - Texts

extension PasswordPause {
    /// The menu's status line.
    var menuLine: String {
        switch reason {
        case .secureInput, .secureField:
            return "パスワード入力中のため、読み取りを止めています" + (appName.map { "（\($0)）" } ?? "")
        case .terminalPrompt:
            return (appName.map { "\($0) が" } ?? "") + "パスワードを待っているため、このウインドウの読み取りを止めています"
        }
    }

    /// Reason and app name (logs).
    var logDescription: String {
        reason.rawValue + (appName.map { ", \($0)" } ?? "")
    }
}

/// Lines about the password pause for logs (reason, app names and window numbers only; never any text).
enum PasswordGuardNote: Sendable {
    case report(PasswordGuardReport)
    case pauseChanged(PasswordPause?)
    case stuckSecureInput([String])
    /// A terminal window waits at a password prompt (rule c).
    case promptPaused(WindowKey, app: String)
    case promptResumed(WindowKey, why: String)
    case translateNowIgnored(PasswordPause)

    var line: String {
        switch self {
        case .report(let report):
            return "password guard: " + report.line
        case .pauseChanged(let pause):
            return pause.map { "password pause: reading stopped (\($0.logDescription))" }
                ?? "password pause: ended, rescanning every app"
        case .stuckSecureInput(let names):
            return "password guard: secure input stays on across app switches (\(names.joined(separator: ", "))); "
                + "probably held by a background app, not pausing for it"
        case .promptPaused(let key, let app):
            return "password prompt: \(app) window \(key) waits for a password; no timed scans of it"
        case .promptResumed(let key, let why):
            return "password prompt: window \(key) is scanned again (\(why))"
        case .translateNowIgnored(let pause):
            return "translate-now ignored: reading is stopped (\(pause.logDescription))"
        }
    }
}
