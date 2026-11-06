import AppKit
import os

/// Draws translations over other apps' windows: one click-through panel per target window (replace style)
/// and one shared popup (hover style, selection and manual translations, and the full text of a replace-style
/// translation cut with "…").
///
/// Z-order decision: a window's panel sits directly above its target window via
/// `order(.above, relativeTo: cgWindowID)` at the target's own window level (from CGWindowList), re-asserted
/// on every `update` and when the target app activates. Windows in front of the target (other apps, the
/// target's own dialogs) therefore stay in front of the overlay, also while the target app is in the
/// background. Cross-process relative ordering was measured to work (macOS 27), but the window server applies
/// it asynchronously, so the first ordering above each target is checked in CGWindowList ~100 ms later (up to
/// three tries). Only when relative ordering is impossible (no CGWindowID, or the check failed) does the panel
/// fall back to the `.floating` level, and only while the target app is frontmost; otherwise it is hidden.
/// Panels are hidden while their target window is not on screen (closed, minimized, other Space, app hidden).
///
/// Links and the original (DESIGN §6.1): links in a translation are drawn in the original link's color, and
/// small click panels (child windows of the overlay panel, so they keep its place in the z-order; only while it
/// is checked to be directly above its target) sit over the translated links and over original links hidden
/// under translations. Resting the pointer on a translation shows its original in the popup (the default) or
/// fades just that item out; a click on a hidden original link fades the item out at once, in every mode. Right
/// after a fade-out, the item's click areas swallow clicks for a double-click interval, so the rest of a
/// double-click never presses the original.
/// While the pointer is over a translated link, the cursor is the pointing hand (`OverlayLinkCursor`) and every
/// piece of that link shows a hover look (an underline, or a stronger color when it is underlined already), drawn
/// by the canvas with the text. A right click or control-click on a translated link asks the session for the
/// original link's context menu.
@MainActor
final class OverlayController {
    /// Measures the target window's colors so overlays can match it (set by the app; nil = theme colors only).
    /// Used only while `appearance.matchBackgroundFromScreen` is on and it reports permission.
    var colorSampler: (any ScreenColorSampling)?

    /// While true (the user holds the "show original" modifier) every overlay and popup fades out.
    var revealOriginal = false {
        didSet {
            guard oldValue != revealOriginal else { return }
            for overlay in overlays.values {
                applyAlpha(overlay, duration: Self.fadeDuration)
                syncClickPanels(overlay)
            }
            updatePopupSuppression(duration: Self.fadeDuration)
            if !revealOriginal {
                // Hover state starts over once everything is back.
                cancelDwell()
                endReveal(animated: false)
            }
        }
    }

    /// Windows that currently have overlay state (shown or not).
    var activeWindows: Set<WindowKey> { Set(overlays.keys) }

    /// Some window draws a translation cut with "…". Its full text is shown in the hover popup.
    private(set) var hasTruncatedItems = false
    /// Called when `hasTruncatedItems` changes.
    var onTruncatedItemsChanged: (() -> Void)?

    /// A link drawn in a translation was clicked: the window, the item id and the original link it stands for.
    /// The session opens it (AXPress on `link.element`, or the URL). DESIGN §6.1.
    var onLinkActivated: (@MainActor (WindowKey, String, SegmentLink) -> Void)?

    /// A link drawn in a translation was right-clicked or control-clicked, at this point (AX coordinates). The
    /// session shows the original link's own context menu (AXShowMenu on `link.element`), or Plamonic's own
    /// small menu when the app has none. DESIGN §6.1.
    var onLinkContextMenu: (@MainActor (WindowKey, String, SegmentLink, CGPoint) -> Void)?

    /// Shows the item's original in place now, as a click on a hidden original link does (used by the
    /// fallback link menu's 「原文を表示」). Does nothing when the item is not drawn. The pointer is on the menu
    /// then, not on the item: until it comes onto the item, moves outside it do not bring the translation back,
    /// unless they are more than `originalWaitDistance` away or `originalWaitLimit` has passed. After that the
    /// usual rule applies (`revealLeaveDelay` outside).
    func showOriginal(window key: WindowKey, itemID: String) {
        guard let overlay = overlays[key], overlay.style.displayStyle == .replace, overlay.hasContent,
            overlay.targetOnScreen, shouldShow(overlay), overlay.hoverAreas.contains(where: { $0.id == itemID })
        else { return }
        cancelDwell()
        let hoverKey = HoverKey(window: key, id: itemID)
        lastMouseAX = nil
        reveal(hoverKey)
        guard revealed == hoverKey else { return }
        originalWait = (hoverKey, cursorSystem.now())
        revealLeaveGeneration += 1
        revealLeavePending = false
    }

    /// Checks the cursor again (the session calls it after its own link menu closed): the pointing hand stays
    /// only while the pointer is over a translated link, also when AppKit put it back as the menu closed.
    func revalidateCursor() {
        linkCursor.menuClosed()
        updateHoverLook()
    }

    /// The translated link whose pieces show the hover look, if any. For tests, the demo and the smoke test.
    var hoveredLink: (window: WindowKey, itemID: String, linkIndex: Int)? {
        hoverLook.map { (window: $0.window, itemID: $0.itemID, linkIndex: $0.linkIndex) }
    }

    /// The session must deliver mouse moves (`updateMouseLocation`) while this is true: some shown translation
    /// shows its original when the pointer rests on it, is cut with "…", or shows its original right now
    /// (the pointer leaving it ends that). DESIGN §6.1.
    private(set) var needsMouseMoves = false
    /// Called when `needsMouseMoves` changes.
    var onNeedsMouseMovesChanged: (() -> Void)?

    /// The item whose translation the hover popup shows, if any. For tests and diagnostics.
    var hoverPopupItem: (window: WindowKey, id: String)? {
        if case .hover(let key, let id) = popupOwner { return (key, id) }
        return nil
    }

    /// The item whose translation is faded out so its original shows, if any. For tests and diagnostics.
    var revealedItem: (window: WindowKey, id: String)? { revealed.map { ($0.window, $0.id) } }

    /// The revealed item whose click areas still swallow clicks (just revealed), if any. For tests and the demo.
    var guardedItem: (window: WindowKey, id: String)? { revealGuard.map { ($0.key.window, $0.key.id) } }

    /// How long the pointer rests on a cut translation drawn in place before its popup opens, so passing
    /// over it does not flash a popup.
    static let truncatedHoverDelay: TimeInterval = 0.3
    /// How long the pointer may be outside a revealed item before its translation comes back (moving to a
    /// neighbour does not flicker).
    static let revealLeaveDelay: TimeInterval = 0.15
    /// Pointer moves smaller than this (points) do not restart the rest timer.
    static let dwellSlop: CGFloat = 3
    /// How long a revealed item's click areas keep swallowing clicks after the reveal, and after each press or
    /// release on them: the system's double-click interval, so the second click of a double-click never presses
    /// an original link that just appeared under the pointer.
    static var revealGuardInterval: TimeInterval { min(max(NSEvent.doubleClickInterval, 0.3), 3) }
    /// After `showOriginal` (the pointer on the menu), moves farther than this (points) from the item end the
    /// wait for the pointer to come onto it. The menu reaches about 180 pt right of and 80 pt below the click.
    static let originalWaitDistance: CGFloat = 200
    /// After `showOriginal`, how long moves outside the item are ignored at most.
    static let originalWaitLimit: TimeInterval = 3

    /// Window numbers of this controller's panels, to exclude them from window lists and hit tests.
    var overlayWindowNumbers: Set<Int> {
        var numbers = Set(overlays.values.map(\.panel.windowNumber))
        for overlay in overlays.values { numbers.formUnion(overlay.clickPanels.map(\.windowNumber)) }
        if let popup = popupWindow { numbers.insert(popup.panel.windowNumber) }
        numbers.remove(-1)
        numbers.remove(0)
        return numbers
    }

    static let fadeDuration: TimeInterval = 0.12

    private var overlays: [WindowKey: WindowOverlay] = [:]
    private var hiddenWindows: Set<WindowKey> = []
    private var allHidden = false
    private let fitter = TextFitter()
    /// Created on first use.
    private var popupWindow: PopupWindow?
    private var popup: PopupWindow {
        if let popupWindow { return popupWindow }
        let created = PopupWindow()
        popupWindow = created
        return created
    }
    private var popupOwner: PopupOwner = .none
    private var lastMouseAX: CGPoint?
    /// When an open hover popup last checked that no window came in front of its item (moves check at most every
    /// `popupCoverageInterval`; redraws always check).
    private var lastPopupCoverageCheck: TimeInterval = -.infinity
    static let popupCoverageInterval: TimeInterval = 0.2
    /// Whether another window covers a point in front of the target window (injectable for tests).
    var isPointCovered: @MainActor (CGPoint, CGWindowID) -> Bool = { point, id in
        OverlayWindowServer.isPoint(point, coveredAbove: id, ignoringPID: getpid())
    }
    private var hoverHideGeneration = 0
    private var hoverHidePending = false
    /// The item the pointer rests on, waiting for its delay.
    private var dwell: Dwell?
    private var dwellGeneration = 0
    /// The item faded out so its original shows.
    private var revealed: HoverKey?
    private var revealLeaveGeneration = 0
    private var revealLeavePending = false
    /// Right after a reveal, the revealed item's click areas stay (all swallowing clicks) for
    /// `revealGuardInterval`; this generation tells the timer it is still the current one.
    private var revealGuard: (key: HoverKey, generation: Int)?
    private var revealGuardGeneration = 0
    /// Revealed by `showOriginal` and the pointer has not come onto the item since (clock: `cursorSystem.now`).
    private var originalWait: (key: HoverKey, since: TimeInterval)?
    /// Click panels not in use.
    private var clickPanelPool: [OverlayClickPanel] = []
    /// The pointing hand over translated links.
    private let cursorSystem: OverlayCursorSystem
    private lazy var linkCursor: OverlayLinkCursor = {
        let cursor = OverlayLinkCursor(system: cursorSystem) { [weak self] number in
            self?.liveLinkPanel(number) != nil
        }
        cursor.onHoverChanged = { [weak self] in self?.updateHoverLook() }
        return cursor
    }()
    /// `OverlayClickView.simulateHover`: the panel (and what it stood for then) that shows the hover look.
    private var simulatedHover: (number: Int, target: OverlayClickTarget)?
    /// The link the canvas draws with the hover look.
    private var hoverLook: HoveredLink?
    nonisolated(unsafe) private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let log = Logger(subsystem: "io.smdr.Plamonic", category: "Overlay")

