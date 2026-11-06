import ApplicationServices
import Foundation

enum AXEventKind: String, CaseIterable, Hashable, Sendable {
    case valueChanged
    case layoutChanged
    case focusedWindowChanged
    case focusedElementChanged
    case mainWindowChanged
    case windowMoved
    case windowResized
    case windowCreated
    case windowMiniaturized
    case windowDeminiaturized
    case elementDestroyed
    case selectedTextChanged
    case selectedChildrenChanged
    case rowCountChanged
    case titleChanged
    case applicationActivated
    case applicationDeactivated
    case applicationHidden
    case applicationShown

    var notificationName: String {
        switch self {
        case .valueChanged: kAXValueChangedNotification
        case .layoutChanged: kAXLayoutChangedNotification
        case .focusedWindowChanged: kAXFocusedWindowChangedNotification
        case .focusedElementChanged: kAXFocusedUIElementChangedNotification
        case .mainWindowChanged: kAXMainWindowChangedNotification
        case .windowMoved: kAXWindowMovedNotification
        case .windowResized: kAXWindowResizedNotification
        case .windowCreated: kAXWindowCreatedNotification
        case .windowMiniaturized: kAXWindowMiniaturizedNotification
        case .windowDeminiaturized: kAXWindowDeminiaturizedNotification
        case .elementDestroyed: kAXUIElementDestroyedNotification
        case .selectedTextChanged: kAXSelectedTextChangedNotification
        case .selectedChildrenChanged: kAXSelectedChildrenChangedNotification
        case .rowCountChanged: kAXRowCountChangedNotification
        case .titleChanged: kAXTitleChangedNotification
        case .applicationActivated: kAXApplicationActivatedNotification
        case .applicationDeactivated: kAXApplicationDeactivatedNotification
        case .applicationHidden: kAXApplicationHiddenNotification
        case .applicationShown: kAXApplicationShownNotification
        }
    }

    init?(notificationName: String) {
        guard let kind = AXEventKind.byName[notificationName] else { return nil }
        self = kind
    }

    private static let byName: [String: AXEventKind] = Dictionary(
        uniqueKeysWithValues: AXEventKind.allCases.map { ($0.notificationName, $0) })

    /// What the real-time loop needs. Chromium can be noisy with valueChanged / layoutChanged; coalesce downstream.
    static let defaultSet: Set<AXEventKind> = [
        .valueChanged, .layoutChanged, .focusedWindowChanged, .focusedElementChanged, .mainWindowChanged,
        .windowMoved, .windowResized, .windowCreated, .windowMiniaturized, .windowDeminiaturized,
        .elementDestroyed, .selectedTextChanged, .titleChanged,
    ]
}

struct AXEvent: @unchecked Sendable {
    var kind: AXEventKind
    var pid: pid_t
    /// The element the notification refers to (a window for window events).
    var element: AXElement
    var timestamp: Date
}

/// One AXObserver per pid, all serviced by a dedicated run-loop thread.
/// The handler is called on that thread; keep it short and hop to your own queue.
final class AXEventHub: @unchecked Sendable {
    typealias Handler = @Sendable (AXEvent) -> Void

    private final class Registration {
        let pid: pid_t
        let observer: AXObserver
        let app: AXElement
        var kinds: Set<AXEventKind> = []
        weak var hub: AXEventHub?
        init(pid: pid_t, observer: AXObserver, app: AXElement, hub: AXEventHub) {
            self.pid = pid
            self.observer = observer
            self.app = app
            self.hub = hub
        }
    }

    private let handler: Handler
    private let loop = RunLoopThread(name: "Plamonic.AXEventHub")
    // Touched only on the hub thread.
    private var registrations: [pid_t: Registration] = [:]
    private let pidLock = NSLock()
    private var pidSnapshot: Set<pid_t> = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// PIDs with an active observer.
    var observedPIDs: Set<pid_t> {
        pidLock.lock()
        defer { pidLock.unlock() }
        return pidSnapshot
    }

    /// Starts (or extends) observation of a process. Returns the kinds the app accepted;
    /// apps that refuse some notifications are tolerated. Blocks until registration finishes.
    @discardableResult
    func observe(pid: pid_t, kinds: Set<AXEventKind> = AXEventKind.defaultSet) -> Set<AXEventKind> {
        guard pid != getpid() else { return [] }
        var accepted: Set<AXEventKind> = []
        loop.performSync { accepted = self.register(pid: pid, kinds: kinds) }
        return accepted
    }

