import AppKit

/// An entry of Plamonic's own link menu, shown when the app has no context menu for the link. DESIGN §6.1.
enum LinkMenuAction: String, Equatable, Sendable, CaseIterable {
    /// Does what a click on the translated link does.
    case open
    /// Puts the link's address on the pasteboard (only with an http / https / mailto URL).
    case copyAddress
    /// Shows the item's original in place.
    case showOriginal

    var title: String {
        switch self {
        case .open: return "リンクを開く"
        case .copyAddress: return "リンクのアドレスをコピー"
        case .showOriginal: return "原文を表示"
        }
    }
}

struct LinkMenuEntry {
    var action: LinkMenuAction
    var isEnabled = true
    /// Runs only when the entry is chosen.
    var perform: @MainActor () -> Void
}

/// What a right-click (or control-click) on a translated link did.
enum LinkMenuOutcome: Equatable, Sendable {
    /// The app accepted AXShowMenu on the link's element: it shows its own menu for the link.
    case appMenu
    /// Plamonic's own menu was shown (no element, or the app has no menu for it).
    case ownMenu
    /// Dry run: would ask the app for its menu (the element exists and offers AXShowMenu).
    case wouldShowAppMenu
    /// Dry run: would show Plamonic's own menu.
    case wouldShowOwnMenu
    case ignored(LinkMenuIgnoreReason)
}

enum LinkMenuIgnoreReason: Equatable, Sendable {
    /// The same link asked for a menu less than `LinkActivator.repeatInterval` ago.
    case repeated
    /// AXShowMenu timed out: the app may still show its menu, so Plamonic's own is not shown as well.
    case timedOut
    /// Plamonic's own menu is already open.
    case menuOpen
    /// Menus were cancelled (the session stopped) while the request waited for the app.
    case cancelled
}

/// One menu request, for logs and the smoke test. Keeps only the URL's scheme and host, never the link text.
struct LinkMenuReport: Equatable, Sendable {
    var window: WindowKey
    var itemID: String
    var kind: SegmentLinkKind
    var outcome: LinkMenuOutcome
    /// Where the menu was asked for (AX coordinates).
    var point: CGPoint
    /// AXShowMenu result when it failed.
    var menuError: AXError?
    /// Dry runs: whether the link's element exists and offers AXShowMenu (nil = no element).
    var menuSupported: Bool?
    /// The entries of Plamonic's own menu, when it was (or in a dry run would be) shown.
    var ownMenu: [LinkMenuAction] = []
    var scheme: String?
    var host: String?
}

/// Shows Plamonic's own link menu. The live one pops up an NSMenu; tests use a fake.
@MainActor
protocol LinkMenuPresenting: AnyObject {
    /// A menu is open or about to open.
    var isPresenting: Bool { get }
    /// Shows `entries` with the menu's top-left at `point` (AX coordinates) without activating Plamonic.
    /// Returns at once; `closed` runs after the menu closed (chosen or not).
    func present(_ entries: [LinkMenuEntry], at point: CGPoint, closed: @escaping @MainActor () -> Void)
    /// Closes the menu without choosing anything.
    func cancel()
}

/// Writes a link's address for 「リンクのアドレスをコピー」.
@MainActor
protocol LinkPasteboardWriting {
    func write(_ url: URL)
}

struct GeneralPasteboardWriter: LinkPasteboardWriting {
    func write(_ url: URL) {
        let pasteboard = NSPasteboard.general
        let text = url.absoluteString
        pasteboard.clearContents()
        pasteboard.declareTypes([.URL, .string], owner: nil)
        pasteboard.setString(text, forType: .URL)
        pasteboard.setString(text, forType: .string)
    }
}

/// Pops up an NSMenu at a screen point from the main thread. Plamonic is never activated: the menu shows and
/// tracks while another app stays in front (measured).
@MainActor
final class NSLinkMenuPresenter: NSObject, LinkMenuPresenting {
    private enum State {
        case idle
        /// Waiting for the run-loop block that opens it.
        case scheduled
        case open
    }

    /// An entry's action, carried by its menu item (so it still runs if AppKit sends it after the menu closed).
    private final class Action: NSObject {
        let perform: @MainActor () -> Void
        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    }

    private var state = State.idle
    private var menu: NSMenu?
    private var location: CGPoint = .zero
    private var closed: (@MainActor () -> Void)?

    var isPresenting: Bool { state != .idle }

    func present(_ entries: [LinkMenuEntry], at point: CGPoint, closed: @escaping @MainActor () -> Void) {
        guard state == .idle, !entries.isEmpty else { return }
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        for entry in entries {
            let item = NSMenuItem(title: entry.action.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Action(entry.perform)
            item.isEnabled = entry.isEnabled
            menu.addItem(item)
        }
        self.menu = menu
        self.closed = closed
        location = CoordinateSpace.cocoaPoint(fromAX: point)
        state = .scheduled
        // Opened from a run-loop block, never from a main-queue block or a MainActor continuation: the menu
        // tracks in a nested run loop, and only this way do the main queue and MainActor work (scans, redraws)
        // keep running while it is open (measured: otherwise all of it waits until the menu closes).
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    func cancel() {
        switch state {
        case .idle: return
        case .scheduled: finish()
        case .open: menu?.cancelTrackingWithoutAnimation()
        }
    }

    private func open() {
        guard state == .scheduled, let menu else { return }
        state = .open
        // Blocks until the menu closes.
        menu.popUp(positioning: nil, at: location, in: nil)
        finish()
    }

    private func finish() {
        let closed = self.closed
        state = .idle
        menu = nil
        self.closed = nil
        closed?()
    }

    @objc private func choose(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.perform()
    }
}
