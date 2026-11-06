import Foundation

/// Normalizes text before it is used as a translation input or a cache key.
enum TextSanitizer {
    /// A piece of a long text, plus the separator that followed it in the original.
    struct Chunk: Hashable, Sendable {
        var text: String
        /// "\n\n", "\n", " " or "" (the last chunk always has "").
        var separator: String
    }

    /// Prefix of every PLaMo special token. Inputs must never contain it.
    static let controlPrefix = "<|plamo:"

    /// Trims, unifies line breaks, collapses runs of horizontal whitespace into one space
    /// (newlines are kept, at most one blank line in a row), drops invisible characters,
    /// neutralizes "<|plamo:" and caps the result at `maxLength` characters.
    static func normalize(_ text: String, maxLength: Int? = nil) -> String {
        var offsets: [Int]?
        return normalize(text, maxLength: maxLength, offsets: &offsets)
    }

    /// A normalized text and where each of its UTF-16 units came from in the source.
    struct MappedText: Hashable, Sendable {
        var text: String
        /// For each UTF-16 unit of `text`, the UTF-16 offset in the source of the character it came from.
        /// A space or line break that stands for collapsed whitespace points at the end of the text before it.
        /// Never decreases.
        var offsets: [Int]
    }

    /// `normalize`, also recording where each unit of the result came from (to move ranges of the source,
    /// such as links, onto the normalized text).
    static func normalizeMapped(_ text: String, maxLength: Int? = nil) -> MappedText {
        var offsets: [Int]? = []
        let result = normalize(text, maxLength: maxLength, offsets: &offsets)
        return MappedText(text: result, offsets: offsets ?? [])
    }

    private static func normalize(_ text: String, maxLength: Int?, offsets: inout [Int]?) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var pendingNewlines = 0
        var hasContent = false
        var previousWasCR = false
        // UTF-16 offsets in `text`: of the current scalar, and just past the last kept one.
        var sourceOffset = 0
        var contentEnd = 0

        for scalar in text.unicodeScalars {
            let start = sourceOffset
            sourceOffset += UTF16.width(scalar)
            let isCR = scalar == "\r"
            defer { previousWasCR = isCR }
            if scalar == "\n" && previousWasCR { continue }
            if isLineBreak(scalar) {
                pendingNewlines += 1
                pendingSpace = false  // drop trailing spaces of the line
                continue
            }
            if isHorizontalSpace(scalar) {
                if pendingNewlines == 0 { pendingSpace = true }  // leading spaces of a line are dropped
                continue
            }
            if isInvisible(scalar) { continue }
            if hasContent {
                if pendingNewlines > 0 {
                    scalars.append("\n")
                    offsets?.append(contentEnd)
                    if pendingNewlines > 1 {
                        scalars.append("\n")
                        offsets?.append(contentEnd)
                    }
                } else if pendingSpace {
                    scalars.append(" ")
                    offsets?.append(contentEnd)
                }
            }
            pendingNewlines = 0
            pendingSpace = false
            hasContent = true
            scalars.append(scalar)
            if offsets != nil {
                for _ in 0..<UTF16.width(scalar) { offsets?.append(start) }
            }
            contentEnd = sourceOffset
        }