    func unobserve(pid: pid_t) {
        loop.performSync { self.unregister(pid: pid) }
    }

    func unobserveAll() {
        loop.performSync {
            for pid in Array(self.registrations.keys) { self.unregister(pid: pid) }
        }
    }

    /// Removes all observers and ends the thread. The hub cannot be reused afterwards.
    func stop() {
        unobserveAll()
        loop.stop()
    }

    private func register(pid: pid_t, kinds: Set<AXEventKind>) -> Set<AXEventKind> {
        let registration: Registration
        let isNew = registrations[pid] == nil
        if let existing = registrations[pid] {
            registration = existing
        } else {
            var observer: AXObserver?
            let err = AXObserverCreate(pid, AXEventHub.callback, &observer)
            guard err == .success, let observer else { return [] }
            registration = Registration(
                pid: pid, observer: observer, app: AXElement.application(pid: pid), hub: self)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            registrations[pid] = registration
            updateSnapshot()
        }
        let refcon = Unmanaged.passUnretained(registration).toOpaque()
        var timedOut = false
        for kind in kinds where !registration.kinds.contains(kind) {
            let err = AXObserverAddNotification(
                registration.observer, registration.app.ref, kind.notificationName as CFString, refcon)
            if err == .success || err == .notificationAlreadyRegistered {
                registration.kinds.insert(kind)
            } else if err == .cannotComplete {
                // The app does not answer: every further kind would wait out the messaging timeout as well.
                timedOut = true
                break
            }
        }
        // The app refused everything, is not ready yet or did not answer; let the caller retry later.
        // A new registration that timed out part way is dropped whole, so the retry asks for every kind again.
        if registration.kinds.isEmpty || (timedOut && isNew) {
            unregister(pid: pid)
            return []
        }
        return registration.kinds.intersection(kinds)
    }

    private func unregister(pid: pid_t) {
        guard let registration = registrations.removeValue(forKey: pid) else { return }
        for kind in registration.kinds {
            AXObserverRemoveNotification(
                registration.observer, registration.app.ref, kind.notificationName as CFString)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(registration.observer), .defaultMode)
        updateSnapshot()
    }

    private func updateSnapshot() {
        pidLock.lock()
        pidSnapshot = Set(registrations.keys)
        pidLock.unlock()
    }

    private func deliver(_ registration: Registration, element: AXUIElement, name: String) {
        guard let kind = AXEventKind(notificationName: name) else { return }
        handler(AXEvent(kind: kind, pid: registration.pid, element: AXElement(element), timestamp: Date()))
    }

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let registration = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
        registration.hub?.deliver(registration, element: element, name: notification as String)
    }
}

/// A thread that runs a CFRunLoop until stopped; blocks can be executed on it synchronously.
final class RunLoopThread: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var thread: Thread?

    init(name: String, qos: QualityOfService = .userInitiated) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let rl = CFRunLoopGetCurrent()!
            self.lock.lock()
            self.runLoop = rl
            self.lock.unlock()
            // A port keeps the run loop alive while it has no other sources.
            RunLoop.current.add(Port(), forMode: .default)
            ready.signal()
            while !self.isStopped {
                _ = CFRunLoopRunInMode(.defaultMode, 60, false)
            }
        }
        thread.name = name
        thread.qualityOfService = qos
        self.thread = thread
        thread.start()
        ready.wait()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var isCurrent: Bool { Thread.current === thread }

    /// Runs `block` on the thread and waits for it. Runs inline when already on the thread; no-op after stop.
    func performSync(_ block: @escaping () -> Void) {
        lock.lock()
        let rl = runLoop
        let isStopped = stopped
        lock.unlock()
        guard let rl, !isStopped else { return }
        if isCurrent {
            block()
            return
        }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
            block()
            done.signal()
        }
        CFRunLoopWakeUp(rl)
        done.wait()
    }

    func stop() {
        lock.lock()
        let rl = runLoop
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard let rl, !wasStopped else { return }
        CFRunLoopStop(rl)
        CFRunLoopWakeUp(rl)
    }
}
