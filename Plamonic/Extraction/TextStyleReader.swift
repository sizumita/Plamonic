import ApplicationServices
import CoreGraphics
import CoreText
import Foundation

/// Where to ask the app for the look of a segment's dominant text run.
struct StyleSource: Hashable, Sendable {
    var element: AXElement
    /// UTF-16 offset of the sampled text in the element's value (native text views, terminals). nil = the
    /// element's own text, read through text markers when the app has them (Chromium / WebKit), else from 0.
    var location: Int?
    /// UTF-16 length of the sampled text.
    var length: Int
}

/// What an app reports about the dominant run of a text.
struct ReportedTextStyle: Hashable, Sendable {
    var fontSize: Double?
    var textColor: RGBAColor?
    var isMonospaced = false
}

/// How a link inside a text looks in the app.
struct ReportedLinkStyle: Hashable, Sendable {
    var color: RGBAColor?
    var isUnderlined = false
}

/// A link to find in a style source's text: its text and, when known, where the walk put it (UTF-16 offset in
/// the source's text as the walk read it).
struct LinkStyleProbe: Hashable, Sendable {
    var text: String
    var offset: Int?
}

/// What an app reports about a text: the look of the text outside its links, and of each link asked for.
struct ReportedStyles: Hashable, Sendable {
    /// The dominant run outside the links. When the text is nothing but links: their size, without a color
    /// (the links' color is not the text's).
    var text: ReportedTextStyle?
    /// Per link text asked for, in order; nil when it was not found.
    var links: [ReportedLinkStyle?] = []
    /// Some visible text is marked as a link by the app (AXLink runs: native text views).
    var hasLinkRuns = false
}

/// The runs of an attributed string as read from the app, kept so link looks can be looked up per scan.
struct StyleRuns: Hashable, Sendable {
    struct Run: Hashable, Sendable {
        var location: Int
        var length: Int
        var style: ReportedTextStyle
        var isUnderlined: Bool
        /// The app marks it as a link (AXLink: native text views).
        var isLink: Bool
    }

    var string: String
    var runs: [Run]

    /// The dominant look outside links, and each of `linkTexts` (searched in order in the string).
    func resolve(linkTexts: [String] = []) -> ReportedStyles {
        resolve(links: linkTexts.map { LinkStyleProbe(text: $0, offset: nil) })
    }

    /// The dominant look outside links, and each of `links` (in text order; see `locate`).
    func resolve(links probes: [LinkStyleProbe]) -> ReportedStyles {
        let ns = string as NSString
        let linkRanges = Self.locate(probes, in: ns)
        func linkIndex(at i: Int) -> Int? {
            linkRanges.firstIndex { $0.map { NSLocationInRange(i, $0) } ?? false }
        }
        var text = Weights<ReportedTextStyle>()
        var allLinks = Weights<ReportedTextStyle>()
        var perLink = Array(repeating: Weights<ReportedLinkStyle>(), count: probes.count)
        var hasLinkRuns = false
        for run in runs {
            let look = ReportedLinkStyle(color: run.style.textColor, isUnderlined: run.isUnderlined)
            var plain = 0
            var hasPlain = false
            var linked = 0
            for i in run.location..<(run.location + run.length) {
                let c = ns.character(at: i)
                // Spaces between runs say nothing about the look.
                let visible = c != 0x20 && c != 0x0A && c != 0x09 && c != 0xA0
                if !run.isLink, let k = linkIndex(at: i) {
                    if visible {
                        linked += 1
                        perLink[k].add(look, 1)
                    }
                } else if run.isLink {
                    if visible { linked += 1 }
                } else {
                    hasPlain = true
                    if visible { plain += 1 }
                }
            }
            if hasPlain { text.add(run.style, plain) }
            if linked > 0 { allLinks.add(run.style, linked) }
            if run.isLink, linked > 0 { hasLinkRuns = true }
        }
        var result = ReportedStyles()
        result.hasLinkRuns = hasLinkRuns
        if let t = text.best {
            result.text = t
        } else if var l = allLinks.best {
            l.textColor = nil
            result.text = l
        }
        result.links = perLink.map(\.best)
        return result
    }

