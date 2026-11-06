import AppKit

/// Transparent, click-through, never-key panel used for per-window overlays and popups.
final class OverlayPanel: NSPanel {
    /// Alpha the panel is showing or fading towards (see `setAlpha(_:duration:)`).
    var alphaTarget: CGFloat = 1

    init(contentRect: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10), hasShadow: Bool = false) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = false
        level = .normal
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false
        self.hasShadow = hasShadow
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        animationBehavior = .none
        // Not .canJoinAllSpaces: an overlay belongs to the Space its target window is on.
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Window-server facts about windows of other processes (CGWindowList; no Screen Recording permission needed
/// for the fields used here).
enum OverlayWindowServer {
    struct Entry: Equatable {
        var number: CGWindowID
        var ownerPID: pid_t
        var layer: Int
        var alpha: CGFloat
        var isOnScreen: Bool
        /// CG global coordinates = AX coordinates.
        var bounds: CGRect
    }

    /// The window `id`, or nil when it no longer exists.
    static func info(for id: CGWindowID) -> Entry? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else {
            return nil
        }
        return list.lazy.compactMap(entry).first { $0.number == id }
    }

    /// On-screen windows in front of `id`, front to back (the last one is directly above `id`).
    static func windowsAbove(_ id: CGWindowID) -> [Entry] {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], id)
                as? [[String: Any]]
        else { return [] }
        return list.compactMap(entry)
    }

    /// true when `panelNumber` is in front of `target` with nothing between them except windows of `targetPID`
    /// (its own child windows may stay attached above it).
    static func isOrdered(panelNumber: Int, directlyAbove target: CGWindowID, targetPID: pid_t) -> Bool {
        let above = windowsAbove(target)
        guard let index = above.lastIndex(where: { Int($0.number) == panelNumber }) else { return false }
        return above[(index + 1)...].allSatisfy { $0.ownerPID == targetPID }
    }

    /// true when a visible window of another process (or another window of the target) in front of `target`
    /// covers `point` (AX coordinates). Windows of `ignoringPID` (this app) are skipped, and so are the Dock,
    /// the menu bar and higher system levels, except open menus (an app's context menu or a menu-bar menu).
    static func isPoint(_ point: CGPoint, coveredAbove target: CGWindowID, ignoringPID: pid_t) -> Bool {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windowsAbove(target).contains { entry in
            entry.ownerPID != ignoringPID && ((entry.layer >= 0 && entry.layer < dockLevel) || entry.layer == menuLevel)
                && entry.alpha > 0.05 && entry.bounds.contains(point)
        }
    }

    private static func entry(_ dict: [String: Any]) -> Entry? {
        guard let number = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
        var bounds = CGRect.null
        if let b = dict[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .null
        }
        return Entry(
            number: number,
            ownerPID: (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            layer: (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            alpha: CGFloat((dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1),
            isOnScreen: (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            bounds: bounds)
    }
}