    private enum PopupOwner: Equatable {
        case none
        /// `showPopup`; with the window it belongs to, it is hidden while that window is temporarily hidden.
        case manual(WindowKey?)
        case hover(WindowKey, String)
    }

    private struct HoverKey: Hashable {
        var window: WindowKey
        var id: String
    }

    private struct HoveredLink: Equatable {
        var window: WindowKey
        var itemID: String
        var linkIndex: Int
    }

    private struct Dwell {
        var key: HoverKey
        /// Where the pointer was when the wait (re)started.
        var anchor: CGPoint
        var generation: Int
    }

    /// What the pointer on an item does.
    private enum HoverKind {
        /// Hover display style: the translation in the popup, at once.
        case translationPopup
        /// Drawn in place but cut with "…": the full translation and the original in the popup, after a rest.
        case cut
        /// Drawn in place: the translation fades out after a rest.
        case reveal
        /// Drawn in place: the original in the popup after a rest.
        case originalPopup
    }

    private struct HoverHit {
        let overlay: WindowOverlay
        let item: OverlayItem
        let kind: HoverKind
        /// The pointer is on a translated link (about to click it).
        let onLink: Bool
        /// Window-local bounds of the item's area (original and drawn translation).
        let bounds: CGRect
    }

    convenience init() {
        self.init(cursorSystem: .live)
    }

