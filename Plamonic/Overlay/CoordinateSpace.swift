import AppKit

/// A screen described in AX coordinates.
struct AXScreen: Equatable, Sendable {
    var frame: CGRect
    /// Without the menu bar and the Dock.
    var visibleFrame: CGRect
}

/// Conversion between the two global coordinate systems macOS uses.
///
/// - AX (and CGWindowList): origin at the top-left of the primary screen, y grows downward.
/// - Cocoa (NSWindow / NSScreen / NSEvent): origin at the bottom-left of the primary screen, y grows upward.
///
/// The primary screen is `NSScreen.screens[0]` (the one with the menu bar). Both systems share the same
/// x axis and units on every screen, so the conversion is a single flip around the primary screen's height,
/// also for screens left of, above or below the primary one (negative coordinates included).
enum CoordinateSpace {
    static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        guard !rect.isNull, !rect.isInfinite else { return rect }
        let r = rect.standardized
        return CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    static func axRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        // The flip is its own inverse.
        cocoaRect(fromAX: rect, primaryScreenHeight: primaryScreenHeight)
    }

    static func cocoaPoint(fromAX point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func axPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Index of the screen that shows the largest part of `rect`. When `rect` is on no screen,
    /// the screen whose frame is nearest to its center. nil only when `screens` is empty.
    static func screenIndex(for rect: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let r = rect.standardized
        var best: Int?
        var bestArea: CGFloat = 0
        for (i, screen) in screens.enumerated() {
            let overlap = screen.intersection(r)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            // A zero-size rect (a point) still counts when it lies on the screen.
            if best == nil || area > bestArea {
                best = i
                bestArea = area
            }
        }
        if let best { return best }
        let center = CGPoint(x: r.midX, y: r.midY)
        return screens.indices.min { distance(center, screens[$0]) < distance(center, screens[$1]) }
    }

    /// Distance from a point to the nearest edge of a rect (0 when inside).
    static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Live screen configuration

    /// Height of `NSScreen.screens[0]`, or 0 when no screen is attached.
    @MainActor static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    @MainActor static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        cocoaRect(fromAX: rect, primaryScreenHeight: primaryScreenHeight)
    }

    @MainActor static func axRect(fromCocoa rect: CGRect) -> CGRect {
        axRect(fromCocoa: rect, primaryScreenHeight: primaryScreenHeight)
    }

    @MainActor static func cocoaPoint(fromAX point: CGPoint) -> CGPoint {
        cocoaPoint(fromAX: point, primaryScreenHeight: primaryScreenHeight)
    }

    @MainActor static func axPoint(fromCocoa point: CGPoint) -> CGPoint {
        axPoint(fromCocoa: point, primaryScreenHeight: primaryScreenHeight)
    }

    /// The mouse location in AX coordinates.
    @MainActor static var mouseLocationAX: CGPoint {
        axPoint(fromCocoa: NSEvent.mouseLocation)
    }

    /// All screens in AX coordinates, primary first.
    @MainActor static func axScreens() -> [AXScreen] {
        let height = primaryScreenHeight
        return NSScreen.screens.map {
            AXScreen(
                frame: axRect(fromCocoa: $0.frame, primaryScreenHeight: height),
                visibleFrame: axRect(fromCocoa: $0.visibleFrame, primaryScreenHeight: height))
        }
    }

    /// The screen that shows most of `axRect`, in AX coordinates.
    @MainActor static func axScreen(for axRect: CGRect) -> AXScreen? {
        let screens = axScreens()
        guard let i = screenIndex(for: axRect, screens: screens.map(\.frame)) else { return nil }
        return screens[i]
    }
}
