import ApplicationServices
import XCTest

@testable import Plamonic

/// Presses, menu requests and URL opens are recorded by fakes: no real app is pressed or asked for a menu,
/// nothing is opened, no menu is shown and the real pasteboard is never written.
final class SessionFakePresser: LinkElementPressing, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: AXError
    private var _supported: Bool
    private var _menuResult: AXError
    private var _menuSupported: Bool
    private var _presses = 0
    private var _checks = 0
    private var _menus = 0
    private var _menuChecks = 0
    /// AXShowMenu waits for this before it answers (a slow app).
    private let menuGate: DispatchSemaphore?

    init(
        result: AXError = .success, supported: Bool = true, menuResult: AXError = .success,
        menuSupported: Bool = true, menuGate: DispatchSemaphore? = nil
    ) {
        _result = result
        _supported = supported
        _menuResult = menuResult
        _menuSupported = menuSupported
        self.menuGate = menuGate
    }

    var presses: Int { lock.withLock { _presses } }
    var checks: Int { lock.withLock { _checks } }
    var menus: Int { lock.withLock { _menus } }
    var menuChecks: Int { lock.withLock { _menuChecks } }

    func press(_ element: AXElement) -> AXError {
        XCTAssertFalse(Thread.isMainThread, "AXPress must not run on the main thread")
        return lock.withLock {
            _presses += 1
            return _result
        }
    }

    func canPress(_ element: AXElement) -> Bool {
        lock.withLock {
            _checks += 1
            return _supported
        }
    }

    func showMenu(_ element: AXElement) -> AXError {
        XCTAssertFalse(Thread.isMainThread, "AXShowMenu must not run on the main thread")
        let result = lock.withLock {
            _menus += 1
            return _menuResult
        }
        menuGate?.wait()
        return result
    }

    func canShowMenu(_ element: AXElement) -> Bool {
        XCTAssertFalse(Thread.isMainThread, "reading the actions must not run on the main thread")
        return lock.withLock {
            _menuChecks += 1
            return _menuSupported
        }
    }
}

@MainActor
final class SessionFakeOpener: LinkURLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

/// Records the menus Plamonic would pop up; a test chooses an entry or closes it.
@MainActor
final class SessionFakeMenuPresenter: LinkMenuPresenting {
    struct Shown {
        var entries: [LinkMenuEntry]
        var point: CGPoint
        var closed: @MainActor () -> Void
    }

    private(set) var shown: [Shown] = []
    private(set) var cancels = 0
    private var open = false

    var isPresenting: Bool { open }

    func present(_ entries: [LinkMenuEntry], at point: CGPoint, closed: @escaping @MainActor () -> Void) {
        XCTAssertFalse(open, "a second menu while one is open")
        shown.append(Shown(entries: entries, point: point, closed: closed))
        open = true
    }

    func cancel() {
        cancels += 1
        close()
    }

    /// The entries of the last menu, by action.
    var actions: [LinkMenuAction] { shown.last?.entries.map(\.action) ?? [] }

    /// Chooses an entry of the open menu (as AppKit does: the action runs, then the menu closes).
    func choose(_ action: LinkMenuAction) {
        guard open, let entry = shown.last?.entries.first(where: { $0.action == action }) else {
            return XCTFail("no open menu with \(action)")
        }
        XCTAssertTrue(entry.isEnabled, "\(action) is disabled")
        entry.perform()
        close()
    }

    func close() {
        guard open else { return }
        open = false
        shown.last?.closed()
    }
}

@MainActor
final class SessionFakePasteboard: LinkPasteboardWriting {
    private(set) var written: [URL] = []
    func write(_ url: URL) { written.append(url) }
}