    /// Where each link lies in `ns`, in order and without overlaps; nil when it is not there. The same words may
    /// come earlier as plain text ("the docs … the docs"), or inside another word ("Where … here"), so a link is
    /// taken where the walk put it when it is there. Otherwise (the walk's text differs a little: a line break
    /// it put between runs, an image it left out) the occurrence nearest to that place, preferring whole words.
    /// Offsets after a link found elsewhere move by the same amount.
    static func locate(_ probes: [LinkStyleProbe], in ns: NSString) -> [NSRange?] {
        var result: [NSRange?] = []
        var cursor = 0
        var drift = 0
        for probe in probes {
            let t = probe.text
            guard !t.isEmpty, cursor < ns.length else {
                result.append(nil)
                continue
            }
            // The walk puts a line break between runs on different lines that the app joins without one.
            var variants = [t]
            if t.contains("\n") {
                variants += [t.replacingOccurrences(of: "\n", with: ""), t.replacingOccurrences(of: "\n", with: " ")]
            }
            let expected = probe.offset.map { $0 + drift }
            var found: NSRange?
            if let e = expected, e >= cursor {
                for v in variants {
                    let r = NSRange(location: e, length: (v as NSString).length)
                    if r.location + r.length <= ns.length, ns.substring(with: r) == v {
                        found = r
                        break
                    }
                }
            }
            if found == nil {
                var all: [NSRange] = []
                for v in variants where all.isEmpty {
                    all = occurrences(of: v, in: ns, from: cursor)
                }
                let words = all.filter { isWholeWord($0, in: ns) }
                let pool = words.isEmpty ? all : words
                if let e = expected {
                    found = pool.min { abs($0.location - e) < abs($1.location - e) }
                } else {
                    found = pool.first
                }
            }
            result.append(found)
            if let r = found {
                cursor = r.location + r.length
                if let o = probe.offset { drift = r.location - o }
            }
        }
        return result
    }