    /// - Parameter cursorSystem: what sets the cursor over translated links (tests pass a fake).
    init(cursorSystem: OverlayCursorSystem) {
        self.cursorSystem = cursorSystem
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { controller, note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            controller.applicationDidActivate(pid: app?.processIdentifier)
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { controller, _ in
            controller.recheckTargets()
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { controller, _ in
            controller.screenParametersChanged()
        }
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    // MARK: - Per-window overlays

    /// Called by the session after every scan of a window. Cheap when nothing changed.
    /// - Parameters:
    ///   - axWindowFrame: the target window's frame (AX coordinates).
    ///   - axClipRect: visible region for translations (AX); nil = the whole window.
    ///   - cgWindowID: the target's window number; needed to keep the overlay directly above it.
    ///   - items: every segment of the window; pending/failed ones draw nothing.
    ///   - obstacles: other visible content (AX) that translations must not cover: untranslated texts, names,
    ///     buttons, terminal borders.
    ///   - targetIsFrontmost: whether the target app is the active app.
    func update(
        window key: WindowKey, axWindowFrame: CGRect, axClipRect: CGRect?, cgWindowID: CGWindowID?,
        items: [OverlayItem], obstacles: [CGRect] = [], style: OverlayStyle, targetIsFrontmost: Bool
    ) {
        let overlay = overlays[key] ?? makeOverlay(for: key)
        overlay.axWindowFrame = axWindowFrame.standardized
        overlay.axClipRect = axClipRect?.standardized
        if overlay.cgWindowID != cgWindowID { overlay.orderingFailures = 0 }
        overlay.cgWindowID = cgWindowID
        overlay.setItems(items)
        overlay.obstacles = obstacles
        overlay.style = style
        overlay.targetIsFrontmost = targetIsFrontmost
        // A scroll over a click panel took its panels away until this scan.
        overlay.clickPanelsSuppressed = false

        if let id = cgWindowID {
            let info = OverlayWindowServer.info(for: id)
            overlay.targetOnScreen = info?.isOnScreen ?? false
            overlay.targetLayer = info?.layer ?? 0
        } else {
            overlay.targetOnScreen = true
            overlay.targetLayer = 0
        }

        if style.displayStyle == .hover {
            // Nothing is drawn in place; the items only feed the hover popup.
            overlay.colorSamplingOn = false
            overlay.colorSampling.stop()
            overlay.clearContent()
            overlay.panel.orderOut(nil)
            syncClickPanels(overlay)
            refreshHover(of: key)
            noteMouseMoveNeeds()
            evaluateHover()
            return
        }

        guard overlay.targetOnScreen, overlay.axWindowFrame.width > 0, overlay.axWindowFrame.height > 0 else {
            overlay.colorSampling.pause()
            overlay.panel.orderOut(nil)
            syncClickPanels(overlay)
            refreshHover(of: key)
            noteMouseMoveNeeds()
            return
        }
        // One permission check per update: the drawing and the sampler share it.
        overlay.colorSamplingOn = isColorSamplingOn(overlay)
        updateColorSampling(overlay)
        syncFrame(overlay)
        rebuildContentIfNeeded(overlay)
        refreshHover(of: key)
        guard overlay.hasContent else {
            overlay.panel.orderOut(nil)
            syncClickPanels(overlay)
            return
        }

        if !overlay.panel.isVisible { overlay.panel.setAlpha(0, duration: 0) }
        order(overlay)
        if overlay.panel.isVisible {
            let show = shouldShow(overlay)
            overlay.panel.setAlpha(show ? 1 : 0, duration: show ? Self.fadeDuration : 0)
        }
        syncClickPanels(overlay)
    }

    /// Hides one window's overlay at once (scrolling / moving); showing it again fades in.
    func setTemporarilyHidden(_ hidden: Bool, window key: WindowKey) {
        if hidden {
            guard hiddenWindows.insert(key).inserted else { return }
            // The content moves: what rests or shows its original there starts over.
            if dwell?.key.window == key { cancelDwell() }
            if revealed?.window == key { endReveal(animated: false) }
            // A hover popup there was for the content before the move: it closes, so it never fades back in at
            // its old place. It opens again only after the pointer moves and rests.
            if case .hover(let owner, _) = popupOwner, owner == key { hidePopup() }
        } else {
            guard hiddenWindows.remove(key) != nil else { return }
        }
        if let overlay = overlays[key] {
            // No captures while the content scrolls; what moved to new places is measured once it stops.
            overlay.colorSampling.isSuspended = hidden
            if !hidden { overlay.clickPanelsSuppressed = false }
            applyAlpha(overlay, duration: hidden ? 0 : Self.fadeDuration)
            syncClickPanels(overlay)
        }
        updatePopupSuppression(duration: hidden ? 0 : Self.fadeDuration)
    }

    /// Hides every overlay and the popup at once; showing them again fades in.
    func setAllTemporarilyHidden(_ hidden: Bool) {
        guard allHidden != hidden else { return }
        allHidden = hidden
        if hidden {
            cancelDwell()
            endReveal(animated: false)
        }
        for overlay in overlays.values {
            applyAlpha(overlay, duration: hidden ? 0 : Self.fadeDuration)
            syncClickPanels(overlay)
        }
        updatePopupSuppression(duration: hidden ? 0 : Self.fadeDuration)
    }

    func remove(window key: WindowKey) {
        if hiddenWindows.remove(key) != nil, case .manual(let owner?) = popupOwner, owner == key {
            updatePopupSuppression(duration: Self.fadeDuration)
        }
        guard let overlay = overlays.removeValue(forKey: key) else { return }
        releaseClickPanels(of: overlay)
        revalidateLinkHover()
        overlay.panel.orderOut(nil)
        overlay.panel.close()
        if case .hover(let owner, _) = popupOwner, owner == key { hidePopupNow() }
        if dwell?.key.window == key { cancelDwell() }
        if revealed?.window == key { endReveal(animated: false) }
        noteMouseMoveNeeds()
    }

    func removeAll() {
        for key in Array(overlays.keys) { remove(window: key) }
        hiddenWindows.removeAll()
        hidePopup()
    }

    /// What the window's canvas currently draws (canvas coordinates). For tests and diagnostics.
    func contentItems(window key: WindowKey) -> [OverlayDrawItem] {
        overlays[key]?.canvas.items ?? []
    }

    /// The click areas of a window's drawn items (AX coordinates): translated links, then original links hidden
    /// under translations. Panels are placed over them while the overlay is shown. For tests and diagnostics.
    func clickAreas(window key: WindowKey) -> [OverlayHitArea] {
        guard let overlay = overlays[key] else { return [] }
        let origin = overlay.axWindowFrame.origin
        return overlay.hitAreas.map { area in
            var copy = area
            copy.rect = area.rect.offsetBy(dx: origin.x, dy: origin.y)
            return copy
        }
    }

    /// The click areas that have a panel right now (AX coordinates). For tests and the demo.
    func activeClickAreas(window key: WindowKey) -> [OverlayHitArea] {
        guard let overlay = overlays[key] else { return [] }
        let origin = overlay.axWindowFrame.origin
        return overlay.activeHitAreas.map { area in
            var copy = area
            copy.rect = area.rect.offsetBy(dx: origin.x, dy: origin.y)
            return copy
        }
    }

    /// Click panels placed for a window right now (links, blockers). For tests, diagnostics and the smoke test.
    func clickPanelCounts(window key: WindowKey) -> (links: Int, blockers: Int) {
        let areas = overlays[key]?.activeHitAreas ?? []
        let links = areas.filter(\.isLink).count
        return (links, areas.count - links)
    }

    /// The view that draws a window's translations (its frame is window-local). For tests and the demo.
    func canvasView(window key: WindowKey) -> OverlayCanvasView? {
        overlays[key]?.canvas
    }

    /// The click panels placed for a window (on screen only while its overlay panel is). For tests.
    func clickPanels(window key: WindowKey) -> [OverlayClickPanel] {
        overlays[key]?.clickPanels ?? []
    }

    // MARK: - Popups

    /// Shows a popup next to `nearAX` (AX coordinates), below it when there is room, otherwise above,
    /// never covering it. Used for the selection / manual / under-mouse cases. Stays until `hidePopup()`.
    /// `window`: the window the text is in; the popup is hidden while `setTemporarilyHidden` hides that window
    /// (scrolling or dragging in it).
    func showPopup(
        translation: String, original: String, state: OverlayItemState, nearAX: CGRect, style: OverlayStyle,
        window: WindowKey? = nil
    ) {
        hoverHideGeneration += 1
        hoverHidePending = false
        cancelDwell()
        popupOwner = .manual(window)
        popup.show(
            content: OverlayPopupContent(translation: translation, original: original, state: state),
            anchorAX: nearAX.standardized, appearance: style.appearance, suppressed: isPopupSuppressed,
            fitter: fitter)
    }

    func hidePopup() {
        hoverHideGeneration += 1
        hoverHidePending = false
        hidePopupNow()
    }

    /// The pointer moved (AX coordinates). Hover display style: shows the translation of the item under the
    /// mouse in a popup below (or above) the item, and hides it when the mouse leaves. Replace style: resting on
    /// a translation shows its original (DESIGN §6.1), resting on a cut one shows its full text. Ignored while a
    /// popup from `showPopup` is shown.
    func updateMouseLocation(ax point: CGPoint) {
        // Moves the global monitor sees are not over a click panel (those go to the panel): a hand left from a
        // panel whose exit never came goes now.
        linkCursor.revalidate()
        pointerMoved(ax: point)
    }

    private func pointerMoved(ax point: CGPoint) {
        let moved = lastMouseAX.map { $0 != point } ?? true
        lastMouseAX = point
        evaluateHover(moved: moved)
    }

    // MARK: - Private: overlays

    private func makeOverlay(for key: WindowKey) -> WindowOverlay {
        let overlay = WindowOverlay(key: key)
        overlay.colorSampling.onColorsChanged = { [weak self] in self?.colorsArrived(for: key) }
        overlays[key] = overlay
        return overlay
    }

    private func shouldShow(_ overlay: WindowOverlay) -> Bool {
        !revealOriginal && !allHidden && !hiddenWindows.contains(overlay.key)
    }

    private func applyAlpha(_ overlay: WindowOverlay, duration: TimeInterval) {
        guard overlay.panel.isVisible else { return }
        overlay.panel.setAlpha(shouldShow(overlay) ? 1 : 0, duration: duration)
    }

    private func syncFrame(_ overlay: WindowOverlay) {
        let frame = CoordinateSpace.cocoaRect(fromAX: overlay.axWindowFrame)
        if !overlay.panel.frame.isClose(to: frame) {
            overlay.panel.setFrame(frame, display: false)
        }
    }

    private func rebuildContentIfNeeded(_ overlay: WindowOverlay) {
        defer { noteMouseMoveNeeds() }
        guard let clip = OverlayLayout.localClip(axClipRect: overlay.axClipRect, windowAXFrame: overlay.axWindowFrame)
        else {
            overlay.clearContent()
            return
        }
        let windowFrame = overlay.axWindowFrame
        let appearance = overlay.style.appearance
        let showsLinks = overlay.style.interaction.clickableLinks
        let sampling = overlay.colorSamplingOn
        // Every item takes part, drawn or not: pending and failed ones keep their original visible, so the
        // others must stay off it.
        var inputs: [OverlayLayoutInput] = []
        var states: [String: OverlayItemState] = [:]
        var colors: [OverlayItemColors] = []
        var linksByID: [String: [OverlayDrawLink]] = [:]
        var blockerFramesByID: [String: [CGRect]] = [:]
        var signatureLinks: [[OverlayDrawLink]] = []
        var signatureBlockers: [[CGRect]] = []
        inputs.reserveCapacity(overlay.items.count)
        for item in overlay.items {
            let drawable = OverlayLayout.isDrawable(item)
            var text = drawable ? item.translation : ""
            var links: [OverlayDrawLink] = []
            if drawable, showsLinks, !item.links.isEmpty {
                // Break opportunities inside link runs are part of what is measured and drawn.
                (text, links) = OverlayLinkText.styled(item)
                if !links.isEmpty { linksByID[item.id] = links }
            }
            let blockers = drawable && showsLinks ? item.originalLinks.flatMap(\.frames) : []
            if !blockers.isEmpty { blockerFramesByID[item.id] = blockers }
            signatureLinks.append(links)
            signatureBlockers.append(blockers.map { OverlayLayout.localRect($0, windowAXFrame: windowFrame) })
            inputs.append(
                OverlayLayoutInput(
                    id: item.id, text: text,
                    frame: OverlayLayout.localRect(item.axFrame, windowAXFrame: windowFrame),
                    lineFrames: item.lineFrames.map { OverlayLayout.localRect($0, windowAXFrame: windowFrame) },
                    style: item.style, drawable: drawable))
            states[item.id] = item.state
            let nonLinkText =
                sampling && Self.hasLinks(item)
                ? overlay.colorSampling.colors(for: Self.nonLinkSampleID(item.id))?.text : nil
            colors.append(
                drawable
                    ? Self.itemColors(
                        item, sampled: sampling ? overlay.colorSampling.colors(for: item.id) : nil,
                        nonLinkText: nonLinkText, appearance: appearance)
                    : OverlayItemColors())
        }
        // Content that stays as it is takes part like a pending item: nothing is drawn over it.
        for (i, obstacle) in overlay.obstacles.enumerated() {
            inputs.append(
                OverlayLayoutInput(
                    id: "obstacle-\(i)", text: "", frame: OverlayLayout.localRect(obstacle, windowAXFrame: windowFrame),
                    drawable: false))
            colors.append(OverlayItemColors())
        }
        let signature = ContentSignature(
            clip: clip, inputs: inputs, states: overlay.items.map(\.state), colors: colors, appearance: appearance,
            links: signatureLinks, blockers: signatureBlockers)
        guard signature != overlay.signature else { return }
        // State swaps in place (draft -> final) and newly measured colors crossfade; streaming text, moves
        // and scrolls redraw at once.
        let crossfade = overlay.signature?.isRestyle(to: signature) ?? false
        // Where each item may draw depends only on the geometry; streaming text reuses it.
        let sameGeometry = overlay.signature?.hasSameGeometry(as: signature) ?? false
        if !sameGeometry || overlay.regions == nil {
            overlay.regions = OverlayLayout.regions(
                for: inputs, clip: clip, widensLabels: appearance.matchOriginalStyle)
        }
        overlay.signature = signature

        let layouts = OverlayLayout.drawOrder(
            OverlayLayout.layoutWindow(
                inputs, clip: clip, appearance: appearance, fitter: fitter, regions: overlay.regions))
        overlay.truncatedIDs = Set(layouts.lazy.filter { $0.stage == .truncated }.map(\.id))
        let canvasRect = OverlayLayout.canvasRect(for: layouts, clip: clip)
        guard !canvasRect.isNull else {
            overlay.clearContent(keepSignature: true)
            return
        }
        if overlay.canvas.frame != canvasRect { overlay.canvas.frame = canvasRect }
        var colorByID: [String: OverlayItemColors] = [:]
        var inputByID: [String: OverlayLayoutInput] = [:]
        for (input, color) in zip(inputs, colors) where input.drawable {
            colorByID[input.id] = color
            inputByID[input.id] = input
        }
        var drawItems: [OverlayDrawItem] = []
        var hitItems: [OverlayHitAreas.Item] = []
        var hoverAreas: [WindowOverlay.HoverArea] = []
        drawItems.reserveCapacity(layouts.count)
        for layout in layouts {
            var text = inputByID[layout.id]?.text ?? ""
            var drawLinks: [OverlayDrawLink] = []
            var linkRects: [(linkIndex: Int, rects: [CGRect])] = []
            if let links = linksByID[layout.id] {
                let prepared = OverlayLinkText.prepare(
                    text, links: links, fontSize: layout.fontSize, look: layout.look, size: layout.textRect.size)
                text = prepared.text
                drawLinks = prepared.links
                let origin = layout.textRect.origin
                linkRects = zip(prepared.links, prepared.linkRects).map { link, rects in
                    (link.linkIndex, rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) })
                }
            }
            let blockers = blockerFramesByID[layout.id] ?? []
            if !linkRects.isEmpty || !blockers.isEmpty {
                hitItems.append(
                    OverlayHitAreas.Item(id: layout.id, layout: layout, links: linkRects, originalLinkFrames: blockers))
            }
            // The pointer is "on" an item over its drawn background and over its original text.
            var rects = layout.background.rows.map { $0.intersection(clip) }.filter { !$0.isNull && !$0.isEmpty }
            if let input = inputByID[layout.id], let (area, _) = OverlayLayout.originalArea(of: input) {
                let visible = area.intersection(clip)
                if !visible.isNull, !visible.isEmpty { rects.append(visible) }
            }
            if let first = rects.first {
                hoverAreas.append(
                    WindowOverlay.HoverArea(
                        id: layout.id, rects: rects, bounds: rects.dropFirst().reduce(first) { $0.union($1) }))
            }
            let local = layout.offsetBy(dx: -canvasRect.minX, dy: -canvasRect.minY)
            let state = states[layout.id] ?? .final
            drawItems.append(
                OverlayDrawItem(
                    layout: local, text: text, state: state, colors: colorByID[layout.id] ?? OverlayItemColors(),
                    indicatorCenter: state == .draft && appearance.showStateIndicator
                        ? OverlayLayout.indicatorCenter(for: local, text: text, fitter: fitter) : nil,
                    links: drawLinks))
        }
        let hit = OverlayHitAreas.compute(hitItems, windowAXFrame: windowFrame, clip: clip)
        let overLimit = OverlayHitAreas.OverLimit(merged: hit.merged, unprotected: hit.unprotected)
        if overLimit != overlay.hitAreasOverLimit {
            overlay.hitAreasOverLimit = overLimit
            if hit.merged > 0 || hit.unprotected > 0 {
                log.notice(
                    "Window \(overlay.key.description, privacy: .public): over \(OverlayHitAreas.maximumPerWindow) click areas; links of \(hit.merged) items not clickable, \(hit.unprotected) items without click areas"
                )
            }
        }
        overlay.hitAreas = hit.areas
        overlay.hoverAreas = hoverAreas
        overlay.allDrawItems = drawItems
        overlay.hasContent = true
        if let key = revealed, key.window == overlay.key, !hoverAreas.contains(where: { $0.id == key.id }) {
            // The revealed item is no longer drawn: nothing to bring back.
            revealed = nil
            revealLeaveGeneration += 1
            revealLeavePending = false
            clearRevealGuard()
        }
        applyCanvas(overlay, crossfade: crossfade ? OverlayCanvasView.crossfadeDuration : nil)
    }

    /// Colors of one drawn item. In a paragraph with links only the links may take link colors (DESIGN §6.1),
    /// but the most common color measured over a paragraph with a long link can be the link's. So there:
    /// - the original's own (non-link) text color wins when the original's look is matched;
    /// - else the color measured where there is no link (`nonLinkText`);
    /// - else the color measured over the whole paragraph only when it is the original's non-link color, or, when
    ///   that is unknown, when link colors are known and it is none of them;
    /// - else the theme's text color.
    nonisolated static func itemColors(
        _ item: OverlayItem, sampled: SampledColors?, nonLinkText: RGBAColor? = nil, appearance: OverlayAppearance
    ) -> OverlayItemColors {
        let reported = item.style.textColor
        let original = appearance.matchOriginalStyle ? reported : nil
        guard hasLinks(item), var measured = sampled else {
            return OverlayItemColors(sampled: sampled, originalText: original)
        }
        if original != nil {
            measured.text = nil
        } else if let nonLinkText {
            measured.text = nonLinkText
        } else if let text = measured.text {
            let linkColors = item.originalLinks.compactMap(\.color)
            let usable: Bool
            if let reported {
                usable = OverlayPalette.isClose(text, reported)
            } else {
                usable = !linkColors.isEmpty && !linkColors.contains { OverlayPalette.isClose($0, text) }
            }
            if !usable { measured.text = nil }
        }
        return OverlayItemColors(sampled: measured, originalText: original)
    }

    /// The item's original has links (recorded, or link runs the app marks in a native text view), so a color
    /// measured over all of it may be a link's.
    nonisolated static func hasLinks(_ item: OverlayItem) -> Bool {
        !item.originalLinks.isEmpty || item.style.hasLinkRuns
    }

    /// Sample id of the part of an item's original outside its links (only its text color is used).
    nonisolated static func nonLinkSampleID(_ id: String) -> String {
        id + "\u{1F}text"
    }

    /// Kept between a link and the piece measured for the text around it (the sampler looks 2 pt around a rect).
    nonisolated static let nonLinkSampleGap: CGFloat = 3
    /// Narrower pieces of text outside the links are not measured.
    nonisolated static let minimumNonLinkSampleWidth: CGFloat = 8

    /// The largest piece of the item's visible original lines with no link on it (AX), or nil. Links take
    /// their line's full height; pieces keep `nonLinkSampleGap` away from them.
    nonisolated static func nonLinkSampleRect(_ item: OverlayItem, visible: CGRect) -> CGRect? {
        let linkFrames = item.originalLinks.flatMap(\.frames).map(\.standardized).filter { !$0.isNull && !$0.isEmpty }
        let lines = item.lineFrames.isEmpty ? [item.axFrame] : item.lineFrames
        var best: CGRect?
        for frame in lines {
            let line = frame.standardized.intersection(visible)
            guard !line.isNull, line.height >= OverlayLayout.minimumItemSide else { continue }
            let holes = linkFrames.compactMap { link -> CGRect? in
                // Only links mostly on this line (not ones on a neighbour that touch it).
                let shared = min(link.maxY, line.maxY) - max(link.minY, line.minY)
                guard shared > min(link.height, line.height) * 0.3 else { return nil }
                return CGRect(
                    x: link.minX - nonLinkSampleGap, y: line.minY, width: link.width + nonLinkSampleGap * 2,
                    height: line.height)
            }
            for piece in OverlayHitAreas.subtract(holes, from: line) where piece.width >= minimumNonLinkSampleWidth {
                if let current = best, current.width * current.height >= piece.width * piece.height { continue }
                best = piece
            }
        }
        return best
    }

    /// Hands the canvas what it draws: every laid-out item except a revealed one, the hovered link with its
    /// hover look.
    private func applyCanvas(_ overlay: WindowOverlay, crossfade: TimeInterval?) {
        let hidden = revealed.flatMap { $0.window == overlay.key ? $0.id : nil }
        var items = hidden.map { id in overlay.allDrawItems.filter { $0.layout.id != id } } ?? overlay.allDrawItems
        if let look = hoverLook, look.window == overlay.key,
            let index = items.firstIndex(where: { $0.layout.id == look.itemID })
        {
            items[index].hoveredLink = look.linkIndex
        }
        overlay.canvas.setContent(
            items, appearance: overlay.style.appearance, crossfade: crossfade != nil,
            duration: crossfade ?? OverlayCanvasView.crossfadeDuration)
    }

    // MARK: - Private: colors from the screen

    /// Asks the sampler for the permission (the setting and the window are checked first, so windows that
    /// do not sample never ask). Called once per `update`; the result is kept in `colorSamplingOn`.
    private func isColorSamplingOn(_ overlay: WindowOverlay) -> Bool {
        guard overlay.style.displayStyle == .replace, overlay.style.appearance.matchBackgroundFromScreen,
            overlay.cgWindowID != nil, let sampler = colorSampler
        else { return false }
        return sampler.isAuthorized
    }

    /// Tells the window's sampler what to measure. The sampler itself decides when (debounced, only for
    /// items in new places), so this is cheap on every update.
    private func updateColorSampling(_ overlay: WindowOverlay) {
        guard overlay.colorSamplingOn, let sampler = colorSampler, let windowID = overlay.cgWindowID else {
            overlay.colorSampling.stop()
            return
        }
        let targets = Self.colorSampleTargets(
            items: overlay.items, axClipRect: overlay.axClipRect, axWindowFrame: overlay.axWindowFrame)
        overlay.colorSampling.isSuspended = hiddenWindows.contains(overlay.key)
        overlay.colorSampling.update(targets: targets, windowID: windowID, sampler: sampler)
    }

    /// What to measure in one window: the visible original text of every item that is or may soon be drawn
    /// (pending ones too, so their colors are ready when the translation arrives). An item with links also has
    /// its text outside the links measured (`nonLinkSampleID`), for the text color of its translation.
    /// AX coordinates.
    nonisolated static func colorSampleTargets(
        items: [OverlayItem], axClipRect: CGRect?, axWindowFrame: CGRect
    ) -> [String: OverlayColorSampleScheduler.Target] {
        let window = axWindowFrame.standardized
        let clip = (axClipRect?.standardized ?? window).intersection(window)
        guard !clip.isNull else { return [:] }
        // Whole points: frames that jitter by fractions of a point between scans are not measured again.
        func rounded(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
        }
        var targets: [String: OverlayColorSampleScheduler.Target] = [:]
        for item in items where item.state != .failed {
            let input = OverlayLayoutInput(id: item.id, text: "", frame: item.axFrame, lineFrames: item.lineFrames)
            guard let (area, _) = OverlayLayout.originalArea(of: input) else { continue }
            let visible = area.intersection(clip)
            guard !visible.isNull, visible.width >= OverlayLayout.minimumItemSide,
                visible.height >= OverlayLayout.minimumItemSide
            else { continue }
            targets[item.id] = OverlayColorSampleScheduler.Target(axRect: rounded(visible), original: item.original)
            // Only recorded links have rects to keep the piece away from.
            if !item.originalLinks.isEmpty, let piece = nonLinkSampleRect(item, visible: visible) {
                targets[nonLinkSampleID(item.id)] = OverlayColorSampleScheduler.Target(
                    axRect: rounded(piece), original: item.original, isNonLinkText: true)
            }
        }
        return targets
    }

    private func colorsArrived(for key: WindowKey) {
        guard let overlay = overlays[key], overlay.style.displayStyle == .replace, overlay.targetOnScreen,
            overlay.hasContent
        else { return }
        rebuildContentIfNeeded(overlay)
        refreshHover(of: key)
        syncClickPanels(overlay)
    }

    private func order(_ overlay: WindowOverlay) {
        let panel = overlay.panel
        guard let id = overlay.cgWindowID, overlay.failedTarget != id else {
            orderFallback(overlay)
            return
        }
        let level = NSWindow.Level(rawValue: overlay.targetLayer)
        if panel.level != level { panel.level = level }
        panel.order(.above, relativeTo: Int(id))
        scheduleOrderingCheck(overlay, target: id)
    }

    /// The window server applies ordering at the end of the run-loop turn, so the check runs a little later.
    private func scheduleOrderingCheck(_ overlay: WindowOverlay, target id: CGWindowID) {
        guard overlay.verifiedTarget != id, overlay.failedTarget != id, !overlay.orderingCheckPending else { return }
        overlay.orderingCheckPending = true
        let key = overlay.key
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, let overlay = self.overlays[key] else { return }
            overlay.orderingCheckPending = false
            self.checkOrdering(overlay, target: id)
        }
    }

