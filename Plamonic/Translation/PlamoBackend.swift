import Foundation
import PlamoKit

/// What the backend is doing with models, for the menu bar status line.
struct ModelLoadActivity: Equatable, Sendable {
    /// Model being loaded into memory right now.
    var loading: ModelSize?
    var lastLoadSeconds: TimeInterval?
    var lastError: String?
}

/// TranslationBackend and ModelLibraryBackend on top of PlamoKit's engine and model store.
final class PlamoBackend: TranslationBackend, ModelLibraryBackend, @unchecked Sendable {
    let engine: PlamoTranslationEngine
    let store: PlamoModelStore

    /// Called on an arbitrary thread whenever `loadActivity` changes.
    var onLoadActivityChanged: (@Sendable (ModelLoadActivity) -> Void)? {
        get { withLock { _onLoadActivityChanged } }
        set { withLock { _onLoadActivityChanged = newValue } }
    }

    var loadActivity: ModelLoadActivity { withLock { _loadActivity } }

    private let lock = NSLock()
    private var _onLoadActivityChanged: (@Sendable (ModelLoadActivity) -> Void)?
    private var _loadActivity = ModelLoadActivity()
    private var downloads: [ModelSize: Task<Void, Error>] = [:]
    private var preloadTask: Task<Void, Never>?
    private var preloadGeneration = 0
    private var activeCalls = 0
    private var lastCallEnd = Date.distantPast

    /// Models after the first one wait until no translation ran for this long.
    private static let preloadIdleDelay: TimeInterval = 1.5

    init(store: PlamoModelStore = PlamoModelStore(), idleUnloadMinutes: Int = 15) {
        self.store = store
        self.engine = PlamoTranslationEngine(store: store, idleUnloadMinutes: Self.idleMinutes(idleUnloadMinutes))
    }

    static func variant(_ size: ModelSize) -> PlamoModelVariant {
        // Both enums use the Hugging Face size names as raw values.
        PlamoModelVariant(rawValue: size.rawValue) ?? .b0_8
    }

    static func size(_ variant: PlamoModelVariant) -> ModelSize {
        ModelSize(rawValue: variant.rawValue) ?? .b0_8
    }

    private static func idleMinutes(_ minutes: Int) -> Double? {
        minutes > 0 ? Double(minutes) : nil
    }

    // MARK: - Settings

    /// 0 keeps models loaded.
    func setIdleUnloadMinutes(_ minutes: Int) {
        let value = Self.idleMinutes(minutes)
        Task { await engine.setIdleUnloadMinutes(value) }
    }

