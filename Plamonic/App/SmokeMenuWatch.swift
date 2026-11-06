import AppKit
import ApplicationServices

/// A pop-up-menu-level window of the target app or of Plamonic.
struct SmokeMenuWindow: Equatable {
    var id: CGWindowID
    var pid: pid_t
    /// AX / global display coordinates.
    var bounds: CGRect
}

/// One place to look for the AXMenu shown in an app's menu window.
enum SmokeMenuProbe: Hashable {
    /// Hit-test at a point, system-wide, then walk up AXParent.
    case systemWide(CGPoint)
    /// Hit-test at a point on the app's element (only its windows), then walk up AXParent.
    case application(CGPoint)
    /// The app's focused element (often a menu item while the menu tracks), then walk up AXParent.
    case focusedElement
    /// The app's own children (some apps list the open menu there).
    case children

    var label: String {
        switch self {
        case .systemWide: return "system-wide hit"
        case .application: return "app hit"
        case .focusedElement: return "focused element"
        case .children: return "app children"
        }
    }
}

/// An AXMenu found for a menu window.
struct SmokeFoundMenu {
    var itemCount: Int
    /// AXCancel on it (never chooses an item).
    var cancel: @MainActor () -> AXError
}

/// What the watch reads and does. The live one asks the window server and AX; tests use a fake.
@MainActor
protocol SmokeMenuEnvironment: AnyObject {
    var now: CFAbsoluteTime { get }
    var frontmostPID: pid_t? { get }
    var isPlamonicActive: Bool { get }
    /// On-screen pop-up-menu-level windows of these processes.
    func menuWindows(of pids: Set<pid_t>) -> [SmokeMenuWindow]
    /// The AXMenu of `pid` that `probe` leads to, or nil. Stops asking once `deadline` has passed.
    func menu(of pid: pid_t, probe: SmokeMenuProbe, deadline: CFAbsoluteTime) -> SmokeFoundMenu?
}

/// `--context-menu-first-link`: waits for the menu a right-click on a translated link brings up (the target
/// app's own, a new pop-up-menu window of its process; or Plamonic's own) and closes it within 1 s of
/// appearing: AXCancel on the app's AXMenu, or cancelling Plamonic's own menu. Never chooses an item.
/// After the first report it keeps watching until `stop()` for a menu that opens late (an app that answered
/// AXShowMenu slowly or timed out) and closes it the same way. A menu it cannot close is reported through
/// `leftOpen` (the run must end at once, so the caller can close the app). Reports counts, times and places
/// only (no titles).
@MainActor
final class SmokeMenuWatch {
    enum Owner: String {
        case app
        case plamonic
    }

    struct Result {
        var owner: Owner?
        /// The menu opened after the first report (a late answer to the request).
        var late = false
        /// Seconds from the request to the menu window.
        var appearedAfter: TimeInterval?
        /// The menu window (AX / global display coordinates).
        var frame: CGRect?
        /// Items of the menu (separators included): from its AXMenu for the app, from Plamonic's menu otherwise.
        var itemCount: Int?
        var foundAXMenu = false
        /// Where the AXMenu was found.
        var foundBy: SmokeMenuProbe?
        /// Probes asked before it was found (or in all, when it was not).
        var probesTried = 0
        var cancelError: AXError?
        /// Seconds the menu window was on screen.
        var visibleFor: TimeInterval?
        var frontChanged = false
        var plamonicActivated = false
        /// The menu could not be closed: the run must end now.
        var leftOpen = false
        var error: String?
    }

    /// No window after this long: no menu (dry run, timed out, or a menu drawn inside the page). Late menus are
    /// still watched for.
    static let appearTimeout: TimeInterval = 1.5
    /// The app's menu is left open when no AXMenu is found this long after it appeared.
    static let findDeadline: TimeInterval = 0.6
    /// A menu must be gone this long after it appeared.
    static let closeDeadline: TimeInterval = 0.9
    /// Probing time per tick (the timer runs on the main thread).
    static let probeBudget: TimeInterval = 0.03

    private enum Phase {
        case idle
        /// Waiting for the requested menu.
        case waiting
        /// A menu window is on screen: closing it.
        case closing(Menu)
        /// Reported; watching for a menu that opens late.
        case lingering
        case finished
    }

    private struct Menu {
        var window: SmokeMenuWindow
        var appeared: CFAbsoluteTime
        var result: Result
        var probes: [SmokeMenuProbe]
        var nextProbe = 0
        var found: SmokeFoundMenu?
        var cancelled = false
    }