    private func checkOrdering(_ overlay: WindowOverlay, target id: CGWindowID) {
        guard overlay.cgWindowID == id, overlay.panel.isVisible, overlay.verifiedTarget != id,
            overlay.failedTarget != id, OverlayWindowServer.info(for: id)?.isOnScreen == true
        else { return }
        if OverlayWindowServer.isOrdered(
            panelNumber: overlay.panel.windowNumber, directlyAbove: id, targetPID: overlay.key.pid)
        {
            overlay.verifiedTarget = id
            overlay.orderingFailures = 0
            // Click panels go on screen only now (they must never float above other windows).
            syncClickPanels(overlay)
            return
        }
        // The target may have been raised in between (activation, click); retry before giving up.
        overlay.orderingFailures += 1
        if overlay.orderingFailures < 3 {
            overlay.panel.order(.above, relativeTo: Int(id))
            scheduleOrderingCheck(overlay, target: id)
        } else {
            overlay.failedTarget = id
            log.notice("Relative ordering above window \(id) failed; using the floating fallback")
            orderFallback(overlay)
            syncClickPanels(overlay)
        }
    }

    private func orderFallback(_ overlay: WindowOverlay) {
        if overlay.targetIsFrontmost {
            if overlay.panel.level != .floating { overlay.panel.level = .floating }
            overlay.panel.orderFrontRegardless()
        } else {
            overlay.panel.orderOut(nil)
        }
    }

