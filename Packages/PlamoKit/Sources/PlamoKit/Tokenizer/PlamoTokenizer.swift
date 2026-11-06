// Ported from tokenization_plamo.py in the PLaMo 3 Translate model repositories. See THIRD_PARTY_NOTICES.md.

import Foundation

public enum PlamoTokenizerError: Error, CustomStringConvertible {
    case missingFile(String)
    case invalidVocabulary(String)

    public var description: String {
        switch self {
        case .missingFile(let name): "tokenizer file not found: \(name)"
        case .invalidVocabulary(let reason): "invalid tokenizer vocabulary: \(reason)"
        }
    }
}

/// Port of PFN's `tokenization_plamo.py` (Plamo3Tokenizer / AhoCorasick).
///
/// Unigram-style Viterbi over Unicode scalars with an Aho-Corasick suffix table, byte fallback,
/// and forced boundaries (U+EE00) around special tokens, runs of repeated characters and runs of spaces.
/// Immutable after init, so it is safe to share across threads.
public final class PlamoTokenizer: Sendable {
    public static let unknownTokenID = 0
    public static let bosTokenID = 1
    public static let eosTokenID = 2
    public static let padTokenID = 3
    public static let tagTokenID = 16

    static let boundaryChar: UInt32 = 0xEE00
    static let boundaryTokenID: Int32 = 10_000_000
    static let invalidScore: Int32 = -20_000_000
    static let unknownScore: Int32 = -10_000_000

    // Flattened suffix table: 4 Int32 per row (piece length, token id, score, piece id).
    private let table: [Int32]
    private let tableRows: Int
    // (code point << 32 | suffix id of the rest) -> suffix id
    private let toSuffixID: PieceCodeMap
    private let byteTokens: [Int32]

    // Decoding tables, indexed by token id.
    private let pieceBytes: [UInt8]
    private let pieceOffsets: [Int32]
    private let byteValues: [Int16]

    private let repeatedCharsThreshold: Int?
    private let consecutiveSpacesThreshold: Int?

    public let vocabSize: Int

    /// Loads `tokenizer.jsonl` and `tokenizer_config.json` from a model directory.
    public convenience init(directory: URL) throws {
        let vocabURL = directory.appendingPathComponent("tokenizer.jsonl")
        guard let data = try? Data(contentsOf: vocabURL, options: .mappedIfSafe) else {
            throw PlamoTokenizerError.missingFile(vocabURL.path)
        }
        let rows = try VocabParser.parse(data)

        var spaces: Int?
        var repeated: Int?
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        if let configData = try? Data(contentsOf: configURL),
            let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        {
            spaces = (config["break_around_consecutive_spaces_threshold"] as? NSNumber)?.intValue
            repeated = (config["break_around_repeated_chars_threshold"] as? NSNumber)?.intValue
        }
        try self.init(rows: rows, breakAroundConsecutiveSpaces: spaces, breakAroundRepeatedChars: repeated)
    }

