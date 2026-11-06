// Follows mlx-lm (Copyright © 2023 Apple Inc., MIT License) as used by modeling_plamo_mlx.py.
// See THIRD_PARTY_NOTICES.md.

import MLX

/// Growing KV cache (mlx-lm `KVCache`). Sliding-window layers use it too, with an explicit
/// window mask; unlike a rotating cache it can be trimmed to any prefix for prompt reuse.
final class PlamoKVCache {
    private var keys: MLXArray?
    private var values: MLXArray?
    private(set) var offset = 0
    private let step = 256

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let previous = offset
        let count = newKeys.dim(2)
        if keys == nil || previous + count > keys!.dim(2) {
            let (b, heads, kDim, vDim) = (newKeys.dim(0), newKeys.dim(1), newKeys.dim(3), newValues.dim(3))
            let steps = (step + count - 1) / step
            let grownK = MLXArray.zeros([b, heads, steps * step, kDim], dtype: newKeys.dtype)
            let grownV = MLXArray.zeros([b, heads, steps * step, vDim], dtype: newValues.dtype)
            if var k = keys, var v = values {
                if previous % step != 0 {
                    k = k[.ellipsis, ..<previous, 0...]
                    v = v[.ellipsis, ..<previous, 0...]
                }
                keys = concatenated([k, grownK], axis: 2)
                values = concatenated([v, grownV], axis: 2)
            } else {
                keys = grownK
                values = grownV
            }
        }
        offset += count
        keys![.ellipsis, previous ..< offset, 0...] = newKeys
        values![.ellipsis, previous ..< offset, 0...] = newValues
        return (keys![.ellipsis, ..<offset, 0...], values![.ellipsis, ..<offset, 0...])
    }

    /// Drops everything after the first `length` positions.
    func trim(to length: Int) {
        offset = max(0, min(offset, length))
    }

    func reset() {
        keys = nil
        values = nil
        offset = 0
    }

    /// Arrays to evaluate after a prefill chunk.
    var state: [MLXArray] {
        guard let keys, let values else { return [] }
        return [keys, values]
    }
}
