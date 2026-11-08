import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A candidate that the filters rejected (kept only when `TextExtractor.collectRejected` is on).
struct RejectedText: Sendable {
    var text: String
    var axFrame: CGRect
    var reason: TextRejection
}

/// Counters of the last scan, for the probe and debugging UI.
struct ExtractionDiagnostics: Sendable {
    var scope: TranslationScope = .window
    var candidates = 0
    var rejectionCounts: [TextRejection: Int] = [:]
    var rejected: [RejectedText] = []
    var prunedInvisible = 0
    var prunedExcluded = 0
    var containerCount = 0
    var containerCacheHit = false
    var droppedOverSegmentLimit = 0
    /// AppAccessibilityEnabler is still waiting for Chromium to build its tree.
    var warmingUp = false
    /// A web area reported frames in the wrong scale and they were corrected (see FrameTransform).
    var scaledWebArea = false
    /// Segments merged into another because their frames covered each other (see SegmentMerger).
    var mergedOverlaps = 0
    /// Style reads that went to the app in this scan (the rest came from the cache).
    var styleLookups = 0
    /// Links in the kept segments, and URL reads that went to the app in this scan.
    var links = 0
    var linkLookups = 0
    /// Page zoom applied to the sizes the app reported (1 = none measured).
    var zoom: Double = 1
}

/// Converts the AX tree of one window into translation segments.
/// Not thread-safe: use one instance from one serial queue (it caches rule containers between scans).
final class TextExtractor {
    let ownPID: pid_t
    /// Keep rejected candidates in `lastDiagnostics.rejected` (costs memory; for debugging).
    var collectRejected = false
    private(set) var lastDiagnostics = ExtractionDiagnostics()

    private struct ContainerKey: Hashable {
        var pid: pid_t
        var windowID: UInt32
        var matchers: [ElementMatcher]
    }
    private struct ContainerEntry {
        var containers: [FoundContainer]
        var foundAt: CFAbsoluteTime
    }
    private var containerCache: [ContainerKey: ContainerEntry] = [:]
    private var windowKeys: [AXElement: WindowKey] = [:]
    private var ignoreCache: IgnorePatterns?
    private let styleReader = TextStyleReader()
    private let linkReader = LinkReader()
    private var zoom = ZoomEstimator()

    private static let windowPlan = AXFetchPlan([.role, .subrole, .frame])
    private static let climbPlan = AXFetchPlan([
        .role, .subrole, .roleDescription, .frame, .domClassList, .identifier, .parent,
    ])

    init(ownPID: pid_t = getpid()) {
        self.ownPID = ownPID
    }

    /// Drops cached containers and window ids (all, or for one process).
    func invalidateCaches(pid: pid_t? = nil) {
        styleReader.invalidate(pid: pid)
        linkReader.invalidate(pid: pid)
        zoom.forget(pid: pid)
        guard let pid else {
            containerCache.removeAll()
            windowKeys.removeAll()
            return
        }
        containerCache = containerCache.filter { $0.key.pid != pid }
        windowKeys = windowKeys.filter { $0.value.pid != pid }
    }

