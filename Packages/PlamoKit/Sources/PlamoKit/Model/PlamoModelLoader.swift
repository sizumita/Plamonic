import Foundation
import MLX
import MLXNN

/// Loads config.json + safetensors (single file or sharded with an index) into a `Plamo3Model`.
enum PlamoModelLoader {
    /// The weight files of a model directory: the index's shards, else `model*.safetensors`.
    static func weightFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if fm.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let map = json["weight_map"] as? [String: String]
            else {
                throw PlamoError.invalidModel("model.safetensors.index.json を読み込めません")
            }
            let names = Set(map.values).sorted()
            // Shards sit next to the index, like the downloaded files (no subdirectories).
            guard !names.isEmpty, names.allSatisfy(isShardName) else {
                throw PlamoError.invalidModel("model.safetensors.index.json のファイル名が不正です")
            }
            let urls = names.map { directory.appendingPathComponent($0) }
            for url in urls where !fm.fileExists(atPath: url.path) {
                throw PlamoError.invalidModel("\(url.lastPathComponent) がありません")
            }
            return urls
        }
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = contents.filter { $0.hasPrefix("model") && $0.hasSuffix(".safetensors") }.sorted()
        guard !files.isEmpty else { throw PlamoError.invalidModel("safetensors ファイルがありません") }
        return files.map { directory.appendingPathComponent($0) }
    }

    /// A plain `*.safetensors` file name: no path separators, not hidden.
    static func isShardName(_ name: String) -> Bool {
        name.hasSuffix(".safetensors") && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
    }

    static func load(directory: URL) throws -> Plamo3Model {
        let config = try Plamo3Configuration.load(directory: directory)
        var weights = [String: MLXArray]()
        for url in try weightFiles(in: directory) {
            do {
                for (key, value) in try loadArrays(url: url) { weights[key] = value }
            } catch {
                throw PlamoError.invalidModel("\(url.lastPathComponent): \(error)")
            }
        }
        if config.tieWordEmbeddings { weights["lm_head.weight"] = nil }

        var builder = Builder(config: config, weights: weights)
        let model = try builder.build()
        let unused = builder.weights.keys.sorted()
        if !unused.isEmpty {
            throw PlamoError.invalidModel("未使用の重み: \(unused.prefix(5).joined(separator: ", "))")
        }
        // Materialize every weight now; later evaluations only compute.
        eval(model.parameters())
        return model
    }

    private struct Builder {
        let config: Plamo3Configuration
        var weights: [String: MLXArray]
        /// Activations take the embedding's dtype (BF16 for the PFN checkpoints).
        let activationType: DType
        /// Keep float32 copies of the quantization scales unless that costs too much memory
        /// (about +0.1 GB for 2B, +0.5 GB for 8B, +1.9 GB for 31B).
        let promoteScalesOnLoad: Bool

        init(config: Plamo3Configuration, weights: [String: MLXArray]) {
            self.config = config
            self.weights = weights
            activationType =
                weights["model.embed_tokens.scales"]?.dtype ?? weights["model.embed_tokens.weight"]?.dtype
                ?? .bfloat16
            let scaleBytes = weights.reduce(0) { total, item in
                item.key.hasSuffix(".scales") || item.key.hasSuffix(".biases") ? total + item.value.nbytes : total
            }
            promoteScalesOnLoad = scaleBytes <= 600_000_000
        }

        mutating func take(_ key: String) throws -> MLXArray {
            guard let value = weights.removeValue(forKey: key) else {
                throw PlamoError.invalidModel("重み \(key) がありません")
            }
            return value
        }

        /// Float types MLX runs on the GPU.
        static let floatTypes: [DType] = [.float16, .bfloat16, .float32]

        /// Throws unless `array` has exactly `shape` and one of `types`. MLX ops on mismatched
        /// shapes fail inside the C++ library, which Swift cannot recover from, so every weight is
        /// checked against config.json before the model is built.
        func check(_ key: String, _ array: MLXArray, shape: [Int], types: [DType] = floatTypes) throws {
            guard array.shape == shape else {
                throw PlamoError.invalidModel("\(key) の形状 \(array.shape) が config.json と合いません (\(shape))")
            }
            guard types.contains(array.dtype) else {
                throw PlamoError.invalidModel("\(key) の型 \(array.dtype) は未対応です")
            }
        }

        struct Quantized {
            var scales: MLXArray
            var biases: MLXArray
            var parameters: Plamo3Configuration.Quantization
        }

        /// The `[outputs, inputs]` weight of `path`, plus its scales, biases and parameters when
        /// it is quantized (packed `[outputs, inputs * bits / 32]` uint32 with one scale and bias
        /// per group).
        mutating func weight(_ path: String, outputs: Int, inputs: Int) throws -> (MLXArray, Quantized?) {
            let weight = try take("\(path).weight")
            guard let scales = weights.removeValue(forKey: "\(path).scales") else {
                try check("\(path).weight", weight, shape: [outputs, inputs])
                return (weight, nil)
            }
            let biases = try take("\(path).biases")
            guard let q = config.quantization(for: path) ?? config.defaultQuantization else {
                throw PlamoError.invalidModel("\(path) の量子化設定がありません")
            }
            // Group sizes are multiples of 32, so this also makes `inputs * bits` a multiple of 32.
            guard inputs % q.groupSize == 0 else {
                throw PlamoError.invalidModel("\(path) の入力次元 \(inputs) が group_size \(q.groupSize) で割り切れません")
            }
            try check("\(path).weight", weight, shape: [outputs, inputs * q.bits / 32], types: [.uint32])
            try check("\(path).scales", scales, shape: [outputs, inputs / q.groupSize])
            try check("\(path).biases", biases, shape: [outputs, inputs / q.groupSize])
            return (weight, Quantized(scales: scales, biases: biases, parameters: q))
        }

        mutating func linear(_ path: String, outputs: Int, inputs: Int) throws -> Linear {
            let (weight, quantized) = try self.weight(path, outputs: outputs, inputs: inputs)
            guard let quantized else { return Linear(weight: weight, bias: nil) }
            return PlamoQuantizedLinear(
                weight: weight, scales: quantized.scales, biases: quantized.biases,
                groupSize: quantized.parameters.groupSize, bits: quantized.parameters.bits,
                activationType: activationType, promoteOnLoad: promoteScalesOnLoad)
        }

        mutating func embedding(_ path: String, count: Int, dimensions: Int) throws -> Embedding {
            let (weight, quantized) = try self.weight(path, outputs: count, inputs: dimensions)
            guard let quantized else { return Embedding(weight: weight) }
            return QuantizedEmbedding(
                weight: weight, scales: quantized.scales, biases: quantized.biases,
                groupSize: quantized.parameters.groupSize, bits: quantized.parameters.bits, mode: .affine)
        }

        mutating func norm(_ path: String, size: Int, offset: Float) throws -> PlamoRMSNorm {
            let weight = try take("\(path).weight")
            try check("\(path).weight", weight, shape: [size])
            return PlamoRMSNorm(weight: weight, eps: config.rmsNormEps, offset: offset)
        }

        mutating func build() throws -> Plamo3Model {
            let hidden = config.hiddenSize
            let headDim = config.headDim
            let qkvSize = (config.numAttentionHeads + 2 * config.numKeyValueHeads) * headDim
            let attentionSize = config.numAttentionHeads * headDim
            let intermediate = config.intermediateSize
            var layers = [PlamoDecoderLayer]()
            for i in 0 ..< config.numHiddenLayers {
                let p = "model.layers.layers.\(i)"
                let attention = PlamoAttention(
                    config: config,
                    qkvProj: try linear("\(p).mixer.qkv_proj", outputs: qkvSize, inputs: hidden),
                    oProj: try linear("\(p).mixer.o_proj", outputs: hidden, inputs: attentionSize),
                    qNorm: try norm("\(p).mixer.q_norm", size: headDim, offset: 1),
                    kNorm: try norm("\(p).mixer.k_norm", size: headDim, offset: 1))
                let mlp = PlamoMLP(
                    gateUpProj: try linear("\(p).mlp.gate_up_proj", outputs: 2 * intermediate, inputs: hidden),
                    downProj: try linear("\(p).mlp.down_proj", outputs: hidden, inputs: intermediate))
                layers.append(
                    PlamoDecoderLayer(
                        fullAttention: config.isFullAttention(layer: i),
                        mixer: attention,
                        mlp: mlp,
                        preMixerNorm: try norm("\(p).pre_mixer_norm", size: hidden, offset: 1),
                        postMixerNorm: try norm("\(p).post_mixer_norm", size: hidden, offset: Float(1.0 / 5.0)),
                        preMLPNorm: try norm("\(p).pre_mlp_norm", size: hidden, offset: 1),
                        postMLPNorm: try norm(
                            "\(p).post_mlp_norm", size: hidden, offset: Float(1.0 / pow(5.0, 1.5)))))
            }
            let inner = PlamoInnerModel(
                embedTokens: try embedding("model.embed_tokens", count: config.vocabSize, dimensions: hidden),
                layers: PlamoDecoder(layers: layers),
                norm: try norm("model.norm", size: hidden, offset: 1))
            let lmHead =
                config.tieWordEmbeddings ? nil : try linear("lm_head", outputs: config.vocabSize, inputs: hidden)
            return Plamo3Model(config: config, model: inner, lmHead: lmHead)
        }
    }
}
