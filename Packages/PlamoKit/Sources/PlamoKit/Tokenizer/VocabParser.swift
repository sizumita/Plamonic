import Foundation

/// One row of tokenizer.jsonl: `[token, score, type, ...]`.
struct VocabRow {
    var scalars: [UInt32]
    var score: Double
    var isByte: Bool
}

enum VocabParseError: Error, CustomStringConvertible {
    case malformed(line: Int, reason: String)

    var description: String {
        switch self {
        case .malformed(let line, let reason): "tokenizer.jsonl line \(line): \(reason)"
        }
    }
}

/// Minimal JSON reader specialised for tokenizer.jsonl. JSONSerialization takes ~1 s for 107k lines;
/// this takes a few milliseconds. Strings are returned as raw code points (no normalization), like Python.
enum VocabParser {
    static func parse(_ data: Data) throws -> [VocabRow] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [VocabRow] in
            let p = raw.bindMemory(to: UInt8.self)
            var rows = [VocabRow]()
            rows.reserveCapacity(110_000)
            var i = 0
            let n = p.count
            var line = 0
            var scratch = [UInt32]()
            scratch.reserveCapacity(64)
            while i < n {
                // skip blank lines
                while i < n, p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x20 || p[i] == 0x09 { i += 1 }
                if i >= n { break }
                line += 1
                guard p[i] == UInt8(ascii: "[") else {
                    throw VocabParseError.malformed(line: line, reason: "expected '['")
                }
                i += 1
                skipSpace(p, &i)
                scratch.removeAll(keepingCapacity: true)
                try parseString(p, &i, into: &scratch, line: line)
                skipSpace(p, &i)
                try expect(p, &i, UInt8(ascii: ","), line: line)
                skipSpace(p, &i)
                let score = try parseNumber(p, &i, line: line)
                skipSpace(p, &i)
                var isByte = false
                if i < n, p[i] == UInt8(ascii: ",") {
                    i += 1
                    skipSpace(p, &i)
                    if i < n, p[i] == UInt8(ascii: "\"") {
                        var type = [UInt32]()
                        try parseString(p, &i, into: &type, line: line)
                        isByte = type == [0x42, 0x59, 0x54, 0x45]  // "BYTE"
                    }
                }
                // ignore any further elements
                while i < n, p[i] != 0x0A { i += 1 }
                rows.append(VocabRow(scalars: scratch, score: score, isByte: isByte))
            }
            return rows
        }
    }

    @inline(__always)
    private static func skipSpace(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
        while i < p.count, p[i] == 0x20 || p[i] == 0x09 { i += 1 }
    }

    private static func expect(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int, _ c: UInt8, line: Int) throws {
        guard i < p.count, p[i] == c else {
            throw VocabParseError.malformed(line: line, reason: "expected '\(Character(UnicodeScalar(c)))'")
        }
        i += 1
    }

    private static func hex(_ c: UInt8) -> UInt32? {
        switch c {
        case 0x30 ... 0x39: UInt32(c - 0x30)
        case 0x41 ... 0x46: UInt32(c - 0x41 + 10)
        case 0x61 ... 0x66: UInt32(c - 0x61 + 10)
        default: nil
        }
    }

    private static func parseHex4(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int, line: Int) throws -> UInt32 {
        guard i + 4 <= p.count else { throw VocabParseError.malformed(line: line, reason: "short \\u escape") }
        var v: UInt32 = 0
        for k in 0 ..< 4 {
            guard let h = hex(p[i + k]) else { throw VocabParseError.malformed(line: line, reason: "bad \\u escape") }
            v = v << 4 | h
        }
        i += 4
        return v
    }

    private static func parseString(
        _ p: UnsafeBufferPointer<UInt8>, _ i: inout Int, into out: inout [UInt32], line: Int
    ) throws {
        try expect(p, &i, UInt8(ascii: "\""), line: line)
        let n = p.count
        while i < n {
            let b = p[i]
            if b == UInt8(ascii: "\"") {
                i += 1
                return
            }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < n else { break }
                let e = p[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var v = try parseHex4(p, &i, line: line)
                    // Combine a surrogate pair like Python's json module; keep lone surrogates as-is.
                    if v >= 0xD800, v < 0xDC00, i + 6 <= n, p[i] == UInt8(ascii: "\\"), p[i + 1] == UInt8(ascii: "u") {
                        var j = i + 2
                        let lo = try parseHex4(p, &j, line: line)
                        if lo >= 0xDC00, lo < 0xE000 {
                            v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                            i = j
                        }
                    }
                    out.append(v)
                default:
                    throw VocabParseError.malformed(line: line, reason: "bad escape")
                }
                continue
            }
            // raw UTF-8
            if b < 0x80 {
                out.append(UInt32(b))
                i += 1
            } else {
                let len: Int
                var v: UInt32
                if b & 0xE0 == 0xC0 {
                    len = 2
                    v = UInt32(b & 0x1F)
                } else if b & 0xF0 == 0xE0 {
                    len = 3
                    v = UInt32(b & 0x0F)
                } else if b & 0xF8 == 0xF0 {
                    len = 4
                    v = UInt32(b & 0x07)
                } else {
                    throw VocabParseError.malformed(line: line, reason: "invalid UTF-8")
                }
                guard i + len <= n else { throw VocabParseError.malformed(line: line, reason: "truncated UTF-8") }
                for k in 1 ..< len {
                    let c = p[i + k]
                    guard c & 0xC0 == 0x80 else {
                        throw VocabParseError.malformed(line: line, reason: "invalid UTF-8")
                    }
                    v = v << 6 | UInt32(c & 0x3F)
                }
                out.append(v)
                i += len
            }
        }
        throw VocabParseError.malformed(line: line, reason: "unterminated string")
    }

    private static func parseNumber(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int, line: Int) throws -> Double {
        let start = i
        while i < p.count {
            let c = p[i]
            let isNumberChar =
                (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
                || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
            if !isNumberChar { break }
            i += 1
        }
        let length = i - start
        guard length > 0, length < 64 else { throw VocabParseError.malformed(line: line, reason: "bad number") }
        // strtod is correctly rounded, like Python's float().
        var buffer = (
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
            Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0)
        )
        return withUnsafeMutableBytes(of: &buffer) { buf -> Double in
            let chars = buf.bindMemory(to: CChar.self)
            for k in 0 ..< length { chars[k] = CChar(bitPattern: p[start + k]) }
            chars[length] = 0
            return strtod(chars.baseAddress!, nil)
        }
    }
}
