import Combine
import Foundation

/// How the settings were obtained at launch.
struct SettingsLoadReport: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case defaults  // no settings file yet
        case file  // settings.json decoded normally
        case salvaged  // settings.json was damaged; the readable parts were kept
        case backup  // settings.json was missing or not JSON; settings.json.bak was used
        case reset  // nothing was readable; defaults were used
        /// settings.json exists but could not be read (permissions, I/O). settings.json.bak or the defaults
        /// are used, and nothing is saved this session so the file is not overwritten.
        case unreadable
    }

    var source: Source
    /// Dropped fields / profiles or read errors (English, for logs).
    var problems: [String] = []
    /// Where a damaged settings.json was moved so it is not overwritten.
    var quarantinedFileURL: URL? = nil
}

/// Owns the settings document: loads it, saves it (debounced, atomic) and publishes changes.
@MainActor
final class SettingsStore: ObservableObject {
    /// ~/Library/Application Support/Plamonic/settings.json
    nonisolated static var defaultFileURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Plamonic", isDirectory: true).appendingPathComponent("settings.json")
    }

    let fileURL: URL
    /// Copy of the previous launch's settings, written before the first save of a session.
    var backupURL: URL { fileURL.appendingPathExtension("bak") }

    @Published private(set) var document: SettingsDocument
    @Published private(set) var lastSaveError: String?
    private(set) var loadReport: SettingsLoadReport
    /// True when settings.json could not be read at launch: saving would replace it with what we have in memory.
    let isReadOnly: Bool

    private let saveDelay: TimeInterval
    private var saveTask: Task<Void, Never>?
    private var isDirty = false
    private var didBackUpThisSession = false
    private let changeSubject = PassthroughSubject<SettingsSnapshot, Never>()

    /// - Parameters:
    ///   - fileURL: settings file location; tests pass a temporary file.
    ///   - saveDelay: debounce interval for writes after a change.
    init(fileURL: URL = SettingsStore.defaultFileURL, saveDelay: TimeInterval = 0.5) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        let (document, report) = Self.load(from: fileURL)
        self.document = document
        self.loadReport = report
        self.isReadOnly = report.source == .unreadable
        if isReadOnly { lastSaveError = Self.readOnlyMessage }
        // Re-create settings.json right away if it had to be repaired.
        if report.source == .salvaged || report.source == .backup || report.source == .reset {
            isDirty = true
            scheduleSave()
        }
    }

    // MARK: - Reading

    var snapshot: SettingsSnapshot { SettingsSnapshot(document: document) }

    var global: GlobalSettings {
        get { document.global }
        set {
            var doc = document
            doc.global = SettingsNormalizer.normalized(newValue)
            commit(doc)
        }
    }

    /// Profiles stored in settings.json (created or edited by the user).
    var profiles: [AppProfile] { document.profiles }

    func userProfile(for bundleID: String) -> AppProfile? { snapshot.userProfile(for: bundleID) }

    func profileSource(for bundleID: String) -> ProfileSource { snapshot.profileSource(for: bundleID) }

    /// User profile -> preset -> default profile built from `global.defaultMode` / `global.defaultScope`.
    func profile(for bundleID: String, appName: String? = nil) -> AppProfile {
        snapshot.profile(for: bundleID, appName: appName)
    }

    func effectiveSettings(bundleID: String, appName: String? = nil) -> EffectiveSettings {
        snapshot.effectiveSettings(bundleID: bundleID, appName: appName)
    }

    /// Emits a snapshot on the main thread after every change (not on subscription).
    var changes: AnyPublisher<SettingsSnapshot, Never> { changeSubject.eraseToAnyPublisher() }

    /// Current effective settings for one app, then a new value whenever they change.
    func effectiveSettingsPublisher(bundleID: String, appName: String? = nil) -> AnyPublisher<EffectiveSettings, Never>
    {
        changeSubject
            .map { $0.effectiveSettings(bundleID: bundleID, appName: appName) }
            .prepend(effectiveSettings(bundleID: bundleID, appName: appName))
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Writing

    func updateGlobal(_ body: (inout GlobalSettings) -> Void) {
        var g = document.global
        body(&g)
        global = g
    }

    /// Stores a profile. A profile identical to its app's preset is removed instead, so later preset updates apply.
    func upsert(_ profile: AppProfile) {
        let profile = SettingsNormalizer.normalized(profile)
        var doc = document
        let index = doc.profiles.lastIndex { $0.bundleID.caseInsensitiveCompare(profile.bundleID) == .orderedSame }
        if let preset = AppPresets.preset(for: profile.bundleID), preset.profile == profile {
            if let index { doc.profiles.remove(at: index) }
        } else if let index {
            doc.profiles[index] = profile
        } else {
            doc.profiles.append(profile)
        }
        commit(doc)
    }

    /// Edits the resolved profile of an app and stores the result.
    func updateProfile(bundleID: String, appName: String? = nil, _ body: (inout AppProfile) -> Void) {
        var profile = self.profile(for: bundleID, appName: appName)
        body(&profile)
        upsert(profile)
    }

    /// Deletes the stored profile. The app falls back to its preset, or to the default profile.
    func removeProfile(bundleID: String) {
        var doc = document
        doc.profiles.removeAll { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
        commit(doc)
    }

    /// Discards the user's edits of a preset app. Returns false when the app has no preset
    /// (the stored profile is still removed, so the default profile applies).
    @discardableResult
    func resetToPreset(bundleID: String) -> Bool {
        removeProfile(bundleID: bundleID)
        return AppPresets.preset(for: bundleID) != nil
    }

    /// Restores every setting to its default and forgets all user profiles.
    func resetAll() {
        commit(SettingsDocument())
    }

    /// Posted by `flush()` before it saves, so settings text fields hand over the text still being edited
    /// (they commit when editing ends, not on every keystroke).
    nonisolated static let willFlushNotification = Notification.Name("SettingsStoreWillFlush")

    /// Writes pending changes now, including text still being edited. Call on app termination.
    func flush() {
        NotificationCenter.default.post(name: Self.willFlushNotification, object: self)
        save()
    }

    // MARK: - Private

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        guard !isReadOnly else {
            lastSaveError = Self.readOnlyMessage
            return
        }
        do {
            try write(document)
            isDirty = false
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    private func commit(_ newDocument: SettingsDocument) {
        guard newDocument != document else { return }
        document = newDocument
        isDirty = true
        scheduleSave()
        changeSubject.send(SettingsSnapshot(document: newDocument))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private static let readOnlyMessage =
        "settings.json を読み込めなかったため、上書きしないように保存を止めています。ファイルのアクセス権を確認して Plamonic を再起動してください。"

    private func write(_ doc: SettingsDocument) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !didBackUpThisSession {
            didBackUpThisSession = true
            if fm.fileExists(atPath: fileURL.path) { backUpCurrentFile() }
        }
        try Self.encode(doc).write(to: fileURL, options: .atomic)
    }

    /// Copies settings.json to settings.json.bak. The previous backup is replaced only once the copy exists,
    /// so a failed copy keeps it.
    private func backUpCurrentFile() {
        let fm = FileManager.default
        let staged = backupURL.appendingPathExtension("tmp")
        try? fm.removeItem(at: staged)
        do {
            try fm.copyItem(at: fileURL, to: staged)
            if fm.fileExists(atPath: backupURL.path) {
                _ = try fm.replaceItemAt(backupURL, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: backupURL)
            }
        } catch {
            try? fm.removeItem(at: staged)
        }
    }

    nonisolated static func encode(_ doc: SettingsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    nonisolated static func load(from url: URL) -> (SettingsDocument, SettingsLoadReport) {
        let fm = FileManager.default
        let backupURL = url.appendingPathExtension("bak")

        guard fm.fileExists(atPath: url.path) else {
            if let doc = decodeStrict(at: backupURL) {
                return (SettingsNormalizer.normalized(doc), SettingsLoadReport(source: .backup))
            }
            return (SettingsDocument(), SettingsLoadReport(source: .defaults))
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Unreadable (permissions, I/O): leave the file alone (the store does not save this session)
            // and run on the previous session's backup, or on the defaults.
            var report = SettingsLoadReport(
                source: .unreadable, problems: ["read failed: \(error.localizedDescription)"])
            if let doc = decodeStrict(at: backupURL) {
                report.problems.append("using settings.json.bak")
                return (SettingsNormalizer.normalized(doc), report)
            }
            return (SettingsDocument(), report)
        }

        if let doc = try? JSONDecoder().decode(SettingsDocument.self, from: data) {
            return (SettingsNormalizer.normalized(doc), SettingsLoadReport(source: .file))
        }

        // Damaged: move it aside so the next save does not destroy it, then recover what we can.
        let quarantined = quarantine(url)
        if let salvaged = SettingsFileRecovery.salvage(data) {
            var report = SettingsLoadReport(source: .salvaged, problems: salvaged.problems)
            report.quarantinedFileURL = quarantined
            return (SettingsNormalizer.normalized(salvaged.document), report)
        }
        if let doc = decodeStrict(at: backupURL) {
            var report = SettingsLoadReport(source: .backup, problems: ["settings.json is not valid JSON"])
            report.quarantinedFileURL = quarantined
            return (SettingsNormalizer.normalized(doc), report)
        }
        var report = SettingsLoadReport(source: .reset, problems: ["settings.json is not valid JSON"])
        report.quarantinedFileURL = quarantined
        return (SettingsDocument(), report)
    }

    private nonisolated static func decodeStrict(at url: URL) -> SettingsDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let doc = try? JSONDecoder().decode(SettingsDocument.self, from: data) { return doc }
        return SettingsFileRecovery.salvage(data)?.document
    }

    /// Renames a damaged file to settings.corrupt-<timestamp>.json next to it.
    private nonisolated static func quarantine(_ url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let fm = FileManager.default
        var target = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).corrupt-\(formatter.string(from: Date())).\(ext)")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem).corrupt-\(formatter.string(from: Date()))-\(n).\(ext)")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
