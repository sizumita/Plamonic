import ApplicationServices
import CoreGraphics
import Foundation

// Private but long-stable API that maps an AX window to its CGWindowID (used by many window managers).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A window as reported by the window server.
struct CGWindowInfo: Hashable, Sendable {
    var windowID: CGWindowID
    var pid: pid_t
    /// AX coordinates (CGWindowList bounds already use the top-left origin).
    var axFrame: CGRect
    var layer: Int
    var alpha: Double
    var isOnScreen: Bool
}

/// Finds AX windows and maps them to CGWindowIDs.
enum WindowLocator {
    static func focusedWindow(pid: pid_t) -> AXElement? {
        AXElement.application(pid: pid).element(AXAttr.focusedWindow)
    }

    static func mainWindow(pid: pid_t) -> AXElement? {
        AXElement.application(pid: pid).element(AXAttr.mainWindow)
    }

    static func windows(pid: pid_t) -> [AXElement] {
        AXElement.application(pid: pid).elements(AXAttr.windows)
    }

    /// Focused window, falling back to the main window and then the first standard window.
    static func bestWindow(pid: pid_t) -> AXElement? {
        if let w = focusedWindow(pid: pid) { return w }
        if let w = mainWindow(pid: pid) { return w }
        // One request: for a busy app each call waits out the messaging timeout.
        let all = windows(pid: pid)
        return all.first { $0.subrole == "AXStandardWindow" } ?? all.first
    }

    /// CGWindowID of an AX window. Uses the private call first, then matches the window list by pid + bounds.
    static func windowID(of window: AXElement, pid: pid_t? = nil) -> CGWindowID? {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(window.ref, &id) == .success, id != 0 { return id }
        guard let pid = pid ?? window.pid, let frame = window.frame else { return nil }
        let candidates = windowList(onScreenOnly: false).filter { $0.pid == pid && $0.layer == 0 }
        if let exact = candidates.first(where: { approximatelyEqual($0.axFrame, frame, tolerance: 1) }) {
            return exact.windowID
        }
        return candidates.first(where: { approximatelyEqual($0.axFrame, frame, tolerance: 8) })?.windowID
    }

    /// Stable key for a window: the CGWindowID when available, otherwise a hash of the AX element.
    static func windowKey(for window: AXElement, pid: pid_t) -> WindowKey {
        if let id = windowID(of: window, pid: pid) { return WindowKey(pid: pid, windowID: id) }
        return fallbackKey(for: window, pid: pid)
    }

    /// Key for a window whose CGWindowID could not be looked up (a hash of the AX element). Do not cache it:
    /// the same window gets its CGWindowID key once the lookup succeeds.
    static func fallbackKey(for window: AXElement, pid: pid_t) -> WindowKey {
        WindowKey(pid: pid, windowID: UInt32(truncatingIfNeeded: CFHash(window.ref)))
    }

    /// true when the window is currently on screen (not minimized, not on another Space, not hidden).
    static func isOnScreen(windowID: CGWindowID) -> Bool {
        guard
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let info = list.first
        else { return false }
        return (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// Window server list, front to back.
    static func windowList(onScreenOnly: Bool = true) -> [CGWindowInfo] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return CGWindowInfo(
                windowID: id, pid: pid, axFrame: bounds,
                layer: (info[kCGWindowLayer as String] as? Int) ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? onScreenOnly)
        }
    }

    /// Topmost normal-layer window containing an AX point, skipping the given processes (e.g. our overlays).
    static func topWindow(atAX point: CGPoint, excludingPIDs: Set<pid_t> = []) -> CGWindowInfo? {
        windowList(onScreenOnly: true).first {
            $0.layer == 0 && $0.alpha > 0.01 && !excludingPIDs.contains($0.pid) && $0.axFrame.contains(point)
        }
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Coordinate conversion. AX: origin at the top-left of the primary screen, y down.
/// Cocoa: origin at the bottom-left of the primary screen, y up.
enum AXGeometry {
    /// Height of the primary screen (the display at the global origin). Safe off the main thread.
    static var primaryScreenHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func axToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaToAX(_ rect: CGRect) -> CGRect {
        // The transform is its own inverse.
        axToCocoa(rect)
    }

    static func axToCocoa(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func cocoaToAX(_ point: CGPoint) -> CGPoint {
        axToCocoa(point)
    }

    /// Current mouse location in AX coordinates.
    static func mouseLocationAX() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
