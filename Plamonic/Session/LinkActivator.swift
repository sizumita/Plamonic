import AppKit
import ApplicationServices
import os

/// Presses a link's own element in the target app, or asks it for the element's context menu. Called off the
/// main thread.
protocol LinkElementPressing: Sendable {
    /// AXPress on `element`. `.success` when the app accepted it.
    func press(_ element: AXElement) -> AXError
    /// The element still exists and offers AXPress (read only; used by dry runs).
    func canPress(_ element: AXElement) -> Bool
    /// AXShowMenu on `element`: the app shows its own context menu for it. `.success` when the app accepted it
    /// (the app draws the menu a little later).
    func showMenu(_ element: AXElement) -> AXError
    /// The element still exists and offers AXShowMenu (read only; used by dry runs).
    func canShowMenu(_ element: AXElement) -> Bool
}

/// Opens a URL in the app that handles it (the browser, the mail app), never in Plamonic.
protocol LinkURLOpening {
    @MainActor func open(_ url: URL)
}

struct AXLinkPresser: LinkElementPressing {
    func press(_ element: AXElement) -> AXError {
        AXUIElementPerformAction(element.ref, kAXPressAction as CFString)
    }

    func canPress(_ element: AXElement) -> Bool {
        offers(kAXPressAction, element)
    }

    func showMenu(_ element: AXElement) -> AXError {
        // Not checked against the action names first: one more call, and links and buttons offer it.
        AXUIElementPerformAction(element.ref, kAXShowMenuAction as CFString)
    }

    func canShowMenu(_ element: AXElement) -> Bool {
        offers(kAXShowMenuAction, element)
    }

    private func offers(_ action: String, _ element: AXElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element.ref, &names) == .success else { return false }
        return ((names as? [String]) ?? []).contains(action)
    }
}

private let linkLog = Logger(subsystem: "io.smdr.Plamonic", category: "Links")

