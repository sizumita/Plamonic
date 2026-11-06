import Foundation

/// Carries a segment's links through translation (DESIGN §6.1 「訳文の中のリンク」).
///
/// Natural-language anchors ("the setup guide") are sent to the model wrapped as `[anchor](n)`: the model
/// translates the anchor in place and keeps the marker, and the number survives word-order changes. Verbatim
/// links (URLs, @mentions, #channels, issue numbers, file names, code) are sent as they are and found in the
/// output by exact search; wrapping them made the model drop or alter some (links-spike in the design notes).
/// When the markup comes back broken, all of it is removed and the anchors are looked up as plain text.
enum TranslationLinks {
    /// One link of a segment as it travels through translation.
    struct Planned: Hashable, Sendable {
        /// Index into the segment's links (`OverlayItem.originalLinks`).
        var index: Int
        /// The link's text in the normalized source.
        var text: String
        /// Number of its `[anchor](n)` marker in the model input; nil when it is sent unmarked.
        var markupID: Int?
        /// Must appear in the translation exactly as in the original (URL, mention, channel, file name, code).
        var isVerbatim: Bool
        /// UTF-16 offsets of the link in `Plan.plain`.
        var range: Range<Int>
    }

    /// How one segment's links are sent to the model and found again in its output.
    struct Plan: Hashable, Sendable {
        /// The normalized source, without markup.
        var plain: String
        /// What the model translates: `plain` with markers around the natural-language anchors.
        var input: String
        /// Links that survived normalization, in text order.
        var links: [Planned]

        var usesMarkup: Bool { input != plain }
    }

    /// A translation as displayed, and where the original links are in it.
    struct Mapped: Hashable, Sendable {
        var text: String
        var links: [OverlayLink]
    }

    // MARK: - Planning

    /// Moves the segment's links onto its normalized text and marks the natural-language anchors.
    /// Links cut off or changed by normalization are left out (they stay reachable in the original).
    /// nil when no link is left.
    static func plan(source: String, links: [SegmentLink], normalized: TextSanitizer.MappedText) -> Plan? {
        guard !links.isEmpty, !normalized.text.isEmpty else { return nil }
        let plain = normalized.text
        let plainUnits = Array(plain.utf16)
        let sourceString = source as NSString
        let order = links.indices.sorted {
            (links[$0].range.lowerBound, $0) < (links[$1].range.lowerBound, $1)
        }
        var found: [Planned] = []
        var lastEnd = 0
        for index in order {
            let range = links[index].range
            guard range.lowerBound >= 0, range.upperBound <= sourceString.length, !range.isEmpty else { continue }
            var lower = firstIndex(in: normalized.offsets, notBelow: range.lowerBound)
            var upper = firstIndex(in: normalized.offsets, notBelow: range.upperBound)
            while lower < upper, isSpace(plainUnits[lower]) { lower += 1 }
            while upper > lower, isSpace(plainUnits[upper - 1]) { upper -= 1 }
            // Overlapping links keep the first one.
            guard lower < upper, lower >= lastEnd else { continue }
            let text = String(decoding: plainUnits[lower..<upper], as: UTF16.self)
            let original = sourceString.substring(with: NSRange(location: range.lowerBound, length: range.count))
            guard text == TextSanitizer.normalize(original) else { continue }
            lastEnd = upper
            let verbatim = isVerbatim(text, kind: links[index].kind)
            found.append(Planned(index: index, text: text, markupID: nil, isVerbatim: verbatim, range: lower..<upper))
        }
        guard !found.isEmpty else { return nil }

        // Numbers start above the source's own list numbers ("(1)", "（2）", "3)", "①"): a translation that
        // writes one of them as "(n)" in the other width must not look like a leftover marker.
        let firstID = (listNumbers(in: plain).max() ?? 0) + 1
        let markable = found.filter { !$0.isVerbatim && isMarkable($0.text) }.count
        // Sent unmarked when the source already reads like markup (it would be misread on the way back) or the
        // numbers would not fit in three digits.
        let canMark =
            !matches(markupRegex, plain) && !matches(strayIDRegex, plain) && firstID + markable - 1 <= maxMarkupID
        var input: [UInt16] = []
        var cursor = 0
        var nextID = firstID
        for position in found.indices {
            let planned = found[position]
            guard canMark, !planned.isVerbatim, isMarkable(planned.text) else { continue }
            found[position].markupID = nextID
            input.append(contentsOf: plainUnits[cursor..<planned.range.lowerBound])
            input.append(contentsOf: "[".utf16)
            input.append(contentsOf: plainUnits[planned.range])
            input.append(contentsOf: "](\(nextID))".utf16)
            cursor = planned.range.upperBound
            nextID += 1
        }
        let marked = nextID > firstID
        if marked { input.append(contentsOf: plainUnits[cursor...]) }
        return Plan(plain: plain, input: marked ? String(decoding: input, as: UTF16.self) : plain, links: found)
    }

