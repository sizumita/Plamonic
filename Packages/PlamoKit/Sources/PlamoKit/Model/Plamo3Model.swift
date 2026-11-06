// Ported from modeling_plamo_mlx.py in the PLaMo 3 Translate MLX model repositories, which carries:
//   Portions Copyright © 2026 Apple Inc. (mlx-lm, MIT License; see LICENSE.mlx-lm).
//   Modifications Copyright © 2026 Preferred Networks, Inc.
// See THIRD_PARTY_NOTICES.md.

import Foundation
import MLX
import MLXNN

// Port of PFN's modeling_plamo_mlx.py. Numerics follow it step by step: each cast and each
// rounding point matters for reproducing mlx-lm's greedy outputs token for token.

/// RMSNorm that normalizes in float32, rounds back to the input dtype, then multiplies by (weight + offset).
final class PlamoRMSNorm: Module, UnaryLayer {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float
    let offset: Float
    private let epsArray: MLXArray
    private var cachedScale: MLXArray?

    init(weight: MLXArray, eps: Float, offset: Float) {
        self._weight.wrappedValue = weight
        self.eps = eps
        self.offset = offset
        self.epsArray = MLXArray(eps)
    }

    var scale: MLXArray {
        if offset == 0 { return weight }
        if let cachedScale { return cachedScale }
        // bf16 weight + scalar stays bf16, like Python's weak scalar promotion
        let s = weight + offset
        cachedScale = s
        return s
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        if PlamoFusedOps.enabled, x.dim(-2) == 1 { return PlamoFusedOps.rmsNorm(x, scale, epsArray) }
        let v = x.asType(.float32)
        let normalized = v * rsqrt(mean(v * v, axis: -1, keepDims: true) + eps)
        return normalized.asType(x.dtype) * scale
    }

    /// `residual + self(x)`
    func addingResidual(_ residual: MLXArray, _ x: MLXArray) -> MLXArray {
        if PlamoFusedOps.enabled, x.dim(-2) == 1 {
            return PlamoFusedOps.residualRMSNorm([residual, x, scale, epsArray])[0]
        }
        return residual + self(x)
    }
}

/// Affine-quantized linear layer that does MLX's dtype promotion explicitly.
///
/// The checkpoints store FP16 scales while activations are BF16, so `quantized_matmul` promotes
/// x, scales and biases to float32. Letting MLX 0.32.2 do that implicitly runs ~10x slower than
/// casting first; the results are identical. With `promoteOnLoad` the float32 scales are kept
/// (faster, more memory); otherwise they are cast on every call.
final class PlamoQuantizedLinear: QuantizedLinear {
    private let computeType: DType

    /// `activationType` is the dtype of the inputs (the embedding dtype).
    init(
        weight: MLXArray, scales: MLXArray, biases: MLXArray?, groupSize: Int, bits: Int, activationType: DType,
        promoteOnLoad: Bool
    ) {
        // MLX's promote_types for the float types involved
        let computeType: DType = activationType == scales.dtype ? activationType : .float32
        self.computeType = computeType
        let keep = promoteOnLoad ? computeType : scales.dtype
        super.init(
            weight: weight, bias: nil, scales: scales.asType(keep), biases: biases?.asType(keep),
            groupSize: groupSize, bits: bits, mode: .affine)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        quantizedMM(
            x.asType(computeType), weight, scales: scales.asType(computeType), biases: biases?.asType(computeType),
            transpose: true, groupSize: groupSize, bits: bits, mode: mode)
    }
}

/// cos/sin tables for one forward pass, shared by every layer of the same attention kind.
struct PlamoRotary {
    let cos: MLXArray
    let sin: MLXArray

    /// `phase = (arange(L) + offset)[:, None] * invFreq`, duplicated to the full head dim.
    init(invFreq: MLXArray, concentration: Float, length: Int, offset: Int, dtype: DType) {
        let positions = MLX.arange(length, dtype: .float32) + Float(offset)
        var phase = positions.expandedDimensions(axis: -1) * invFreq
        phase = concatenated([phase, phase], axis: -1)
        var c = MLX.cos(phase).asType(dtype)
        var s = MLX.sin(phase).asType(dtype)
        if concentration != 1 {
            c = c * concentration
            s = s * concentration
        }
        self.cos = c
        self.sin = s
    }