    init(rows: [VocabRow], breakAroundConsecutiveSpaces: Int?, breakAroundRepeatedChars: Int?) throws {
        consecutiveSpacesThreshold = breakAroundConsecutiveSpaces
        repeatedCharsThreshold = breakAroundRepeatedChars
        vocabSize = rows.count

        // 1. Trie over reversed tokens. Every node is a suffix of some token; a node's parent is
        //    the suffix without its first character, and its edge is that first character.
        var parent: [Int32] = [-1]
        var edge: [UInt32] = [0]
        var depth: [Int32] = [0]
        var score: [Double] = [.nan]
        var nodeToken: [Int32] = [-1]
        var children = PieceCodeMap(minimumCapacity: rows.count * 2)
        parent.reserveCapacity(rows.count * 2)
        edge.reserveCapacity(rows.count * 2)
        depth.reserveCapacity(rows.count * 2)
        score.reserveCapacity(rows.count * 2)
        nodeToken.reserveCapacity(rows.count * 2)

        func insert(_ scalars: [UInt32], score s: Double, id: Int32) {
            var node: Int32 = 0
            for k in stride(from: scalars.count - 1, through: 0, by: -1) {
                let key = UInt64(scalars[k]) << 32 | UInt64(UInt32(node))
                if let next = children.get(key) {
                    node = next
                } else {
                    let new = Int32(parent.count)
                    parent.append(node)
                    edge.append(scalars[k])
                    depth.append(depth[Int(node)] + 1)
                    score.append(.nan)
                    nodeToken.append(-1)
                    children.insert(key, new)
                    node = new
                }
            }
            score[Int(node)] = s
            nodeToken[Int(node)] = id
        }

        func find(_ scalars: [UInt32]) -> Int32? {
            var node: Int32 = 0
            for k in stride(from: scalars.count - 1, through: 0, by: -1) {
                guard let next = children.get(UInt64(scalars[k]) << 32 | UInt64(UInt32(node))) else { return nil }
                node = next
            }
            return node
        }

        var bytes = [Int32](repeating: 0, count: 256)
        var byteRows = [(scalars: [UInt32], id: Int32)]()
        var byteValues = [Int16](repeating: -1, count: rows.count)
        for (index, row) in rows.enumerated() {
            let id = Int32(index)
            if let value = Self.byteTokenValue(row.scalars) {
                // Python decodes any token starting with "<0x" as a raw byte.
                byteValues[index] = Int16(value)
            }
            if row.isByte {
                guard let value = Self.byteTokenValue(row.scalars), row.scalars.count == 6 else {
                    throw PlamoTokenizerError.invalidVocabulary("malformed byte token at \(index)")
                }
                bytes[value] = id
                byteRows.append((row.scalars, id))
                continue
            }
            guard !row.scalars.isEmpty else {
                throw PlamoTokenizerError.invalidVocabulary("empty token at \(index)")
            }
            insert(row.scalars, score: row.score, id: id)
        }
        insert([Self.boundaryChar], score: 0, id: Self.boundaryTokenID)
        for b in 0 ..< 256 where bytes[b] == 0 {
            throw PlamoTokenizerError.invalidVocabulary(String(format: "byte token <0x%02X> is not set", b))
        }
        // token_to_token_id also holds byte tokens (last row wins); ids grow with row order.
        for (scalars, id) in byteRows {
            if let node = find(scalars) {
                nodeToken[Int(node)] = max(nodeToken[Int(node)], id)
            }
        }

        let nodeCount = parent.count

        // 2. Children of each node sorted by code point, then a preorder walk: this lists suffixes
        //    in lexicographic order of their reversed strings, as Python's sort does.
        var childStart = [Int32](repeating: 0, count: nodeCount + 1)
        for k in 1 ..< nodeCount { childStart[Int(parent[k]) + 1] += 1 }
        for k in 0 ..< nodeCount { childStart[k + 1] += childStart[k] }
        var fill = childStart
        var childList = [Int32](repeating: 0, count: max(nodeCount - 1, 0))
        for k in 1 ..< nodeCount {
            let p = Int(parent[k])
            childList[Int(fill[p])] = Int32(k)
            fill[p] += 1
        }
        for p in 0 ..< nodeCount {
            let lo = Int(childStart[p])
            let hi = Int(childStart[p + 1])
            if hi - lo > 1 {
                childList[lo ..< hi].sort { edge[Int($0)] < edge[Int($1)] }
            }
        }
        var order = [Int32]()
        order.reserveCapacity(nodeCount)
        var stack: [Int32] = [0]
        while let node = stack.popLast() {
            order.append(node)
            let lo = Int(childStart[Int(node)])
            let hi = Int(childStart[Int(node) + 1])
            var k = hi - 1
            while k >= lo {
                stack.append(childList[k])
                k -= 1
            }
        }

        // 3. For each suffix, the prefixes that are themselves suffixes (decreasing length).
        //    prefix(c + rest) = c + prefix(rest), so they derive from the parent's list.
        var rowStart = [Int32](repeating: 0, count: nodeCount)
        var rowCount = [Int32](repeating: 0, count: nodeCount)
        var position = [Int32](repeating: 0, count: nodeCount)
        var pieces = [Int32]()
        pieces.reserveCapacity(nodeCount * 4)
        for (pos, node32) in order.enumerated() {
            let node = Int(node32)
            position[node] = Int32(pos)
            rowStart[node] = Int32(pieces.count)
            if node == 0 { continue }
            let c = UInt64(edge[node])
            let p = Int(parent[node])
            let start = Int(rowStart[p])
            let end = start + Int(rowCount[p])
            var added: Int32 = 0
            var r = start
            while r < end {
                if let next = children.get(c << 32 | UInt64(UInt32(pieces[r]))) {
                    pieces.append(next)
                    added += 1
                }
                r += 1
            }
            if let next = children.get(c << 32) {
                pieces.append(next)
                added += 1
            }
            rowCount[node] = added
        }

        // 4. Flattened table with a sentinel row after each suffix.
        @inline(__always) func offset(_ node: Int) -> Int32 { rowStart[node] + position[node] }
        let totalRows = pieces.count + nodeCount
        var table = [Int32](repeating: 0, count: totalRows * 4)
        var row = 0
        for node32 in order {
            let node = Int(node32)
            let start = Int(rowStart[node])
            for r in start ..< start + Int(rowCount[node]) {
                let q = Int(pieces[r])
                table[row * 4] = depth[q]
                table[row * 4 + 1] = nodeToken[q]
                let s = score[q]
                if s.isFinite {
                    // Python builds this table as int32 and fails on scores that do not fit.
                    guard let fixed = Int32(exactly: (s * 1e4).rounded(.toNearestOrEven)) else {
                        throw PlamoTokenizerError.invalidVocabulary("score out of range for token \(nodeToken[q])")
                    }
                    table[row * 4 + 2] = fixed
                } else {
                    table[row * 4 + 2] = Self.invalidScore
                }
                table[row * 4 + 3] = offset(q)
                row += 1
            }
            table[row * 4] = 1
            table[row * 4 + 1] = -1
            table[row * 4 + 2] = Self.unknownScore
            table[row * 4 + 3] = 0
            row += 1
        }
        precondition(row == totalRows)

        var toSuffixID = PieceCodeMap(minimumCapacity: nodeCount)
        for node in 1 ..< nodeCount {
            let key = UInt64(edge[node]) << 32 | UInt64(UInt32(offset(Int(parent[node]))))
            toSuffixID.insert(key, offset(node))
        }

        // Decoding tables.
        var pieceBytes = [UInt8]()
        pieceBytes.reserveCapacity(rows.count * 8)
        var pieceOffsets = [Int32]()
        pieceOffsets.reserveCapacity(rows.count + 1)
        for row in rows {
            pieceOffsets.append(Int32(pieceBytes.count))
            Self.appendUTF8(row.scalars, to: &pieceBytes)
        }
        pieceOffsets.append(Int32(pieceBytes.count))

        self.table = table
        self.tableRows = totalRows
        self.toSuffixID = toSuffixID
        self.byteTokens = bytes
        self.pieceBytes = pieceBytes
        self.pieceOffsets = pieceOffsets
        self.byteValues = byteValues
    }

