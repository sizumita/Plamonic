// Follows mlx-lm's BatchGenerator and BatchKVCache (Copyright © 2023 Apple Inc., MIT License).
// See THIRD_PARTY_NOTICES.md.

import Foundation
import MLX
import os

/// Set from any thread to stop a batched request; the batch notices it at its next step.
final class PlamoCancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() { state.withLock { $0 = true } }
    var isCancelled: Bool { state.withLock { $0 } }
}

/// Greedy generation for several prompts of one model at once (continuous batching).
///
/// A decode step costs about the same for a few sequences as for one: it is bound by encoding ~1,400 small
/// kernels and by reading the weights, not by arithmetic. So requests that arrive together decode together,
/// one token for every sequence per step.
///
/// Each prompt is processed alone with `PlamoGenerator.prefill` (so it reuses the prompt cache as before);
/// its keys and values then join the batch cache. Rows are left-padded so that they all end at the same slot,
/// and each row keeps its own positions, so every row computes what it would alone. A finished row leaves the
/// batch at once and a waiting request takes its place.
///
/// Not thread-safe: PlamoTranslationEngine drives it from its own queue.
final class PlamoBatchGenerator {
    let generator: PlamoGenerator
    /// Sequences decoded together; more requests wait for a free row.
    var maxBatchSize = 8
    /// Minimum interval between partial-text callbacks of a request.
    var partialInterval: TimeInterval = 0.05

    private final class Row {
        let prompt: [Int]
        let maxNewTokens: Int
        let onText: ((String) -> Void)?
        let cancellation: PlamoCancellationFlag
        let completion: (Result<PlamoGenerationOutput, Error>) -> Void

        var tokens: [Int] = []
        var decoder: PlamoStreamingDecoder
        var reused = 0
        /// The row's next input is its last prompt token, whose output is the first generated token.
        var feedsPrompt = true
        var admittedAt = Date()
        var firstTokenAt: Date?
        var lastEmit = Date.distantPast
        var pendingPartial = false

        init(
            prompt: [Int], maxNewTokens: Int, onText: ((String) -> Void)?, cancellation: PlamoCancellationFlag,
            decoder: PlamoStreamingDecoder, completion: @escaping (Result<PlamoGenerationOutput, Error>) -> Void
        ) {
            self.prompt = prompt
            self.maxNewTokens = max(1, maxNewTokens)
            self.onText = onText
            self.cancellation = cancellation
            self.decoder = decoder
            self.completion = completion
        }
    }

    private var waiting: [Row] = []
    /// Active sequences, in batch row order.
    private var rows: [Row] = []
    /// One cache per layer with a row per sequence.
    private var caches: [PlamoKVCache]
    /// Empty slots at the start of each row.
    private var leftPadding: [Int] = []
    /// [B] next input token of each row. Except for rows that still feed their prompt, it is also the row's
    /// newest output, not read yet: the next step is queued before it is read, as in mlx-lm.
    private var inputs: MLXArray?

    init(generator: PlamoGenerator) {
        self.generator = generator
        self.caches = generator.model.makeCaches()
    }

    var hasWork: Bool { !rows.isEmpty || !waiting.isEmpty }
    /// Sequences in the batch right now.
    var activeCount: Int { rows.count }

    /// Queues a prompt. `completion` runs on the driving queue, during a later `step` or `failAll`.
    /// A cancelled request completes with `CancellationError`.
    func submit(
        prompt: [Int], maxNewTokens: Int, onText: ((String) -> Void)?, cancellation: PlamoCancellationFlag,
        completion: @escaping (Result<PlamoGenerationOutput, Error>) -> Void
    ) {
        precondition(!prompt.isEmpty)
        waiting.append(
            Row(
                prompt: prompt, maxNewTokens: maxNewTokens, onText: onText, cancellation: cancellation,
                decoder: generator.tokenizer.makeStreamingDecoder(), completion: completion))
    }

    /// Completes every request with `error` and empties the batch (an MLX error, or the model is unloaded).
    func failAll(_ error: Error) {
        let all = rows + waiting
        rows = []
        waiting = []
        resetBatch()
        for row in all { row.completion(.failure(error)) }
    }

    /// Admits a waiting request, then decodes one token for every row and completes the rows that finished.
    /// Call it inside `withError`; on a throw, call `failAll`.
    ///
    /// At most one prompt is processed per step: a prompt costs several decode steps, so admitting a whole
    /// queue at once would hold every running row (and its streamed text) until all of them are done.
    func step() throws {
        dropCancelled()
        if rows.count < maxBatchSize, !waiting.isEmpty {
            let row = waiting.removeFirst()
            do {
                try admit(row)
            } catch {
                row.completion(.failure(error))
                throw error
            }
        }
        guard !rows.isEmpty, let current = inputs else { return }

        let next = decode(current)
        asyncEval(next)
        let values = current.asArray(Int32.self)

        var keep: [Int] = []
        let now = Date()
        for (index, row) in rows.enumerated() {
            if row.feedsPrompt {
                row.feedsPrompt = false
                keep.append(index)
            } else if receive(Int(values[index]), for: row, now: now) {
                keep.append(index)
            }
        }
        inputs = next
        if keep.count < rows.count { removeRows(keeping: keep) }
    }

    // MARK: - Rows