    /// Scans one window. `mouseAX` is the pointer in AX coordinates (used by the underMouse scope).
    /// `windowID`: the window's CGWindowID when the caller already looked it up, so both sides key the window
    /// the same way; otherwise it is looked up here.
    func scan(
        window: AXElement, pid: pid_t, bundleID: String, settings: EffectiveSettings, limits: ExtractionLimits,
        mouseAX: CGPoint?, windowID: CGWindowID? = nil
    ) -> WindowSnapshot {
        let start = CFAbsoluteTimeGetCurrent()
        let key = windowKey(for: window, pid: pid, knownID: windowID)
        let scope = settings.profile.scope
        var diagnostics = ExtractionDiagnostics()
        diagnostics.scope = scope
        if pid != ownPID {
            // Idempotent: sets AXManualAccessibility / AXEnhancedUserInterface once per process.
            AppAccessibilityEnabler.shared.ensureEnabled(pid: pid, profile: settings.profile)
        }
        diagnostics.warmingUp = AppAccessibilityEnabler.shared.isWarmingUp(pid: pid)

        func snapshot(
            frame: CGRect, clip: CGRect?, segments: [TextSegment], walk: ExtractionWalk?, obstacles: [CGRect] = [],
            scrollRegions: [CGRect] = []
        ) -> WindowSnapshot {
            if let walk {
                diagnostics.prunedInvisible = walk.prunedInvisible
                diagnostics.prunedExcluded = walk.prunedExcluded
                diagnostics.scaledWebArea = walk.scaledWebArea
            }
            lastDiagnostics = diagnostics
            return WindowSnapshot(
                key: key, pid: pid, bundleID: bundleID, axWindowFrame: frame, axClipRect: clip, segments: segments,
                nodeCount: walk?.nodeCount ?? 0, scanDuration: CFAbsoluteTimeGetCurrent() - start,
                truncated: walk?.truncated ?? false, obstacles: Self.keptObstacles(obstacles, segments: segments),
                scrollRegions: scrollRegions, passwordPrompt: walk?.passwordPrompt ?? false)
        }

        // Never read our own windows (overlays, settings).
        guard pid != ownPID, let windowInfo = window.fetch(Self.windowPlan), let windowFrame = windowInfo.frame else {
            return snapshot(frame: .zero, clip: nil, segments: [], walk: nil)
        }

        let walk = ExtractionWalk(
            settings: settings, limits: limits, ignore: ignorePatterns(settings.profile.ignorePatterns), start: start)
        let rules = settings.profile.rules
        var clipRect: CGRect?
        var scrollRegions: [CGRect] = []
        var relaxedFilters = false
        var keepNear: CGPoint?
        // Scopes that read one element know nothing of what is around it.
        var readOneElement = false
        var elementFrame: CGRect?

        switch scope {
        case .window:
            walk.walk(root: window, clip: windowFrame, itemsOnly: false)

        case .rules:
            if rules.hasContainers {
                let containers = self.containers(
                    window: window, key: key, rules: rules, walk: walk, clip: windowFrame,
                    limits: limits, diagnostics: &diagnostics)
                for c in containers {
                    let cf = c.element.frame.map { c.transform?.apply($0) ?? $0 }
                    var clip = windowFrame
                    if let cf, cf.width >= limits.minVisibleHeight, cf.height >= limits.minVisibleHeight {
                        let i = windowFrame.intersection(cf)
                        if !i.isNull { clip = i }
                    }
                    clipRect = clipRect.map { $0.union(clip) } ?? clip
                    scrollRegions.append(clip)
                    walk.walk(root: c.element, clip: clip, itemsOnly: rules.hasItems, transform: c.transform)
                }
                // No container in this window (e.g. Claude's chat tab): items are searched in the whole window.
                // Rules without items keep translating nothing rather than the whole window.
                if containers.isEmpty, rules.hasItems, !walk.truncated {
                    walk.walk(root: window, clip: windowFrame, itemsOnly: true)
                }
            } else {
                walk.walk(root: window, clip: windowFrame, itemsOnly: rules.hasItems)
            }

        case .focusedElement:
            let app = AXElement.application(pid: pid)
            if let focused = app.element(AXAttr.focusedUIElement), focused.pid == pid {
                walk.walk(root: focused, clip: windowFrame, itemsOnly: false)
                readOneElement = true
                elementFrame = focused.frame
            }

        case .underMouse:
            if let mouse = mouseAX, windowFrame.contains(mouse),
                let root = blockUnderMouse(pid: pid, point: mouse, windowFrame: windowFrame, walk: walk)
            {
                if root.isItem { walk.granularity = .item }
                walk.walk(root: root.element, clip: windowFrame, itemsOnly: false)
                keepNear = mouse
                readOneElement = true
                elementFrame = root.frame
            }

        case .selection:
            readSelection(pid: pid, window: window, clip: windowFrame, walk: walk)
            relaxedFilters = true
        }

        var raw = walk.segments
        var obstacles = walk.obstacles
        if let point = keepNear {
            let near = Self.segments(near: point, in: raw)
            raw = near.kept
            obstacles += near.others
        }
        let segments = finalize(
            raw, pid: pid, start: start, settings: settings, limits: limits, ignore: walk.ignore,
            relaxed: relaxedFilters, obstacles: &obstacles, diagnostics: &diagnostics)
        if readOneElement {
            // The next paragraph or message is outside the walk, so it is no obstacle: translations stay inside
            // the element.
            clipRect = Self.elementClip(elementFrame, segments: segments, window: windowFrame)
        }
        // Each container scrolls on its own (a chat and a side chat); a scroll outside all of them (a thread list)
        // moves none of the translations.
        return snapshot(
            frame: windowFrame, clip: clipRect, segments: segments, walk: walk, obstacles: obstacles,
            scrollRegions: scrollRegions)
    }

