import AppKit
import os

// The pointing hand over translated links (DESIGN §6.1). The window server lets only the active app change the
// cursor, and Plamonic never activates, so its connection is allowed to set the cursor from the background
// (private SkyLight property "SetsCursorInBackground", looked up at run time). Every change goes through
// `OverlayCursorSystem`, so tests use a fake and never touch the real cursor.

/// Standard cursors the pointer may show; what the cursor goes back to after leaving a link.
enum OverlayCursorShape: CaseIterable, Sendable {
    case arrow, iBeam, iBeamVertical, pointingHand, crosshair, openHand, closedHand, operationNotAllowed
    case dragLink, dragCopy, contextualMenu, disappearingItem

    @MainActor var cursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .iBeam: .iBeam
        case .iBeamVertical: .iBeamCursorForVerticalLayout
        case .pointingHand: .pointingHand
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .operationNotAllowed: .operationNotAllowed
        case .dragLink: .dragLink
        case .dragCopy: .dragCopy
        case .contextualMenu: .contextualMenu
        case .disappearingItem: .disappearingItem
        }
    }
}

/// What the cursor logic needs from the system. `live` acts on the real cursor; tests pass a fake.
@MainActor
struct OverlayCursorSystem {
    /// Lets Plamonic set the cursor while another app is active. Called once; false when unavailable.
    var enableBackgroundCursor: () -> Bool
    /// The cursor shown now, as a standard shape; nil when it is none of them.
    var currentShape: () -> OverlayCursorShape?
    var set: (OverlayCursorShape) -> Void
    /// Number of the front-most window under the pointer that takes clicks (any app).
    var windowUnderPointer: () -> Int
    /// Runs `action` on the main actor after `delay` seconds.
    var after: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    /// A monotonic clock in seconds (the controller's waits use it too, so tests can move it).
    var now: () -> TimeInterval

    static let live = OverlayCursorSystem(
        enableBackgroundCursor: { OverlayBackgroundCursor.enable() },
        currentShape: { NSCursor.currentSystem.flatMap { OverlayCursorFingerprints.shape(of: $0) } },
        set: { $0.cursor.set() },
        windowUnderPointer: { NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) },
        after: { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { action() } }
        },
        now: { ProcessInfo.processInfo.systemUptime })
}

/// Owns the cursor while the pointer is over a translated link's click panel. Panels are identified by
/// `OverlayClickPanel.pointerNumber` (their window number once on screen).
///
/// - Entering a link panel from elsewhere remembers the cursor shown (a standard shape, else the arrow) and sets
///   the pointing hand; it is set again on every move over the panel (while the panel is the window under the
///   pointer) and once at +0.05 s and +0.2 s (the app below may set its own right after the pointer left it).
/// - Leaving onto another link panel keeps the hand (pieces of one link, neighbouring links: no flicker);
///   leaving onto anything else restores the remembered cursor, only while the hand still shows (else the app
///   has set its own already). Right after a set that changed what shows, the current cursor is not trusted
///   (the set may not show yet); a set on a move is not one (the hand shows already).
/// - `revalidate` after panels change (scroll, hide, reveal, redraw, reuse): the hand stays only while a link
///   panel is under the pointer.
/// - After a right click (`pauseForMenu`), until the next enter: no re-asserts, and leaving puts back the arrow
///   (menus show the arrow), never the cursor from before the link. `menuClosed` after Plamonic's own menu: a hand
///   that shows then goes back to the cursor from before the link, also when the hand was given up meanwhile.
/// - Blockers never change the cursor. When background setting is unavailable, the hand is still set on enter
///   and move (it shows whenever Plamonic happens to be active) but never re-asserted later.
@MainActor
final class OverlayLinkCursor {
    /// Re-asserts after entering a panel.
    static let reassertDelays: [TimeInterval] = [0.05, 0.2]
    /// A second look after the hand was kept on a change (the window server may not have applied it yet).
    static let recheckDelay: TimeInterval = 0.15
    /// A set that changes what shows may take this long to show (measured 2–11 ms); a restore right after one
    /// does not trust the current cursor.
    static let setSettleTime: TimeInterval = 0.012
    /// A second look after a menu closed (a cursor AppKit put back may not show yet).
    static let menuCloseRecheckDelay: TimeInterval = 0.05

    /// The link panel the pointer is over, as far as this knows.
    private(set) var hoveredPanel: Int?
    /// The hand was set by this and not restored yet.
    private(set) var ownsCursor = false
    /// Called when `hoveredPanel` changes.
    var onHoverChanged: (() -> Void)?