    /// Flags are set from other threads, so each is read once: a row that is removed is exactly a row that is
    /// completed (completing one twice would trap its continuation; removing one uncompleted would leak it).
    private func dropCancelled() {
        let waitingCancelled = waiting.map { $0.cancellation.isCancelled }
        if waitingCancelled.contains(true) {
            let cancelled = zip(waiting, waitingCancelled).filter { $0.1 }.map(\.0)
            waiting = zip(waiting, waitingCancelled).filter { !$0.1 }.map(\.0)
            for row in cancelled { row.completion(.failure(CancellationError())) }
        }
        let rowsCancelled = rows.map { $0.cancellation.isCancelled }
        guard rowsCancelled.contains(true) else { return }
        let cancelled = zip(rows, rowsCancelled).filter { $0.1 }.map(\.0)
        removeRows(keeping: rowsCancelled.indices.filter { !rowsCancelled[$0] })
        for row in cancelled { row.completion(.failure(CancellationError())) }
    }

    /// Processes the prompt alone (reusing the prompt cache) and adds its keys and values as a new row.
    private func admit(_ row: Row) throws {
        row.admittedAt = Date()
        row.reused = try generator.prefill(row.prompt)
        let contents = generator.promptCacheContents
        let length = row.prompt.count - 1
        let current = caches.first?.offset ?? 0
        let total = max(current, length)
        let count = rows.count

        for (cache, new) in zip(caches, contents) {
            guard total > 0 else { break }
            let template = new ?? cache.filled
            guard let template else { break }
            let old = cache.filled
            var keys = [Self.leftPad(new?.keys, rows: 1, to: total, like: template.keys)]
            var values = [Self.leftPad(new?.values, rows: 1, to: total, like: template.values)]
            if count > 0 {
                keys.insert(Self.leftPad(old?.keys, rows: count, to: total, like: template.keys), at: 0)
                values.insert(Self.leftPad(old?.values, rows: count, to: total, like: template.values), at: 0)
            }
            cache.replace(with: (concatenated(keys, axis: 0), concatenated(values, axis: 0)))
        }
        leftPadding = leftPadding.map { $0 + total - current } + [total - length]
        let last = MLXArray([Int32(row.prompt[row.prompt.count - 1])])
        inputs = inputs.map { concatenated([$0, last], axis: 0) } ?? last
        rows.append(row)
        // No eval here: the next decode step evaluates the joined cache, and the queued step keeps running.
        // The prompt cache stays valid for this graph when the next prefill replaces it (arrays are immutable).
    }

    /// `array` ([rows, heads, n, dim], or nil for n = 0) with zeros in front, to `length` slots.
    private static func leftPad(_ array: MLXArray?, rows: Int, to length: Int, like template: MLXArray) -> MLXArray {
        let have = array?.dim(2) ?? 0
        guard have < length else { return array! }
        let zeros = MLXArray.zeros(
            [rows, template.dim(1), length - have, template.dim(3)], dtype: template.dtype)
        guard let array, have > 0 else { return zeros }
        return concatenated([zeros, array], axis: 2)
    }

    /// Keeps the rows at `keep` (in order) and drops the padding every remaining row has.
    private func removeRows(keeping keep: [Int]) {
        rows = keep.map { rows[$0] }
        leftPadding = keep.map { leftPadding[$0] }
        guard !rows.isEmpty, let current = inputs else {
            resetBatch()
            return
        }
        let index = MLXArray(keep.map { Int32($0) })
        inputs = current.take(index, axis: 0)
        let trim = leftPadding.min() ?? 0
        for cache in caches {
            guard let filled = cache.filled else { continue }
            var keys = filled.keys.take(index, axis: 0)
            var values = filled.values.take(index, axis: 0)
            if trim > 0 {
                keys = keys[.ellipsis, trim..., 0...]
                values = values[.ellipsis, trim..., 0...]
            }
            cache.replace(with: (keys, values))
        }
        leftPadding = leftPadding.map { $0 - trim }
    }

    private func resetBatch() {
        for cache in caches { cache.reset() }
        leftPadding = []
        inputs = nil
    }

    // MARK: - Decoding

    private func decode(_ tokens: MLXArray) -> MLXArray {
        let model = generator.model
        let hidden = model.batchHiddenStates(tokens.reshaped(-1, 1), caches: caches, leftPadding: leftPadding)
        return argMax(model.logits(hidden[0..., -1, 0...]), axis: -1).asType(.int32)
    }

    /// Handles a generated token. Returns false when the row finished (and completes it).
    private func receive(_ token: Int, for row: Row, now: Date) -> Bool {
        if row.firstTokenAt == nil { row.firstTokenAt = now }
        if generator.stopTokens.contains(token) {
            complete(row, hitLimit: false, now: now)
            return false
        }
        row.tokens.append(token)
        if !row.decoder.append(token).isEmpty { row.pendingPartial = true }
        if let onText = row.onText, row.pendingPartial, now.timeIntervalSince(row.lastEmit) >= partialInterval {
            row.pendingPartial = false
            row.lastEmit = now
            onText(row.decoder.text)
        }
        if row.tokens.count >= row.maxNewTokens {
            complete(row, hitLimit: true, now: now)
            return false
        }
        return true
    }

    private func complete(_ row: Row, hitLimit: Bool, now: Date) {
        let first = row.firstTokenAt ?? now
        row.completion(
            .success(
                PlamoGenerationOutput(
                    tokens: row.tokens,
                    text: generator.tokenizer.decode(row.tokens),
                    promptTokens: row.prompt.count,
                    reusedPromptTokens: row.reused,
                    hitTokenLimit: hitLimit,
                    prefillTime: first.timeIntervalSince(row.admittedAt),
                    decodeTime: now.timeIntervalSince(first))))
    }
}