        // Neutralizing swaps "|" for "｜": one UTF-16 unit each, so the offsets still line up.
        var result = neutralizeControlSequences(String(scalars))
        if let maxLength, maxLength > 0, result.count > maxLength {
            result = truncate(result, to: maxLength)
            // The cut keeps a prefix (the text never starts with whitespace).
            if let all = offsets { offsets = Array(all.prefix(result.utf16.count)) }
        }
        return result
    }

    /// Normalizes and joins lines with spaces (for glossary terms and other one-line values).
    static func singleLine(_ text: String, maxLength: Int? = nil) -> String {
        let normalized = normalize(text, maxLength: maxLength)
        guard normalized.contains("\n") else { return normalized }
        return normalized.split(separator: "\n", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Replaces "<|" with "<｜" wherever it starts a "<|plamo:" sequence (case-insensitive),
    /// so the text can never be tokenized as a PLaMo special token.
    static func neutralizeControlSequences(_ text: String) -> String {
        let offsets = controlPrefixOffsets(in: text)
        guard !offsets.isEmpty else { return text }
        var bytes = Array(text.utf8)
        for offset in offsets.reversed() {
            bytes.replaceSubrange((offset + 1)..<(offset + 2), with: "\u{FF5C}".utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether `text` contains "<|plamo:" (case-insensitive), compared code point by code point.
    static func containsControlPrefix(_ text: String) -> Bool {
        !controlPrefixOffsets(in: text).isEmpty
    }

    /// UTF-8 offsets of every "<|plamo:" (ASCII letters in any case). PlamoKit rejects the sequence
    /// by code points, so a Character-based search is not enough: a combining mark, variation selector
    /// or ZWJ after the ":" joins it into one Character and hides it. The prefix is pure ASCII and
    /// UTF-8 never uses ASCII bytes inside other characters, so a byte match is a code-point match.
    private static func controlPrefixOffsets(in text: String) -> [Int] {
        var text = text
        return text.withUTF8 { bytes in
            let prefix = controlPrefixBytes
            guard bytes.count >= prefix.count else { return [] }
            var offsets: [Int] = []
            for start in 0...(bytes.count - prefix.count) where bytes[start] == prefix[0] {
                let matched = (1..<prefix.count).allSatisfy { offset in
                    var byte = bytes[start + offset]
                    if (0x41...0x5A).contains(byte) { byte += 0x20 }  // ASCII lowercase
                    return byte == prefix[offset]
                }
                if matched { offsets.append(start) }
            }
            return offsets
        }
    }

    private static let controlPrefixBytes = Array(controlPrefix.utf8)

    /// Cleans a model output: removes leftover special tokens and surrounding whitespace.
    static func cleanOutput(_ text: String) -> String {
        var result = text
        if containsControlPrefix(result) {
            result = result.replacingOccurrences(
                of: #"<\|plamo:[A-Za-z_]*\|>"#, with: "", options: .regularExpression)
            result = neutralizeControlSequences(result)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chunking

    /// Splits `text` into chunks of at most `maxLength` characters, preferring paragraph breaks,
    /// then line breaks, then sentence ends, then spaces. Short text comes back as one chunk.
    static func chunks(_ text: String, maxLength: Int) -> [Chunk] {
        let limit = max(1, maxLength)
        guard text.count > limit else { return [Chunk(text: text, separator: "")] }
        var result = split(text, limit: limit, level: .paragraph)
        result = result.filter { !$0.text.isEmpty }
        if !result.isEmpty { result[result.count - 1].separator = "" }
        return result
    }

    /// Joins chunk translations back together with their original separators.
    /// A single space between two CJK sentences is dropped ("文。 文。" -> "文。文。").
    static func join(_ parts: [String], separators: [String]) -> String {
        var result = ""
        for (index, part) in parts.enumerated() {
            result += part
            guard index < parts.count - 1 else { break }
            var separator = index < separators.count ? separators[index] : " "
            if !separator.contains("\n"), let last = part.unicodeScalars.last,
                let next = parts[index + 1].unicodeScalars.first,
                isCJKBoundaryScalar(last) && isCJKBoundaryScalar(next)
            {
                separator = ""
            }
            result += separator
        }
        return result
    }

    private enum SplitLevel: Int {
        case paragraph, line, sentence, word, character

        var next: SplitLevel { SplitLevel(rawValue: rawValue + 1) ?? .character }
    }

    private static func split(_ text: String, limit: Int, level: SplitLevel) -> [Chunk] {
        if text.count <= limit { return [Chunk(text: text, separator: "")] }
        if level == .character { return hardSplit(text, limit: limit) }

        let pieces = self.pieces(of: text, level: level)
        if pieces.count <= 1 { return split(text, limit: limit, level: level.next) }

        var result: [Chunk] = []
        var current = ""
        var currentCount = 0
        var currentSeparator = ""

        func flush() {
            if !current.isEmpty { result.append(Chunk(text: current, separator: currentSeparator)) }
            current = ""
            currentCount = 0
            currentSeparator = ""
        }

        for piece in pieces {
            let pieceCount = piece.text.count
            if pieceCount > limit {
                flush()
                var sub = split(piece.text, limit: limit, level: level.next)
                if !sub.isEmpty { sub[sub.count - 1].separator = piece.separator }
                result += sub
            } else if current.isEmpty {
                current = piece.text
                currentCount = pieceCount
                currentSeparator = piece.separator
            } else if currentCount + currentSeparator.count + pieceCount <= limit {
                current += currentSeparator + piece.text
                currentCount += currentSeparator.count + pieceCount
                currentSeparator = piece.separator
            } else {
                flush()
                current = piece.text
                currentCount = pieceCount
                currentSeparator = piece.separator
            }
        }
        flush()
        return result
    }

    /// Splits text at one level; each piece carries the separator that followed it.
    private static func pieces(of text: String, level: SplitLevel) -> [Chunk] {
        switch level {
        case .paragraph:
            return splitKeepingSeparator(text, separator: "\n\n")
        case .line:
            return splitKeepingSeparator(text, separator: "\n")
        case .sentence:
            return sentencePieces(text)
        case .word:
            return splitKeepingSeparator(text, separator: " ")
        case .character:
            return [Chunk(text: text, separator: "")]
        }
    }

    private static func splitKeepingSeparator(_ text: String, separator: String) -> [Chunk] {
        let parts = text.components(separatedBy: separator)
        return parts.enumerated().compactMap { index, part in
            guard !part.isEmpty else { return nil }
            return Chunk(text: part, separator: index < parts.count - 1 ? separator : "")
        }
    }

    private static let asciiTerminators: Set<Character> = [".", "!", "?"]
    private static let cjkTerminators: Set<Character> = ["。", "！", "？", "．", "…"]
    private static let closers: Set<Character> = ["」", "』", "）", ")", "\"", "'", "”", "’", "】", "》", "〉"]

    private static func sentencePieces(_ text: String) -> [Chunk] {
        var pieces: [Chunk] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            let isCJK = cjkTerminators.contains(character)
            guard isCJK || asciiTerminators.contains(character) else { continue }
            // Keep closing quotes / brackets and repeated terminators with the sentence.
            while index < characters.count,
                closers.contains(characters[index]) || cjkTerminators.contains(characters[index])
                    || asciiTerminators.contains(characters[index])
            {
                current.append(characters[index])
                index += 1
            }
            if index < characters.count, characters[index] == " " {
                pieces.append(Chunk(text: current, separator: " "))
                current = ""
                while index < characters.count, characters[index] == " " { index += 1 }
            } else if isCJK {
                pieces.append(Chunk(text: current, separator: ""))
                current = ""
            }
            // An ASCII terminator not followed by a space ("3.14", "e.g.x") does not end a sentence.
        }
        if !current.isEmpty { pieces.append(Chunk(text: current, separator: "")) }
        return pieces
    }

    private static func hardSplit(_ text: String, limit: Int) -> [Chunk] {
        var result: [Chunk] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            result.append(Chunk(text: String(text[start..<end]), separator: ""))
            start = end
        }
        return result
    }

    // MARK: - Truncation

    /// Cuts to `maxLength` characters, backing up to a line / sentence / word boundary
    /// when one is found in the last third.
    private static func truncate(_ text: String, to maxLength: Int) -> String {
        let prefix = Array(text.prefix(maxLength))
        let floor = maxLength * 2 / 3
        var cut = prefix.count
        var index = prefix.count - 1
        var bestRank = 0
        while index >= floor {
            let character = prefix[index]
            let rank: Int
            if character == "\n" {
                rank = 3
            } else if cjkTerminators.contains(character) || asciiTerminators.contains(character) {
                rank = 2
            } else if character == " " {
                rank = 1
            } else {
                rank = 0
            }
            if rank > bestRank {
                bestRank = rank
                cut = (character == "\n" || character == " ") ? index : index + 1
                if rank == 3 { break }
            }
            index -= 1
        }
        return String(prefix[0..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Character classes

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private static func isHorizontalSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// Zero-width and formatting characters that carry no meaning for translation.
    /// ZWJ / ZWNJ are kept (emoji sequences, Persian, Indic scripts).
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0E...0x1F, 0x7F...0x84, 0x86...0x9F: return true  // control characters
        case 0xAD, 0x200B, 0x200E, 0x200F, 0x2060...0x2064, 0xFEFF, 0xFFFC, 0xFFFD: return true
        case 0x202A...0x202E, 0x2066...0x2069: return true  // bidi embedding / isolate controls
        default: return false
        }
    }

    private static func isCJKBoundaryScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,  // CJK punctuation
            0x3040...0x30FF,  // kana
            0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // han
            0xFF01...0xFF60:  // fullwidth forms
            return true
        default:
            return false
        }
    }
}