    private let system: OverlayCursorSystem
    private let isLiveLinkPanel: (Int) -> Bool
    private var remembered: OverlayCursorShape?
    /// nil = not tried yet.
    private var backgroundCursor: Bool?
    /// Delayed re-asserts and rechecks are still current only while these are unchanged.
    private var reassertGeneration = 0
    private var recheckGeneration = 0
    private var menuGeneration = 0
    /// When the last set that changed what shows was made.
    private var lastSet: TimeInterval = -.greatestFiniteMagnitude
    /// A context menu was asked for over a link and no panel was entered since: what showed before the link
    /// (never the hand), put back once the menu closed.
    private var menuBefore: OverlayCursorShape?

    init(system: OverlayCursorSystem, isLiveLinkPanel: @escaping (Int) -> Bool) {
        self.system = system
        self.isLiveLinkPanel = isLiveLinkPanel
    }

    func entered(panel: Int) {
        if backgroundCursor == nil { backgroundCursor = system.enableBackgroundCursor() }
        menuBefore = nil
        menuGeneration += 1
        var changes = false
        if !ownsCursor {
            remembered = system.currentShape()
            ownsCursor = true
            changes = remembered != .pointingHand
        }
        setHovered(panel)
        setHand(changesWhatShows: changes)
        reassertGeneration += 1
        guard backgroundCursor == true else { return }
        let current = reassertGeneration
        for delay in Self.reassertDelays {
            system.after(delay) { [weak self] in
                guard let self, self.reassertGeneration == current, self.hoveredPanel == panel,
                    self.system.windowUnderPointer() == panel
                else { return }
                // The app below may have set its own cursor since.
                self.setHand(changesWhatShows: self.system.currentShape() != .pointingHand)
            }
        }
    }

    func moved(panel: Int) {
        // An enter can be missed (a panel put under a still pointer).
        guard ownsCursor, hoveredPanel == panel else { return entered(panel: panel) }
        // Not while something covers the panel (an app's context menu), nor while a menu may be open.
        guard menuBefore == nil, system.windowUnderPointer() == panel else { return }
        // The hand shows already: reading the cursor on every move costs too much (0.3 ms, at times 9 ms).
        setHand(changesWhatShows: false)
    }

    func exited(panel: Int) {
        guard hoveredPanel == panel else { return }
        let under = system.windowUnderPointer()
        if under != panel, isLiveLinkPanel(under) {
            // Onto another link panel: it takes over before its own enter arrives.
            setHovered(under)
            scheduleRecheck()
        } else {
            setHovered(nil)
            restore()
        }
    }

    /// The pointer is on one of our panels that is not a link (a blocker).
    func pointerOnOtherPanel() {
        guard ownsCursor else { return }
        setHovered(nil)
        restore()
    }

    /// Panels changed or the pointer moved somewhere else: keeps the hand only while a link panel is under the
    /// pointer.
    func revalidate() {
        revalidate(recheck: true)
    }

    /// A context menu is about to show: pending re-asserts must not fight it.
    func pauseForMenu() {
        reassertGeneration += 1
        recheckGeneration += 1
        menuGeneration += 1
        if ownsCursor { menuBefore = Self.restorable(remembered) }
    }

    /// Plamonic's own menu closed. AppKit may put back the cursor it saved when the menu opened (the hand), also
    /// after the hand was given up while the menu was open (a scan): unless a link panel is under the pointer, a
    /// hand that shows now or a moment later goes back to what showed before the link.
    func menuClosed() {
        guard let before = menuBefore else { return revalidate() }
        menuBefore = nil
        menuGeneration += 1
        let generation = menuGeneration
        revalidate()
        putBackAfterMenu(before)
        system.after(Self.menuCloseRecheckDelay) { [weak self] in
            guard let self, self.menuGeneration == generation else { return }
            self.putBackAfterMenu(before)
        }
    }

    // MARK: - Private

    private func revalidate(recheck: Bool) {
        guard ownsCursor else { return }
        let under = system.windowUnderPointer()
        if isLiveLinkPanel(under) {
            if hoveredPanel != under {
                setHovered(under)
                if menuBefore == nil { setHand(changesWhatShows: false) }
            }
            if recheck { scheduleRecheck() }
        } else {
            setHovered(nil)
            restore()
        }
    }

    private func scheduleRecheck() {
        recheckGeneration += 1
        let current = recheckGeneration
        system.after(Self.recheckDelay) { [weak self] in
            guard let self, self.recheckGeneration == current else { return }
            self.revalidate(recheck: false)
        }
    }