    private let targetPID: pid_t
    private let ownPID = getpid()
    private let environment: SmokeMenuEnvironment
    private let cancelOwnMenu: @MainActor () -> Void
    private let ownMenuItemCount: @MainActor () -> Int?
    private let reported: @MainActor (Result) -> Void
    private let leftOpen: @MainActor (Result) -> Void
    private var phase = Phase.idle
    private var timer: Timer?
    private var started: CFAbsoluteTime = 0
    /// Menu windows already there before the request, and the ones handled since.
    private var seen: Set<CGWindowID> = []
    private var frontPID: pid_t?
    private var frontChanged = false
    private var plamonicActivated = false
    private var reports = 0

    init(
        targetPID: pid_t, environment: SmokeMenuEnvironment? = nil,
        cancelOwnMenu: @escaping @MainActor () -> Void, ownMenuItemCount: @escaping @MainActor () -> Int?,
        reported: @escaping @MainActor (Result) -> Void, leftOpen: @escaping @MainActor (Result) -> Void
    ) {
        self.targetPID = targetPID
        self.environment = environment ?? LiveSmokeMenuEnvironment()
        self.cancelOwnMenu = cancelOwnMenu
        self.ownMenuItemCount = ownMenuItemCount
        self.reported = reported
        self.leftOpen = leftOpen
    }

    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// Call right before the request. `timer: false` leaves the ticks to the caller (tests).
    func start(timer runsTimer: Bool = true) {
        guard case .idle = phase else { return }
        started = environment.now
        seen = Set(environment.menuWindows(of: [targetPID, ownPID]).map(\.id))
        frontPID = environment.frontmostPID
        phase = .waiting
        guard runsTimer else { return }
        // Common modes: also fires while Plamonic's own menu tracks.
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Ends the watch. A menu still being closed gets one more try (no report). Returns true when a menu of the
    /// app was still on screen (Plamonic's own closes with the process).
    @discardableResult
    func stop() -> Bool {
        defer { end() }
        guard case .closing(var menu) = phase,
            environment.menuWindows(of: [menu.window.pid]).contains(where: { $0.id == menu.window.id })
        else { return false }
        close(&menu, budget: Self.probeBudget * 3)
        if menu.result.owner == .plamonic {
            cancelOwnMenu()
            return false
        }
        return true
    }

    /// For the end of the run: ticks (blocking) while the requested menu may still appear or an app menu is
    /// being closed, up to `timeout`, then stops. Returns what `stop()` returns.
    @discardableResult
    func settle(timeout: TimeInterval, sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) })
        -> Bool
    {
        let end = environment.now + timeout
        while environment.now < end {
            switch phase {
            case .waiting: break
            case .closing(let menu) where menu.result.owner == .app: break
            default: return stop()
            }
            sleep(0.01)
            tick()
        }
        return stop()
    }

    func tick() {
        let now = environment.now
        switch phase {
        case .idle, .finished: return
        default: break
        }
        if let front = environment.frontmostPID, front != frontPID { frontChanged = true }
        if environment.isPlamonicActive { plamonicActivated = true }
        let windows = environment.menuWindows(of: [targetPID, ownPID])
        switch phase {
        case .waiting:
            if let window = windows.first(where: { !seen.contains($0.id) }) {
                open(window, now: now)
            } else if now - started > Self.appearTimeout {
                report(Result())
                phase = .lingering
            }
        case .lingering:
            if let window = windows.first(where: { !seen.contains($0.id) }) { open(window, now: now) }
        case .closing(var menu):
            guard windows.contains(where: { $0.id == menu.window.id }) else {
                menu.result.visibleFor = now - menu.appeared
                report(menu.result)
                phase = .lingering
                return
            }
            let age = now - menu.appeared
            if menu.result.owner == .app, menu.found == nil, age > Self.findDeadline {
                abandon(menu, "no AXMenu found within \(Int(Self.findDeadline * 1000))ms")
                return
            }
            if age > Self.closeDeadline {
                abandon(menu, "the menu did not close within \(Int(Self.closeDeadline * 1000))ms")
                return
            }
            close(&menu, budget: Self.probeBudget)
            phase = .closing(menu)
        case .idle, .finished:
            return
        }
    }

    private func open(_ window: SmokeMenuWindow, now: CFAbsoluteTime) {
        seen.insert(window.id)
        var result = Result()
        result.owner = window.pid == ownPID ? .plamonic : .app
        result.late = reports > 0
        result.appearedAfter = now - started
        result.frame = window.bounds
        var menu = Menu(window: window, appeared: now, result: result, probes: Self.probes(for: window.bounds))
        close(&menu, budget: Self.probeBudget)
        phase = .closing(menu)
    }

    /// Cancels the menu: Plamonic's own at once; the app's once its AXMenu is found (probes, a pass at most per
    /// call, within `budget`). A failed AXCancel is tried again.
    private func close(_ menu: inout Menu, budget: TimeInterval) {
        guard !menu.cancelled, let owner = menu.result.owner else { return }
        switch owner {
        case .plamonic:
            menu.result.itemCount = ownMenuItemCount()
            cancelOwnMenu()
            menu.cancelled = true
        case .app:
            if menu.found == nil {
                let deadline = environment.now + budget
                for _ in 0..<menu.probes.count {
                    let probe = menu.probes[menu.nextProbe]
                    menu.nextProbe = (menu.nextProbe + 1) % menu.probes.count
                    menu.result.probesTried += 1
                    if let found = environment.menu(of: targetPID, probe: probe, deadline: deadline) {
                        menu.found = found
                        menu.result.foundAXMenu = true
                        menu.result.foundBy = probe
                        menu.result.itemCount = found.itemCount
                        break
                    }
                    if environment.now >= deadline { break }
                }
            }
            guard let found = menu.found else { return }
            let error = found.cancel()
            menu.result.cancelError = error
            menu.cancelled = error == .success
        }
    }

    private func abandon(_ menu: Menu, _ reason: String) {
        var result = stamped(menu.result)
        result.leftOpen = true
        result.error = "menu left open: " + reason
        if result.owner == .plamonic { cancelOwnMenu() }
        end()
        leftOpen(result)
    }

    private func report(_ result: Result) {
        reports += 1
        reported(stamped(result))
    }

    private func stamped(_ result: Result) -> Result {
        var result = result
        result.frontChanged = frontChanged
        result.plamonicActivated = plamonicActivated
        return result
    }

    private func end() {
        phase = .finished
        timer?.invalidate()
        timer = nil
    }

    /// Where to look for the AXMenu of a menu window: near its top first (the first item; lower in case it is a
    /// separator or not exposed), the focused element and the app's children, then a grid over the whole window,
    /// system-wide and on the app's element.
    static func probes(for frame: CGRect) -> [SmokeMenuProbe] {
        let frame = frame.standardized
        var first: [CGPoint] = []
        for y in [frame.minY + 14, frame.minY + 40, frame.midY] where y < frame.maxY {
            first.append(CGPoint(x: frame.midX, y: y))
        }
        if first.isEmpty { first.append(CGPoint(x: frame.midX, y: frame.midY)) }
        var grid: [CGPoint] = []
        // Inset from the rounded edges and the menu's padding.
        let inset = frame.insetBy(dx: min(12, frame.width / 4), dy: min(6, frame.height / 4))
        if !inset.isEmpty {
            let rows = min(8, max(2, Int((inset.height / 30).rounded(.up)) + 1))
            for row in 0..<rows {
                let y = inset.minY + inset.height * CGFloat(row) / CGFloat(rows - 1)
                for x in [inset.minX, inset.midX, inset.maxX] {
                    let point = CGPoint(x: x, y: y)
                    if !first.contains(point), !grid.contains(point) { grid.append(point) }
                }
            }
        }
        return first.map { .systemWide($0) } + first.map { .application($0) } + [.focusedElement, .children]
            + grid.map { .systemWide($0) } + grid.map { .application($0) }
    }
}

