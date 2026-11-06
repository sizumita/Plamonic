import AppKit

/// What one click panel stands for.
struct OverlayClickTarget: Equatable {
    var window: WindowKey
    var itemID: String
    var kind: OverlayHitArea.Kind
}

/// A small transparent panel over one click area (a translated link, or an original link hidden under a
/// translation). DESIGN §6.1: only these take clicks; the overlay itself stays click-through. Never key or
/// main, never activates Plamonic. Attached as a child window of its overlay panel, so it stays directly above
/// it (and so below every window in front of the target) whenever the overlay is ordered.
final class OverlayClickPanel: NSPanel {
    let clickView: OverlayClickView
    private(set) var target: OverlayClickTarget?
    /// Stands in for the window number before the panel was ever on screen (-1 then).
    private let serial: Int
    private static var serials = 0

    /// Identifies the panel to the cursor logic: its window number once it has one (what a hit test at the
    /// pointer returns), else a negative number no window has.
    var pointerNumber: Int { windowNumber > 0 ? windowNumber : -serial }

    /// The panel stands for a translated link (not a blocker).
    var isLinkPanel: Bool {
        guard let target else { return false }
        return target.kind != .blocker
    }

    init() {
        let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        clickView = OverlayClickView(frame: frame)
        Self.serials += 1
        serial = Self.serials
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = false
        level = .normal
        becomesKeyOnlyIfNeeded = true
        // Set explicitly: a transparent window takes mouse events only when told so.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        clickView.autoresizingMask = [.width, .height]
        contentView = clickView
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setTarget(_ target: OverlayClickTarget) {
        guard target != self.target else { return }
        self.target = target
        clickView.isLink = target.kind != .blocker
        // A press on what the panel stood for before does not finish as a click on the new target.
        clickView.cancelPress()
    }

    /// The panel goes back to the pool.
    func clearTarget() {
        target = nil
        clickView.isLink = false
        clickView.cancelPress()
    }
}

/// How the pointer moved relative to a click panel.
enum OverlayPointerEvent: Equatable {
    case entered, moved, exited
}

/// Fills a click panel. Takes the first click without activating anything, and reports the pointer entering,
/// moving over and leaving it (those moves never reach the session's global monitor).
///
/// Clicks act like a click on the original (DESIGN §6.1): a link acts on release, when the press was on the same
/// panel and the release is inside it (dragging off cancels; the second click of a double-click does nothing).
/// A blocker acts on press. A right click or a control-click (the context menu gesture) on a link asks for the
/// original link's context menu; on a blocker it does what a left click does. Other buttons are swallowed and
/// do nothing.
///
/// The view sets no cursor itself: cursor rects and `cursorUpdate` work only in the active app, and Plamonic is
/// never active. The controller sets the pointing hand from the reported enter / move / exit
/// (`OverlayLinkCursor`).
final class OverlayClickView: NSView {
    var isLink = false
    /// What a click on the panel does, at this point (AX coordinates): called on release over a link, on press
    /// over a blocker (also for a right click or a control-click there).
    var onActivate: ((CGPoint) -> Void)?
    /// A right click or a control-click on a link, at this point (AX coordinates): show the original link's
    /// context menu.
    var onContextMenu: ((CGPoint) -> Void)?
    /// A button went down or up on the panel (also when it does not activate), at this point.
    var onButton: ((CGPoint) -> Void)?
    /// The pointer moved over the panel (AX coordinates).
    var onPointerMoved: ((CGPoint) -> Void)?
    /// The pointer entered, moved over or left the panel (for the cursor and the link's hover look).
    var onPointer: ((OverlayPointerEvent) -> Void)?
    /// `simulateHover` was called.
    var onSimulatedHover: ((Bool) -> Void)?
    /// A scroll started over the panel (the panel swallowed it).
    var onScroll: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    /// A left press on a link that may finish as a click.
    private var linkPressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Not quite clear: clicks may pass through fully transparent pixels. 1/255 is invisible.
        layer?.backgroundColor = NSColor(white: 0, alpha: 1.0 / 255.0).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// AppKit never shows a menu of its own here.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onPointer?(.entered)
        reportPointer(event)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?(.moved)
        reportPointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointer?(.exited)
        reportPointer(event)
    }

    /// The link's hover look as if the pointer entered (true) or left (false) the panel, for the smoke test and
    /// the demo. Never touches the real cursor.
    func simulateHover(_ entered: Bool) {
        onSimulatedHover?(entered)
    }

    /// Forgets a press in progress (the panel changed target or went back to the pool).
    func cancelPress() {
        linkPressed = false
    }

    // Every mouse event is swallowed: none reaches the app below.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return contextClick(event) }
        let point = axPoint(event) ?? .zero
        linkPressed = false
        onButton?(point)
        if isLink {
            linkPressed = event.clickCount <= 1
        } else {
            onActivate?(point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = linkPressed
        linkPressed = false
        let point = axPoint(event) ?? .zero
        onButton?(point)
        guard pressed, isLink, !event.modifierFlags.contains(.control),
            bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        onActivate?(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        contextClick(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        // On a blocker, like the release of a left click.
        guard !isLink else { return }
        onButton?(axPoint(event) ?? .zero)
    }

    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        onScroll?()
    }

    /// A right click or control-click: the original link's menu on a link, a left click's action on a blocker.
    private func contextClick(_ event: NSEvent) {
        let point = axPoint(event) ?? .zero
        linkPressed = false
        if isLink {
            onContextMenu?(point)
        } else {
            onButton?(point)
            onActivate?(point)
        }
    }

    private func reportPointer(_ event: NSEvent) {
        guard let point = axPoint(event) else { return }
        onPointerMoved?(point)
    }

    private func axPoint(_ event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        return CoordinateSpace.axPoint(fromCocoa: window.convertPoint(toScreen: event.locationInWindow))
    }
}