    /// The element a scope read, grown to its segments (text may stick out of its element, like a list marker
    /// out of its item), inside the window. Only the segments when the element's frame is unknown.
    static func elementClip(_ element: CGRect?, segments: [TextSegment], window: CGRect) -> CGRect? {
        var area = element.map(\.standardized).flatMap { $0.width >= 1 && $0.height >= 1 ? $0 : nil }
        for s in segments { area = area.map { $0.union(s.axFrame.standardized) } ?? s.axFrame.standardized }
        guard let clip = area?.intersection(window), !clip.isNull, clip.width >= 1, clip.height >= 1 else {
            return nil
        }
        return clip
    }

    // MARK: Containers

    private func containers(
        window: AXElement, key: WindowKey, rules: ExtractionRules, walk: ExtractionWalk, clip: CGRect,
        limits: ExtractionLimits, diagnostics: inout ExtractionDiagnostics
    ) -> [FoundContainer] {
        let ck = ContainerKey(pid: key.pid, windowID: key.windowID, matchers: rules.containers)
        let now = CFAbsoluteTimeGetCurrent()
        // An empty result is retried sooner, so a container that appears later is picked up quickly.
        let lifetime = limits.containerCacheLifetime
        if let entry = containerCache[ck], now - entry.foundAt < (entry.containers.isEmpty ? min(2, lifetime) : lifetime),
            entry.containers.allSatisfy({ $0.element.role != nil })
        {
            diagnostics.containerCacheHit = true
            diagnostics.containerCount = entry.containers.count
            return entry.containers
        }
        let found = walk.findContainers(window: window, clip: clip, matchers: CompiledMatcherSet(rules.containers))
        diagnostics.containerCount = found.count
        // A search cut short by the time budget may have missed containers: cache only complete results, so the
        // next scan searches again (this scan is reported as truncated and keeps the previous overlay).
        guard !walk.truncated else { return found }
        containerCache[ck] = ContainerEntry(containers: found, foundAt: now)
        if containerCache.count > 32 { containerCache = containerCache.filter { now - $0.value.foundAt < 60 } }
        return found
    }

    // MARK: Under the mouse

    private struct MouseRoot {
        var element: AXElement
        var isItem: Bool
        var frame: CGRect?
    }

