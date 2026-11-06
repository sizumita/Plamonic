// Ported from modeling_plamo_mlx.py in the PLaMo 3 Translate MLX model repositories, which carries:
//   Portions Copyright © 2026 Apple Inc. (mlx-lm, MIT License; see LICENSE.mlx-lm).
//   Modifications Copyright © 2026 Preferred Networks, Inc.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// The parts of config.json that modeling_plamo_mlx.py uses.
struct Plamo3Configuration: Sendable {
    struct Quantization: Sendable, Equatable {
        var groupSize: Int
        var bits: Int

        /// What MLX's affine quantization supports.
        var isSupported: Bool {
            [2, 3, 4, 5, 6, 8].contains(bits) && [32, 64, 128].contains(groupSize)
        }
    }

    /// Upper bound for every size in the config; keeps shape arithmetic far from Int overflow.
    static let maxDimension = 1 << 24

    var hiddenSize: Int
    var numHiddenLayers: Int
    var rmsNormEps: Float
    var tieWordEmbeddings: Bool
    var scaleEmbedding: Bool
    var ropeScalingFactor: Double?
    var ropeInvFreqFull: [Float]
    var ropeInvFreqLocal: [Float]
    var numAttentionHeads: Int
    var numKeyValueHeads: Int
    var headDim: Int
    var windowSize: Int
    var slidingWindowPattern: Int
    var intermediateSize: Int
    var vocabSize: Int
    /// Default quantization and per-module overrides (`nil` value = not quantized).
    var defaultQuantization: Quantization?
    var moduleQuantization: [String: Quantization?]

    func isFullAttention(layer: Int) -> Bool {
        (layer + 1) % slidingWindowPattern == 0
    }

    /// Quantization parameters for the module at `path`, as mlx-lm's class_predicate resolves them.
    func quantization(for path: String) -> Quantization? {
        if let entry = moduleQuantization[path] { return entry }
        return defaultQuantization
    }

    static func load(directory: URL) throws -> Plamo3Configuration {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PlamoError.invalidModel("config.json を読み込めません")
        }
        return try Plamo3Configuration(json: json)
    }

    init(json: [String: Any]) throws {
        func int(_ key: String, _ fallback: Int? = nil) throws -> Int {
            if let v = (json[key] as? NSNumber)?.intValue { return v }
            if let fallback { return fallback }
            throw PlamoError.invalidModel("config.json に \(key) がありません")
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            (json[key] as? NSNumber)?.boolValue ?? fallback
        }

        hiddenSize = try int("hidden_size")
        numHiddenLayers = try int("num_hidden_layers")
        rmsNormEps = (json["rms_norm_eps"] as? NSNumber)?.floatValue ?? 1e-6
        tieWordEmbeddings = bool("tie_word_embeddings", true)
        scaleEmbedding = bool("scale_embedding", false)
        ropeScalingFactor = (json["rope_scaling_factor"] as? NSNumber)?.doubleValue
        numAttentionHeads = try int("num_attention_heads")
        numKeyValueHeads = try int("num_key_value_heads")
        headDim = try int("head_dim", 128)
        // sliding_window overrides window_size (ModelArgs.__post_init__)
        windowSize = try (json["sliding_window"] as? NSNumber)?.intValue ?? int("window_size", 2048)
        slidingWindowPattern = try int("sliding_window_pattern", 8)
        intermediateSize = try int("intermediate_size")
        vocabSize = try int("vocab_size")

        guard let inv = json["plamo_rope_inv_freq"] as? [String: Any],
            let full = inv["full"] as? [NSNumber], let local = inv["local"] as? [NSNumber]
        else {
            throw PlamoError.invalidModel("config.json に plamo_rope_inv_freq がありません。モデルを再ダウンロードしてください")
        }
        // values are FP32-exact; go through Double like Python's mx.array(list, dtype=float32)
        ropeInvFreqFull = full.map { Float($0.doubleValue) }
        ropeInvFreqLocal = local.map { Float($0.doubleValue) }
        guard ropeInvFreqFull.count == headDim / 2, ropeInvFreqLocal.count == headDim / 2 else {
            throw PlamoError.invalidModel("RoPE の次元が不正です")
        }

        defaultQuantization = nil
        moduleQuantization = [:]
        if let q = json["quantization"] as? [String: Any] {
            if let mode = q["mode"] as? String, mode != "affine" {
                throw PlamoError.invalidModel("未対応の量子化モード: \(mode)")
            }
            if let g = (q["group_size"] as? NSNumber)?.intValue, let b = (q["bits"] as? NSNumber)?.intValue {
                defaultQuantization = Quantization(groupSize: g, bits: b)
            }
            for (key, value) in q where key != "group_size" && key != "bits" && key != "mode" {
                if let entry = value as? [String: Any] {
                    if let mode = entry["mode"] as? String, mode != "affine" {
                        throw PlamoError.invalidModel("未対応の量子化モード: \(mode)")
                    }
                    let g = (entry["group_size"] as? NSNumber)?.intValue ?? defaultQuantization?.groupSize ?? 64
                    let b = (entry["bits"] as? NSNumber)?.intValue ?? defaultQuantization?.bits ?? 4
                    moduleQuantization[key] = .some(Quantization(groupSize: g, bits: b))
                } else if let flag = value as? NSNumber, !flag.boolValue {
                    moduleQuantization[key] = .some(nil)
                }
            }
        }
        try validate()
    }

    /// Rejects values that would trap (division by zero, invalid ranges) or that MLX cannot run.
    /// The weights' shapes are checked against these values when the model is built.
    private func validate() throws {
        let sizes: [(String, Int)] = [
            ("hidden_size", hiddenSize), ("num_hidden_layers", numHiddenLayers),
            ("num_attention_heads", numAttentionHeads), ("num_key_value_heads", numKeyValueHeads),
            ("head_dim", headDim), ("window_size", windowSize), ("sliding_window_pattern", slidingWindowPattern),
            ("intermediate_size", intermediateSize), ("vocab_size", vocabSize),
        ]
        for (key, value) in sizes where !(1 ... Self.maxDimension).contains(value) {
            throw PlamoError.invalidModel("config.json の \(key) が不正です (\(value))")
        }
        guard numAttentionHeads % numKeyValueHeads == 0 else {
            throw PlamoError.invalidModel("num_attention_heads が num_key_value_heads で割り切れません")
        }
        guard headDim % 2 == 0 else { throw PlamoError.invalidModel("head_dim が奇数です") }
        guard rmsNormEps.isFinite, rmsNormEps >= 0 else {
            throw PlamoError.invalidModel("rms_norm_eps が不正です")
        }
        if let factor = ropeScalingFactor, !(factor.isFinite && factor > 0) {
            throw PlamoError.invalidModel("rope_scaling_factor が不正です")
        }
        let quantizations = [defaultQuantization] + Array(moduleQuantization.values)
        for case let q? in quantizations where !q.isSupported {
            throw PlamoError.invalidModel("未対応の量子化設定です (bits \(q.bits), group_size \(q.groupSize))")
        }
    }
}