    private func usesRelativeOrdering(_ overlay: WindowOverlay) -> Bool {
        guard let id = overlay.cgWindowID else { return false }
        return overlay.failedTarget != id
    }

    private func applicationDidActivate(pid: pid_t?) {
        // Popups float above everything; they belong to the app that was active.
        hidePopup()
        for overlay in overlays.values {
            overlay.targetIsFrontmost = overlay.key.pid == pid
            guard overlay.style.displayStyle == .replace, overlay.hasContent, overlay.targetOnScreen else { continue }
            if usesRelativeOrdering(overlay) {
                // The activated app's windows were just raised above our panels.
                guard overlay.key.pid == pid, overlay.panel.isVisible else { continue }
                reassertOrder(overlay)
                let key = overlay.key
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self, let overlay = self.overlays[key] else { return }
                    self.reassertOrder(overlay)
                }
            } else if overlay.targetIsFrontmost {
                if !overlay.panel.isVisible { overlay.panel.setAlpha(0, duration: 0) }
                orderFallback(overlay)
                applyAlpha(overlay, duration: Self.fadeDuration)
            } else {
                overlay.panel.orderOut(nil)
            }
            syncClickPanels(overlay)
        }
    }

    private func reassertOrder(_ overlay: WindowOverlay) {
        guard overlay.panel.isVisible, let id = overlay.cgWindowID, usesRelativeOrdering(overlay) else { return }
        overlay.panel.order(.above, relativeTo: Int(id))
    }

    private func recheckTargets() {
        for overlay in overlays.values {
            guard let id = overlay.cgWindowID else { continue }
            let onScreen = OverlayWindowServer.info(for: id)?.isOnScreen ?? false
            overlay.targetOnScreen = onScreen
            if !onScreen {
                overlay.panel.orderOut(nil)
                if revealed?.window == overlay.key { endReveal(animated: false) }
            }
            syncClickPanels(overlay)
        }
        noteMouseMoveNeeds()
        evaluateHover()
    }

    private func screenParametersChanged() {
        for overlay in overlays.values where overlay.axWindowFrame.width > 0 {
            syncFrame(overlay)
            syncClickPanels(overlay)
        }
        hidePopup()
    }

    // MARK: - Private: click panels

    /// Panels go over the click areas only while the item is drawn and shown: replace style with links on, the
    /// window shown (not scrolling, not hidden, the original not shown). A revealed item keeps its areas only
    /// right after the reveal (`revealGuard`), and then they only swallow clicks.
    private func wantsClickPanels(_ overlay: WindowOverlay) -> Bool {
        overlay.style.displayStyle == .replace && overlay.style.interaction.clickableLinks && overlay.hasContent
            && overlay.targetOnScreen && shouldShow(overlay) && !overlay.clickPanelsSuppressed
    }

    /// Click panels are on screen only while the overlay panel is, ordered directly above its target and
    /// checked to be there. In the floating fallback they would sit above every normal window, also above
    /// windows in front of the target, so there links are drawn but not clickable and clicks pass through.
    private func placesClickPanelsOnScreen(_ overlay: WindowOverlay) -> Bool {
        guard overlay.panel.isVisible, let id = overlay.cgWindowID, usesRelativeOrdering(overlay) else { return false }
        return overlay.verifiedTarget == id
    }

    /// Places (or takes away) the window's click panels to match its click areas and its overlay panel. Panels
    /// are children of the overlay panel while it is on screen, so they move with it in the z-order.
    private func syncClickPanels(_ overlay: WindowOverlay) {
        // A hovered panel may have gone, moved or changed target (no exit comes then).
        defer { revalidateLinkHover() }
        var wanted: [OverlayHitArea] = []
        if wantsClickPanels(overlay) {
            let hidden = revealed.flatMap { $0.window == overlay.key ? $0.id : nil }
            let guarded = hidden != nil && revealGuard?.key == revealed
            for area in overlay.hitAreas {
                guard area.itemID == hidden else {
                    wanted.append(area)
                    continue
                }
                // Its original shows: just after the reveal every area only swallows clicks, then none is left.
                guard guarded else { continue }
                var copy = area
                copy.kind = .blocker
                wanted.append(copy)
            }
        }
        overlay.activeHitAreas = wanted
        let origin = overlay.axWindowFrame.origin
        let frames = wanted.map { CoordinateSpace.cocoaRect(fromAX: $0.rect.offsetBy(dx: origin.x, dy: origin.y)) }
        let targets = wanted.map { OverlayClickTarget(window: overlay.key, itemID: $0.itemID, kind: $0.kind) }
        // A panel keeps its area when it still has one (a press on it finishes there), else its target.
        var free = overlay.clickPanels
        var assigned = [OverlayClickPanel?](repeating: nil, count: wanted.count)
        for i in wanted.indices {
            if let j = free.firstIndex(where: { $0.target == targets[i] && $0.frame.isClose(to: frames[i], tolerance: 0.25) }) {
                assigned[i] = free.remove(at: j)
            }
        }
        for i in wanted.indices where assigned[i] == nil {
            if let j = free.firstIndex(where: { $0.target == targets[i] }) { assigned[i] = free.remove(at: j) }
        }
        for i in wanted.indices where assigned[i] == nil {
            assigned[i] = free.isEmpty ? dequeueClickPanel() : free.removeFirst()
        }
        for panel in free { recycle(panel) }
        overlay.clickPanels = assigned.compactMap { $0 }
        guard !wanted.isEmpty else { return }
        let onScreen = placesClickPanelsOnScreen(overlay)
        for (i, panel) in overlay.clickPanels.enumerated() {
            panel.setTarget(targets[i])
            let frame = frames[i]
            if !panel.frame.isClose(to: frame, tolerance: 0.25) { panel.setFrame(frame, display: false) }
            if onScreen {
                if panel.level != overlay.panel.level { panel.level = overlay.panel.level }
                if panel.parent !== overlay.panel {
                    panel.parent?.removeChildWindow(panel)
                    overlay.panel.addChildWindow(panel, ordered: .above)
                }
                if !panel.isVisible { panel.order(.above, relativeTo: overlay.panel.windowNumber) }
            } else {
                detach(panel)
            }
        }
    }

    private func releaseClickPanels(of overlay: WindowOverlay) {
        overlay.activeHitAreas = []
        for panel in overlay.clickPanels { recycle(panel) }
        overlay.clickPanels = []
    }

    private func detach(_ panel: OverlayClickPanel) {
        panel.parent?.removeChildWindow(panel)
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func recycle(_ panel: OverlayClickPanel) {
        detach(panel)
        panel.clearTarget()
        if clickPanelPool.count < 32 {
            clickPanelPool.append(panel)
        } else {
            panel.close()
        }
    }

    private func dequeueClickPanel() -> OverlayClickPanel {
        if let panel = clickPanelPool.popLast() { return panel }
        let panel = OverlayClickPanel()
        panel.clickView.onActivate = { [weak self, weak panel] point in
            guard let self, let target = panel?.target else { return }
            self.clicked(target, at: point)
        }
        panel.clickView.onButton = { [weak self, weak panel] _ in
            guard let self, let target = panel?.target else { return }
            self.buttonChanged(on: target)
        }
        panel.clickView.onContextMenu = { [weak self, weak panel] point in
            guard let self, let target = panel?.target else { return }
            self.contextMenu(on: target, at: point)
        }
        panel.clickView.onPointerMoved = { [weak self] point in self?.pointerMoved(ax: point) }
        panel.clickView.onPointer = { [weak self, weak panel] event in
            guard let self, let panel else { return }
            self.pointerEvent(event, on: panel)
        }
        panel.clickView.onSimulatedHover = { [weak self, weak panel] entered in
            guard let self, let panel else { return }
            self.simulateHover(entered, on: panel)
        }
        panel.clickView.onScroll = { [weak self, weak panel] in
            guard let self, let key = panel?.target?.window else { return }
            self.scrolledOverClickPanel(window: key)
        }
        return panel
    }

    /// A right click or control-click on a panel: on a translated link the session shows the original link's
    /// context menu; on a hidden original link it is a click. Nothing on a revealed item (the rest of a
    /// double-click lands there).
    private func contextMenu(on target: OverlayClickTarget, at point: CGPoint) {
        guard case .link(let index) = target.kind else { return clicked(target, at: point) }
        guard let overlay = overlays[target.window], let item = overlay.item(id: target.itemID) else { return }
        cancelDwell()
        // The app's menu opens here: a hover popup must not stay beside or under it. The next move on the link
        // does not open it again (no popup over links).
        if case .hover = popupOwner { hidePopup() }
        let key = HoverKey(window: target.window, id: target.itemID)
        guard revealed != key, revealGuard?.key != key, item.originalLinks.indices.contains(index) else { return }
        // The menu sets its own cursor; pending re-asserts must not fight it.
        linkCursor.pauseForMenu()
        onLinkContextMenu?(target.window, target.itemID, item.originalLinks[index], point)
    }

    // MARK: - Private: links under the pointer

    /// The pointer entered, moved over or left a click panel: the hand over links, nothing over blockers.
    private func pointerEvent(_ event: OverlayPointerEvent, on panel: OverlayClickPanel) {
        let number = panel.pointerNumber
        switch event {
        case .entered where panel.isLinkPanel:
            linkCursor.entered(panel: number)
        case .moved where panel.isLinkPanel:
            linkCursor.moved(panel: number)
        case .entered, .moved:
            linkCursor.pointerOnOtherPanel()
        case .exited:
            linkCursor.exited(panel: number)
        }
    }

    private func simulateHover(_ entered: Bool, on panel: OverlayClickPanel) {
        if entered {
            guard panel.isLinkPanel, let target = panel.target else { return }
            simulatedHover = (panel.pointerNumber, target)
        } else if simulatedHover?.number == panel.pointerNumber {
            simulatedHover = nil
        }
        updateHoverLook()
    }

    /// A click panel of a translated link that is in use and on screen (panels never on screen, which only a
    /// fake hit test can name, count too).
    private func liveLinkPanel(_ number: Int) -> OverlayClickPanel? {
        guard number != 0 else { return nil }
        for overlay in overlays.values {
            guard let panel = overlay.clickPanels.first(where: { $0.pointerNumber == number }) else { continue }
            return panel.isLinkPanel && (panel.isVisible || panel.windowNumber <= 0) ? panel : nil
        }
        return nil
    }

    private func revalidateLinkHover() {
        linkCursor.revalidate()
        updateHoverLook()
    }

    /// Redraws the items whose hover look changed: the link of the hovered panel (simulated first), if it still
    /// stands for one.
    private func updateHoverLook() {
        if let simulated = simulatedHover, liveLinkPanel(simulated.number)?.target != simulated.target {
            simulatedHover = nil
        }
        var look: HoveredLink?
        if let number = simulatedHover?.number ?? linkCursor.hoveredPanel,
            let target = liveLinkPanel(number)?.target, case .link(let index) = target.kind
        {
            look = HoveredLink(window: target.window, itemID: target.itemID, linkIndex: index)
        }
        guard look != hoverLook else { return }
        let previous = hoverLook
        hoverLook = look
        for key in Set([previous?.window, look?.window].compactMap { $0 }) {
            if let overlay = overlays[key] { applyCanvas(overlay, crossfade: nil) }
        }
    }

    /// A click on a panel: a translated link opens the original link; an original link under a translation
    /// is kept from the click, and the item shows its original at once. A click on a just revealed item's
    /// areas (the rest of a double-click) does nothing.
    private func clicked(_ target: OverlayClickTarget, at point: CGPoint) {
        guard let overlay = overlays[target.window], let item = overlay.item(id: target.itemID) else { return }
        cancelDwell()
        let key = HoverKey(window: target.window, id: target.itemID)
        switch target.kind {
        case .link(let index):
            guard revealed != key, item.originalLinks.indices.contains(index) else { return }
            onLinkActivated?(target.window, target.itemID, item.originalLinks[index])
        case .blocker:
            lastMouseAX = point
            if revealed != key { reveal(key) }
        }
    }

    /// The left button went down or up on a panel: on a just revealed item, its areas stay a little longer.
    private func buttonChanged(on target: OverlayClickTarget) {
        let key = HoverKey(window: target.window, id: target.itemID)
        guard revealGuard?.key == key, revealed == key else { return }
        armRevealGuard(key)
    }

    /// The panel swallowed a scroll meant for the app below: the window's panels go until its next scan, so
    /// the rest of the scroll reaches the app.
    private func scrolledOverClickPanel(window key: WindowKey) {
        guard let overlay = overlays[key] else { return }
        cancelDwell()
        overlay.clickPanelsSuppressed = true
        syncClickPanels(overlay)
    }

    // MARK: - Private: the original in place

    private func reveal(_ key: HoverKey) {
        guard let overlay = overlays[key.window], overlay.hoverAreas.contains(where: { $0.id == key.id }) else {
            return
        }
        if revealed == key { return }
        if revealed != nil { endReveal(animated: true) }
        revealed = key
        cancelDwell()
        if case .hover(let owner, let id) = popupOwner, owner == key.window, id == key.id { hidePopupNow() }
        // The original shows at once, but its links take clicks only after a double-click interval.
        armRevealGuard(key)
        applyCanvas(overlay, crossfade: Self.fadeDuration)
        syncClickPanels(overlay)
        noteMouseMoveNeeds()
        if let point = lastMouseAX { checkRevealLeave(point) }
    }

    private func endReveal(animated: Bool) {
        guard let key = revealed else { return }
        revealed = nil
        originalWait = nil
        revealLeaveGeneration += 1
        revealLeavePending = false
        clearRevealGuard()
        if let overlay = overlays[key.window] {
            applyCanvas(overlay, crossfade: animated ? Self.fadeDuration : nil)
            syncClickPanels(overlay)
        }
        noteMouseMoveNeeds()
    }

    /// Keeps the revealed item's click areas (swallowing clicks) for `revealGuardInterval` from now.
    private func armRevealGuard(_ key: HoverKey) {
        revealGuardGeneration += 1
        let generation = revealGuardGeneration
        revealGuard = (key, generation)
        let delay = Self.revealGuardInterval
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.revealGuard?.generation == generation else { return }
            self.revealGuard = nil
            if let overlay = self.overlays[key.window] { self.syncClickPanels(overlay) }
        }
    }

    private func clearRevealGuard() {
        revealGuard = nil
        revealGuardGeneration += 1
    }

    /// The revealed item stays while the pointer is on its original or where its translation was drawn; after
    /// `revealLeaveDelay` outside, the translation comes back. Revealed from the menu (`showOriginal`): points
    /// outside count only once the pointer was on the item, is far from it, or the wait is long over.
    private func checkRevealLeave(_ point: CGPoint) {
        guard let key = revealed else { return }
        guard let inside = isInsideRevealed(point) else {
            endReveal(animated: false)
            return
        }
        if inside {
            originalWait = nil
            revealLeaveGeneration += 1
            revealLeavePending = false
            return
        }
        if let wait = originalWait, wait.key == key {
            let distance = distanceToRevealed(point) ?? .infinity
            if distance <= Self.originalWaitDistance, cursorSystem.now() - wait.since < Self.originalWaitLimit {
                return
            }
            originalWait = nil
        }
        guard !revealLeavePending else { return }
        revealLeavePending = true
        revealLeaveGeneration += 1
        let generation = revealLeaveGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.revealLeaveDelay * 1_000_000_000))
            guard let self, self.revealLeaveGeneration == generation, self.revealed == key else { return }
            self.revealLeavePending = false
            if let point = self.lastMouseAX, self.isInsideRevealed(point) == true { return }
            self.endReveal(animated: true)
        }
    }

    /// nil when the revealed item is gone.
    private func isInsideRevealed(_ point: CGPoint) -> Bool? {
        guard let key = revealed, let overlay = overlays[key.window],
            let area = overlay.hoverAreas.first(where: { $0.id == key.id })
        else { return nil }
        let local = CGPoint(x: point.x - overlay.axWindowFrame.minX, y: point.y - overlay.axWindowFrame.minY)
        return area.bounds.contains(local) && area.rects.contains { $0.contains(local) }
    }

    /// Points from `point` to the revealed item's area; nil when it is gone.
    private func distanceToRevealed(_ point: CGPoint) -> CGFloat? {
        guard let key = revealed, let overlay = overlays[key.window],
            let area = overlay.hoverAreas.first(where: { $0.id == key.id })
        else { return nil }
        let local = CGPoint(x: point.x - overlay.axWindowFrame.minX, y: point.y - overlay.axWindowFrame.minY)
        let dx = max(area.bounds.minX - local.x, 0, local.x - area.bounds.maxX)
        let dy = max(area.bounds.minY - local.y, 0, local.y - area.bounds.maxY)
        return hypot(dx, dy)
    }

    // MARK: - Private: popups and hover

    private var isPopupSuppressed: Bool {
        if revealOriginal || allHidden { return true }
        switch popupOwner {
        case .hover(let owner, _), .manual(let owner?): return hiddenWindows.contains(owner)
        case .manual(nil), .none: return false
        }
    }

    private func updatePopupSuppression(duration: TimeInterval) {
        popupWindow?.setSuppressed(isPopupSuppressed, duration: duration)
    }

    private func hidePopupNow() {
        popupOwner = .none
        popupWindow?.hide()
    }

    private func cancelDwell() {
        dwell = nil
    }

    /// Reacts to the pointer at `lastMouseAX`. Only a move (`moved`) starts a wait: content that scrolls or is
    /// redrawn under a still pointer shows nothing. `afterDwell`: the wait with that generation ended.
    private func evaluateHover(moved: Bool = false, afterDwell: Int? = nil) {
        guard let point = lastMouseAX else { return }
        checkRevealLeave(point)
        if case .manual = popupOwner {
            cancelDwell()
            return
        }
        guard let hit = hoverHit(at: point) else {
            cancelDwell()
            if case .hover = popupOwner { scheduleHoverHide() }
            return
        }
        let key = HoverKey(window: hit.overlay.key, id: hit.item.id)
        let owner = PopupOwner.hover(hit.overlay.key, hit.item.id)
        if hit.kind == .translationPopup {
            cancelDwell()
            hoverHideGeneration += 1
            hoverHidePending = false
            if owner != popupOwner, let id = hit.overlay.cgWindowID, isPointCovered(point, id) {
                // Another window is in front of the target here.
                if case .hover = popupOwner { hidePopupNow() }
                return
            }
            showHoverPopup(hit, owner: owner)
            return
        }
        if owner == popupOwner {
            // Its popup is open: it stays, following the item's text and place.
            cancelDwell()
            hoverHideGeneration += 1
            hoverHidePending = false
            guard hit.kind == .cut || hit.kind == .originalPopup else {
                hidePopupNow()
                return
            }
            // A window may have come in front of the item since the popup opened (the target's sheet or popover,
            // an app's menu): then it closes, and opens again only after a move and a rest once the item is clear.
            // Redraws always check; moves inside the item at most every `popupCoverageInterval`.
            let now = ProcessInfo.processInfo.systemUptime
            if !moved || now - lastPopupCoverageCheck >= Self.popupCoverageInterval {
                lastPopupCoverageCheck = now
                if let id = hit.overlay.cgWindowID, isPointCovered(point, id) {
                    hidePopupNow()
                    return
                }
            }
            showHoverPopup(hit, owner: owner)
            return
        }
        if case .hover = popupOwner {
            // Another item's popup goes at once.
            hoverHideGeneration += 1
            hoverHidePending = false
            hidePopupNow()
        }
        if revealed == key || hit.onLink {
            // Already showing its original, or about to click a translated link.
            cancelDwell()
            return
        }
        if let generation = afterDwell, let current = dwell, current.generation == generation, current.key == key {
            dwell = nil
            fire(hit, owner: owner, point: point)
            return
        }
        if let current = dwell, current.key == key {
            // Resting means not moving: a real move starts the wait again.
            let distance = hypot(point.x - current.anchor.x, point.y - current.anchor.y)
            if moved, distance > Self.dwellSlop { startDwell(key, at: point, delay: delay(for: hit)) }
        } else if moved {
            startDwell(key, at: point, delay: delay(for: hit))
        } else {
            cancelDwell()
        }
    }

    private func delay(for hit: HoverHit) -> TimeInterval {
        if hit.kind == .cut { return Self.truncatedHoverDelay }
        return min(max(hit.overlay.style.interaction.hoverDelay, 0.05), 5)
    }

    private func startDwell(_ key: HoverKey, at point: CGPoint, delay: TimeInterval) {
        dwellGeneration += 1
        let generation = dwellGeneration
        dwell = Dwell(key: key, anchor: point, generation: generation)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.dwell?.generation == generation else { return }
            self.evaluateHover(afterDwell: generation)
        }
    }

    /// The pointer rested on the item long enough.
    private func fire(_ hit: HoverHit, owner: PopupOwner, point: CGPoint) {
        if let id = hit.overlay.cgWindowID, isPointCovered(point, id) {
            // Another window (or an app's menu) is in front of the target here.
            return
        }
        lastPopupCoverageCheck = ProcessInfo.processInfo.systemUptime
        switch hit.kind {
        case .reveal:
            // Nothing to fade while every translation is hidden.
            guard !revealOriginal, !allHidden else { return }
            reveal(HoverKey(window: hit.overlay.key, id: hit.item.id))
        case .cut, .originalPopup:
            showHoverPopup(hit, owner: owner)
        case .translationPopup:
            break
        }
    }

    private func showHoverPopup(_ hit: HoverHit, owner: PopupOwner) {
        let overlay = hit.overlay
        let item = hit.item
        popupOwner = owner
        let window = overlay.axWindowFrame
        let clip = (overlay.axClipRect ?? window).intersection(window)
        // In place, the popup must not cover the drawn translation either (it may reach below the original).
        var anchor = item.axFrame.standardized
        if hit.bounds.width > 0 { anchor = anchor.union(hit.bounds.offsetBy(dx: window.minX, dy: window.minY)) }
        let visible = anchor.intersection(clip)
        let parts: OverlayPopupContent.Parts
        switch hit.kind {
        case .translationPopup, .reveal: parts = .translation
        case .cut: parts = .translationAndOriginal
        case .originalPopup: parts = .original
        }
        popup.show(
            content: OverlayPopupContent(
                translation: item.translation, original: item.original, state: item.state, parts: parts),
            anchorAX: visible.isNull ? anchor : visible, appearance: overlay.style.appearance,
            suppressed: isPopupSuppressed, fitter: fitter)
    }

    /// The item under `point` that reacts to the pointer: any item of a hover-style window; in replace-style
    /// windows the drawn items (cut ones always, the others unless `hoverOriginal` is off). Frontmost windows
    /// first, then the smallest area.
    private func hoverHit(at point: CGPoint) -> HoverHit? {
        var best: (hit: HoverHit, frontmost: Bool, area: CGFloat)?
        func consider(_ hit: HoverHit, frontmost: Bool, area: CGFloat) {
            if let current = best {
                if frontmost != current.frontmost {
                    if frontmost { best = (hit, frontmost, area) }
                } else if area < current.area {
                    best = (hit, frontmost, area)
                }
            } else {
                best = (hit, frontmost, area)
            }
        }
        for overlay in overlays.values
        where overlay.targetOnScreen && !hiddenWindows.contains(overlay.key) {
            let window = overlay.axWindowFrame
            let clip = (overlay.axClipRect ?? window).intersection(window)
            guard !clip.isNull, clip.contains(point) else { continue }
            if overlay.style.displayStyle == .hover {
                for item in overlay.items where item.state != .failed {
                    let frame = item.axFrame.standardized
                    guard frame.height >= OverlayLayout.minimumItemSide, frame.contains(point) else { continue }
                    consider(
                        HoverHit(overlay: overlay, item: item, kind: .translationPopup, onLink: false, bounds: .zero),
                        frontmost: overlay.targetIsFrontmost, area: frame.width * frame.height)
                }
                continue
            }
            guard overlay.hasContent else { continue }
            let mode = overlay.style.interaction.hoverOriginal
            let local = CGPoint(x: point.x - window.minX, y: point.y - window.minY)
            for area in overlay.hoverAreas
            where area.bounds.contains(local) && area.rects.contains(where: { $0.contains(local) }) {
                let kind: HoverKind
                if overlay.truncatedIDs.contains(area.id) {
                    kind = .cut
                } else if mode == .inPlace || revealed == HoverKey(window: overlay.key, id: area.id) {
                    kind = .reveal
                } else if mode == .popup {
                    kind = .originalPopup
                } else {
                    continue
                }
                guard let item = overlay.item(id: area.id) else { continue }
                let onLink = overlay.activeHitAreas.contains {
                    $0.isLink && $0.itemID == area.id && $0.rect.contains(local)
                }
                consider(
                    HoverHit(overlay: overlay, item: item, kind: kind, onLink: onLink, bounds: area.bounds),
                    frontmost: overlay.targetIsFrontmost, area: area.bounds.width * area.bounds.height)
            }
        }
        return best?.hit
    }

    /// After a window was updated or redrawn: a revealed item that is gone ends, a wait on an item that no
    /// longer reacts stops, and a popup of one of its items follows the new text and position or closes.
    private func refreshHover(of key: WindowKey) {
        guard let overlay = overlays[key] else { return }
        let drawn = overlay.style.displayStyle == .replace && overlay.hasContent && overlay.targetOnScreen
        if let r = revealed, r.window == key, !drawn || !overlay.hoverAreas.contains(where: { $0.id == r.id }) {
            endReveal(animated: false)
        }
        if let r = revealed, r.window == key, let point = lastMouseAX {
            // The content may have moved away from a still pointer (auto-scroll, streaming text, a scroll the
            // session does not hide for): once the pointer is outside the item's new place, it ends after the
            // usual grace. Nothing new starts here (only a move starts a wait).
            checkRevealLeave(point)
        }
        if let d = dwell, d.key.window == key, !drawn || !overlay.hoverAreas.contains(where: { $0.id == d.key.id }) {
            cancelDwell()
        }
        guard overlay.style.displayStyle == .replace else { return }
        guard case .hover(let owner, let id) = popupOwner, owner == key else { return }
        let keepsPopup =
            overlay.truncatedIDs.contains(id) || (overlay.style.interaction.hoverOriginal == .popup && overlay.item(id: id) != nil)
        if keepsPopup, drawn, overlay.hoverAreas.contains(where: { $0.id == id }) {
            evaluateHover()
        } else {
            hidePopupNow()
        }
    }

    private func noteMouseMoveNeeds() {
        let truncated = overlays.values.contains {
            $0.style.displayStyle == .replace && $0.hasContent && !$0.truncatedIDs.isEmpty
        }
        if truncated != hasTruncatedItems {
            hasTruncatedItems = truncated
            onTruncatedItemsChanged?()
        }
        let needs =
            revealed != nil
            || overlays.values.contains {
                $0.style.displayStyle == .replace && $0.hasContent && $0.targetOnScreen
                    && (!$0.truncatedIDs.isEmpty || ($0.style.interaction.hoverOriginal != .off && !$0.hoverAreas.isEmpty))
            }
        if needs != needsMouseMoves {
            needsMouseMoves = needs
            onNeedsMouseMovesChanged?()
        }
    }

    /// Hides the hover popup shortly after the mouse leaves its item, so crossing a gap between blocks does not flicker.
    private func scheduleHoverHide() {
        guard !hoverHidePending else { return }
        hoverHidePending = true
        hoverHideGeneration += 1
        let generation = hoverHideGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, self.hoverHideGeneration == generation else { return }
            self.hoverHidePending = false
            if case .hover = self.popupOwner { self.hidePopupNow() }
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ handler: @escaping @MainActor @Sendable (OverlayController, Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, note)
            }
        }
        observers.append((center, token))
    }
}