struct WorkspaceURLOpener: LinkURLOpening {
    @MainActor func open(_ url: URL) {
        // The handling app comes forward, as after a click on the original link. Plamonic is never activated.
        let scheme = url.scheme ?? "-"
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            linkLog.error(
                "Opening a \(scheme, privacy: .public) link failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// What activating a link did.
enum LinkActivationOutcome: Equatable, Sendable {
    /// The app accepted AXPress on the link's element.
    case pressed
    /// The URL was opened (no element, or pressing it failed).
    case openedURL
    /// Dry run: would press the element (it exists and offers AXPress).
    case wouldPress
    /// Dry run: would open the URL.
    case wouldOpenURL
    case ignored(LinkIgnoreReason)
}

enum LinkIgnoreReason: Equatable, Sendable {
    /// The same link was activated less than `LinkActivator.repeatInterval` ago (a double click).
    case repeated
    /// No element to press (or the press failed) and the URL is missing or not http / https / mailto.
    case disallowedURL
    /// The press timed out: the app may still perform it, so the URL is not opened as well.
    case pressTimedOut
}

/// One activation, for logs and the smoke test. Keeps only the URL's scheme and host, never the link text.
struct LinkActivationReport: Equatable, Sendable {
    var window: WindowKey
    var itemID: String
    var kind: SegmentLinkKind
    var outcome: LinkActivationOutcome
    /// AXPress result when the element was pressed and failed.
    var pressError: AXError?
    /// Dry runs: whether the link's element exists and offers AXPress (nil = no element).
    var pressSupported: Bool?
    /// Scheme and host of the link's URL, if any.
    var scheme: String?
    var host: String?
}

/// Opens a link drawn in a translation the way the original link opens: AXPress on its element, off the main
/// thread; the URL only when there is no element or pressing it failed, and only for http, https and mailto.
/// A right-click shows the original link's own context menu (AXShowMenu), or Plamonic's own small menu when the
/// app has none. DESIGN §6.1.
@MainActor
final class LinkActivator {
    nonisolated static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
    /// A second activation of the same link within this time is ignored.
    nonisolated static let repeatInterval: CFAbsoluteTime = 0.5

    /// Only reports what it would do: nothing is pressed or opened, no menu is shown.
    var dryRun = false
    /// Plamonic's own link menu closed (chosen or not).
    var onOwnMenuClosed: (@MainActor () -> Void)?

    private let presser: any LinkElementPressing
    private let opener: any LinkURLOpening
    private let menuPresenter: any LinkMenuPresenting
    private let pasteboard: any LinkPasteboardWriting
    private let now: () -> CFAbsoluteTime
    /// Presses and menu requests run here, so a slow app never blocks the main thread or the scans.
    private let queue = DispatchQueue(label: "io.smdr.Plamonic.link", qos: .userInitiated)
    private var recent: [ActivationKey: CFAbsoluteTime] = [:]
    /// Menu requests have their own repeat guard: a right-click right after a click still shows the menu.
    private var recentMenus: [ActivationKey: CFAbsoluteTime] = [:]
    /// Bumped by `cancelOwnMenu`: a request still waiting for the app then shows nothing.
    private var menuGeneration = 0

    private struct ActivationKey: Hashable {
        var window: WindowKey
        var itemID: String
        var range: Range<Int>
        var text: String
    }

    init(
        presser: any LinkElementPressing = AXLinkPresser(), opener: any LinkURLOpening = WorkspaceURLOpener(),
        menuPresenter: (any LinkMenuPresenting)? = nil, pasteboard: (any LinkPasteboardWriting)? = nil,
        now: @escaping () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) {
        self.presser = presser
        self.opener = opener
        self.menuPresenter = menuPresenter ?? NSLinkMenuPresenter()
        self.pasteboard = pasteboard ?? GeneralPasteboardWriter()
        self.now = now
    }

    /// The URL may be opened by Plamonic: http / https with a host, or mailto.
    nonisolated static func isAllowed(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return false }
        if scheme == "mailto" { return true }
        return !(url.host ?? "").isEmpty
    }

    @discardableResult
    func activate(_ link: SegmentLink, window: WindowKey, itemID: String) async -> LinkActivationReport {
        var report = LinkActivationReport(
            window: window, itemID: itemID, kind: link.kind, outcome: .ignored(.repeated),
            scheme: link.url?.scheme?.lowercased(), host: link.url?.host)
        // Decided before any await, so the second click of a double click is caught.
        let time = now()
        recent = recent.filter { time - $0.value < Self.repeatInterval }
        let key = ActivationKey(window: window, itemID: itemID, range: link.range, text: link.text)
        guard recent[key] == nil else {
            finish(report)
            return report
        }
        recent[key] = time

        if let element = link.element {
            let presser = self.presser
            if dryRun {
                // A real press of an element that is gone or cannot be pressed falls back to the URL.
                let supported = await runOffMain { presser.canPress(element) }
                report.pressSupported = supported
                if supported {
                    report.outcome = .wouldPress
                    finish(report)
                    return report
                }
            } else {
                let error = await runOffMain { presser.press(element) }
                if error == .success {
                    report.outcome = .pressed
                    finish(report)
                    return report
                }
                report.pressError = error
                if error == .cannotComplete {
                    // The app did not answer in time but may still act on the press; opening the URL as well
                    // could open the link twice.
                    report.outcome = .ignored(.pressTimedOut)
                    finish(report)
                    return report
                }
            }
        }
        // No element, or the element is gone / cannot be pressed.
        guard Self.isAllowed(link.url), let url = link.url else {
            report.outcome = .ignored(.disallowedURL)
            finish(report)
            return report
        }
        if dryRun {
            report.outcome = .wouldOpenURL
        } else {
            opener.open(url)
            report.outcome = .openedURL
        }
        finish(report)
        return report
    }

    // MARK: - Context menu

    /// Plamonic's own link menu is open or about to open.
    var isOwnMenuOpen: Bool { menuPresenter.isPresenting }

    /// A link drawn in a translation was right-clicked (or control-clicked) at `point` (AX coordinates): shows
    /// what right-clicking the original link shows. AXShowMenu on its element, off the main thread; the app
    /// draws its own menu for the link (where the app decides). Plamonic's own small menu at `point` only when
    /// there is no element or the app has no menu for it; never both (a timed-out request shows nothing).
    /// `showOriginal` and `opened` serve the own menu's 「原文を表示」 and 「リンクを開く」.
    @discardableResult
    func showMenu(
        _ link: SegmentLink, window: WindowKey, itemID: String, at point: CGPoint,
        showOriginal: @escaping @MainActor () -> Void,
        opened: @escaping @MainActor (LinkActivationReport) -> Void = { _ in }
    ) async -> LinkMenuReport {
        var report = LinkMenuReport(
            window: window, itemID: itemID, kind: link.kind, outcome: .ignored(.repeated), point: point,
            scheme: link.url?.scheme?.lowercased(), host: link.url?.host)
        // Decided before any await, so a second request right after the first is caught.
        let time = now()
        recentMenus = recentMenus.filter { time - $0.value < Self.repeatInterval }
        let key = ActivationKey(window: window, itemID: itemID, range: link.range, text: link.text)
        guard recentMenus[key] == nil else { return finishMenu(report) }
        recentMenus[key] = time
        guard !menuPresenter.isPresenting else {
            report.outcome = .ignored(.menuOpen)
            return finishMenu(report)
        }

        let generation = menuGeneration
        if let element = link.element {
            let presser = self.presser
            if dryRun {
                let supported = await runOffMain { presser.canShowMenu(element) }
                report.menuSupported = supported
                if supported {
                    report.outcome = .wouldShowAppMenu
                    return finishMenu(report)
                }
            } else {
                let error = await runOffMain { presser.showMenu(element) }
                if error == .success {
                    // Not checked for a menu window: apps draw it later, and web apps draw theirs inside the page,
                    // so a check would add a second menu.
                    report.outcome = .appMenu
                    return finishMenu(report)
                }
                report.menuError = error
                if error == .cannotComplete {
                    // The app did not answer in time but may still show its menu.
                    report.outcome = .ignored(.timedOut)
                    return finishMenu(report)
                }
            }
        }
        // No element, or the element is gone / has no menu.
        let entries = ownMenuEntries(link, window: window, itemID: itemID, showOriginal: showOriginal, opened: opened)
        report.ownMenu = entries.map(\.action)
        if dryRun {
            report.outcome = .wouldShowOwnMenu
            return finishMenu(report)
        }
        guard generation == menuGeneration else {
            report.outcome = .ignored(.cancelled)
            return finishMenu(report)
        }
        guard !menuPresenter.isPresenting else {
            report.outcome = .ignored(.menuOpen)
            return finishMenu(report)
        }
        menuPresenter.present(entries, at: point) { [weak self] in self?.onOwnMenuClosed?() }
        report.outcome = .ownMenu
        return finishMenu(report)
    }

    /// Closes Plamonic's own link menu, if open, without choosing anything; a request still waiting for the app
    /// shows no menu of Plamonic's own.
    func cancelOwnMenu() {
        menuGeneration += 1
        menuPresenter.cancel()
    }

    /// 「リンクを開く」 (what a click on the translated link does), 「リンクのアドレスをコピー」 (only with an address
    /// Plamonic may open) and 「原文を表示」.
    private func ownMenuEntries(
        _ link: SegmentLink, window: WindowKey, itemID: String, showOriginal: @escaping @MainActor () -> Void,
        opened: @escaping @MainActor (LinkActivationReport) -> Void
    ) -> [LinkMenuEntry] {
        var entries: [LinkMenuEntry] = []
        // Without an element and an allowed URL, a click opens nothing either.
        let canOpen = link.element != nil || Self.isAllowed(link.url)
        entries.append(
            LinkMenuEntry(action: .open, isEnabled: canOpen) { [weak self] in
                Task { [weak self] in
                    guard let self else { return }
                    opened(await self.activate(link, window: window, itemID: itemID))
                }
            })
        if Self.isAllowed(link.url), let url = link.url {
            let pasteboard = self.pasteboard
            entries.append(LinkMenuEntry(action: .copyAddress) { pasteboard.write(url) })
        }
        entries.append(LinkMenuEntry(action: .showOriginal, perform: showOriginal))
        return entries
    }

    private func finishMenu(_ report: LinkMenuReport) -> LinkMenuReport {
        let outcome = Self.describe(report.outcome)
        let error = report.menuError.map { " AXError=\($0.rawValue)" } ?? ""
        // Scheme and host only: never the URL's path or query, never the link text.
        linkLog.notice(
            "Link menu \(report.kind.rawValue, privacy: .public) \(outcome, privacy: .public)\(error, privacy: .public) scheme=\(report.scheme ?? "-", privacy: .public) host=\(report.host ?? "-", privacy: .private)"
        )
        return report
    }

    private func runOffMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func finish(_ report: LinkActivationReport) {
        let outcome = Self.describe(report.outcome)
        let error = report.pressError.map { " AXError=\($0.rawValue)" } ?? ""
        // Scheme and host only: never the URL's path or query, never the link text.
        linkLog.notice(
            "Link \(report.kind.rawValue, privacy: .public) \(outcome, privacy: .public)\(error, privacy: .public) scheme=\(report.scheme ?? "-", privacy: .public) host=\(report.host ?? "-", privacy: .private)"
        )
    }

    nonisolated static func describe(_ outcome: LinkActivationOutcome) -> String {
        switch outcome {
        case .pressed: return "pressed"
        case .openedURL: return "opened-url"
        case .wouldPress: return "would-press"
        case .wouldOpenURL: return "would-open-url"
        case .ignored(.repeated): return "ignored(repeated)"
        case .ignored(.disallowedURL): return "ignored(no-allowed-url)"
        case .ignored(.pressTimedOut): return "ignored(press-timed-out)"
        }
    }

    nonisolated static func describe(_ outcome: LinkMenuOutcome) -> String {
        switch outcome {
        case .appMenu: return "app-menu"
        case .ownMenu: return "own-menu"
        case .wouldShowAppMenu: return "would-show-app-menu"
        case .wouldShowOwnMenu: return "would-show-own-menu"
        case .ignored(.repeated): return "ignored(repeated)"
        case .ignored(.timedOut): return "ignored(menu-timed-out)"
        case .ignored(.menuOpen): return "ignored(menu-open)"
        case .ignored(.cancelled): return "ignored(cancelled)"
        }
    }
}