    /// Markers carry up to three digits.
    private static let maxMarkupID = 999

    /// The values of the list numbers in `text`: a number before ")" or "）" ("(1)", "（２）", "3)") and an
    /// enclosed number ("①", "⑴", "❶"). A translation may write any of them as "(n)" or "（n）".
    private static func listNumbers(in text: String) -> [Int] {
        var numbers: [Int] = []
        let source = text as NSString
        for match in listNumberRegex?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? [] {
            if let value = number(source.substring(with: match.range(at: 1))) { numbers.append(value) }
        }
        for scalar in text.unicodeScalars where isEnclosedNumber(scalar) {
            if let value = scalar.properties.numericValue, value >= 0, value <= Double(maxMarkupID),
                value == value.rounded()
            {
                numbers.append(Int(value))
            }
        }
        return numbers
    }

    /// Circled, parenthesized and dotted numbers (Enclosed Alphanumerics, Dingbats, Enclosed CJK).
    private static func isEnclosedNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2460...0x24FF, 0x2776...0x2793, 0x3251...0x325F, 0x32B1...0x32BF: return true
        default: return false
        }
    }

    /// Text that must come back unchanged: URLs, @mentions, #channels and issue numbers, file names, paths,
    /// e-mail addresses and identifiers. Everything else is a natural-language anchor the model translates.
    static func isVerbatim(_ text: String, kind: SegmentLinkKind) -> Bool {
        if kind == .detected { return true }
        guard let first = text.unicodeScalars.first else { return true }
        if "@#＠＃".unicodeScalars.contains(first) { return true }
        if !text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { return true }
        if text.contains("://") || text.lowercased().hasPrefix("www.") { return true }
        guard !text.contains(where: \.isWhitespace), text.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        if text.contains(where: { "./\\_:@$`~=<>{}[]()".contains($0) }) { return true }
        // camelCase and brand-like names ("GitHub", "iOS"): a lowercase letter followed by an uppercase one.
        var previousIsLower = false
        for scalar in text.unicodeScalars {
            let isUpper = scalar.properties.isUppercase
            if previousIsLower && isUpper { return true }
            previousIsLower = scalar.properties.isLowercase
        }
        return false
    }

    /// The anchor can sit inside `[...]`: no brackets and on one line.
    private static func isMarkable(_ text: String) -> Bool {
        !text.contains(where: { "[]［］\n".contains($0) })
    }

    // MARK: - Mapping

    /// The translation to display for `output` (a model output for `plan.input`, or a partial of it) and where
    /// the original links are in it. Never shows markup: a broken one is removed, and a partial's unfinished
    /// marker is hidden. Verbatim links the model changed slightly are written back as in the original.
    static func map(_ output: String, plan: Plan, isPartial: Bool) -> Mapped {
        var text: [UInt16]
        var spans: [Span] = []
        if plan.usesMarkup {
            let decoded = decode(output, plan: plan, isPartial: isPartial)
            text = decoded.text
            spans = decoded.spans
        } else {
            text = Array(output.utf16)
        }

        // Verbatim links, and anchors whose marker was not sent or did not come back: by their own text
        // (an anchor the model kept, such as a name). Repeated texts take their occurrences in order.
        for link in plan.links where !spans.contains(where: { $0.index == link.index }) {
            let needle = Array(link.text.utf16)
            guard link.isVerbatim || needle.count >= 2 else { continue }
            if let range = find(needle, in: text, avoiding: spans, verbatim: link.isVerbatim) {
                spans.append(Span(index: link.index, range: range))
                continue
            }
            guard link.isVerbatim,
                let mangled = looseMatch(needle, in: text, avoiding: spans)
                    ?? (isPartial ? nil : truncatedURL(link, plain: plan.plain, in: text, avoiding: spans))
            else { continue }
            // Write the original back over the changed copy.
            text.replaceSubrange(mangled, with: needle)
            let delta = needle.count - mangled.count
            for position in spans.indices where spans[position].range.lowerBound >= mangled.upperBound {
                let range = spans[position].range
                spans[position].range = (range.lowerBound + delta)..<(range.upperBound + delta)
            }
            spans.append(Span(index: link.index, range: mangled.lowerBound..<(mangled.lowerBound + needle.count)))
        }

        let links = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { OverlayLink(range: $0.range, linkIndex: $0.index) }
        return Mapped(text: String(decoding: text, as: UTF16.self), links: links)
    }

    private struct Span {
        /// Index into the segment's links.
        var index: Int
        /// UTF-16 offsets in the displayed text.
        var range: Range<Int>
    }

    // MARK: - Markup

    /// `[anchor](n)`, also with full-width brackets, parentheses or digits, or a space before the "(".
    private static let markupRegex = regex(#"[\[［]([^\[\]［］\n]*)[\]］] ?[(（]([0-9０-９]{1,3})[)）]"#)
    /// What is left of a marker whose "[" went missing.
    private static let strayIDRegex = regex(#"[\]］] ?[(（][0-9０-９]{1,3}[)）]"#)
    /// A number in parentheses: left over when it is one that was sent and the source does not have it.
    private static let orphanIDRegex = regex(#"[(（]([0-9０-９]{1,3})[)）]"#)
    /// A list number of the source: up to three digits before ")" or "）".
    private static let listNumberRegex = regex(#"(?<![0-9０-９])([0-9０-９]{1,3})[)）]"#)
    /// The unfinished marker at the end of a partial output: "[anchor", "[anchor]", "[anchor](1".
    private static let partialTailRegex = regex(#"[\[［]([^\[\]［］\n]*)(?:[\]］] ?(?:[(（][0-9０-９]{0,3})?)?$"#)
    /// The unfinished end of a marker whose "[" went missing: "](", "](1".
    private static let partialStrayTailRegex = regex(#"[\]］] ?(?:[(（][0-9０-９]{0,3})?$"#)

    private struct Decoded {
        var text: [UInt16]
        var spans: [Span]
    }

    /// Removes the markers. The anchors become spans when the markers came back whole: every number once, no
    /// marker left over (a partial may still lack the later ones). Otherwise no span is kept.
    private static func decode(_ output: String, plan: Plan, isPartial: Bool) -> Decoded {
        let source = output as NSString
        let length = source.length
        let markers = markupRegex?.matches(in: output, range: NSRange(location: 0, length: length)) ?? []
        var end = length
        var tail: String?
        if isPartial {
            let start = markers.last.map { NSMaxRange($0.range) } ?? 0
            let rest = NSRange(location: start, length: length - start)
            if let match = partialTailRegex?.firstMatch(in: output, range: rest) {
                end = match.range.location
                tail = source.substring(with: match.range(at: 1))
            } else if let match = partialStrayTailRegex?.firstMatch(in: output, range: rest) {
                end = match.range.location
            }
        }

        // Brackets the source does not have are left over from markers. Ones it has may be its own.
        let keepsOpen = plan.plain.contains(where: { $0 == "[" || $0 == "［" })
        let keepsClose = plan.plain.contains(where: { $0 == "]" || $0 == "］" })
        func isStrayBracket(_ character: Character) -> Bool {
            (!keepsOpen && (character == "[" || character == "［"))
                || (!keepsClose && (character == "]" || character == "］"))
        }
        let wanted = Set(plan.links.compactMap(\.markupID))
        // A "(n)" with a sent number is left over from a marker. `plan` numbers past the source's list numbers,
        // so none should be the source's own; still keep as many of each as the source has, in either width.
        var ownNumbers = Dictionary(listNumbers(in: plan.plain).map { ($0, 1) }, uniquingKeysWith: +)
        var broken = false
        var text: [UInt16] = []
        func appendClean(_ range: NSRange) {
            guard range.length > 0 else { return }
            var piece = source.substring(with: range)
            if let strayIDRegex, matches(strayIDRegex, piece) {
                piece = strayIDRegex.stringByReplacingMatches(
                    in: piece, range: NSRange(location: 0, length: (piece as NSString).length), withTemplate: "")
                broken = true
            }
            if let orphanIDRegex {
                let units = piece as NSString
                let fragments = orphanIDRegex.matches(in: piece, range: NSRange(location: 0, length: units.length))
                    .filter { match in
                        guard let id = number(units.substring(with: match.range(at: 1))), wanted.contains(id) else {
                            return false
                        }
                        let own = ownNumbers[id, default: 0]
                        guard own > 0 else { return true }
                        ownNumbers[id] = own - 1
                        return false
                    }
                if !fragments.isEmpty {
                    let mutable = NSMutableString(string: piece)
                    for match in fragments.reversed() { mutable.deleteCharacters(in: match.range) }
                    piece = mutable as String
                    broken = true
                }
            }
            let count = piece.count
            piece.removeAll(where: isStrayBracket)
            if piece.count != count { broken = true }
            text.append(contentsOf: piece.utf16)
        }

        var seen = Set<Int>()
        var spans: [Span] = []
        var cursor = 0
        for marker in markers where NSMaxRange(marker.range) <= end {
            appendClean(NSRange(location: cursor, length: marker.range.location - cursor))
            let anchor = Array(source.substring(with: marker.range(at: 1)).utf16)
            let id = number(source.substring(with: marker.range(at: 2)))
            var lower = text.count
            text.append(contentsOf: anchor)
            var upper = text.count
            while lower < upper, isSpace(text[lower]) { lower += 1 }
            while upper > lower, isSpace(text[upper - 1]) { upper -= 1 }
            if let id, wanted.contains(id), seen.insert(id).inserted {
                if lower < upper, let link = plan.links.first(where: { $0.markupID == id }) {
                    spans.append(Span(index: link.index, range: lower..<upper))
                }
            } else {
                broken = true  // a number that was not sent, or one used twice
            }
            cursor = NSMaxRange(marker.range)
        }
        appendClean(NSRange(location: cursor, length: end - cursor))
        if let tail { text.append(contentsOf: tail.utf16) }
        if !isPartial && seen.count != wanted.count { broken = true }
        return Decoded(text: text, spans: broken ? [] : spans)
    }

    private static func number(_ digits: String) -> Int? {
        let ascii = String(
            digits.unicodeScalars.map { scalar -> Character in
                (0xFF10...0xFF19).contains(scalar.value)
                    ? Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!) : Character(scalar)
            })
        return Int(ascii)
    }

    // MARK: - Search

    /// First occurrence of `needle` that overlaps no span. Verbatim text must not run into a longer word
    /// ("@bob" in "@bobby", "#12" in "#123").
    private static func find(_ needle: [UInt16], in text: [UInt16], avoiding spans: [Span], verbatim: Bool)
        -> Range<Int>?
    {
        guard !needle.isEmpty, needle.count <= text.count else { return nil }
        var start = 0
        while start + needle.count <= text.count {
            guard let range = firstRange(of: needle, in: text, from: start) else { return nil }
            if !overlaps(range, spans), !verbatim || isWordBounded(range, in: text, needle: needle) { return range }
            start = range.lowerBound + 1
        }
        return nil
    }

    private static func firstRange(of needle: [UInt16], in text: [UInt16], from start: Int) -> Range<Int>? {
        guard let first = needle.first else { return nil }
        var index = start
        let last = text.count - needle.count
        while index <= last {
            if text[index] == first {
                var matched = true
                for offset in 1..<needle.count where text[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index..<(index + needle.count) }
            }
            index += 1
        }
        return nil
    }

    /// The copy of a verbatim link the model changed in case, width or spacing ("＠Alice", "README .md").
    private static func looseMatch(_ needle: [UInt16], in text: [UInt16], avoiding spans: [Span]) -> Range<Int>? {
        let target = folded(needle)
        let haystack = folded(text)
        guard !target.isEmpty, target.count <= haystack.count else { return nil }
        let targetUnits = target.map(\.unit)
        let units = haystack.map(\.unit)
        var start = 0
        while let range = firstRange(of: targetUnits, in: units, from: start) {
            let mapped = haystack[range.lowerBound].source.lowerBound..<haystack[range.upperBound - 1].source.upperBound
            if !overlaps(mapped, spans), isWordBounded(mapped, in: text, needle: needle) { return mapped }
            start = range.lowerBound + 1
        }
        return nil
    }

    /// Case- and width-folded UTF-16 units without whitespace, each with the range it came from.
    private static func folded(_ units: [UInt16]) -> [(unit: UInt16, source: Range<Int>)] {
        var result: [(unit: UInt16, source: Range<Int>)] = []
        var offset = 0
        for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
            let width = UTF16.width(scalar)
            defer { offset += width }
            if scalar.properties.isWhitespace { continue }
            let range = offset..<(offset + width)
            if scalar.isASCII {
                let value = UInt16(scalar.value)
                result.append(((0x41...0x5A).contains(value) ? value + 0x20 : value, range))
                continue
            }
            let fold = String(scalar).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            for unit in fold.utf16 { result.append((unit, range)) }
        }
        return result
    }

    /// A URL the model cut short ("https://github.com/org/repo" for ".../repo/actions/runs/1"): the same
    /// scheme and host, and a prefix of the original. Not a URL the source has elsewhere, whole or as the start
    /// of a longer one ("https://github.com/org" beside ".../org/repo/pull/1"): that copy may be the source's own.
    private static func truncatedURL(_ link: Planned, plain: String, in text: [UInt16], avoiding spans: [Span])
        -> Range<Int>?
    {
        let original = Array(link.text.lowercased().utf16)
        guard let scheme = firstRange(of: Array("://".utf16), in: original, from: 0) else { return nil }
        let hostEnd = firstRange(of: Array("/".utf16), in: original, from: scheme.upperBound)?.lowerBound ?? original.count
        let head = Array(original[..<hostEnd])
        let lowered = asciiLowercased(text)
        let source = asciiLowercased(Array(plain.utf16))
        var start = 0
        while let range = firstRange(of: head, in: lowered, from: start) {
            start = range.lowerBound + 1
            var upper = range.upperBound
            while upper < text.count, isURLUnit(text[upper]) { upper += 1 }
            while upper > range.upperBound, ".,;:!?".utf16.contains(text[upper - 1]) { upper -= 1 }
            let candidate = range.lowerBound..<upper
            let units = Array(lowered[candidate])
            guard candidate.count < original.count, Array(original.prefix(candidate.count)) == units,
                !overlaps(candidate, spans),
                range.lowerBound == 0 || !isURLUnit(text[range.lowerBound - 1]),
                !occurs(units, in: source, outside: link.range)
            else { continue }
            return candidate
        }
        return nil
    }

    /// `needle` is somewhere in `source` apart from `excluded` (other links of the source are there too).
    private static func occurs(_ needle: [UInt16], in source: [UInt16], outside excluded: Range<Int>) -> Bool {
        var start = 0
        while let range = firstRange(of: needle, in: source, from: start) {
            if !range.overlaps(excluded) { return true }
            start = range.lowerBound + 1
        }
        return false
    }

    private static func asciiLowercased(_ units: [UInt16]) -> [UInt16] {
        units.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
    }

    private static func isURLUnit(_ unit: UInt16) -> Bool {
        // Printable ASCII except spaces, quotes and brackets that end a URL in running text.
        (0x21...0x7E).contains(unit) && !"\"'<>()[]{}`".utf16.contains(unit)
    }

    /// When the link text starts or ends with a letter or digit, its neighbors must not be ASCII letters,
    /// digits or "_" (CJK text right next to it is fine: "@aliceさん").
    private static func isWordBounded(_ range: Range<Int>, in text: [UInt16], needle: [UInt16]) -> Bool {
        func isWord(_ unit: UInt16) -> Bool {
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F
        }
        if let first = needle.first, isWord(first), range.lowerBound > 0, isWord(text[range.lowerBound - 1]) {
            return false
        }
        if let last = needle.last, isWord(last), range.upperBound < text.count, isWord(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func overlaps(_ range: Range<Int>, _ spans: [Span]) -> Bool {
        spans.contains { $0.range.overlaps(range) }
    }

    // MARK: - Helpers

    /// The first index whose offset is at least `value` (`offsets` never decreases).
    private static func firstIndex(in offsets: [Int], notBelow value: Int) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x3000 || unit == 0xA0
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
