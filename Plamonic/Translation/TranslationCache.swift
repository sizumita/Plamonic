import Foundation

/// Everything that determines a translation except the model.
struct TranslationSubject: Hashable, Sendable {
    /// What the model translates: normalized by `TextSanitizer.normalize`, with `[anchor](n)` markers around
    /// natural-language links (`TranslationLinks`). Texts with such links therefore have their own cache entries.
    var text: String
    var targetLanguage: String
    /// Source language hint sent to the model (nil = automatic).
    var sourceLanguage: String? = nil
    /// "plain" / "polite" or nil.
    var form: String?
    /// Sanitized context ("" when none).
    var context: String
    /// `TranslationSubject.fingerprint(of:)` of the glossary terms sent with the request ("" when none).
    var glossaryFingerprint: String

    func key(for model: ModelSize) -> TranslationKey {
        TranslationKey(
            text: text, targetLanguage: targetLanguage, sourceLanguage: sourceLanguage, form: form,
            context: context, glossaryFingerprint: glossaryFingerprint, model: model)
    }

    /// Stable across launches (FNV-1a 64), so persisted keys stay valid.
    static func fingerprint(of glossary: [GlossaryTerm]) -> String {
        guard !glossary.isEmpty else { return "" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        for term in glossary {
            mix(term.source)
            mix("\u{1F}")
            mix(term.target)
            mix("\u{1E}")
        }
        return String(hash, radix: 16)
    }
}

/// Cache key: one translation of one text with one model.
struct TranslationKey: Hashable, Codable, Sendable {
    var text: String
    var targetLanguage: String
    var sourceLanguage: String? = nil
    var form: String?
    var context: String
    var glossaryFingerprint: String
    var model: ModelSize

    var subject: TranslationSubject {
        TranslationSubject(
            text: text, targetLanguage: targetLanguage, sourceLanguage: sourceLanguage, form: form,
            context: context, glossaryFingerprint: glossaryFingerprint)
    }
}

struct TranslationCacheEntry: Codable, Hashable, Sendable {
    var translation: String
    var model: ModelSize
    var timestamp: Date
}

/// Result of `TranslationCache.best(for:finalModel:draftModel:)`.
struct CachedTranslation: Hashable, Sendable {
    var translation: String
    var model: ModelSize
    var timestamp: Date
    /// true when produced by the final model.
    var isFinal: Bool
}

/// Thread-safe LRU cache of translations with optional JSON persistence.
final class TranslationCache: @unchecked Sendable {
    static var defaultFileURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Plamonic", isDirectory: true)
            .appendingPathComponent("translation-cache.json")
    }

