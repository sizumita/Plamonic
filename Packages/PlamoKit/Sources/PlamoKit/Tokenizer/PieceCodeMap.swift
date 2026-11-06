// Open-addressing hash map UInt64 -> Int32 used by the tokenizer's suffix table.
// Swift's Dictionary hashes with SipHash, which dominates tokenizer load and encode time.
struct PieceCodeMap: Sendable {
    private static let emptyKey = UInt64.max

    private var keys: [UInt64]
    private var values: [Int32]
    private var shift: UInt64
    private(set) var count = 0

    init(minimumCapacity: Int) {
        var capacity = 16
        var bits: UInt64 = 4
        // keep the load factor at or below 0.5
        while capacity < minimumCapacity * 2 {
            capacity <<= 1
            bits += 1
        }
        keys = [UInt64](repeating: Self.emptyKey, count: capacity)
        values = [Int32](repeating: 0, count: capacity)
        shift = 64 - bits
    }

    @inline(__always)
    private func slot(_ key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> shift)
    }

    mutating func insert(_ key: UInt64, _ value: Int32) {
        precondition(key != Self.emptyKey)
        if (count + 1) * 2 > keys.count { grow() }
        let mask = keys.count - 1
        var i = slot(key)
        while true {
            let k = keys[i]
            if k == Self.emptyKey {
                keys[i] = key
                values[i] = value
                count += 1
                return
            }
            if k == key {
                values[i] = value
                return
            }
            i = (i + 1) & mask
        }
    }

    @inline(__always)
    func get(_ key: UInt64) -> Int32? {
        keys.withUnsafeBufferPointer { kp in
            let mask = kp.count - 1
            var i = slot(key)
            while true {
                let k = kp[i]
                if k == key { return values[i] }
                if k == Self.emptyKey { return nil }
                i = (i + 1) & mask
            }
        }
    }

    private mutating func grow() {
        let oldKeys = keys
        let oldValues = values
        keys = [UInt64](repeating: Self.emptyKey, count: oldKeys.count * 2)
        values = [Int32](repeating: 0, count: oldKeys.count * 2)
        shift -= 1
        count = 0
        for i in 0 ..< oldKeys.count where oldKeys[i] != Self.emptyKey {
            insert(oldKeys[i], oldValues[i])
        }
    }
}
