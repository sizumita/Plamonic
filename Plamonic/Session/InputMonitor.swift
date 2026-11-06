import AppKit

/// Global mouse / keyboard monitors the session needs. Each kind is installed only while it is wanted.
/// Handlers run on the main thread. Points are in AX coordinates.
@MainActor
final class InputMonitor {
    var onScrollOrDrag: ((CGPoint) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onModifierFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    var onEscape: (() -> Void)?

    private var scrollMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var flagsMonitors: [Any] = []
    private var escapeMonitor: Any?

    func setScrollMonitoring(_ enabled: Bool) {
        if enabled, scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) {
                [weak self] event in
                let point = event.cgEvent?.location ?? AXGeometry.mouseLocationAX()
                MainActor.assumeIsolated { self?.onScrollOrDrag?(point) }
            }
        } else if !enabled, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    func setMouseMoveMonitoring(_ enabled: Bool) {
        if enabled, mouseMoveMonitor == nil {
            mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                let point = event.cgEvent?.location ?? AXGeometry.mouseLocationAX()
                MainActor.assumeIsolated { self?.onMouseMoved?(point) }
            }
        } else if !enabled, let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
    }

    func setModifierMonitoring(_ enabled: Bool) {
        if enabled, flagsMonitors.isEmpty {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.onModifierFlagsChanged?(flags) }
            }) {
                flagsMonitors.append(global)
            }
            // Also while our own settings window is in front.
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.onModifierFlagsChanged?(flags) }
                return event
            }) {
                flagsMonitors.append(local)
            }
        } else if !enabled, !flagsMonitors.isEmpty {
            for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
            flagsMonitors.removeAll()
        }
    }

    /// Esc in any app (needs the Accessibility permission, which the app has anyway).
    func setEscapeMonitoring(_ enabled: Bool) {
        if enabled, escapeMonitor == nil {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.onEscape?() }
            }
        } else if !enabled, let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    func stopAll() {
        setScrollMonitoring(false)
        setMouseMoveMonitoring(false)
        setModifierMonitoring(false)
        setEscapeMonitoring(false)
    }

    /// true when exactly `key` is held (other modifiers would be part of a shortcut).
    static func isOnlyModifierHeld(_ key: ModifierKey, flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.shift, .control, .option, .command, .function])
        switch key {
        case .none: return false
        case .option: return relevant == .option
        case .control: return relevant == .control
        case .command: return relevant == .command
        case .shift: return relevant == .shift
        case .function: return relevant == .function
        }
    }
}