    func apply(_ x: MLXArray) -> MLXArray {
        if PlamoFusedOps.enabled, x.dim(-2) == 1 { return PlamoFusedOps.rope(x, cos, sin) }
        let half = x.dim(-1) / 2
        let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
        return x * cos + rotated * sin
    }
}

final class PlamoAttention: Module {
    @ModuleInfo(key: "qkv_proj") var qkvProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: PlamoRMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: PlamoRMSNorm

    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float

    init(config: Plamo3Configuration, qkvProj: Linear, oProj: Linear, qNorm: PlamoRMSNorm, kNorm: PlamoRMSNorm) {
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = Float(pow(Double(config.headDim), -0.5))
        self._qkvProj.wrappedValue = qkvProj
        self._oProj.wrappedValue = oProj
        self._qNorm.wrappedValue = qNorm
        self._kNorm.wrappedValue = kNorm
    }

    func callAsFunction(
        _ x: MLXArray, rotary: PlamoRotary, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: PlamoKVCache?
    ) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        // Affine scales are FP16; BF16 x FP16 promotes to FP32, so cast back at every linear.
        let qkv = qkvProj(x).asType(x.dtype)
        let qDim = numHeads * headDim
        let kDim = numKVHeads * headDim
        let parts = split(qkv, indices: [qDim, qDim + kDim], axis: -1)

        var queries = parts[0].reshaped(b, l, numHeads, headDim).transposed(0, 2, 1, 3)
        var keys = parts[1].reshaped(b, l, numKVHeads, headDim).transposed(0, 2, 1, 3)
        var values = parts[2].reshaped(b, l, numKVHeads, headDim).transposed(0, 2, 1, 3)

        queries = rotary.apply(qNorm(queries))
        keys = rotary.apply(kNorm(keys))
        if let cache {
            (keys, values) = cache.update(keys: keys, values: values)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask)
        return oProj(output.transposed(0, 2, 1, 3).reshaped(b, l, numHeads * headDim)).asType(x.dtype)
    }
}

final class PlamoMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_up_proj") var gateUpProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(gateUpProj: Linear, downProj: Linear) {
        self._gateUpProj.wrappedValue = gateUpProj
        self._downProj.wrappedValue = downProj
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let parts = split(gateUpProj(x).asType(x.dtype), parts: 2, axis: -1)
        if PlamoFusedOps.enabled, x.dim(-2) == 1 { return downProj(PlamoFusedOps.swiGLU(parts[0], parts[1])).asType(x.dtype) }
        let gate = parts[0]
        // silu in float32 with a single rounding back, like torch.nn.functional.silu
        let g = gate.asType(.float32)
        let activated = (g * sigmoid(g)).asType(gate.dtype)
        return downProj(activated * parts[1]).asType(x.dtype)
    }
}

final class PlamoDecoderLayer: Module {
    @ModuleInfo(key: "mixer") var mixer: PlamoAttention
    @ModuleInfo(key: "mlp") var mlp: PlamoMLP
    @ModuleInfo(key: "pre_mixer_norm") var preMixerNorm: PlamoRMSNorm
    @ModuleInfo(key: "post_mixer_norm") var postMixerNorm: PlamoRMSNorm
    @ModuleInfo(key: "pre_mlp_norm") var preMLPNorm: PlamoRMSNorm
    @ModuleInfo(key: "post_mlp_norm") var postMLPNorm: PlamoRMSNorm

    let fullAttention: Bool

    init(
        fullAttention: Bool, mixer: PlamoAttention, mlp: PlamoMLP, preMixerNorm: PlamoRMSNorm,
        postMixerNorm: PlamoRMSNorm, preMLPNorm: PlamoRMSNorm, postMLPNorm: PlamoRMSNorm
    ) {
        self.fullAttention = fullAttention
        self._mixer.wrappedValue = mixer
        self._mlp.wrappedValue = mlp
        self._preMixerNorm.wrappedValue = preMixerNorm
        self._postMixerNorm.wrappedValue = postMixerNorm
        self._preMLPNorm.wrappedValue = preMLPNorm
        self._postMLPNorm.wrappedValue = postMLPNorm
    }