/// The live environment: the window server and AX. Only reads, plus AXCancel on a found AXMenu.
@MainActor
final class LiveSmokeMenuEnvironment: SmokeMenuEnvironment {
    var now: CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var isPlamonicActive: Bool { NSApp.isActive }

    func menuWindows(of pids: Set<pid_t>) -> [SmokeMenuWindow] {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                (info[kCGWindowLayer as String] as? Int) == level,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({
                    CGRect(dictionaryRepresentation: $0 as CFDictionary)
                })
            else { return nil }
            return SmokeMenuWindow(id: id, pid: pid, bounds: bounds)
        }
    }

    func menu(of pid: pid_t, probe: SmokeMenuProbe, deadline: CFAbsoluteTime) -> SmokeFoundMenu? {
        let app = AXElement.application(pid: pid)
        let menu: AXElement?
        switch probe {
        case .systemWide(let point):
            menu = Self.menu(above: AXElement.systemWide.element(atAX: point), pid: pid, deadline: deadline)
        case .application(let point):
            menu = Self.menu(above: app.element(atAX: point), pid: pid, deadline: deadline)
        case .focusedElement:
            menu = Self.menu(above: app.element(AXAttr.focusedUIElement), pid: pid, deadline: deadline)
        case .children:
            menu = app.children.first { $0.role == "AXMenu" }
        }
        guard let menu else { return nil }
        return SmokeFoundMenu(itemCount: menu.children.count) {
            AXUIElementPerformAction(menu.ref, kAXCancelAction as CFString)
        }
    }

    /// The element or the nearest AXMenu above it, within the app's process.
    private static func menu(above element: AXElement?, pid: pid_t, deadline: CFAbsoluteTime) -> AXElement? {
        var element = element
        for _ in 0..<6 {
            guard let current = element, current.pid == pid else { return nil }
            if current.role == "AXMenu" { return current }
            if CFAbsoluteTimeGetCurrent() >= deadline { return nil }
            element = current.parent
        }
        return nil
    }
}
