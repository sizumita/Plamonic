import AppKit
import Carbon.HIToolbox

enum HotkeyError: LocalizedError, Equatable {
    case handlerInstallFailed(OSStatus)
    /// Usually eventHotKeyExistsErr: another app already owns the combination.
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .handlerInstallFailed(let status):
            return "ホットキーの監視を開始できませんでした（\(status)）。"
        case .registrationFailed(let status) where status == OSStatus(eventHotKeyExistsErr):
            return "このショートカットはほかのアプリが使っています。"
        case .registrationFailed(let status):
            return "ショートカットを登録できませんでした（\(status)）。"
        }
    }
}

/// System-wide hotkeys through Carbon RegisterEventHotKey. Handlers run on the main thread.
@MainActor
final class HotkeyCenter {
    /// The app's instance. The settings recorder suspends it while capturing a new shortcut.
    static let shared = HotkeyCenter()

    typealias Handler = @MainActor () -> Void

    private struct Entry {
        var spec: HotkeySpec
        var numericID: UInt32
        var handler: Handler
    }

    private static let signature: OSType = 0x504C_4D4E  // 'PLMN'

    private var entries: [String: Entry] = [:]
    private var nextNumericID: UInt32 = 1
    // Touched from deinit, which is nonisolated.
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var systemRefs: [String: EventHotKeyRef] = [:]

    init() {}

    deinit {
        for ref in systemRefs.values { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// While true, every hotkey is released to the system (so a recorder can capture the same combination).
    /// Registrations are kept and restored when it becomes false.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended {
                for id in Array(systemRefs.keys) { releaseSystemHotkey(id) }
            } else {
                for (id, entry) in entries { _ = try? attachSystemHotkey(id: id, entry: entry) }
            }
        }
    }

    var registeredIDs: [String] { entries.keys.sorted() }

    func spec(for id: String) -> HotkeySpec? { entries[id]?.spec }

    /// Registers (or replaces) the hotkey `id`. Throws when the system refuses the combination;
    /// the previous registration for `id` is removed either way.
    func register(id: String, spec: HotkeySpec, handler: @escaping Handler) throws {
        unregister(id: id)
        try installEventHandlerIfNeeded()
        let entry = Entry(spec: spec, numericID: nextNumericID, handler: handler)
        nextNumericID &+= 1
        if !isSuspended {
            try attachSystemHotkey(id: id, entry: entry)
        }
        entries[id] = entry
    }

    func unregister(id: String) {
        releaseSystemHotkey(id)
        entries[id] = nil
    }

    func unregisterAll() {
        for id in Array(entries.keys) { unregister(id: id) }
    }

    // MARK: - Private

    fileprivate func handleHotKey(numericID: UInt32) {
        guard !isSuspended, let entry = entries.values.first(where: { $0.numericID == numericID }) else { return }
        entry.handler()
    }

    private func attachSystemHotkey(id: String, entry: Entry) throws {
        releaseSystemHotkey(id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: entry.numericID)
        let status = RegisterEventHotKey(
            entry.spec.keyCode, entry.spec.carbonModifiers & HotkeySpec.carbonModifierMask, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registrationFailed(status) }
        systemRefs[id] = ref
    }

    private func releaseSystemHotkey(_ id: String) {
        if let ref = systemRefs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotkeyEventCallback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotkeyError.handlerInstallFailed(status) }
        eventHandler = handler
    }
}

/// Carbon delivers application-target events on the main thread.
private func hotkeyEventCallback(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x504C_4D4E else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let numericID = hotKeyID.id
    MainActor.assumeIsolated {
        center.handleHotKey(numericID: numericID)
    }
    return noErr
}