// MARK: - Window state

private struct ContentSignature: Equatable {
    var clip: CGRect
    var inputs: [OverlayLayoutInput]
    var states: [OverlayItemState]
    var colors: [OverlayItemColors]
    var appearance: OverlayAppearance
    /// Links drawn per item, and original link rects (window-local) that clicks are kept from.
    var links: [[OverlayDrawLink]]
    var blockers: [[CGRect]]

    func hasSameGeometry(as other: ContentSignature) -> Bool {
        clip == other.clip && appearance == other.appearance && inputs.count == other.inputs.count
            && zip(inputs, other.inputs).allSatisfy {
                $0.id == $1.id && $0.frame == $1.frame && $0.lineFrames == $1.lineFrames && $0.style == $1.style
                    && $0.drawable == $1.drawable
            }
    }

    /// Same geometry, and at least one item changed state (streaming -> draft, draft -> final) or colors.
    func isRestyle(to other: ContentSignature) -> Bool {
        hasSameGeometry(as: other) && (states != other.states || colors != other.colors)
    }
}

@MainActor
private final class WindowOverlay {
    /// Where the pointer counts as "on" one drawn item (window-local): its background rows and its original.
    struct HoverArea {
        var id: String
        var rects: [CGRect]
        var bounds: CGRect
    }

