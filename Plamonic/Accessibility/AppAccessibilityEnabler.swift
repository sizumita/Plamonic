import ApplicationServices
import Foundation

/// Turns on the AX tree of apps that build it lazily (Electron / Chromium need AXManualAccessibility).
/// Remembers what it did per pid so the attributes are set only once per process, and turns back off only
/// what it switched on itself (an attribute VoiceOver or another tool had already set is left alone).
final class AppAccessibilityEnabler: @unchecked Sendable {
    static let shared = AppAccessibilityEnabler()

    struct State: Sendable {
        var enabledAt: Date
        var manualResult: AXError?
        var enhancedResult: AXError?
        /// The attribute was already on before we set it, so restoring leaves it on.
        var manualWasOn = false
        var enhancedWasOn = false
    }

    /// Chromium needs a few seconds after AXManualAccessibility before the web tree is complete.
    var warmUpInterval: TimeInterval = 3.0

    private let lock = NSLock()
    private var states: [pid_t: State] = [:]

    init() {}

    /// Sets the requested attributes once per pid. Returns true when this call enabled something
    /// (the caller may want to wait `warmUpInterval` before trusting an empty scan).
    @discardableResult
    func ensureEnabled(pid: pid_t, manualAccessibility: Bool, enhancedUserInterface: Bool) -> Bool {
        lock.lock()
        let existing = states[pid]
        lock.unlock()
        let needManual = manualAccessibility && existing?.manualResult == nil
        let needEnhanced = enhancedUserInterface && existing?.enhancedResult == nil
        guard needManual || needEnhanced else { return false }

        let app = AXElement.application(pid: pid)
        // The warm-up window starts only when an attribute was actually switched on (native apps answer
        // attributeUnsupported and need no warm-up).
        var state = existing ?? State(enabledAt: .distantPast, manualResult: nil, enhancedResult: nil)
        var changed = false
        // A timeout (cannotComplete) is left unrecorded so the next call retries.
        if needManual {
            let wasOn = app.bool(AXAttr.manualAccessibility) == true
            let r = app.setAttribute(AXAttr.manualAccessibility, bool: true)
            state.manualResult = r == .cannotComplete ? nil : r
            state.manualWasOn = wasOn
            changed = changed || (r == .success && !wasOn)
        }
        if needEnhanced {
            let wasOn = app.bool(AXAttr.enhancedUserInterface) == true
            let r = app.setAttribute(AXAttr.enhancedUserInterface, bool: true)
            state.enhancedResult = r == .cannotComplete ? nil : r
            state.enhancedWasOn = wasOn
            changed = changed || (r == .success && !wasOn)
        }
        if changed { state.enabledAt = Date() }
        lock.lock()
        states[pid] = state
        lock.unlock()
        return changed
    }

    /// Applies the profile's switches: sets the enabled attributes, and turns back off an attribute we set
    /// earlier whose switch is now off. Cheap when nothing changes (no AX call).
    @discardableResult
    func ensureEnabled(pid: pid_t, profile: AppProfile) -> Bool {
        if !profile.enableEnhancedUserInterface { restoreEnhancedUserInterface(pid: pid) }
        if !profile.enableManualAccessibility { restoreManualAccessibility(pid: pid) }
        return ensureEnabled(
            pid: pid, manualAccessibility: profile.enableManualAccessibility,
            enhancedUserInterface: profile.enableEnhancedUserInterface)
    }

    /// true for a few seconds after the attributes were first set for this pid.
    func isWarmingUp(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let state = states[pid] else { return false }
        return Date().timeIntervalSince(state.enabledAt) < warmUpInterval
    }

    func state(pid: pid_t) -> State? {
        lock.lock()
        defer { lock.unlock() }
        return states[pid]
    }

    /// Turns back off what we switched on in one app (translation turned off for it, or stopped).
    /// AX calls: run it off the main thread.
    func restore(pid: pid_t) {
        restoreEnhancedUserInterface(pid: pid)
        restoreManualAccessibility(pid: pid)
    }

    /// Turns AXEnhancedUserInterface back off if we switched it on (it can disable window animations).
    func restoreEnhancedUserInterface(pid: pid_t) {
        guard let state = state(pid: pid), state.enhancedResult == .success else { return }
        if !state.enhancedWasOn {
            AXElement.application(pid: pid).setAttribute(AXAttr.enhancedUserInterface, bool: false)
        }
        lock.lock()
        states[pid]?.enhancedResult = nil
        lock.unlock()
    }

    /// Turns AXManualAccessibility back off if we switched it on (Chromium then drops its accessibility tree,
    /// and Electron apps such as VS Code leave their screen-reader mode).
    func restoreManualAccessibility(pid: pid_t) {
        guard let state = state(pid: pid), state.manualResult == .success else { return }
        if !state.manualWasOn {
            let app = AXElement.application(pid: pid)
            // Chromium keeps one accessibility switch for both attributes: leave it on while an assistive
            // app (VoiceOver) has AXEnhancedUserInterface on.
            if app.bool(AXAttr.enhancedUserInterface) != true {
                app.setAttribute(AXAttr.manualAccessibility, bool: false)
            }
        }
        lock.lock()
        states[pid]?.manualResult = nil
        lock.unlock()
    }

    /// Restores both attributes in every app where we switched them on (at quit).
    func restoreAll() {
        for pid in trackedPIDs() { restore(pid: pid) }
    }

    /// Call when the process terminates.
    func forget(pid: pid_t) {
        lock.lock()
        states[pid] = nil
        lock.unlock()
    }

    /// Apps whose attributes Plamonic has touched (some may already be restored).
    func trackedPIDs() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(states.keys)
    }
}