    // MARK: - Encoding

    /// Encodes text to token ids, like `tokenizer.encode(text, add_special_tokens=False)`.
    /// Special tokens written as text (e.g. `<|plamo:bos|>`) map to their ids.
    public func encode(_ text: String) -> [Int] {
        var data = [UInt32]()
        data.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars { data.append(s.value) }
        data = insertSpecialTokenBoundaries(data)
        data = insertRunBoundaries(data)
        return viterbi(data)
    }

    /// Token string for an id (byte tokens as `<0xXX>`).
    public func tokenString(_ id: Int) -> String {
        guard id >= 0, id < vocabSize else { return "" }
        let lo = Int(pieceOffsets[id])
        let hi = Int(pieceOffsets[id + 1])
        return String(decoding: pieceBytes[lo ..< hi], as: UTF8.self)
    }

    /// `(<\|plamo:[^|\s]{,64}\|>)` -> BOUNDARY + match + BOUNDARY
    func insertSpecialTokenBoundaries(_ s: [UInt32]) -> [UInt32] {
        let prefix: [UInt32] = Array("<|plamo:".unicodeScalars.map(\.value))
        let n = s.count
        var out = [UInt32]()
        out.reserveCapacity(n + 8)
        var i = 0
        while i < n {
            if s[i] == 0x3C, i + prefix.count <= n, s[i ..< i + prefix.count].elementsEqual(prefix) {
                var j = i + prefix.count
                var k = 0
                while j < n, k < 64, s[j] != 0x7C, !Self.isPythonWhitespace(s[j]) {
                    j += 1
                    k += 1
                }
                if j + 1 < n, s[j] == 0x7C, s[j + 1] == 0x3E {
                    out.append(Self.boundaryChar)
                    out.append(contentsOf: s[i ..< j + 2])
                    out.append(Self.boundaryChar)
                    i = j + 2
                    continue
                }
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    /// `((.)\2{R-1,}| {S,})` -> BOUNDARY + match + BOUNDARY, where `.` excludes "\n".
    func insertRunBoundaries(_ s: [UInt32]) -> [UInt32] {
        if repeatedCharsThreshold == nil && consecutiveSpacesThreshold == nil { return s }
        let n = s.count
        var out = [UInt32]()
        out.reserveCapacity(n + 8)
        var i = 0
        while i < n {
            let c = s[i]
            var j = i + 1
            while j < n, s[j] == c { j += 1 }
            let run = j - i
            var matched = false
            if let r = repeatedCharsThreshold, c != 0x0A, run >= r { matched = true }
            if !matched, let sp = consecutiveSpacesThreshold, c == 0x20, run >= sp { matched = true }
            if matched {
                out.append(Self.boundaryChar)
                out.append(contentsOf: s[i ..< j])
                out.append(Self.boundaryChar)
                i = j
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    private func viterbi(_ data: [UInt32]) -> [Int] {
        let n = data.count
        if n == 0 { return [] }
        let invalid = Self.invalidScore
        let unknown = Self.unknownScore
        var scores = [Int64](repeating: 1 << 60, count: n + 1)
        scores[n] = 0
        var pathLength = [Int32](repeating: 0, count: n + 1)
        var pathToken = [Int32](repeating: 0, count: n + 1)

        table.withUnsafeBufferPointer { t in
            var suffixID: Int32 = 0
            for i in stride(from: n - 1, through: 0, by: -1) {
                let c = data[i]
                let code = UInt64(c) << 32

                var p = Int(suffixID)
                while p < tableRows {
                    let next = toSuffixID.get(code | UInt64(UInt32(t[p &* 4 &+ 3]))) ?? 0
                    suffixID = next
                    if next > 0 || t[p &* 4 &+ 2] == unknown { break }
                    p += 1
                }

                // Longest piece wins ties: rows are in decreasing length and the comparison is strict.
                var best = scores[i]
                p = Int(suffixID)
                while p < tableRows {
                    let score = t[p &* 4 &+ 2]
                    if score > invalid {
                        let length = Int(t[p &* 4])
                        let s = scores[i + length] - Int64(score)
                        if s < best {
                            best = s
                            pathLength[i] = Int32(length)
                            pathToken[i] = t[p &* 4 &+ 1]
                        }
                    }
                    if score == unknown { break }
                    p += 1
                }
                scores[i] = best
            }
        }

        var ids = [Int]()
        ids.reserveCapacity(n)
        var pos = 0
        while pos < n {
            let token = pathToken[pos]
            if token >= 0 {
                if token != Self.boundaryTokenID { ids.append(Int(token)) }
            } else {
                let c = data[pos]
                let s = 1 + (c >= 0x80 ? 1 : 0) + (c >= 0x800 ? 1 : 0) + (c >= 0x10000 ? 1 : 0)
                for i in 0 ..< s {
                    let b: UInt32 = s == 1 ? c : (i == 0 ? (0xF00 >> UInt32(s)) & 0xFF : 0x80)
                    ids.append(Int(byteTokens[Int(b | ((c >> UInt32((s - i - 1) * 6)) & 0x3F))]))
                }
            }
            precondition(pathLength[pos] > 0)
            pos += Int(pathLength[pos])
        }
        return ids
    }

    // MARK: - Decoding

    /// Decodes ids to text like `tokenizer.decode(ids)` (special tokens kept, invalid UTF-8 replaced).
    public func decode(_ ids: [Int]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(ids.count * 4)
        for id in ids { appendBytes(of: id, to: &bytes) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func appendBytes(of id: Int, to bytes: inout [UInt8]) {
        guard id >= 0, id < vocabSize else { return }
        let b = byteValues[id]
        if b >= 0 {
            bytes.append(UInt8(b))
        } else {
            let lo = Int(pieceOffsets[id])
            let hi = Int(pieceOffsets[id + 1])
            bytes.append(contentsOf: pieceBytes[lo ..< hi])
        }
    }

    /// A decoder that turns a stream of ids into text without ever splitting a multi-byte character.
    public func makeStreamingDecoder() -> PlamoStreamingDecoder {
        PlamoStreamingDecoder(tokenizer: self)
    }

    // MARK: - Helpers

    private static func byteTokenValue(_ scalars: [UInt32]) -> Int? {
        // "<0xHH" prefix
        guard scalars.count >= 5, scalars[0] == 0x3C, scalars[1] == 0x30, scalars[2] == 0x78 else { return nil }
        func hex(_ v: UInt32) -> Int? {
            switch v {
            case 0x30 ... 0x39: Int(v - 0x30)
            case 0x41 ... 0x46: Int(v - 0x41 + 10)
            case 0x61 ... 0x66: Int(v - 0x61 + 10)
            default: nil
            }
        }
        guard let h = hex(scalars[3]), let l = hex(scalars[4]) else { return nil }
        return h << 4 | l
    }

    static func appendUTF8(_ scalars: [UInt32], to out: inout [UInt8]) {
        for v in scalars {
            switch v {
            case 0 ..< 0x80:
                out.append(UInt8(v))
            case 0x80 ..< 0x800:
                out.append(UInt8(0xC0 | (v >> 6)))
                out.append(UInt8(0x80 | (v & 0x3F)))
            case 0xD800 ..< 0xE000:
                out.append(contentsOf: [0xEF, 0xBF, 0xBD])  // lone surrogate
            case 0x800 ..< 0x10000:
                out.append(UInt8(0xE0 | (v >> 12)))
                out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (v & 0x3F)))
            default:
                out.append(UInt8(0xF0 | (v >> 18)))
                out.append(UInt8(0x80 | ((v >> 12) & 0x3F)))
                out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (v & 0x3F)))
            }
        }
    }

    /// Python's `str.isspace()` / regex `\s` for str patterns.
    static func isPythonWhitespace(_ c: UInt32) -> Bool {
        switch c {
        case 0x09 ... 0x0D, 0x1C ... 0x20, 0x85, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F,
            0x205F, 0x3000:
            true
        default:
            false
        }
    }
}

/// Incremental detokenizer for streaming output. Holds back an incomplete UTF-8 sequence
/// at the end until the bytes that complete it arrive.
public struct PlamoStreamingDecoder: Sendable {
    private let tokenizer: PlamoTokenizer
    private var pending: [UInt8] = []
    /// All text emitted so far.
    public private(set) var text: String = ""

    init(tokenizer: PlamoTokenizer) {
        self.tokenizer = tokenizer
    }

    /// Appends one token and returns the newly completed text (possibly empty).
    @discardableResult
    public mutating func append(_ id: Int) -> String {
        tokenizer.appendBytes(of: id, to: &pending)
        let cut = Self.completePrefixLength(pending)
        guard cut > 0 else { return "" }
        let chunk = String(decoding: pending[..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        text += chunk
        return chunk
    }

    /// Flushes any held-back bytes (an unfinished sequence becomes U+FFFD).
    @discardableResult
    public mutating func finish() -> String {
        guard !pending.isEmpty else { return "" }
        let chunk = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        text += chunk
        return chunk
    }

    /// Length of the prefix that does not end inside a multi-byte sequence.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        var k = 1
        while k <= min(3, n) {
            let b = bytes[n - k]
            if b & 0xC0 == 0x80 {
                k += 1
                continue
            }
            let need: Int
            if b & 0xE0 == 0xC0 {
                need = 2
            } else if b & 0xF0 == 0xE0 {
                need = 3
            } else if b & 0xF8 == 0xF0 {
                need = 4
            } else {
                need = 1
            }
            return need > k ? n - k : n
        }
        return n
    }
}