    private static func occurrences(of t: String, in ns: NSString, from start: Int) -> [NSRange] {
        var found: [NSRange] = []
        var from = start
        while from < ns.length {
            let r = ns.range(of: t, options: [], range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            found.append(r)
            from = r.location + 1
        }
        return found
    }

    /// Not part of a longer word: no letter or digit of a spaced script joins it on either side.
    private static func isWholeWord(_ r: NSRange, in ns: NSString) -> Bool {
        let end = r.location + r.length
        if r.location > 0, isWordUnit(ns.character(at: r.location - 1)), isWordUnit(ns.character(at: r.location)) {
            return false
        }
        if end < ns.length, isWordUnit(ns.character(at: end - 1)), isWordUnit(ns.character(at: end)) { return false }
        return true
    }

    /// Letters and digits of scripts written with spaces between words (Latin, Greek, Cyrillic). CJK text has no
    /// word boundaries to check.
    private static func isWordUnit(_ u: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        guard u < 0x0530 else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Counts per value; the most counted wins, ties go to the first seen.
    private struct Weights<Value: Hashable> {
        var counts: [Value: Int] = [:]
        var order: [Value] = []

        mutating func add(_ v: Value, _ n: Int) {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += n
        }

        var best: Value? {
            var best: Value?
            var bestCount = -1
            for v in order where counts[v, default: 0] > bestCount {
                best = v
                bestCount = counts[v, default: 0]
            }
            return best
        }
    }
}

/// Reads the font size and color of text runs through AX (at most two calls per element) and keeps them across
/// scans, so a steady window costs no extra calls. Not thread-safe: used from the scan queue via TextExtractor.
final class TextStyleReader {
    private struct Key: Hashable {
        var source: StyleSource
        /// Hash of the text for ranged sources: a terminal range holds other text once the screen scrolls.
        var textKey: Int
    }

    private struct Entry {
        var runs: StyleRuns?
        var fetchedAt: CFAbsoluteTime
        var usedAt: CFAbsoluteTime
    }

    /// Which of the two ways of asking work in one process. A way that never answered is dropped after a few
    /// misses (native apps have no text markers; Chromium static text and Terminal have no ranged attributes).
    private struct Support {
        var since: CFAbsoluteTime
        var markerHits = 0
        var markerMisses = 0
        var rangeHits = 0
        var rangeMisses = 0

        var markerUsable: Bool { markerHits > 0 || markerMisses < 3 }
        var rangeUsable: Bool { rangeHits > 0 || rangeMisses < 3 }
    }

    private enum Answer {
        case found(StyleRuns?)
        /// The app does not have this attribute: counts toward dropping this way of asking.
        case unsupported
        /// No answer for this element now (not laid out, gone): asked again later.
        case failed
        case timedOut

        init(_ error: AXCallError) {
            switch error.code {
            case .cannotComplete: self = .timedOut
            case .attributeUnsupported, .parameterizedAttributeUnsupported: self = .unsupported
            default: self = .failed
            }
        }
    }

    /// A missing answer is asked again after this long (the element may not have been laid out yet).
    var retryAfter: TimeInterval = 10
    /// A found style is read again after this long (an element keeps its look while its text streams in).
    var refreshAfter: TimeInterval = 60
    /// Dropped ways of asking are tried again after this long (an app may build its tree later).
    var supportResetAfter: TimeInterval = 120
    /// Samples longer than this are cut (one run decides the look; long strings cost IPC time).
    static let maxSampleLength = 200

    private var cache: [Key: Entry] = [:]
    private var support: [pid_t: Support] = [:]
    private var monospacedFonts: [String: Bool] = [:]

    init() {}

    /// The cached look, or a fresh read when `budget` allows (each read decrements it). `links`: the links whose
    /// look to find in the source's text (in text order).
    func styles(
        for source: StyleSource, textKey: Int = 0, links: [LinkStyleProbe] = [], pid: pid_t, now: CFAbsoluteTime,
        budget: inout Int
    ) -> ReportedStyles? {
        runs(for: source, textKey: textKey, pid: pid, now: now, budget: &budget)?.resolve(links: links)
    }

    private func runs(
        for source: StyleSource, textKey: Int, pid: pid_t, now: CFAbsoluteTime, budget: inout Int
    ) -> StyleRuns? {
        // A whole element keeps its look while its text streams in (length changes): key it by the element alone.
        let key =
            source.location == nil
            ? Key(source: StyleSource(element: source.element, location: nil, length: 0), textKey: 0)
            : Key(source: source, textKey: textKey)
        if var entry = cache[key] {
            let age = now - entry.fetchedAt
            let fresh = entry.runs != nil ? age < refreshAfter : age < retryAfter
            if fresh || budget <= 0 {
                entry.usedAt = now
                cache[key] = entry
                return entry.runs
            }
        }
        let previous = cache[key]?.runs
        guard budget > 0 else { return previous }
        // Neither way of asking works in this app (Terminal): no call, and no budget spent.
        guard canAsk(source, pid: pid, now: now) else {
            cache[key] = Entry(runs: previous, fetchedAt: now, usedAt: now)
            return previous
        }
        budget -= 1
        switch fetch(source, pid: pid, now: now) {
        case .found(let runs):
            cache[key] = Entry(runs: runs ?? previous, fetchedAt: now, usedAt: now)
            return runs ?? previous
        case .unsupported, .failed:
            cache[key] = Entry(runs: previous, fetchedAt: now, usedAt: now)
            return previous
        case .timedOut:
            // Not remembered: the next scan asks again.
            return previous
        }
    }

    /// Drops entries not used for a while (call once per scan).
    func prune(now: CFAbsoluteTime) {
        guard cache.count > 512 else { return }
        cache = cache.filter { now - $0.value.usedAt < 30 }
    }

    func invalidate(pid: pid_t? = nil) {
        guard let pid else {
            cache.removeAll()
            support.removeAll()
            return
        }
        cache = cache.filter { $0.key.source.element.pid != pid }
        support[pid] = nil
    }

    // MARK: Reading

    private func canAsk(_ source: StyleSource, pid: pid_t, now: CFAbsoluteTime) -> Bool {
        guard let s = support[pid], now - s.since <= supportResetAfter else { return true }
        return (source.location == nil && s.markerUsable) || s.rangeUsable
    }

    private func fetch(_ source: StyleSource, pid: pid_t, now: CFAbsoluteTime) -> Answer {
        var s = support[pid] ?? Support(since: now)
        if now - s.since > supportResetAfter, !s.markerUsable || !s.rangeUsable { s = Support(since: now) }
        defer { support[pid] = s }
        let el = source.element

        if source.location == nil, s.markerUsable {
            let answer = readThroughMarkers(el)
            switch answer {
            case .found:
                s.markerHits += 1
                return answer
            case .unsupported: s.markerMisses += 1
            // A web element that has markers but no answer now: the ranged attributes would not help.
            case .failed, .timedOut: return answer
            }
        }
        let length = min(source.length, Self.maxSampleLength)
        guard s.rangeUsable, length > 0 else { return .unsupported }
        let answer = readThroughRange(el, location: source.location ?? 0, length: length)
        switch answer {
        case .found: s.rangeHits += 1
        case .unsupported: s.rangeMisses += 1
        case .failed, .timedOut: break
        }
        return answer
    }

    /// Chromium / WebKit: the element's own text marker range, then its attributed string.
    private func readThroughMarkers(_ el: AXElement) -> Answer {
        let range: AnyObject
        switch el.parameterizedResult(AXParamAttr.textMarkerRangeForUIElement, el.ref) {
        case .success(let r): range = r
        case .failure(let e): return Answer(e)
        }
        switch el.parameterizedResult(AXParamAttr.attributedStringForTextMarkerRange, range) {
        case .success(let value):
            guard let attributed = value as? NSAttributedString else { return .failed }
            return .found(runs(of: attributed))
        case .failure(let e):
            return Answer(e)
        }
    }

    /// Native text (NSTextView, NSTextField, terminals that support it): AXAttributedStringForRange.
    private func readThroughRange(_ el: AXElement, location: Int, length: Int) -> Answer {
        guard let param = AXDecode.makeValue(CFRange(location: location, length: length)) else { return .unsupported }
        switch el.parameterizedResult(AXParamAttr.attributedStringForRange, param) {
        case .success(let value):
            guard let attributed = value as? NSAttributedString else { return .failed }
            return .found(runs(of: attributed))
        case .failure(let e):
            return Answer(e)
        }
    }

    // MARK: Parsing

    /// The runs that tell a size or a color. nil when none does.
    func runs(of string: NSAttributedString) -> StyleRuns? {
        Self.runs(of: string) { [self] name, family in isMonospacedFont(name: name, family: family) }
    }

    static func runs(
        of string: NSAttributedString, isMonospaced: (String?, String?) -> Bool = { defaultIsMonospaced($0, $1) }
    ) -> StyleRuns? {
        guard string.length > 0 else { return nil }
        var runs: [StyleRuns.Run] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attrs, range, _ in
            var style = ReportedTextStyle()
            if let font = attrs[NSAttributedString.Key(AXTextAttr.font)] as? [String: Any] {
                if let size = (font[AXTextAttr.fontSize] as? NSNumber)?.doubleValue, size > 0 { style.fontSize = size }
                let name = font[AXTextAttr.fontName] as? String
                let family = font[AXTextAttr.fontFamily] as? String
                if name != nil || family != nil { style.isMonospaced = isMonospaced(name, family) }
            }
            if let raw = attrs[NSAttributedString.Key(AXTextAttr.foregroundColor)] {
                let ref = raw as CFTypeRef
                if CFGetTypeID(ref) == CGColor.typeID { style.textColor = rgba(unsafeDowncast(ref, to: CGColor.self)) }
            }
            guard style.fontSize != nil || style.textColor != nil else { return }
            let underline = (attrs[NSAttributedString.Key(AXTextAttr.underline)] as? NSNumber)?.intValue ?? 0
            runs.append(
                StyleRuns.Run(
                    location: range.location, length: range.length, style: style, isUnderlined: underline != 0,
                    isLink: attrs[NSAttributedString.Key(AXTextAttr.link)] != nil))
        }
        return runs.isEmpty ? nil : StyleRuns(string: string.string, runs: runs)
    }

    /// The look of the run covering the most visible characters outside links. nil when no run has a size or a
    /// color.
    static func parse(
        _ string: NSAttributedString, isMonospaced: (String?, String?) -> Bool = { defaultIsMonospaced($0, $1) }
    ) -> ReportedTextStyle? {
        runs(of: string, isMonospaced: isMonospaced)?.resolve().text
    }

    /// A color in sRGB, clamped to 0...1.
    static func rgba(_ color: CGColor) -> RGBAColor? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
            let c = converted.components, c.count >= 3
        else { return nil }
        func clamp(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }
        return RGBAColor(red: clamp(c[0]), green: clamp(c[1]), blue: clamp(c[2]), alpha: clamp(converted.alpha))
    }

    private func isMonospacedFont(name: String?, family: String?) -> Bool {
        let key = (name ?? "") + "|" + (family ?? "")
        if let known = monospacedFonts[key] { return known }
        let result = Self.defaultIsMonospaced(name, family)
        if monospacedFonts.count > 256 { monospacedFonts.removeAll() }
        monospacedFonts[key] = result
        return result
    }

    /// Fixed-pitch per CoreText, or a name that says so when the font is not installed here.
    static func defaultIsMonospaced(_ name: String?, _ family: String?) -> Bool {
        let hints = ["mono", "menlo", "monaco", "courier", "consol", "code", "terminal", "fixed"]
        for n in [name, family].compactMap({ $0?.lowercased() }) where hints.contains(where: { n.contains($0) }) {
            return true
        }
        guard let n = name ?? family else { return false }
        let font = CTFontCreateWithName(n as CFString, 12, nil)
        // CoreText substitutes a default font for unknown names: trust only a real match.
        let actual = (CTFontCopyPostScriptName(font) as String).lowercased()
        let family2 = (CTFontCopyFamilyName(font) as String).lowercased()
        guard actual == n.lowercased() || family2 == n.lowercased() else { return false }
        return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
    }
}
