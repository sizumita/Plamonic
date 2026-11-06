import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that records a global shortcut. Click, then press the combination.
/// Esc cancels, Delete clears. Global hotkeys of `HotkeyCenter.shared` are suspended while recording.
struct HotkeyRecorder: View {
    @Binding var spec: HotkeySpec?
    var placeholder: String = "未設定"
    @StateObject private var model = HotkeyRecorderModel()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if model.isRecording {
                        model.stop()
                    } else {
                        model.start { spec = $0 }
                    }
                } label: {
                    Text(title)
                        .monospaced()
                        .frame(minWidth: 110)
                }
                .help(model.isRecording ? "Esc で取り消し、Delete で削除" : "クリックしてショートカットを記録")

                if spec != nil, !model.isRecording {
                    Button {
                        spec = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("ショートカットを削除")
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { model.stop() }
    }

    private var title: String {
        if model.isRecording {
            return model.pendingModifiers.isEmpty ? "キーを押してください…" : model.pendingModifiers + "…"
        }
        return spec?.displayString ?? placeholder
    }
}

@MainActor
final class HotkeyRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var pendingModifiers = ""
    @Published private(set) var message: String?

    private var monitor: Any?
    private var onCapture: ((HotkeySpec?) -> Void)?
    private var suspendedCenter = false
    /// The recorder that is recording. Only one may record: a second one would leave the first one's key monitor
    /// installed (it swallows every key) and could not resume the HotkeyCenter suspension the first one owns.
    private static weak var active: HotkeyRecorderModel?

    func start(onCapture: @escaping (HotkeySpec?) -> Void) {
        if let other = Self.active, other !== self { other.stop() }
        stop()
        self.onCapture = onCapture
        message = nil
        isRecording = true
        if !HotkeyCenter.shared.isSuspended {
            HotkeyCenter.shared.isSuspended = true
            suspendedCenter = true
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread.
            let type = event.type
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self?.handle(type: type, keyCode: keyCode, modifierFlags: flags) ?? false
            }
            return consumed ? nil : event
        }
        Self.active = self
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onCapture = nil
        isRecording = false
        pendingModifiers = ""
        if suspendedCenter {
            HotkeyCenter.shared.isSuspended = false
            suspendedCenter = false
        }
        if Self.active === self { Self.active = nil }
    }

    /// Returns true when the event was consumed.
    private func handle(type: NSEvent.EventType, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = modifierFlags.intersection([.control, .option, .shift, .command])
        switch type {
        case .flagsChanged:
            pendingModifiers = HotkeySpec.modifierSymbols(modifiers)
            return false
        case .keyDown:
            if modifiers.isEmpty, Int(keyCode) == kVK_Escape {
                stop()
                return true
            }
            if modifiers.isEmpty, Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete {
                onCapture?(nil)
                stop()
                return true
            }
            let spec = HotkeySpec(keyCode: keyCode, modifierFlags: modifiers)
            guard spec.isValidGlobalHotkey else {
                message = "⌃・⌥・⌘ のいずれかと組み合わせてください"
                NSSound.beep()
                return true
            }
            onCapture?(spec)
            stop()
            return true
        default:
            return false
        }
    }
}