    let key: WindowKey
    let panel: OverlayPanel
    let canvas: OverlayCanvasView

    var axWindowFrame: CGRect = .zero
    var axClipRect: CGRect?
    var cgWindowID: CGWindowID?
    private(set) var items: [OverlayItem] = []
    private var itemIndex: [String: Int] = [:]
    var obstacles: [CGRect] = []
    var style = OverlayStyle(displayStyle: .replace, appearance: OverlayAppearance())
    var targetIsFrontmost = false
    var targetOnScreen = true
    var targetLayer = 0
    var signature: ContentSignature?
    /// Regions for `signature`'s geometry.
    var regions: [OverlayRegion?]?
    var hasContent = false
    /// Items drawn cut with "…" (their full text is in the hover popup).
    var truncatedIDs: Set<String> = []
    /// Every drawn item (canvas coordinates), a revealed one included.
    var allDrawItems: [OverlayDrawItem] = []
    /// Drawn items, in draw order.
    var hoverAreas: [HoverArea] = []
    /// Click areas of the drawn items (window-local).
    var hitAreas: [OverlayHitArea] = []
    /// The click areas that have a panel right now.
    var activeHitAreas: [OverlayHitArea] = []
    var clickPanels: [OverlayClickPanel] = []
    /// A scroll started over one of the click panels: none until the next update.
    var clickPanelsSuppressed = false
    /// What the limit on click areas cost at the last rebuild (logged when it changes).
    var hitAreasOverLimit = OverlayHitAreas.OverLimit()
    /// Colors are measured from the screen (setting on and permission granted), as of the last update.
    var colorSamplingOn = false
    /// Background and text colors measured from the target window.
    let colorSampling = OverlayColorSampleScheduler()
    /// Target window the panel was confirmed to be ordered directly above.
    var verifiedTarget: CGWindowID?
    /// Target window relative ordering did not work for.
    var failedTarget: CGWindowID?
    var orderingFailures = 0
    var orderingCheckPending = false