    let fileURL: URL?
    private let writeDelay: TimeInterval
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "io.smdr.Plamonic.TranslationCache.io", qos: .utility)

    // LRU: `head` is the most recently used node, `tail` the least.
    private var nodes: [TranslationKey: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var _capacity: Int
    private var _persistenceEnabled: Bool
    private var writeScheduled = false
    /// The load started by `init` has not merged the file yet (`clear()` cancels it).
    private var initialLoadPending = false

    private final class Node {
        let key: TranslationKey
        var entry: TranslationCacheEntry
        // Weak links: `nodes` owns every node, so dropping it frees the list without cycles.
        weak var previous: Node?
        weak var next: Node?

        init(key: TranslationKey, entry: TranslationCacheEntry) {
            self.key = key
            self.entry = entry
        }
    }

    /// With persistence enabled, starts loading `fileURL` on a background queue (a large file would
    /// stall the caller; see `waitUntilLoaded()`). With it disabled, deletes a file left by an
    /// earlier run, since it holds other apps' text.
    /// - Parameters:
    ///   - fileURL: nil disables persistence entirely.
    ///   - writeDelay: changes are written at most once per this interval; entries stored in the
    ///     meantime join the pending write. `flush()` writes the rest when the app quits.
    init(
        capacity: Int = 5000, fileURL: URL? = TranslationCache.defaultFileURL, persistenceEnabled: Bool = true,
        writeDelay: TimeInterval = 30
    ) {
        self._capacity = max(1, capacity)
        self.fileURL = fileURL
        self._persistenceEnabled = persistenceEnabled && fileURL != nil
        self.writeDelay = writeDelay
        guard let fileURL else { return }
        if _persistenceEnabled {
            initialLoadPending = true
            ioQueue.async { [weak self] in self?.initialLoad() }
        } else {
            ioQueue.async { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    var capacity: Int {
        get { withLock { _capacity } }
        set {
            let changed: Bool = withLock {
                let value = max(1, newValue)
                guard value != _capacity else { return false }
                _capacity = value
                return evictOverflow()
            }
            if changed { scheduleWrite() }
        }
    }

    /// Turning persistence off deletes the file (it holds other apps' text).
    var isPersistenceEnabled: Bool {
        get { withLock { _persistenceEnabled } }
        set {
            let (enable, disable): (Bool, Bool) = withLock {
                let value = newValue && fileURL != nil
                guard value != _persistenceEnabled else { return (false, false) }
                _persistenceEnabled = value
                return (value, !value)
            }
            if enable { scheduleWrite() }
            if disable, let fileURL {
                ioQueue.async { try? FileManager.default.removeItem(at: fileURL) }
            }
        }
    }

    var count: Int { withLock { nodes.count } }

    // MARK: - Lookup

    /// Returns the entry and marks it as recently used.
    func lookup(_ key: TranslationKey) -> TranslationCacheEntry? {
        withLock {
            guard let node = nodes[key] else { return nil }
            moveToFront(node)
            return node.entry
        }
    }

    /// Returns the entry without touching the LRU order.
    func peek(_ key: TranslationKey) -> TranslationCacheEntry? {
        withLock { nodes[key]?.entry }
    }

    func contains(_ key: TranslationKey) -> Bool {
        withLock { nodes[key] != nil }
    }

    /// The best translation available for `subject`: the final model's result, else the draft model's,
    /// else any other model's (largest first). Only a `finalModel` result has `isFinal == true`.
    func best(
        for subject: TranslationSubject, finalModel: ModelSize?, draftModel: ModelSize?, touch: Bool = true
    ) -> CachedTranslation? {
        withLock {
            var order: [ModelSize] = []
            if let finalModel { order.append(finalModel) }
            if let draftModel, draftModel != finalModel { order.append(draftModel) }
            for model in ModelSize.allCases.reversed() where !order.contains(model) { order.append(model) }
            for model in order {
                guard let node = nodes[subject.key(for: model)] else { continue }
                if touch { moveToFront(node) }
                return CachedTranslation(
                    translation: node.entry.translation, model: model, timestamp: node.entry.timestamp,
                    isFinal: model == finalModel)
            }
            return nil
        }
    }

    // MARK: - Mutation

    func store(_ translation: String, for key: TranslationKey, date: Date = Date()) {
        let entry = TranslationCacheEntry(translation: translation, model: key.model, timestamp: date)
        withLock { insert(key, entry) }
        scheduleWrite()
    }

    func remove(_ key: TranslationKey) {
        let removed: Bool = withLock {
            guard let node = nodes.removeValue(forKey: key) else { return false }
            unlink(node)
            return true
        }
        if removed { scheduleWrite() }
    }

    /// Removes every entry and the file on disk.
    func clear() {
        withLock {
            nodes.removeAll()
            head = nil
            tail = nil
            writeScheduled = false
            initialLoadPending = false
        }
        if let fileURL {
            ioQueue.async { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    /// Entries from least to most recently used.
    func allEntries() -> [(key: TranslationKey, entry: TranslationCacheEntry)] {
        withLock { orderedOldestFirst() }
    }

    // MARK: - Persistence

    private struct PersistedFile: Codable {
        var version: Int
        var entries: [PersistedEntry]
    }

    private struct PersistedEntry: Codable {
        var key: TranslationKey
        var translation: String
        var timestamp: Date
    }

    /// 2: keys carry the source language. Version 1 keys did not record it, so those files are ignored.
    private static let fileVersion = 2

    /// Merges the file into memory. Entries already in memory win; loaded ones count as older.
    func load() {
        guard let file = readFile() else { return }
        withLock { merge(file) }
    }

    /// Blocks until the load started by `init` (and any other file work queued so far) has run.
    func waitUntilLoaded() {
        ioQueue.sync {}
    }

    /// Writes pending changes now (call before the app quits). Blocks until done.
    func flush() {
        ioQueue.sync { writeNow() }
    }

    /// Runs on `ioQueue`, before any write. Skipped when `clear()` ran first.
    private func initialLoad() {
        guard withLock({ initialLoadPending }) else { return }
        let file = readFile()
        withLock {
            guard initialLoadPending else { return }
            initialLoadPending = false
            if let file { merge(file) }
        }
    }

    private func readFile() -> PersistedFile? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(PersistedFile.self, from: data),
            file.version == Self.fileVersion
        else { return nil }
        return file
    }

    private func scheduleWrite() {
        let schedule: Bool = withLock {
            guard _persistenceEnabled, !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard schedule else { return }
        ioQueue.asyncAfter(deadline: .now() + writeDelay) { [weak self] in
            self?.writeNow()
        }
    }

    /// Runs on `ioQueue`.
    private func writeNow() {
        let snapshot: (entries: [PersistedEntry], enabled: Bool) = withLock {
            writeScheduled = false
            let entries = orderedOldestFirst().map {
                PersistedEntry(key: $0.key, translation: $0.entry.translation, timestamp: $0.entry.timestamp)
            }
            return (entries, _persistenceEnabled)
        }
        guard snapshot.enabled, let fileURL else { return }
        let fileManager = FileManager.default
        if snapshot.entries.isEmpty {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(PersistedFile(version: Self.fileVersion, entries: snapshot.entries))
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Plamonic: failed to save the translation cache: \(error.localizedDescription)")
        }
    }

    // MARK: - LRU internals (call with the lock held)

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func insert(_ key: TranslationKey, _ entry: TranslationCacheEntry) {
        if let node = nodes[key] {
            node.entry = entry
            moveToFront(node)
            return
        }
        let node = Node(key: key, entry: entry)
        nodes[key] = node
        pushFront(node)
        _ = evictOverflow()
    }

    private func merge(_ file: PersistedFile) {
        // The file is oldest-first; append each one behind the current tail in reverse
        // so the newest loaded entry ends up closest to the in-memory ones.
        for item in file.entries.reversed() where nodes[item.key] == nil {
            guard nodes.count < _capacity else { break }
            let node = Node(
                key: item.key,
                entry: TranslationCacheEntry(
                    translation: item.translation, model: item.key.model, timestamp: item.timestamp))
            nodes[item.key] = node
            appendToBack(node)
        }
    }

    @discardableResult
    private func evictOverflow() -> Bool {
        var evicted = false
        while nodes.count > _capacity, let last = tail {
            unlink(last)
            nodes.removeValue(forKey: last.key)
            evicted = true
        }
        return evicted
    }

    private func pushFront(_ node: Node) {
        node.previous = nil
        node.next = head
        head?.previous = node
        head = node
        if tail == nil { tail = node }
    }

    private func appendToBack(_ node: Node) {
        node.next = nil
        node.previous = tail
        tail?.next = node
        tail = node
        if head == nil { head = node }
    }

    private func unlink(_ node: Node) {
        if let previous = node.previous { previous.next = node.next } else { head = node.next }
        if let next = node.next { next.previous = node.previous } else { tail = node.previous }
        node.previous = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        pushFront(node)
    }

    private func orderedOldestFirst() -> [(key: TranslationKey, entry: TranslationCacheEntry)] {
        var result: [(key: TranslationKey, entry: TranslationCacheEntry)] = []
        result.reserveCapacity(nodes.count)
        var node = tail
        while let current = node {
            result.append((current.key, current.entry))
            node = current.previous
        }
        return result
    }
}
