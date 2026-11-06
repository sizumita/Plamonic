// Ported from modeling_plamo_mlx.py in the PLaMo 3 Translate MLX model repositories, which carries:
//   Portions Copyright © 2026 Apple Inc. (mlx-lm, MIT License; see LICENSE.mlx-lm).
//   Modifications Copyright © 2026 Preferred Networks, Inc.
// See THIRD_PARTY_NOTICES.md.

import Foundation
import MLX

/// Compiled (kernel-fused) versions of the elementwise chains in a decode step.
///
/// A single-token step is bound by the CPU cost of encoding ~1,400 small kernels; fusing these
/// chains removes about half of them. The graphs are the same ops with the same dtypes, so the
/// results are bit-identical to the unfused path (the reference tests check this).
/// Only used for single-token inputs: compiled graphs are cached per input shape, and prefill
/// lengths vary without bound.
enum PlamoFusedOps {
    /// PLAMO_DISABLE_FUSION=1 falls back to the unfused ops (for A/B checks).
    static let enabled = ProcessInfo.processInfo.environment["PLAMO_DISABLE_FUSION"] == nil

    /// `normalize(x) * scale` with float32 normalization, as PlamoRMSNorm.
    static let rmsNorm: @Sendable (MLXArray, MLXArray, MLXArray) -> MLXArray = compile { x, scale, eps in
        let v = x.asType(.float32)
        return (v * rsqrt(mean(v * v, axis: -1, keepDims: true) + eps)).asType(x.dtype) * scale
    }

    /// `residual + normalize(x) * scale`
    static let residualRMSNorm: @Sendable ([MLXArray]) -> [MLXArray] = compile { args in
        let (residual, x, scale, eps) = (args[0], args[1], args[2], args[3])
        let v = x.asType(.float32)
        return [residual + (v * rsqrt(mean(v * v, axis: -1, keepDims: true) + eps)).asType(x.dtype) * scale]
    }

    /// Rotary embedding with precomputed cos/sin tables (PlamoRotary.apply).
    static let rope: @Sendable (MLXArray, MLXArray, MLXArray) -> MLXArray = compile { x, cos, sin in
        let half = x.dim(-1) / 2
        let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
        return x * cos + rotated * sin
    }

    /// `silu(gate)` in float32 rounded back once, times `value`.
    static let swiGLU: @Sendable (MLXArray, MLXArray) -> MLXArray = compile { gate, value in
        let g = gate.asType(.float32)
        return (g * sigmoid(g)).asType(gate.dtype) * value
    }
}
