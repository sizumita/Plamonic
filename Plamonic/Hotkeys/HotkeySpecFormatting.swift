import AppKit
import Carbon.HIToolbox

extension HotkeySpec {
    static let carbonControl = UInt32(controlKey)  // 0x1000
    static let carbonOption = UInt32(optionKey)  // 0x0800
    static let carbonShift = UInt32(shiftKey)  // 0x0200
    static let carbonCommand = UInt32(cmdKey)  // 0x0100
    static let carbonModifierMask = carbonControl | carbonOption | carbonShift | carbonCommand

    /// Builds a spec from an AppKit key event's key code and modifier flags.
    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.control) { carbon |= Self.carbonControl }
        if modifierFlags.contains(.option) { carbon |= Self.carbonOption }
        if modifierFlags.contains(.shift) { carbon |= Self.carbonShift }
        if modifierFlags.contains(.command) { carbon |= Self.carbonCommand }
        self.init(keyCode: UInt32(keyCode), carbonModifiers: carbon)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & Self.carbonControl != 0 { flags.insert(.control) }
        if carbonModifiers & Self.carbonOption != 0 { flags.insert(.option) }
        if carbonModifiers & Self.carbonShift != 0 { flags.insert(.shift) }
        if carbonModifiers & Self.carbonCommand != 0 { flags.insert(.command) }
        return flags
    }

    /// "⌃⌥⇧⌘" subset in the standard macOS order.
    var modifierSymbols: String { Self.modifierSymbols(carbonModifiers) }

    var keyName: String { HotkeyKeyNames.name(for: keyCode) }

    /// e.g. "⌃⌥T".
    var displayString: String { modifierSymbols + keyName }

    var isFunctionKey: Bool { HotkeyKeyNames.functionKeyCodes.contains(keyCode) }

    /// Global hotkeys need ⌃, ⌥ or ⌘ so they do not swallow ordinary typing (F-keys are fine alone).
    var isValidGlobalHotkey: Bool {
        let required = Self.carbonControl | Self.carbonOption | Self.carbonCommand
        return carbonModifiers & required != 0 || isFunctionKey
    }

    static func modifierSymbols(_ carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & carbonControl != 0 { s += "⌃" }
        if carbonModifiers & carbonOption != 0 { s += "⌥" }
        if carbonModifiers & carbonShift != 0 { s += "⇧" }
        if carbonModifiers & carbonCommand != 0 { s += "⌘" }
        return s
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        modifierSymbols(HotkeySpec(keyCode: 0, modifierFlags: flags).carbonModifiers)
    }
}

/// Display names for Carbon virtual key codes.
enum HotkeyKeyNames {
    static let functionKeyCodes: Set<UInt32> = Set(
        [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ].map { UInt32($0) })

    /// Name for display: special keys use symbols; character keys follow the current keyboard layout
    /// (on the main thread), falling back to the US ANSI label.
    static func name(for keyCode: UInt32) -> String {
        if let special = specialNames[Int(keyCode)] { return special }
        if Thread.isMainThread, let typed = layoutCharacter(for: keyCode) { return typed }
        return fallbackName(for: keyCode)
    }

    /// Layout-independent label (US ANSI positions).
    static func fallbackName(for keyCode: UInt32) -> String {
        specialNames[Int(keyCode)] ?? ansiNames[Int(keyCode)] ?? "キー\(keyCode)"
    }

    private static let specialNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Help: "Help",
        kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20",
        kVK_JIS_Eisu: "英数", kVK_JIS_Kana: "かな",
    ]

    private static let ansiNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_RightBracket: "]", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`",
        kVK_ANSI_KeypadDecimal: "テンキー.", kVK_ANSI_KeypadMultiply: "テンキー*", kVK_ANSI_KeypadPlus: "テンキー+",
        kVK_ANSI_KeypadDivide: "テンキー/", kVK_ANSI_KeypadMinus: "テンキー-", kVK_ANSI_KeypadEquals: "テンキー=",
        kVK_ANSI_Keypad0: "テンキー0", kVK_ANSI_Keypad1: "テンキー1", kVK_ANSI_Keypad2: "テンキー2",
        kVK_ANSI_Keypad3: "テンキー3", kVK_ANSI_Keypad4: "テンキー4", kVK_ANSI_Keypad5: "テンキー5",
        kVK_ANSI_Keypad6: "テンキー6", kVK_ANSI_Keypad7: "テンキー7", kVK_ANSI_Keypad8: "テンキー8",
        kVK_ANSI_Keypad9: "テンキー9",
        kVK_JIS_Yen: "¥", kVK_JIS_Underscore: "_", kVK_JIS_KeypadComma: "テンキー,",
    ]

    private static let keypadCodes: Set<Int> = [
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadDivide,
        kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals, kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2,
        kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
        kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_JIS_KeypadComma,
    ]

    /// The character the key types without modifiers in the current ASCII-capable layout (uppercased).
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        if keypadCodes.contains(Int(keyCode)) { return nil }
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        for case let source? in sources {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                    return OSStatus(paramErr)
                }
                return UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
            }
            guard status == noErr, length > 0 else { continue }
            let string = String(utf16CodeUnits: chars, count: length)
            let visible = string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !visible.isEmpty { return visible.uppercased() }
        }
        return nil
    }
}