    func callAsFunction(
        _ x: MLXArray, rotary: PlamoRotary, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: PlamoKVCache?
    ) -> MLXArray {
        let h = postMixerNorm.addingResidual(x, mixer(preMixerNorm(x), rotary: rotary, mask: mask, cache: cache))
        return postMLPNorm.addingResidual(h, mlp(preMLPNorm(h)))
    }
}

final class PlamoDecoder: Module {
    @ModuleInfo(key: "layers") var layers: [PlamoDecoderLayer]

    init(layers: [PlamoDecoderLayer]) {
        self._layers.wrappedValue = layers
    }
}

final class PlamoInnerModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: PlamoDecoder
    @ModuleInfo(key: "norm") var norm: PlamoRMSNorm

    init(embedTokens: Embedding, layers: PlamoDecoder, norm: PlamoRMSNorm) {
        self._embedTokens.wrappedValue = embedTokens
        self._layers.wrappedValue = layers
        self._norm.wrappedValue = norm
    }
}

/// PLaMo 3 causal LM (`Plamo3ForCausalLM` in MLX).
final class Plamo3Model: Module {
    @ModuleInfo(key: "model") var model: PlamoInnerModel
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    let config: Plamo3Configuration
    private let invFreqFull: MLXArray
    private let invFreqLocal: MLXArray
    private let fullConcentration: Float

    init(config: Plamo3Configuration, model: PlamoInnerModel, lmHead: Linear?) {
        self.config = config
        self._model.wrappedValue = model
        self._lmHead.wrappedValue = lmHead
        self.invFreqFull = MLXArray(config.ropeInvFreqFull)
        self.invFreqLocal = MLXArray(config.ropeInvFreqLocal)
        if let factor = config.ropeScalingFactor, factor != 1 {
            fullConcentration = Float(1 + 0.1 * log(factor))
        } else {
            fullConcentration = 1
        }
    }

    var layers: [PlamoDecoderLayer] { model.layers.layers }

    func makeCaches() -> [PlamoKVCache] {
        layers.map { _ in PlamoKVCache() }
    }

    /// Runs the decoder and the final norm. `inputs` is [B, L] token ids.
    func hiddenStates(_ inputs: MLXArray, caches: [PlamoKVCache]?) -> MLXArray {
        var h = model.embedTokens(inputs)
        if config.scaleEmbedding {
            h = h * Float(pow(Double(config.hiddenSize), 0.5))
        }
        let length = h.dim(1)
        let offset = caches?.first?.offset ?? 0

        let fullRotary = PlamoRotary(
            invFreq: invFreqFull, concentration: fullConcentration, length: length, offset: offset, dtype: h.dtype)
        let localRotary = PlamoRotary(
            invFreq: invFreqLocal, concentration: 1, length: length, offset: offset, dtype: h.dtype)

        let fullMask: MLXFast.ScaledDotProductAttentionMaskMode = length > 1 ? .causal : .none
        let windowMask: MLXFast.ScaledDotProductAttentionMaskMode
        if offset + length > config.windowSize {
            windowMask = .array(Self.windowedCausalMask(length: length, offset: offset, window: config.windowSize))
        } else {
            windowMask = fullMask
        }

        for (i, layer) in layers.enumerated() {
            h = layer(
                h,
                rotary: layer.fullAttention ? fullRotary : localRotary,
                mask: layer.fullAttention ? fullMask : windowMask,
                cache: caches?[i])
        }
        return model.norm(h)
    }

    /// Float32 logits for the given hidden states.
    func logits(_ hidden: MLXArray) -> MLXArray {
        if let lmHead {
            return lmHead(hidden).asType(.float32)
        }
        return model.embedTokens.asLinear(hidden).asType(.float32)
    }

    func callAsFunction(_ inputs: MLXArray, caches: [PlamoKVCache]?) -> MLXArray {
        logits(hiddenStates(inputs, caches: caches))
    }

    /// mlx-lm `create_causal_mask(N, offset, window_size)`: key j is visible to query i when
    /// j <= i and j > i - window.
    static func windowedCausalMask(length: Int, offset: Int, window: Int) -> MLXArray {
        let rinds = MLX.arange(offset + length).expandedDimensions(axis: 0)
        let linds = MLX.arange(offset, offset + length).expandedDimensions(axis: 1)
        return (linds .>= rinds) .&& (linds .< (rinds + Int32(window)))
    }
}
