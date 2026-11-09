// Follows mlx-lm (Copyright © 2023 Apple Inc., MIT License) as used by modeling_plamo_mlx.py.
// See THIRD_PARTY_NOTICES.md.

import Foundation
import MLX

struct PlamoGenerationOutput {
    var tokens: [Int]
    var text: String
    var promptTokens: Int
    var reusedPromptTokens: Int
    var hitTokenLimit: Bool
    var prefillTime: TimeInterval
    var decodeTime: TimeInterval
}

/// One loaded model with its tokenizer and the KV cache of the last request.
/// Not thread-safe: callers serialize access (PlamoTranslationEngine does).
final class PlamoGenerator {
    let directory: URL
    let model: Plamo3Model
    let tokenizer: PlamoTokenizer
    let stopTokens: Set<Int>
    let loadTime: TimeInterval

    /// Tokens whose keys/values are in `caches`, in order.
    private var cachedTokens: [Int] = []
    private var caches: [PlamoKVCache]

    var prefillChunkSize = 512
    /// Reuse the KV cache of the longest common prompt prefix with the previous request.
    var reusePromptPrefix = true
    /// Minimum interval between partial-text callbacks.
    var partialInterval: TimeInterval = 0.05

    init(directory: URL) throws {
        let start = Date()
        self.directory = directory
        let tokenizer = try PlamoTokenizer(directory: directory)
        let model = try PlamoModelLoader.load(directory: directory)
        // Token ids index the embedding; a larger vocabulary belongs to another model.
        guard tokenizer.vocabSize <= model.config.vocabSize else {
            throw PlamoError.invalidModel(
                "tokenizer.jsonl の語彙数 (\(tokenizer.vocabSize)) が vocab_size (\(model.config.vocabSize)) を超えています")
        }
        self.tokenizer = tokenizer
        self.model = model
        self.stopTokens = Self.readStopTokens(directory: directory)
        self.caches = model.makeCaches()
        self.loadTime = Date().timeIntervalSince(start)
    }

    /// generation_config.json `eos_token_id` (an int or a list); PLaMo uses [1, 16].
    static func readStopTokens(directory: URL) -> Set<Int> {
        let url = directory.appendingPathComponent("generation_config.json")
        if let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let list = json["eos_token_id"] as? [NSNumber], !list.isEmpty {
                return Set(list.map(\.intValue))
            }
            if let one = json["eos_token_id"] as? NSNumber {
                return [one.intValue, PlamoTokenizer.tagTokenID]
            }
        }
        return [PlamoTokenizer.bosTokenID, PlamoTokenizer.tagTokenID]
    }

    /// Runs a tiny generation so that Metal pipelines and fused kernels exist before the first
    /// real request, then forgets it. Call it inside `withError` so that MLX failures throw.
    /// Cancellation of the calling task only skips the warm-up.
    func warmUp() throws {
        let prompt = tokenizer.encode(
            "<|plamo:bos|><|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>Hi"
                + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>")
        defer { resetCache() }
        do {
            _ = try generate(prompt: prompt, maxNewTokens: 2)
        } catch is CancellationError {}
    }

    func resetCache() {
        for c in caches { c.reset() }
        cachedTokens = []
    }

    /// Logits after feeding the whole prompt in one call (fresh cache); used by tests.
    func promptLogits(_ tokens: [Int]) -> MLXArray {
        let fresh = model.makeCaches()
        let logits = model(MLXArray(tokens.map { Int32($0) }).expandedDimensions(axis: 0), caches: fresh)
        return logits[0, -1]
    }

    /// Feeds all prompt tokens but the last into the prompt cache, reusing the longest prefix it shares with
    /// the cached tokens (at least the last prompt token is always recomputed). Returns the reused count.
    /// Afterwards the cache holds exactly `prompt.dropLast()`.
    func prefill(_ prompt: [Int]) throws -> Int {
        var reused = 0
        if reusePromptPrefix {
            let limit = min(cachedTokens.count, prompt.count - 1)
            while reused < limit, cachedTokens[reused] == prompt[reused] { reused += 1 }
        }
        if reused < cachedTokens.count {
            for c in caches { c.trim(to: reused) }
            cachedTokens.removeSubrange(reused...)
        }

        var position = reused
        while prompt.count - position > 1 {
            try Task.checkCancellation()
            let n = min(prefillChunkSize, prompt.count - 1 - position)
            let chunk = Array(prompt[position ..< position + n])
            _ = model.hiddenStates(MLXArray(chunk.map { Int32($0) }).expandedDimensions(axis: 0), caches: caches)
            eval(caches.flatMap(\.state))
            cachedTokens += chunk
            position += n
        }
        return reused
    }

    /// Keys and values of the prompt cache per layer, [1, heads, length, dim] (nil for an empty cache).
    var promptCacheContents: [(keys: MLXArray, values: MLXArray)?] {
        caches.map(\.filled)
    }

    /// Greedy generation. Mirrors mlx-lm's generate_step: prefill all but the last prompt token,
    /// then step one token at a time with the next step queued before the current token is read.
    func generate(
        prompt: [Int],
        maxNewTokens: Int,
        onText: ((String) -> Void)? = nil
    ) throws -> PlamoGenerationOutput {
        precondition(!prompt.isEmpty)
        let prefillStart = Date()
        let reused = try prefill(prompt)

        func step(_ input: MLXArray) -> MLXArray {
            let hidden = model.hiddenStates(input.reshaped(1, -1), caches: caches)
            let logits = model.logits(hidden[0..., -1, 0...])
            return argMax(logits, axis: -1).squeezed()
        }

        try Task.checkCancellation()
        let last = prompt[prompt.count - 1]
        var y = step(MLXArray([Int32(last)]))
        cachedTokens.append(last)
        asyncEval(y)

        var tokens = [Int]()
        var decoder = tokenizer.makeStreamingDecoder()
        var lastEmit = Date.distantPast
        var pendingPartial = false
        var hitLimit = false
        var prefillTime: TimeInterval = 0
        var decodeStart = Date()

        while true {
            if Task.isCancelled { break }
            var next: MLXArray?
            if tokens.count + 1 < maxNewTokens {
                next = step(y)
                asyncEval(next!)
            }
            let token = y.item(Int.self)
            if next != nil { cachedTokens.append(token) }
            if tokens.isEmpty {
                prefillTime = Date().timeIntervalSince(prefillStart)
                decodeStart = Date()
            }
            if stopTokens.contains(token) { break }
            tokens.append(token)
            if !decoder.append(token).isEmpty { pendingPartial = true }
            if let onText, pendingPartial, Date().timeIntervalSince(lastEmit) >= partialInterval {
                pendingPartial = false
                lastEmit = Date()
                onText(decoder.text)
            }
            guard let next else {
                hitLimit = true
                break
            }
            y = next
        }
        let decodeTime = Date().timeIntervalSince(decodeStart)
        // The cache bookkeeping is consistent at every break above, so the caches stay usable.
        try Task.checkCancellation()

        return PlamoGenerationOutput(
            tokens: tokens,
            text: tokenizer.decode(tokens),
            promptTokens: prompt.count,
            reusedPromptTokens: reused,
            hitTokenLimit: hitLimit,
            prefillTime: prefillTime,
            decodeTime: decodeTime)
    }
}
