import AppKit
import SwiftUI

/// The menu bar icon: the app icon's speech bubble and "P", drawn as a template image so it
/// follows the menu bar's light or dark appearance.
struct MenuBarIcon: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Image(nsImage: MenuBarIconImage.image(for: state))
            .accessibilityLabel("Plamonic")
    }

    private var state: MenuBarIconImage.State {
        if !controller.accessibilityTrusted { return .needsPermission }
        return settings.global.isEnabled ? .enabled : .disabled
    }
}

enum MenuBarIconImage {
    enum State: CaseIterable {
        /// Filled bubble with the "P" cut out.
        case enabled
        /// Outlined bubble with the "P".
        case disabled
        /// Outlined bubble with "!": Accessibility permission is missing.
        case needsPermission
    }

    private static let cache: [State: NSImage] = Dictionary(
        uniqueKeysWithValues: State.allCases.map { ($0, makeImage($0)) })

    static func image(for state: State) -> NSImage { cache[state]! }

    // The shapes use the 1024-point canvas of Resources/AppIcon.icon/Assets.
    private static let canvas = NSRect(x: 158, y: 186, width: 708, height: 680)
    private static let height: CGFloat = 17

    private static func makeImage(_ state: State) -> NSImage {
        let scale = height / canvas.height
        let size = NSSize(width: (canvas.width * scale).rounded(), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -canvas.minX, y: -canvas.minY)
            NSColor.black.set()
            let bubble = bubblePath()
            switch state {
            case .enabled:
                bubble.fill()
                context.setBlendMode(.clear)
                strokeMark(letterPath())
            case .disabled:
                bubble.lineWidth = 56
                bubble.lineJoinStyle = .round
                bubble.stroke()
                strokeMark(letterPath())
            case .needsPermission:
                bubble.lineWidth = 56
                bubble.lineJoinStyle = .round
                bubble.stroke()
                strokeMark(exclamationPath())
                NSBezierPath(ovalIn: NSRect(x: 512 - 42, y: 596 - 42, width: 84, height: 84)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Plamonic"
        return image
    }

    private static func strokeMark(_ path: NSBezierPath) {
        path.lineWidth = 76
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// Bubble.svg: a rounded rectangle with a tail at the bottom left.
    private static func bubblePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 362, y: 214))
        path.line(to: NSPoint(x: 662, y: 214))
        path.appendArc(withCenter: NSPoint(x: 662, y: 390), radius: 176, startAngle: -90, endAngle: 0)
        path.line(to: NSPoint(x: 838, y: 546))
        path.appendArc(withCenter: NSPoint(x: 662, y: 546), radius: 176, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: 488, y: 722))
        path.curve(
            to: NSPoint(x: 280, y: 838), controlPoint1: NSPoint(x: 444, y: 772),
            controlPoint2: NSPoint(x: 372, y: 818))
        path.curve(
            to: NSPoint(x: 344, y: 721), controlPoint1: NSPoint(x: 318, y: 796),
            controlPoint2: NSPoint(x: 338, y: 756))
        path.appendArc(withCenter: NSPoint(x: 362, y: 546), radius: 176, startAngle: 95.9, endAngle: 180)
        path.line(to: NSPoint(x: 186, y: 390))
        path.appendArc(withCenter: NSPoint(x: 362, y: 390), radius: 176, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    /// P.svg, moved 6 points right as in icon.json.
    private static func letterPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 427, y: 606))
        path.line(to: NSPoint(x: 427, y: 340))
        path.line(to: NSPoint(x: 514, y: 340))
        path.appendArc(withCenter: NSPoint(x: 514, y: 434), radius: 94, startAngle: -90, endAngle: 90)
        path.line(to: NSPoint(x: 427, y: 528))
        return path
    }

    private static func exclamationPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 512, y: 340))
        path.line(to: NSPoint(x: 512, y: 494))
        return path
    }
}
