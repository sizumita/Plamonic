import AppKit
import ApplicationServices

/// Accessibility (TCC) permission helpers.
enum AccessibilityPermission {
    /// true when this process may use the AX API on other apps.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that points the user to System Settings (only if not trusted yet).
    /// Returns the current trust state; the user's answer arrives later, so poll `isTrusted`.
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens System Settings > Privacy & Security > Accessibility.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