    private func setHand(changesWhatShows: Bool) {
        system.set(.pointingHand)
        if changesWhatShows { lastSet = system.now() }
    }

    /// Puts back what showed before the first link panel, unless the app has set its own cursor since. While a
    /// menu may be open, the arrow (the pointer is on the menu or on its way there).
    private func restore() {
        guard ownsCursor else { return }
        ownsCursor = false
        reassertGeneration += 1
        recheckGeneration += 1
        let shape = menuBefore != nil ? OverlayCursorShape.arrow : Self.restorable(remembered)
        remembered = nil
        // A set may not show yet right after it was made.
        if system.now() - lastSet < Self.setSettleTime || system.currentShape() == .pointingHand {
            system.set(shape)
        }
    }

    private func putBackAfterMenu(_ shape: OverlayCursorShape) {
        guard !ownsCursor, !isLiveLinkPanel(system.windowUnderPointer()), system.currentShape() == .pointingHand
        else { return }
        system.set(shape)
    }

    /// A hand shown before (an original link next to ours) goes back to the arrow: a hand left over text reads
    /// as a link.
    private static func restorable(_ shape: OverlayCursorShape?) -> OverlayCursorShape {
        shape.flatMap { $0 == .pointingHand ? nil : $0 } ?? .arrow
    }

    private func setHovered(_ panel: Int?) {
        guard hoveredPanel != panel else { return }
        hoveredPanel = panel
        onHoverChanged?()
    }
}

// MARK: - Live system

/// Turns on background cursor setting for this process (DESIGN §6.1).
enum OverlayBackgroundCursor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// Sets the private connection property "SetsCursorInBackground" (SkyLight; the CGS names are aliases of the
    /// SLS ones). The symbols are looked up with dlsym and never linked. Logs why and returns false when they
    /// are missing or the call fails; the hand then shows only while Plamonic happens to be active.
    static func enable() -> Bool {
        let log = Logger(subsystem: "io.smdr.Plamonic", category: "Overlay")
        // RTLD_DEFAULT
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let mainSymbol = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "SLSMainConnectionID"),
            let setSymbol = dlsym(handle, "CGSSetConnectionProperty") ?? dlsym(handle, "SLSSetConnectionProperty")
        else {
            log.notice("Background cursor unavailable: connection symbols not found")
            return false
        }
        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnectionID.self)
        let setProperty = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        let connection = mainConnection()
        let error = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        guard error == 0 else {
            log.notice("Background cursor unavailable: setting the connection property failed (CGError \(error))")
            return false
        }
        log.notice("Background cursor on")
        return true
    }
}

/// Tells which standard cursor an `NSCursor` (the system's current one) is. A copy of the current cursor does not
/// draw back faithfully, so restoring uses the standard cursor objects only.
@MainActor
enum OverlayCursorFingerprints {
    private struct Fingerprint: Hashable {
        var size: CGSize
        var hotSpot: CGPoint
        var bitmap: Int

        func hash(into hasher: inout Hasher) {
            hasher.combine(size.width)
            hasher.combine(size.height)
            hasher.combine(hotSpot.x)
            hasher.combine(hotSpot.y)
            hasher.combine(bitmap)
        }
    }

    /// Built on first use, after the app exists (standard cursors read before that differ).
    private static var table: [Fingerprint: OverlayCursorShape]?

    static func shape(of cursor: NSCursor) -> OverlayCursorShape? {
        guard NSApp != nil, let key = fingerprint(cursor) else { return nil }
        if table == nil {
            var built: [Fingerprint: OverlayCursorShape] = [:]
            for shape in OverlayCursorShape.allCases {
                if let standard = fingerprint(shape.cursor), built[standard] == nil { built[standard] = shape }
            }
            table = built
        }
        return table?[key]
    }

    /// Size, hot spot and the bytes of the smallest bitmap.
    private static func fingerprint(_ cursor: NSCursor) -> Fingerprint? {
        let reps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }.filter { !$0.isPlanar }
        guard let rep = reps.min(by: { $0.pixelsWide < $1.pixelsWide }), let data = rep.bitmapData else { return nil }
        var hasher = Hasher()
        hasher.combine(rep.pixelsWide)
        hasher.combine(rep.pixelsHigh)
        hasher.combine(bytes: UnsafeRawBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
        return Fingerprint(size: cursor.image.size, hotSpot: cursor.hotSpot, bitmap: hasher.finalize())
    }
}