    /// Containers the pointer hits over gaps and margins; walking one would translate everything in it.
    private static let tooBroadMouseRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXWebArea", "AXScrollArea", "AXList", "AXOutline", "AXTable", "AXSplitGroup",
        "AXTabGroup",
    ]

    /// The paragraph-level block (or rule item) containing the pointer; nil over gaps between blocks.
    private func blockUnderMouse(
        pid: pid_t, point: CGPoint, windowFrame: CGRect, walk: ExtractionWalk
    ) -> MouseRoot? {
        guard let hit = AXElement.application(pid: pid).element(atAX: point), hit.pid == pid else { return nil }
        var chain: [AXNodeInfo] = []
        var current: AXElement? = hit
        var seen = Set<AXElement>()
        while let el = current, chain.count < 64, !seen.contains(el), let info = el.fetch(Self.climbPlan) {
            seen.insert(el)
            if info.role == "AXApplication" { break }
            chain.append(info)
            if info.role == "AXWindow" { break }
            current = info.parent
        }
        guard !chain.isEmpty else { return nil }
        if chain.contains(where: { walk.excludes.matches($0) }) { return nil }
        if !walk.items.isEmpty, let item = chain.first(where: { walk.items.matches($0) }) {
            return MouseRoot(element: item.element, isItem: true, frame: item.frame)
        }
        let block =
            chain.first {
                !ExtractionRoles.isInline(role: $0.role, subrole: $0.subrole) && $0.role != "AXStaticText"
            } ?? chain[0]
        if Self.tooBroadMouseRoles.contains(block.role) { return nil }
        // A block covering a large part of the window is the list or page around the pointer, not a paragraph.
        // Text inputs are exempt: they are split per line / paragraph and filtered to the one under the pointer.
        if !ExtractionRoles.textInputRoles.contains(block.role), let f = block.frame,
            f.width * f.height > 0.25 * windowFrame.width * windowFrame.height
        {
            return nil
        }
        return MouseRoot(element: block.element, isItem: false, frame: block.frame)
    }

    /// The segments under the pointer, else the closest one a few points away. Never the whole block: hits on
    /// a gap between paragraphs would otherwise translate every paragraph of the block around it.
    /// `others`: the frames of the block's other paragraphs, which stay on screen.
    static func segments(near point: CGPoint, in raw: [RawSegment]) -> (kept: [RawSegment], others: [CGRect]) {
        var keep = raw.indices.filter { raw[$0].frame.insetBy(dx: -2, dy: -2).contains(point) }
        if keep.isEmpty {
            let near = raw.indices.map { ($0, distance(from: point, to: raw[$0].frame)) }.filter { $0.1 <= 10 }
            keep = near.min { $0.1 < $1.1 }.map { [$0.0] } ?? []
        }
        var others: [CGRect] = []
        for (i, r) in raw.enumerated() where !keep.contains(i) {
            others += r.lineFrames.isEmpty ? [r.frame] : r.lineFrames
        }
        return (keep.map { raw[$0] }, others)
    }

    private static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Selection

    private func readSelection(pid: pid_t, window: AXElement, clip: CGRect, walk: ExtractionWalk) {
        let app = AXElement.application(pid: pid)
        let focused = app.element(AXAttr.focusedUIElement)
        if let f = focused, let text = f.string(AXAttr.selectedText),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            var frame: CGRect?
            if let r = f.range(AXAttr.selectedTextRange), r.length > 0 {
                frame = Self.selectionBounds(f, range: r, text: text)
            }
            if let fr = walk.clipped(frame ?? f.frame, clip) {
                walk.emit(
                    RawSegment(
                        text: text, frame: fr, role: f.role ?? "AXTextArea",
                        isEditable: f.isSettable(AXAttr.value), treeIndex: 0))
            }
            return
        }
        // Chromium / WebKit expose document selections as text markers on the web area.
        guard let webArea = Self.webArea(from: focused, window: window),
            let marker = webArea.attribute(AXAttr.selectedTextMarkerRange),
            let text = AXDecode.string(webArea.parameterized(AXParamAttr.stringForTextMarkerRange, marker)),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let bounds = AXDecode.rect(webArea.parameterized(AXParamAttr.boundsForTextMarkerRange, marker))
        if let fr = walk.clipped(bounds, clip) {
            walk.emit(RawSegment(text: text, frame: fr, role: "AXWebArea", isEditable: false, treeIndex: 0))
        }
    }

    /// Union of per-line bounds (AXBoundsForRange often returns only the first line of a multi-line range).
    private static func selectionBounds(_ el: AXElement, range: CFRange, text: String) -> CGRect? {
        var result: CGRect?
        var location = range.location
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let length = line.utf16.count
            if length > 0, i < 80, let b = el.bounds(forRange: CFRange(location: location, length: length)),
                b.width > 0, b.height > 0
            {
                result = result.map { $0.union(b) } ?? b
            }
            location += length + 1
        }
        return result ?? el.bounds(forRange: range)
    }

    private static func webArea(from focused: AXElement?, window: AXElement) -> AXElement? {
        var current = focused
        for _ in 0..<64 {
            guard let el = current else { break }
            if el.role == "AXWebArea" { return el }
            current = el.parent
        }
        // Breadth-first over the top of the window (Electron nests the web area a few levels down).
        var queue: [(AXElement, Int)] = [(window, 0)]
        let plan = AXFetchPlan([.role, .children])
        while !queue.isEmpty {
            let (el, depth) = queue.removeFirst()
            guard let info = el.fetch(plan) else { continue }
            if info.role == "AXWebArea" { return el }
            if depth < 10 { queue.append(contentsOf: info.children.map { ($0, depth + 1) }) }
            if queue.count > 200 { break }
        }
        return nil
    }

    // MARK: Post-processing

    private func finalize(
        _ raw: [RawSegment], pid: pid_t, start: CFAbsoluteTime, settings: EffectiveSettings,
        limits: ExtractionLimits, ignore: IgnorePatterns?, relaxed: Bool, obstacles: inout [CGRect],
        diagnostics: inout ExtractionDiagnostics
    ) -> [TextSegment] {
        diagnostics.candidates = raw.count
        var kept: [(segment: RawSegment, text: String)] = []
        var seen = Set<String>()
        for r in raw {
            let text = TextFilters.normalize(r.text)
            let reason: TextRejection?
            if relaxed {
                if text.isEmpty {
                    reason = .empty
                } else if text.count > limits.maxSegmentCharacters {
                    reason = .tooLong
                } else if !text.contains(where: { $0.isLetter }) {
                    reason = .noLetters
                } else {
                    reason = nil
                }
            } else {
                // Terminal paragraphs: the ignore patterns and the code heuristic already ran per row.
                reason = TextFilters.rejection(
                    for: text, minLength: settings.minTextLength, maxLength: limits.maxSegmentCharacters,
                    ignore: r.filteredPerLine ? nil : ignore, detectCode: !r.filteredPerLine)
            }
            if let reason {
                diagnostics.rejectionCounts[reason, default: 0] += 1
                if collectRejected { diagnostics.rejected.append(RejectedText(text: text, axFrame: r.frame, reason: reason)) }
                // Not translated, but still on screen (a URL, a number, a line of code).
                obstacles.append(contentsOf: r.lineFrames.isEmpty ? [r.frame] : r.lineFrames)
                continue
            }
            // The same text at the same place twice (nested matches) is one segment.
            let dedupeKey = "\(Int(r.frame.minX)),\(Int(r.frame.minY))|\(text)"
            guard seen.insert(dedupeKey).inserted else { continue }
            var segment = r
            if !segment.links.isEmpty {
                // Link ranges follow the text through the normalization (an odd text that maps differently
                // loses its links rather than getting wrong ones).
                let mapped = TextFilters.normalizeMapped(segment.text)
                segment.links = mapped.text == text ? LinkText.remap(segment.links, with: mapped.map, in: text) : []
            }
            segment.text = text
            kept.append((segment, text))
        }

        kept.sort { Self.readingOrder($0.segment, $1.segment) }
        // Pieces of one paragraph whose frames cover each other become one segment again (ids are derived
        // from the joined text below, so they stay stable across scans).
        let merged = SegmentMerger.merge(kept, maxCharacters: limits.maxSegmentCharacters)
        kept = merged.items
        diagnostics.mergedOverlaps = merged.merged

        // Chats and terminals put the newest text at the bottom: keep the last segments.
        if kept.count > limits.maxSegments {
            diagnostics.droppedOverSegmentLimit = kept.count - limits.maxSegments
            for (dropped, _) in kept.prefix(kept.count - limits.maxSegments) {
                obstacles.append(contentsOf: dropped.lineFrames.isEmpty ? [dropped.frame] : dropped.lineFrames)
            }
            kept.removeFirst(kept.count - limits.maxSegments)
        }

        let reported = readStyles(kept, pid: pid, start: start, limits: limits, diagnostics: &diagnostics)
        var styles = Self.resolveStyles(kept.map(\.segment), reported: reported.map { $0?.text })
        Self.markLinkRuns(&styles, reported: reported)
        let linkOnly = kept.map { Self.isOnlyLinks($0.text, $0.segment.links) }
        Self.borrowTextColors(&styles, linkOnly: linkOnly)
        let urls = readURLs(kept, start: start, limits: limits, diagnostics: &diagnostics)

        var occurrences: [String: Int] = [:]
        var segments: [TextSegment] = []
        segments.reserveCapacity(kept.count)
        for (i, (segment, text)) in kept.enumerated() {
            let hash = TextMetrics.stableHash(text)
            let n = occurrences[hash, default: 0]
            occurrences[hash] = n + 1
            let links = Self.finishLinks(
                segment, text: text, style: styles[i].style, reported: reported[i]?.links ?? [], urls: urls[i])
            diagnostics.links += links.count
            segments.append(
                TextSegment(
                    id: "\(hash)-\(n)", text: text, axFrame: segment.frame, role: segment.role,
                    isEditable: segment.isEditable, order: i, style: styles[i].style,
                    lineFrames: styles[i].lineFrames, links: links))
        }
        return segments
    }

    // MARK: Links

    /// URLs of the kept segments' links (AXURL, one call per new link element; cached per element). Only links
    /// whose URL the walk does not know, and only elements that are links (buttons have none).
    private func readURLs(
        _ kept: [(segment: RawSegment, text: String)], start: CFAbsoluteTime, limits: ExtractionLimits,
        diagnostics: inout ExtractionDiagnostics
    ) -> [[URL?]] {
        let now = CFAbsoluteTimeGetCurrent()
        let deadline = start + limits.timeBudget
        var budget = limits.linkLookupsPerScan
        var result: [[URL?]] = []
        result.reserveCapacity(kept.count)
        for (segment, _) in kept {
            var urls: [URL?] = []
            for link in segment.links {
                guard link.url == nil, link.kind == .link, let el = link.element else {
                    urls.append(link.url)
                    continue
                }
                if budget > 0, diagnostics.linkLookups >= limits.minLinkLookupsPerScan,
                    CFAbsoluteTimeGetCurrent() > deadline
                {
                    budget = 0
                }
                let before = budget
                urls.append(linkReader.url(of: el, now: now, budget: &budget))
                diagnostics.linkLookups += before - budget
            }
            result.append(urls)
        }
        linkReader.prune(now: now)
        return result
    }

    /// The segment's links as the overlay gets them: in text order, not overlapping, with one rectangle per line
    /// of the original, their look and where they lead. Pure (no AX calls).
    static func finishLinks(
        _ segment: RawSegment, text: String, style: TextStyleHint, reported: [ReportedLinkStyle?], urls: [URL?]
    ) -> [SegmentLink] {
        guard !segment.links.isEmpty else { return [] }
        let runs = segment.wholeRunFrames
        let textHeight =
            LineGeometry.textHeight(runs: runs, fontSize: style.fontSize) ?? style.fontSize.map { CGFloat($0) * 1.2 }
        let limit = LineGeometry.singleLineLimit(runs: runs, fontSize: style.fontSize)
        let pitch = style.lineHeight.map { CGFloat($0) }
        let length = text.utf16.count
        var result: [SegmentLink] = []
        for (i, raw) in segment.links.enumerated() {
            let r = raw.range.clamped(to: 0..<length)
            guard !r.isEmpty, result.last.map({ $0.range.upperBound <= r.lowerBound }) ?? true else { continue }
            let frames =
                raw.frames.isEmpty
                ? ExtractionWalk.linkFrames(raw.runs, textHeight: textHeight, singleLineLimit: limit, pitch: pitch)
                : raw.frames
            let look = i < reported.count ? reported[i] : nil
            let url = (i < urls.count ? urls[i] : nil) ?? raw.url
            result.append(
                SegmentLink(
                    range: r, text: LinkText.substring(text, r), kind: raw.kind, url: url, frames: frames,
                    element: raw.element, color: look?.color, isUnderlined: look?.isUnderlined ?? false))
        }
        return result
    }

    /// Every letter of the text is inside a link.
    static func isOnlyLinks(_ text: String, _ links: [RawLink]) -> Bool {
        guard !links.isEmpty else { return false }
        let ns = text as NSString
        var covered = 0
        var visible = 0
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            guard c != 0x20, c != 0x0A, c != 0x09, c != 0xA0 else { continue }
            visible += 1
            if links.contains(where: { $0.range.contains(i) }) { covered += 1 }
        }
        return visible > 0 && covered == visible
    }

    /// A paragraph that is nothing but links has no text color of its own (the links' color is theirs): it takes
    /// the color of a paragraph next to it in reading order with text of the same size, when one is known.
    static func borrowTextColors(_ styles: inout [(style: TextStyleHint, lineFrames: [CGRect])], linkOnly: [Bool]) {
        guard linkOnly.count == styles.count else { return }
        for i in styles.indices where linkOnly[i] && styles[i].style.textColor == nil {
            for j in [i - 1, i + 1, i - 2, i + 2] where j >= 0 && j < styles.count && !linkOnly[j] {
                let a = styles[i].style.fontSize
                let b = styles[j].style.fontSize
                let sameSize = (a == nil && b == nil) || (a != nil && b != nil && abs(a! - b!) <= 1)
                if sameSize, let color = styles[j].style.textColor {
                    styles[i].style.textColor = color
                    break
                }
            }
        }
    }

    /// What the app reports for each segment's dominant run (cached per element), with web sizes scaled by the
    /// page zoom. New reads stop once the scan's time is spent, except a few, so a slow app still gets its look
    /// over the next scans.
    private func readStyles(
        _ kept: [(segment: RawSegment, text: String)], pid: pid_t, start: CFAbsoluteTime, limits: ExtractionLimits,
        diagnostics: inout ExtractionDiagnostics
    ) -> [ReportedStyles?] {
        let now = CFAbsoluteTimeGetCurrent()
        var budget = limits.styleLookupsPerScan
        let deadline = start + limits.timeBudget
        var reported: [ReportedStyles?] = []
        reported.reserveCapacity(kept.count)
        for (segment, text) in kept {
            guard let source = segment.styleSource else {
                reported.append(nil)
                continue
            }
            if budget > 0, diagnostics.styleLookups >= limits.minStyleLookupsPerScan,
                CFAbsoluteTimeGetCurrent() > deadline
            {
                budget = 0
            }
            let before = budget
            // The links the source holds are looked up in the same runs (their color and underline).
            let links = segment.links.contains { $0.styleText != nil } ? segment.links.map(\.styleProbe) : []
            let r = styleReader.styles(
                for: source, textKey: text.hashValue, links: links, pid: pid, now: now, budget: &budget)
            diagnostics.styleLookups += before - budget
            reported.append(r)
            if let size = r?.text?.fontSize, let em = segment.dominantEm, let h = segment.dominantHeight {
                zoom.add(pid: pid, reportedSize: size, measuredEm: em, runHeight: h)
            }
        }
        styleReader.prune(now: now)
        let factor = zoom.factor(pid: pid)
        diagnostics.zoom = factor
        guard factor != 1 else { return reported }
        // Web text reports CSS pixels. Ranged sources (native text views, terminals) report points.
        for i in reported.indices where kept[i].segment.styleSource?.location == nil {
            if let size = reported[i]?.text?.fontSize { reported[i]?.text?.fontSize = size * factor }
        }
        return reported
    }

    /// Obstacles worth passing on: visible, not part of a segment (an "(edited)" label or an emoji inside a
    /// paragraph is covered with it), and not inside another obstacle. At most `limit`, in the given order. Past
    /// the limit the ones nearest a segment are kept, since they are what translations would grow over (the
    /// input box under the newest answer, not the middle of a long diff); without segments, the last ones.
    static func keptObstacles(_ obstacles: [CGRect], segments: [TextSegment], limit: Int = 200) -> [CGRect] {
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            let i = a.intersection(b)
            return !i.isNull && i.width > 1 && i.height > 1
        }
        let areas = segments.map(\.axFrame.standardized)
        var candidates: [(index: Int, rect: CGRect)] = []
        for (i, o) in obstacles.map(\.standardized).enumerated() {
            guard !o.isNull, o.width >= 1, o.height >= 3, !areas.contains(where: { overlaps($0, o) }) else { continue }
            candidates.append((i, o))
        }
        if candidates.count > limit {
            if areas.isEmpty {
                candidates.reverse()
            } else {
                let distance = candidates.map { c in areas.map { gap(c.rect, $0) }.min() ?? 0 }
                // Equally near: the later one (newer content).
                let order = candidates.indices.sorted {
                    distance[$0] != distance[$1] ? distance[$0] < distance[$1] : $0 > $1
                }
                candidates = order.map { candidates[$0] }
            }
        }
        var kept: [(index: Int, rect: CGRect)] = []
        for c in candidates {
            guard kept.count < limit else { break }
            if kept.contains(where: { $0.rect.contains(c.rect) }) { continue }
            kept.removeAll { c.rect.contains($0.rect) }
            kept.append(c)
        }
        return kept.sorted { $0.index < $1.index }.map(\.rect)
    }

    /// Shortest distance between two rectangles (0 when they touch or overlap).
    private static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(b.minX - a.maxX, 0, a.minX - b.maxX)
        let dy = max(b.minY - a.maxY, 0, a.minY - b.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Reading order: rows of 6 pt, then left to right, then tree order.
    static func readingOrder(_ a: RawSegment, _ b: RawSegment) -> Bool {
        let ra = Int((a.frame.minY / 6).rounded(.down))
        let rb = Int((b.frame.minY / 6).rounded(.down))
        if ra != rb { return ra < rb }
        if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
        return a.treeIndex < b.treeIndex
    }

    // MARK: Style

    /// The walk's own knowledge plus what the app reported, then the line geometry. Pure (no AX calls).
    /// Paragraphs with link runs that are not recorded as links (native text views) say so, so the overlay does
    /// not take a color measured over the whole paragraph for its text (DESIGN §6.1).
    static func markLinkRuns(
        _ styles: inout [(style: TextStyleHint, lineFrames: [CGRect])], reported: [ReportedStyles?]
    ) {
        for i in styles.indices where i < reported.count && reported[i]?.hasLinkRuns == true {
            styles[i].style.hasLinkRuns = true
        }
    }

    static func resolveStyles(
        _ segments: [RawSegment], reported: [ReportedTextStyle?]
    ) -> [(style: TextStyleHint, lineFrames: [CGRect])] {
        let styles = segments.indices.map { i -> TextStyleHint in
            var style = segments[i].style
            if i < reported.count, let r = reported[i] { apply(r, to: &style, runs: segments[i].wholeRunFrames) }
            return style
        }
        // Height of one line of text per font size in this window, for paragraphs whose runs all span several
        // lines (one long text node): their pitch needs the height of a single line.
        var heights: [Double: [CGFloat]] = [:]
        for (i, s) in segments.enumerated() {
            guard let fs = styles[i].fontSize, let th = LineGeometry.textHeight(runs: s.wholeRunFrames, fontSize: fs)
            else { continue }
            heights[sizeKey(fs), default: []].append(th)
        }
        // Exact pitches per font size (gaps of one line), to divide gaps that span several lines.
        let gaps = segments.indices.map { i -> LineGeometry.Gaps? in
            guard styles[i].lineHeight == nil else { return nil }
            let known = styles[i].fontSize.flatMap { heights[sizeKey($0)] }.map(LineGeometry.median)
            return LineGeometry.gaps(
                runs: segments[i].wholeRunFrames, fontSize: styles[i].fontSize, textHeight: known)
        }
        var direct: [Double: [CGFloat]] = [:]
        for i in segments.indices {
            guard let fs = styles[i].fontSize, let g = gaps[i] else { continue }
            direct[sizeKey(fs), default: []].append(contentsOf: g.direct)
        }
        let windowPitch = direct.compactMapValues { $0.isEmpty ? nil : LineGeometry.median($0) }

        var result: [(style: TextStyleHint, lineFrames: [CGRect])] = []
        result.reserveCapacity(segments.count)
        for (i, s) in segments.enumerated() {
            var style = styles[i]
            if style.lineHeight == nil, let g = gaps[i],
                let pitch = LineGeometry.linePitch(
                    g, fontSize: style.fontSize, windowPitch: style.fontSize.flatMap { windowPitch[sizeKey($0)] })
            {
                style.lineHeight = Double(pitch)
            }
            var lines = s.lineFrames
            if lines.isEmpty {
                lines = LineGeometry.lineFrames(runs: s.runFrames, markers: s.markerFrames, fontSize: style.fontSize)
            }
            result.append((style, lines))
        }
        // One reference pitch per font size: the window's exact pitch, else the median of the paragraphs' own.
        // One-line paragraphs (no pitch of their own) take it, and pitches within rounding of it snap to it so
        // paragraphs of the same text keep the same spacing.
        var pitches: [Double: [CGFloat]] = [:]
        for (i, r) in result.enumerated() {
            guard segments[i].style.lineHeight == nil, let fs = r.style.fontSize, let lh = r.style.lineHeight else {
                continue
            }
            pitches[sizeKey(fs), default: []].append(CGFloat(lh))
        }
        for i in result.indices where segments[i].style.lineHeight == nil {
            guard let fs = result[i].style.fontSize,
                let reference = windowPitch[sizeKey(fs)] ?? pitches[sizeKey(fs)].map(LineGeometry.median)
            else { continue }
            let snapped = Double(LineGeometry.half(reference))
            if let own = result[i].style.lineHeight, abs(own - snapped) > snapped * 0.08 { continue }
            result[i].style.lineHeight = snapped
        }
        return result
    }

    private static func sizeKey(_ fs: Double) -> Double { (fs * 2).rounded() / 2 }

    /// Merges a reported style into the walk's. A reported size that the run frames contradict (text drawn
    /// much larger or smaller than that size, e.g. under a zoom the app does not report) is replaced by one
    /// derived from the frames.
    static func apply(_ reported: ReportedTextStyle, to style: inout TextStyleHint, runs: [CGRect]) {
        if let size = reported.fontSize {
            if let estimate = style.fontSize {
                // Terminal cell metrics: keep the estimate unless the app's size is close to it.
                if abs(size - estimate) <= estimate * 0.3 { style.fontSize = size }
            } else if let th = LineGeometry.textHeight(runs: runs, fontSize: size) ?? smallestRun(runs) {
                let ratio = Double(th) / size
                style.fontSize = (0.75...2.2).contains(ratio) ? round(size) : round(Double(th) / 1.25)
            } else {
                style.fontSize = round(size)
            }
        }
        if style.textColor == nil { style.textColor = reported.textColor }
        if reported.isMonospaced { style.isMonospaced = true }
    }

    private static func round(_ v: Double) -> Double { (v * 2).rounded() / 2 }

    private static func smallestRun(_ runs: [CGRect]) -> CGFloat? {
        runs.map(\.height).filter { $0 > 0 && $0 <= LineGeometry.maxSingleLineHeight }.min()
    }

    // MARK: Caches

    /// Only resolved CGWindowIDs are cached. When the lookup fails (busy app), the fallback key is used for this
    /// scan only and the lookup is retried next time, so a window does not keep a key that differs from the one
    /// the session derives from its CGWindowID.
    private func windowKey(for window: AXElement, pid: pid_t, knownID: CGWindowID?) -> WindowKey {
        if knownID == nil, let k = windowKeys[window] { return k }
        guard let id = knownID ?? WindowLocator.windowID(of: window, pid: pid) else {
            return WindowLocator.fallbackKey(for: window, pid: pid)
        }
        let k = WindowKey(pid: pid, windowID: id)
        if windowKeys.count > 64 { windowKeys.removeAll() }
        windowKeys[window] = k
        return k
    }

    private func ignorePatterns(_ patterns: [String]) -> IgnorePatterns? {
        guard !patterns.isEmpty else { return nil }
        if let cached = ignoreCache, cached.patterns == patterns { return cached }
        let compiled = IgnorePatterns(patterns)
        ignoreCache = compiled
        return compiled
    }
}
