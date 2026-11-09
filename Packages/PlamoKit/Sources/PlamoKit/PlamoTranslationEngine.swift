import Foundation
import MLX
import os

/// Runs PLaMo translations. All model loading and MLX evaluation happens on the actor's own
/// serial queue, so it never blocks Swift's cooperative thread pool.
///
/// Concurrent translations with the same model are generated together (`PlamoBatchGenerator`): a decode
/// step for several sequences costs little more than for one. One driver task steps the batches and
/// yields between steps, so requests that arrive meanwhile join the running batch.
///
/// Several models can be loaded at once (e.g. a 0.8B draft model and a 2B final model).
/// Each loaded model keeps the KV cache of its last prompt and reuses the shared prefix.
public actor PlamoTranslationEngine {
    public nonisolated let store: PlamoModelStore
    private let queue = DispatchSerialQueue(label: "PlamoTranslationEngine", qos: .userInitiated)

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var generators: [String: PlamoGenerator] = [:] {
        didSet {
            let keys = Set(generators.keys)
            loadedKeys.withLock { $0 = keys }
        }
    }
    /// Keys of `generators`, readable without waiting for the actor (which runs model loads and decode steps).
    private nonisolated let loadedKeys = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private var batches: [String: PlamoBatchGenerator] = [:]
    /// Steps the batches while any has work.
    private var driver: Task<Void, Never>?
    private var driverTurn = 0
    private var maxBatchSize = 8
    private var lastUsed: [String: Date] = [:]
    private var reusePromptPrefix = true
    private var idleUnloadInterval: TimeInterval?
    private var idleTask: Task<Void, Never>?

    /// - Parameters:
    ///   - idleUnloadMinutes: unload a model after this many minutes without use; nil keeps models loaded.
    ///   - cacheLimitBytes: MLX buffer cache limit (memory kept for reuse after arrays are freed).
    public init(
        store: PlamoModelStore = PlamoModelStore(),
        idleUnloadMinutes: Double? = 10,
        cacheLimitBytes: Int = 256 * 1024 * 1024
    ) {
        self.store = store
        self.idleUnloadInterval = idleUnloadMinutes.map { max(1, $0 * 60) }
        Memory.cacheLimit = cacheLimitBytes
    }

    // MARK: - Loading

    /// Variants currently in memory.
    public var loadedVariants: [PlamoModelVariant] {
        PlamoModelVariant.allCases.filter { generators[key(store.directory(for: $0))] != nil }
    }

    public func isLoaded(_ variant: PlamoModelVariant) -> Bool {
        generators[key(store.directory(for: variant))] != nil
    }

    /// Same answer as `isLoaded` without waiting for a running generation or load: it reflects every
    /// load and unload (including idle unloads) as soon as the engine made it.
    public nonisolated func isLoadedSnapshot(_ variant: PlamoModelVariant) -> Bool {
        let k = key(store.directory(for: variant))
        return loadedKeys.withLock { $0.contains(k) }
    }

    /// nil disables automatic unloading.
    public func setIdleUnloadMinutes(_ minutes: Double?) {
        idleUnloadInterval = minutes.map { max(1, $0 * 60) }
        scheduleIdleCheck()
    }

    /// Loads a variant from the store. Returns the load time in seconds (0 when already loaded).
    @discardableResult
    public func load(_ variant: PlamoModelVariant) throws -> TimeInterval {
        let dir = store.directory(for: variant)
        guard store.isInstalled(variant) else { throw PlamoError.modelNotInstalled(variant) }
        return try generator(for: dir).1
    }

    /// Loads a model from any directory with the PFN MLX layout.
    @discardableResult
    public func load(directory: URL) throws -> TimeInterval {
        try generator(for: directory).1
    }

    public func unload(_ variant: PlamoModelVariant) {
        unload(directory: store.directory(for: variant))
    }

    public func unload(directory: URL) {
        let k = key(directory)
        guard generators.removeValue(forKey: k) != nil else { return }
        // Running translations stop as if cancelled.
        batches.removeValue(forKey: k)?.failAll(CancellationError())
        lastUsed[k] = nil
        Memory.clearCache()
    }

    public func unloadAll() {
        guard !generators.isEmpty else { return }
        generators.removeAll()
        let running = batches.values
        batches.removeAll()
        for batch in running { batch.failAll(CancellationError()) }
        lastUsed.removeAll()
        idleTask?.cancel()
        idleTask = nil
        Memory.clearCache()
    }

    /// Enables or disables reuse of the previous prompt's KV cache (on by default).
    public func setPromptCacheReuse(_ enabled: Bool) {
        reusePromptPrefix = enabled
        for gen in generators.values { gen.reusePromptPrefix = enabled }
    }

    /// Sequences of one model generated together (default 8); further translations wait for a free row.
    public func setMaxBatchSize(_ size: Int) {
        maxBatchSize = max(1, size)
        for batch in batches.values { batch.maxBatchSize = maxBatchSize }
    }

    /// Forgets the cached prompts of all loaded models (the models stay loaded).
    public func clearPromptCaches() {
        for gen in generators.values { gen.resetCache() }
        Memory.clearCache()
    }

    /// Unloads the variant if needed and deletes its files.
    public func deleteModel(_ variant: PlamoModelVariant) throws {
        unload(variant)
        try store.delete(variant)
    }

    // MARK: - Translation

    /// Translates with an installed variant (loading it on first use).
    /// `onPartial` receives the whole partial translation so far, throttled; it is called on the
    /// engine's queue and must return quickly. Cancel the calling Task to stop generation.
    /// Translations running at the same time with the same model are generated in one batch.
    public func translate(
        _ request: PlamoTranslationRequest,
        variant: PlamoModelVariant,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> PlamoTranslationResult {
        guard isLoaded(variant) || store.isInstalled(variant) else { throw PlamoError.modelNotInstalled(variant) }
        return try await translate(request, modelDirectory: store.directory(for: variant), onPartial: onPartial)
    }

    public func translate(
        _ request: PlamoTranslationRequest,
        modelDirectory: URL,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> PlamoTranslationResult {
        let start = Date()
        var timings = PlamoTimings()
        try Task.checkCancellation()
        let (gen, loadTime) = try generator(for: modelDirectory)
        timings.load = loadTime
        let k = key(modelDirectory)
        defer {
            lastUsed[k] = Date()
            scheduleIdleCheck()
        }

        var output = try await run(gen, key: k, request, timings: &timings, onPartial: onPartial)
        var retried = false
        var wrong = PlamoOutputCheck.looksWrong(
            input: request.text, output: output.text, targetLanguage: request.targetLanguage)
        if wrong {
            var fallback = request
            if !request.history.isEmpty {
                fallback.history = []
            } else if !(request.context ?? "").isEmpty {
                fallback.context = nil
            }
            if fallback != request {
                output = try await run(gen, key: k, fallback, timings: &timings, onPartial: onPartial)
                retried = true
                wrong = PlamoOutputCheck.looksWrong(
                    input: request.text, output: output.text, targetLanguage: request.targetLanguage)
            }
        }
        timings.total = Date().timeIntervalSince(start)
        return PlamoTranslationResult(
            text: output.text,
            promptTokens: output.promptTokens,
            reusedPromptTokens: output.reusedPromptTokens,
            generatedTokens: output.tokens.count,
            hitTokenLimit: output.hitTokenLimit,
            retriedWithoutHistory: retried,
            looksWrong: wrong,
            timings: timings)
    }

    /// Token ids for a prompt, using a loaded (or loadable) model's tokenizer.
    public func tokenize(_ text: String, variant: PlamoModelVariant) throws -> [Int] {
        guard isLoaded(variant) || store.isInstalled(variant) else { throw PlamoError.modelNotInstalled(variant) }
        return try generator(for: store.directory(for: variant)).0.tokenizer.encode(text)
    }

    // MARK: - Internals

    private func run(
        _ gen: PlamoGenerator, key k: String, _ request: PlamoTranslationRequest, timings: inout PlamoTimings,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> PlamoGenerationOutput {
        let t0 = Date()
        let prompt = try PlamoPromptBuilder.prompt(for: request)
        let ids = gen.tokenizer.encode(prompt)
        timings.tokenize += Date().timeIntervalSince(t0)
        let cancellation = PlamoCancellationFlag()
        let maxNewTokens = request.effectiveMaxNewTokens
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PlamoGenerationOutput, Error>) in
                submit(
                    key: k, generator: gen, prompt: ids, maxNewTokens: maxNewTokens, onPartial: onPartial,
                    cancellation: cancellation
                ) { continuation.resume(with: $0) }
            }
        } onCancel: {
            cancellation.cancel()
        }
        timings.prefill += output.prefillTime
        timings.decode += output.decodeTime
        return output
    }

    private func submit(
        key k: String, generator gen: PlamoGenerator, prompt: [Int], maxNewTokens: Int,
        onPartial: (@Sendable (String) -> Void)?, cancellation: PlamoCancellationFlag,
        completion: @escaping (Result<PlamoGenerationOutput, Error>) -> Void
    ) {
        // The model may have been unloaded while the prompt was built.
        guard generators[k] === gen else {
            completion(.failure(CancellationError()))
            return
        }
        let batch = batches[k] ?? {
            let created = PlamoBatchGenerator(generator: gen)
            created.maxBatchSize = maxBatchSize
            batches[k] = created
            return created
        }()
        batch.submit(
            prompt: prompt, maxNewTokens: maxNewTokens, onText: onPartial.map { f in { f($0) } },
            cancellation: cancellation, completion: completion)
        if driver == nil {
            driver = Task { await self.drive() }
        }
    }

    /// Steps the batches with work in turn, one step each, until none has work. Between steps it yields
    /// the actor, so new requests join, cancelled ones leave and other calls are not held for a whole
    /// generation.
    private func drive() async {
        while true {
            let busy = batches.filter { $0.value.hasWork }.sorted { $0.key < $1.key }
            guard !busy.isEmpty else { break }
            driverTurn &+= 1
            let (k, batch) = busy[driverTurn % busy.count]
            do {
                // MLX reports C++ errors through a handler that would otherwise call fatalError.
                try withError { try batch.step() }
            } catch {
                let failure = (error as? MLXError).map { PlamoError.inferenceFailed($0.localizedDescription) } ?? error
                batch.failAll(failure)
                generators[k]?.resetCache()
            }
            await Task.yield()
        }
        driver = nil
    }

    private nonisolated func key(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func generator(for directory: URL) throws -> (PlamoGenerator, TimeInterval) {
        let k = key(directory)
        if let existing = generators[k] { return (existing, 0) }
        let gen: PlamoGenerator
        do {
            gen = try withError { try PlamoGenerator(directory: directory) }
        } catch let error as PlamoError {
            throw error
        } catch let error as MLXError {
            Memory.clearCache()
            throw PlamoError.invalidModel(error.localizedDescription)
        } catch {
            throw PlamoError.invalidModel("\(error)")
        }
        let warmStart = Date()
        do {
            // The loader checks every shape against config.json; this catches what is left
            // (e.g. a kernel MLX cannot build). The generator is dropped on failure.
            try withError { try gen.warmUp() }
        } catch {
            Memory.clearCache()
            throw PlamoError.invalidModel(error.localizedDescription)
        }
        gen.reusePromptPrefix = reusePromptPrefix
        generators[k] = gen
        lastUsed[k] = Date()
        scheduleIdleCheck()
        return (gen, gen.loadTime + Date().timeIntervalSince(warmStart))
    }

    private func scheduleIdleCheck() {
        idleTask?.cancel()
        idleTask = nil
        guard let interval = idleUnloadInterval, !generators.isEmpty else { return }
        let now = Date()
        let earliest = lastUsed.values.min() ?? now
        let delay = max(1, earliest.addingTimeInterval(interval).timeIntervalSince(now))
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unloadIdleModels()
        }
    }

    private func unloadIdleModels() {
        guard let interval = idleUnloadInterval else { return }
        let now = Date()
        for (k, date) in lastUsed where now.timeIntervalSince(date) >= interval - 0.5 {
            // A model that is generating is in use.
            guard batches[k]?.hasWork != true else {
                lastUsed[k] = now
                continue
            }
            generators[k] = nil
            batches[k] = nil
            lastUsed[k] = nil
        }
        Memory.clearCache()
        scheduleIdleCheck()
    }
}