    /// Loads the given models in the background, in order, skipping missing or loaded ones.
    /// The first loads right away; the others wait until the engine is idle, so a large final model
    /// never delays the first drafts (a final job that comes first loads it on demand).
    /// A newer call replaces the queue of an older one (a load already running finishes).
    func preload(_ models: [ModelSize]) {
        let wanted = models.reduce(into: [ModelSize]()) { if !$0.contains($1) { $0.append($1) } }
            .filter { store.isInstalled(Self.variant($0)) }
        guard !wanted.isEmpty else { return }
        let generation: Int = withLock {
            preloadGeneration += 1
            return preloadGeneration
        }
        let previous = withLock { preloadTask }
        let task = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            for (index, model) in wanted.enumerated() {
                guard let self, self.isCurrentPreload(generation) else { return }
                if index > 0 {
                    let deadline = Date().addingTimeInterval(60)
                    while !self.isIdle(), Date() < deadline {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard self.isCurrentPreload(generation) else { return }
                    }
                }
                await self.ensureLoaded(model)
            }
        }
        withLock { preloadTask = task }
    }

    /// Loads one model if needed and reports it through `loadActivity`.
    func ensureLoaded(_ model: ModelSize) async {
        let variant = Self.variant(model)
        guard await !engine.isLoaded(variant) else { return }
        updateActivity { $0.loading = model }
        do {
            let seconds = try await engine.load(variant)
            updateActivity {
                $0.loading = nil
                $0.lastLoadSeconds = seconds
                $0.lastError = nil
            }
        } catch {
            updateActivity {
                $0.loading = nil
                $0.lastError = error.localizedDescription
            }
        }
    }

    private func isCurrentPreload(_ generation: Int) -> Bool {
        withLock { preloadGeneration == generation }
    }

    private func isIdle() -> Bool {
        withLock { activeCalls == 0 && Date().timeIntervalSince(lastCallEnd) >= Self.preloadIdleDelay }
    }

    func loadedModels() async -> [ModelSize] {
        await engine.loadedVariants.map(Self.size)
    }

    // MARK: - TranslationBackend

    func translate(
        _ request: TranslationBackendRequest, model: ModelSize, onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let variant = Self.variant(model)
        let plamoRequest = PlamoTranslationRequest(
            text: request.text,
            targetLanguage: request.targetLanguage,
            sourceLanguage: request.sourceLanguage,
            context: request.context,
            glossary: request.glossary.map { PlamoGlossaryEntry(source: $0.source, target: $0.target) },
            form: request.form,
            history: request.history.map { PlamoHistoryPair(source: $0.source, translation: $0.translation) },
            maxNewTokens: request.maxNewTokens > 0 ? request.maxNewTokens : nil)
        withLock { activeCalls += 1 }
        defer {
            withLock {
                activeCalls -= 1
                lastCallEnd = Date()
            }
        }
        do {
            try Task.checkCancellation()
            // Show "loading" in the menu when this call has to load the model first.
            let needsLoad = await !engine.isLoaded(variant)
            if needsLoad { updateActivity { $0.loading = model } }
            let result: PlamoTranslationResult
            do {
                result = try await engine.translate(plamoRequest, variant: variant, onPartial: onPartial)
            } catch {
                if needsLoad { updateActivity { $0.loading = nil } }
                throw error
            }
            if needsLoad {
                updateActivity {
                    $0.loading = nil
                    $0.lastLoadSeconds = result.timings.load
                    $0.lastError = nil
                }
            }
            return result.text
        } catch is CancellationError {
            throw TranslationBackendError.cancelled
        } catch PlamoError.modelNotInstalled {
            throw TranslationBackendError.modelNotInstalled(model)
        } catch {
            if Task.isCancelled { throw TranslationBackendError.cancelled }
            throw TranslationBackendError.failed(error.localizedDescription)
        }
    }

    /// Cheap: a `.complete` marker check for downloaded models.
    func isModelInstalled(_ model: ModelSize) -> Bool {
        store.isInstalled(Self.variant(model))
    }

    // MARK: - ModelLibraryBackend

    func installState(_ model: ModelSize) async -> ModelInstallState {
        let variant = Self.variant(model)
        var state = ModelInstallState()
        state.downloading = withLock { downloads[model] != nil }
        state.installed = !state.downloading && store.isInstalled(variant)
        state.bytesOnDisk = state.installed ? store.installedBytes(variant) : 0
        // Files kept by a failed download; the next download resumes from them.
        state.partialBytes = state.installed || state.downloading ? 0 : store.partialDownloadBytes(variant)
        // Not `await engine.isLoaded`: the engine actor runs whole generations and loads, so asking it
        // would keep the Models pane waiting behind them.
        state.loaded = engine.isLoadedSnapshot(variant)
        return state
    }

    func download(_ model: ModelSize, progress: @escaping @Sendable (Double) -> Void) async throws {
        let variant = Self.variant(model)
        let task: Task<Void, Error> = withLock {
            if let existing = downloads[model] { return existing }
            let store = self.store
            let created = Task<Void, Error>.detached(priority: .utility) {
                try await store.download(variant) { progress($0.fractionCompleted) }
            }
            downloads[model] = created
            return created
        }
        defer { withLock { if downloads[model] == task { downloads[model] = nil } } }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw TranslationBackendError.cancelled
        } catch let error as PlamoError {
            throw TranslationBackendError.failed(error.localizedDescription)
        }
    }

    func cancelDownload(_ model: ModelSize) async {
        let task = withLock { downloads[model] }
        task?.cancel()
        _ = await task?.result
    }

    func delete(_ model: ModelSize) async throws {
        do {
            try await engine.deleteModel(Self.variant(model))
        } catch {
            throw TranslationBackendError.failed(error.localizedDescription)
        }
    }

    func unloadAll() async {
        withLock {
            preloadGeneration += 1
            preloadTask?.cancel()
        }
        await engine.unloadAll()
    }

    // MARK: - Private

    private func updateActivity(_ body: (inout ModelLoadActivity) -> Void) {
        let (changed, value, callback): (Bool, ModelLoadActivity, (@Sendable (ModelLoadActivity) -> Void)?) =
            withLock {
                var next = _loadActivity
                body(&next)
                let changed = next != _loadActivity
                _loadActivity = next
                return (changed, next, _onLoadActivityChanged)
            }
        if changed { callback?(value) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