    init(key: WindowKey) {
        self.key = key
        panel = OverlayPanel()
        let container = OverlayContainerView(frame: CGRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        canvas = OverlayCanvasView(frame: .zero)
        canvas.layerContentsPlacement = .topLeft
        container.addSubview(canvas)
    }

    func setItems(_ items: [OverlayItem]) {
        self.items = items
        itemIndex.removeAll(keepingCapacity: true)
        for (i, item) in items.enumerated() where itemIndex[item.id] == nil { itemIndex[item.id] = i }
    }

    func item(id: String) -> OverlayItem? {
        itemIndex[id].map { items[$0] }
    }

    func clearContent(keepSignature: Bool = false) {
        if !keepSignature {
            signature = nil
            regions = nil
        }
        hasContent = false
        truncatedIDs = []
        allDrawItems = []
        hoverAreas = []
        hitAreas = []
        canvas.setContent([], appearance: style.appearance, crossfade: false)
    }
}

// MARK: - Popup window

@MainActor
private final class PopupWindow {
    let panel = OverlayPanel(hasShadow: true)
    private let view = OverlayPopupView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    private var isShown = false
    private var hideGeneration = 0

    init() {
        panel.level = .floating
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    func show(
        content: OverlayPopupContent, anchorAX: CGRect, appearance: OverlayAppearance, suppressed: Bool,
        fitter: TextFitter
    ) {
        let screen = CoordinateSpace.axScreen(for: anchorAX)?.visibleFrame ?? anchorAX.insetBy(dx: -600, dy: -600)
        let layout = OverlayLayout.popup(
            text: content.displayText, anchor: anchorAX, screen: screen, appearance: appearance, fitter: fitter)
        let frame = CoordinateSpace.cocoaRect(fromAX: layout.frame)
        hideGeneration += 1
        if !panel.frame.isClose(to: frame) { panel.setFrame(frame, display: false) }
        let changed = view.setContent(content, layout: layout, appearance: appearance)
        if !isShown || !panel.isVisible {
            panel.setAlpha(0, duration: 0)
            panel.orderFrontRegardless()
            isShown = true
        }
        if changed {
            view.display()
            panel.invalidateShadow()
        }
        panel.setAlpha(suppressed ? 0 : 1, duration: suppressed ? 0 : OverlayController.fadeDuration)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        hideGeneration += 1
        let generation = hideGeneration
        panel.setAlpha(0, duration: 0.1)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard let self, self.hideGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }

    func setSuppressed(_ suppressed: Bool, duration: TimeInterval) {
        guard isShown else { return }
        panel.setAlpha(suppressed ? 0 : 1, duration: duration)
    }
}

// MARK: - Helpers

extension OverlayPanel {
    /// Fades to `alpha`. Repeated calls with the same target do not restart a running fade.
    func setAlpha(_ alpha: CGFloat, duration: TimeInterval) {
        if alpha == alphaTarget, duration > 0 || alphaValue == alpha { return }
        alphaTarget = alpha
        if duration <= 0 || !isVisible {
            // A zero-length animation replaces any fade still running.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                animator().alphaValue = alpha
            }
            alphaValue = alpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = alpha
            }
        }
    }
}

extension CGRect {
    /// Equal within half a point on every edge.
    fileprivate func isClose(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
