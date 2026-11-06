import Foundation
import MLX
import os

/// Runs PLaMo translations. All model loading and MLX evaluation happens on the actor's own
/// serial queue, so calls are serialized and never block Swift's cooperative thread pool.
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
    /// Keys of `generators`, readable without waiting for the actor (which runs whole generations).
    private nonisolated let loadedKeys = OSAllocatedUnfairLock<Set<String>>(initialState: [])
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
        lastUsed[k] = nil
        Memory.clearCache()
    }

    public func unloadAll() {
        guard !generators.isEmpty else { return }
        generators.removeAll()
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
    public func translate(
        _ request: PlamoTranslationRequest,
        variant: PlamoModelVariant,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> PlamoTranslationResult {
        guard isLoaded(variant) || store.isInstalled(variant) else { throw PlamoError.modelNotInstalled(variant) }
        return try translate(request, modelDirectory: store.directory(for: variant), onPartial: onPartial)
    }

    public func translate(
        _ request: PlamoTranslationRequest,
        modelDirectory: URL,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> PlamoTranslationResult {
        let start = Date()
        var timings = PlamoTimings()
        try Task.checkCancellation()
        let (gen, loadTime) = try generator(for: modelDirectory)
        timings.load = loadTime
        defer {
            lastUsed[key(modelDirectory)] = Date()
            scheduleIdleCheck()
        }

        var output = try run(gen, request, timings: &timings, onPartial: onPartial)
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
                output = try run(gen, fallback, timings: &timings, onPartial: onPartial)
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
        _ gen: PlamoGenerator, _ request: PlamoTranslationRequest, timings: inout PlamoTimings,
        onPartial: (@Sendable (String) -> Void)?
    ) throws -> PlamoGenerationOutput {
        let t0 = Date()
        let prompt = try PlamoPromptBuilder.prompt(for: request)
        let ids = gen.tokenizer.encode(prompt)
        timings.tokenize += Date().timeIntervalSince(t0)
        let output: PlamoGenerationOutput
        do {
            // MLX reports C++ errors through a handler that would otherwise call fatalError.
            output = try withError {
                try gen.generate(
                    prompt: ids, maxNewTokens: request.effectiveMaxNewTokens, onText: onPartial.map { f in { f($0) } })
            }
        } catch let error as MLXError {
            gen.resetCache()
            throw PlamoError.inferenceFailed(error.localizedDescription)
        }
        timings.prefill += output.prefillTime
        timings.decode += output.decodeTime
        return output
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
            generators[k] = nil
            lastUsed[k] = nil
        }
        Memory.clearCache()
        scheduleIdleCheck()
    }
}
