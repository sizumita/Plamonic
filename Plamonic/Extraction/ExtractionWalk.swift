import ApplicationServices
import CoreGraphics
import Foundation

/// A text candidate before filtering, ordering and id assignment.
struct RawSegment {
    var text: String
    var frame: CGRect
    var role: String
    var isEditable: Bool
    /// Pre-order index of the element that produced it (tie-breaker for reading order).
    var treeIndex: Int
    /// Built from terminal rows that were already checked one by one (ignore patterns, code): the joined
    /// paragraph is not checked again, since a per-line pattern or code heuristic misfires on joined prose.
    var filteredPerLine = false
    /// What the walk already knows about the look (terminal cell metrics, inline code). The app is asked for
    /// the rest through `styleSource`, only for segments that survive filtering.
    var style = TextStyleHint()
    /// Exact line rectangles when the walk knows them (terminal rows). Empty = derive from `runFrames`.
    var lineFrames: [CGRect] = []
    /// Visible frames of the text runs (leaf elements) the paragraph is made of, list markers excluded.
    var runFrames: [CGRect] = []
    /// Per run: not cut by the clip. Only whole runs tell the height and position of lines.
    var runIsWhole: [Bool] = []
    /// Visible frames of list markers ("1.", "•") in the paragraph.
    var markerFrames: [CGRect] = []
    /// The dominant run, to read its font size and color.
    var styleSource: StyleSource?
    /// On-screen em size of the dominant run when it is one whole line of CJK text (each glyph is 1 em wide):
    /// width / glyph count. Tells a page zoom the app does not include in its reported font size.
    var dominantEm: Double?
    /// Height of that run, to make sure it holds one line.
    var dominantHeight: Double?
    /// Tree index of the element that grouped this paragraph (pieces of one split paragraph share it); -1 = none.
    var blockIndex = -1
    /// Links inside `text` (UTF-16 ranges into `text`, kept valid through every change of it).
    var links: [RawLink] = []
    /// Emission order within the scan (tree order).
    var emitIndex = 0

    /// Runs not cut by the clip, for line geometry.
    var wholeRunFrames: [CGRect] {
        zip(runFrames, runIsWhole).compactMap { $1 ? $0 : nil }
    }

    /// Takes in another piece of the same paragraph (see SegmentMerger). `linkOffset`: where the other piece's
    /// text starts in the joined text.
    mutating func absorb(_ other: RawSegment, otherIsLonger: Bool, linkOffset: Int) {
        frame = frame.union(other.frame)
        treeIndex = min(treeIndex, other.treeIndex)
        emitIndex = min(emitIndex, other.emitIndex)
        filteredPerLine = filteredPerLine && other.filteredPerLine
        runFrames += other.runFrames
        runIsWhole += other.runIsWhole
        markerFrames += other.markerFrames
        lineFrames =
            lineFrames.isEmpty || other.lineFrames.isEmpty
            ? [] : (lineFrames + other.lineFrames).sorted { $0.minY < $1.minY }
        // Only the links of the piece whose style source is kept can be looked up in it.
        let takesOtherSource = otherIsLonger && other.styleSource != nil
        var otherLinks = other.links.map { $0.shifted(by: linkOffset) }
        if takesOtherSource {
            for i in links.indices { links[i].styleText = nil }
        } else {
            for i in otherLinks.indices { otherLinks[i].styleText = nil }
        }
        links += otherLinks
        if otherIsLonger {
            if other.styleSource != nil {
                styleSource = other.styleSource
                dominantEm = other.dominantEm
                dominantHeight = other.dominantHeight
            }
            style = other.style
        }
    }
}

/// Roles and subroles that drive the paragraph heuristics.
enum ExtractionRoles {
    /// Elements that flow inside a line of text.
    static let inlineRoles: Set<String> = ["AXStaticText", "AXLink", "AXImage", "AXListMarker"]
    /// AXGroup subroles Chromium / WebKit use for inline formatting (<code>, <strong>, <em>, <time>, ...).
    static let inlineSubroles: Set<String> = [
        "AXCodeStyleGroup", "AXStrongStyleGroup", "AXEmphasisStyleGroup", "AXSubscriptStyleGroup",
        "AXSuperscriptStyleGroup", "AXDeleteStyleGroup", "AXInsertStyleGroup", "AXHighlightStyleGroup",
        "AXMarkStyleGroup", "AXTimeGroup", "AXRubyInline", "AXAbbreviationGroup",
    ]
    /// Leaves whose own value / title is their text.
    static let leafTextRoles: Set<String> = ["AXStaticText", "AXHeading", "AXCell", "AXListMarker", "AXText"]
    static let textInputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    /// Interactive widgets skipped unless `includeControls`.
    static let controlRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXToolbar", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem", "AXScrollBar",
        "AXSplitter", "AXValueIndicator", "AXColorWell", "AXDateField", "AXStepper", "AXSegmentedControl",
        "AXLevelIndicator", "AXProgressIndicator", "AXBusyIndicator", "AXRelevanceIndicator", "AXHandle",
        "AXGrowArea", "AXSwitch", "AXToggle",
    ]
    /// Elements whose frame is a viewport that clips their content.
    static let clippingRoles: Set<String> = ["AXScrollArea", "AXWebArea"]
    static let clippingDOMClasses: Set<String> = [
        "overflow-hidden", "overflow-auto", "overflow-scroll", "overflow-clip", "overflow-y-auto",
        "overflow-y-scroll", "overflow-y-hidden", "overflow-y-clip", "overflow-x-auto", "overflow-x-scroll",
        "overflow-x-hidden",
    ]
    static let clippingDOMPrefixes: [String] = ["c-scrollbar__hider", "scroller_", "scroll-view__viewport"]

    static func isInline(role: String, subrole: String?) -> Bool {
        if inlineRoles.contains(role) { return true }
        if role == "AXGroup", let subrole, inlineSubroles.contains(subrole) { return true }
        return false
    }

    static func isSecure(role: String, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

/// Per-scan tree walker. Not thread-safe; create one per scan.
final class ExtractionWalk {
    struct Part {
        var text: String
        /// Frame clipped to the visible region; nil when unknown or fully hidden.
        var frame: CGRect?
        var visible: Bool
        var role: String
        var treeIndex: Int
        /// The leaf element the text came from (asked for its font and color).
        var element: AXElement? = nil
        /// Inside inline code (Chromium AXCodeStyleGroup).
        var isCode = false
        /// Fully inside the clip (its frame is the element's own).
        var isWhole = false
        /// The link this text belongs to (AXLink, link-style button, mention button); nil = plain text.
        var link: LinkMark? = nil
    }

    struct Run {
        var parts: [Part]
        var role: String
        var treeIndex: Int
        /// An element whose own text is exactly these parts (to read the look of the whole run at once).
        var element: AXElement? = nil
        var visibleFrame: CGRect? {
            parts.reduce(nil as CGRect?) { acc, p in
                guard p.visible, let f = p.frame else { return acc }
                return acc.map { $0.union(f) } ?? f
            }
        }
        var firstVisibleFrame: CGRect? { parts.first(where: { $0.visible })?.frame }
        var lastVisibleFrame: CGRect? { parts.last(where: { $0.visible })?.frame }
    }

    enum Piece {
        case none  // nothing to say; does not split paragraphs
        case boundary  // ends inline runs (block already emitted, control, input field, ...)
        case inline(Run)  // flows inside the parent's paragraph
        /// Block-level text not yet emitted. `mergeable`: may still join neighbours on the same line
        /// (generic groups Chromium exposes for <span>). `keepAlone`: emit it when it stays separate.
        case block(Run, mergeable: Bool, keepAlone: Bool)

        var isNone: Bool {
            if case .none = self { return true }
            return false
        }
    }

    enum Visibility { case visible, invisible, unknown }

    /// Where a visit happens in the tree.
    struct VisitState {
        var depth: Int
        var clip: CGRect
        /// Text may be emitted (inside a rule item, or no items configured).
        var inItem: Bool
        var itemsOnly: Bool
        var transform: FrameTransform?
        var parentFrame: CGRect?
        /// The link (or link-like button) the visited element is inside.
        var link: LinkMark? = nil

        func child(clip: CGRect, parentFrame: CGRect?, transform: FrameTransform?) -> VisitState {
            VisitState(
                depth: depth + 1, clip: clip, inItem: inItem, itemsOnly: itemsOnly, transform: transform,
                parentFrame: parentFrame, link: link)
        }
    }

    // Configuration
    let settings: EffectiveSettings
    let limits: ExtractionLimits
    let plan: AXFetchPlan
    let excludes: CompiledMatcherSet
    let items: CompiledMatcherSet
    let ignore: IgnorePatterns?
    var granularity: SegmentGranularity
    let deadline: CFAbsoluteTime
    let valueInPlan: Bool

    // State
    private(set) var nodeCount = 0
    private(set) var truncated = false
    private(set) var prunedInvisible = 0
    private(set) var prunedExcluded = 0
    /// A web area with scaled AX frames was found and corrected.
    private(set) var scaledWebArea = false
    private var sinks: [[RawSegment]] = [[]]
    private var emitted = 0
    /// Visible content the walk saw but does not translate (see `WindowSnapshot.obstacles`).
    private(set) var obstacles: [CGRect] = []
    /// A terminal text area waits for a password (see `WindowSnapshot.passwordPrompt`). Set by readTerminal.
    var passwordPrompt = false

    var segments: [RawSegment] { sinks.first ?? [] }

    init(settings: EffectiveSettings, limits: ExtractionLimits, ignore: IgnorePatterns?, start: CFAbsoluteTime) {
        self.settings = settings
        self.limits = limits
        let profile = settings.profile
        var set: AXFetchSet = [.role, .subrole, .children, .frame, .domClassList]
        valueInPlan = profile.textAreaHandling != .terminal
        if valueInPlan { set.insert(.value) }
        if profile.rules.usesRoleDescription { set.insert(.roleDescription) }
        if profile.rules.usesIdentifier { set.insert(.identifier) }
        if profile.includeControls { set.formUnion([.title, .description]) }
        plan = AXFetchPlan(set)
        excludes = CompiledMatcherSet(profile.rules.excludes)
        items = CompiledMatcherSet(profile.rules.items)
        self.ignore = ignore
        granularity = profile.granularity
        deadline = start + limits.timeBudget
    }

    var includeControls: Bool { settings.profile.includeControls }
    var includeEditable: Bool { settings.profile.includeEditableText }

    // MARK: Entry points

    /// Walks `root` and emits its paragraphs. With `itemsOnly`, only text inside rule items is emitted.
    func walk(root: AXElement, clip: CGRect, itemsOnly: Bool, transform: FrameTransform? = nil) {
        let state = VisitState(
            depth: 0, clip: clip, inItem: !itemsOnly, itemsOnly: itemsOnly, transform: transform, parentFrame: nil)
        let piece = visit(root, state)
        if !itemsOnly { flush(piece) }
    }

    /// Searches the window for rule containers (outermost matches only).
    func findContainers(window: AXElement, clip: CGRect, matchers: CompiledMatcherSet) -> [FoundContainer] {
        var found: [FoundContainer] = []
        func search(_ el: AXElement, depth: Int, parentFrame: CGRect?, transform: FrameTransform?) {
            guard depth <= limits.maxDepth, checkBudget(), var info = el.fetch(plan) else { return }
            nodeCount += 1
            let t = adjustFrame(&info, parentFrame: parentFrame, inherited: transform)
            if excludes.matches(info) || ExtractionRoles.isSecure(role: info.role, subrole: info.subrole) { return }
            if matchers.matches(info) {
                if visibility(info.frame, clip) != .invisible {
                    found.append(FoundContainer(element: el, frame: info.frame, transform: t))
                }
                return
            }
            if visibility(info.frame, clip) == .invisible { return }
            for child in info.children { search(child, depth: depth + 1, parentFrame: info.frame, transform: t) }
        }
        search(window, depth: 0, parentFrame: nil, transform: nil)
        return found
    }

    /// Applies the inherited frame transform and detects Chromium web areas whose AX frames are scaled
    /// (seen after moving a window between displays: the web area reports half its real size).
    /// Returns the transform for the node's subtree.
    func adjustFrame(_ info: inout AXNodeInfo, parentFrame: CGRect?, inherited: FrameTransform?) -> FrameTransform? {
        if let t = inherited, let f = info.frame { info.frame = t.apply(f) }
        guard info.role == "AXWebArea", inherited == nil, let f = info.frame, let p = parentFrame,
            let t = FrameTransform.detect(webArea: f, host: p)
        else { return inherited }
        info.frame = t.apply(f)
        scaledWebArea = true
        return t
    }

    func checkBudget() -> Bool {
        if truncated { return false }
        if nodeCount >= limits.maxNodes || CFAbsoluteTimeGetCurrent() > deadline {
            truncated = true
            return false
        }
        return true
    }

    /// Remembers visible content that stays as it is, so translations do not grow over it. Only frames the
    /// walk already has: no AX calls.
    func noteObstacle(_ frame: CGRect?, clip: CGRect) {
        guard let frame else { return }
        let visible = frame.standardized.intersection(clip)
        guard !visible.isNull, visible.width >= 1, visible.height >= limits.minVisibleHeight else { return }
        // Past the cap the oldest go: chats and terminals put the newest content and the input box last, and
        // that is what the latest translations grow over.
        if obstacles.count >= Self.maxObstacles { obstacles.removeFirst(Self.maxObstacles / 4) }
        obstacles.append(visible)
    }

    static let maxObstacles = 600

    func emit(_ segment: RawSegment) {
        var segment = segment
        segment.emitIndex = emitted
        emitted += 1
        sinks[sinks.count - 1].append(segment)
    }

    // MARK: Visiting

    func visit(_ el: AXElement, _ state: VisitState) -> Piece {
        guard state.depth <= limits.maxDepth else {
            truncated = true
            return .none
        }
        guard checkBudget(), var info = el.fetch(plan) else { return .none }
        nodeCount += 1
        let index = nodeCount
        var state = state
        state.transform = adjustFrame(&info, parentFrame: state.parentFrame, inherited: state.transform)

        if ExtractionRoles.isSecure(role: info.role, subrole: info.subrole) { return .boundary }
        if excludes.matches(info) {
            prunedExcluded += 1
            // Excluded parts (code blocks, quotes, tool output) are still on screen.
            noteObstacle(info.frame, clip: state.clip)
            return .none
        }
        if state.itemsOnly && !state.inItem && items.matches(info) {
            emitItem(info, index: index, state)
            return .boundary
        }
        return visitContent(info, index: index, state)
    }

    func visitContent(_ info: AXNodeInfo, index: Int, _ state: VisitState) -> Piece {
        let role = info.role
        let emitting = state.inItem
        let clip = state.clip

        if ExtractionRoles.textInputRoles.contains(role) {
            if emitting {
                readTextInput(info, index: index, clip: clip, transform: state.transform)
            } else {
                noteObstacle(info.frame, clip: clip)
            }
            return .boundary
        }

        let isControl = ExtractionRoles.controlRoles.contains(role)
        // Buttons may be inline (mentions); other controls only count when includeControls is on.
        if isControl && !includeControls && role != "AXButton" {
            noteObstacle(info.frame, clip: clip)
            return .boundary
        }

        let isInline = ExtractionRoles.isInline(role: role, subrole: info.subrole)
        if !isInline {
            switch visibility(info.frame, clip) {
            case .invisible:
                prunedInvisible += 1
                return .none
            case .visible, .unknown:
                break
            }
        }

        if info.children.isEmpty {
            guard emitting else {
                // Names, times, reactions and other text outside the rule items stay visible.
                // (Decided from the role and the fetched value: no AX calls for text that is not translated.)
                if isControl || role == "AXImage" || ExtractionRoles.leafTextRoles.contains(role)
                    || !(info.stringValue ?? "").isEmpty
                {
                    noteObstacle(info.frame, clip: clip)
                }
                return .none
            }
            if isControl {
                // A link drawn as a button inside prose (Claude's file references): part of the sentence when it
                // sits on a line with the text around it. As a boundary it would split the paragraph in two,
                // dropping its text, and the halves' frames would overlap on the shared line.
                // The title is read only here (one call per visible leaf button), not for every node of the walk.
                if role == "AXButton", let f = info.frame, f.height >= 6, f.height <= 60,
                    Self.hasLinkStyle(info.domClasses),
                    let title = nonEmpty(info.title ?? info.element.string(AXAttr.title)),
                    Self.looksLikeInlineText(title, frame: f)
                {
                    // Off a line it is dropped but stays on screen. Joined to one, the obstacle lies inside the
                    // segment and is discarded (TextExtractor.keptObstacles).
                    noteObstacle(info.frame, clip: clip)
                    let part = makePart(
                        title, info.frame, clip, role, index, element: info.element,
                        link: LinkMark(element: info.element, kind: .button))
                    return .block(
                        Run(parts: [part], role: role, treeIndex: index, element: info.element), mergeable: true,
                        keepAlone: includeControls)
                }
                guard includeControls, let text = nonEmpty(info.title) ?? nonEmpty(info.descriptionText) else {
                    noteObstacle(info.frame, clip: clip)
                    return .boundary
                }
                let run = Run(
                    parts: [makePart(text, info.frame, clip, role, index, element: info.element, link: state.link)],
                    role: role, treeIndex: index, element: info.element)
                return .block(run, mergeable: false, keepAlone: true)
            }
            guard role == "AXStaticText" || ExtractionRoles.leafTextRoles.contains(role) || isInline,
                let text = leafText(info), !text.isEmpty
            else {
                // Pictures (attachments, emoji) take room too; empty spacers do not.
                if role == "AXImage" { noteObstacle(info.frame, clip: clip) }
                return .none
            }
            // A link without children (its title is its text) is a link of its own.
            let link = role == "AXLink" ? LinkMark(element: info.element, kind: .link) : state.link
            let run = Run(
                parts: [makePart(text, info.frame, clip, role, index, element: info.element, link: link)], role: role,
                treeIndex: index, element: info.element)
            if isInline || role == "AXStaticText" { return .inline(run) }
            return .block(run, mergeable: false, keepAlone: true)
        }

        if isControl && !includeControls {
            // A skipped button around text or an icon stays on screen unless its text joins a line (see the leaf
            // button above).
            noteObstacle(info.frame, clip: clip)
        }
        var childState = state.child(
            clip: clipForChildren(info, clip), parentFrame: info.frame, transform: state.transform)
        if role == "AXLink" { childState.link = LinkMark(element: info.element, kind: .link) }
        var pieces: [Piece] = []
        pieces.reserveCapacity(info.children.count)
        for child in info.children {
            let piece = visit(child, childState)
            if !piece.isNone { pieces.append(piece) }
        }
        guard emitting, !pieces.isEmpty else { return .none }
        return combine(info, index: index, pieces: pieces, isInline: isInline, isControl: isControl)
    }

    /// Groups inline children into paragraphs. Returns the node's own contribution to its parent.
    func combine(_ info: AXNodeInfo, index: Int, pieces: [Piece], isInline: Bool, isControl: Bool) -> Piece {
        if isControl && !includeControls {
            // A skipped control (button) never emits on its own; its text may still join a line it sits in
            // (Discord renders mentions as buttons).
            var parts: [Part] = []
            for piece in pieces {
                switch piece {
                case .inline(let run), .block(let run, _, _): parts.append(contentsOf: run.parts)
                case .boundary, .none: break
                }
            }
            guard !parts.isEmpty else { return .boundary }
            // Its text is only kept where it joins a line: pressing the button is what clicking that text does.
            Self.markLink(&parts, LinkMark(element: info.element, kind: .button))
            return .block(
                Run(parts: parts, role: info.role, treeIndex: index, element: info.element), mergeable: true,
                keepAlone: false)
        }

        var resolved = pieces
        for i in pieces.indices {
            guard case .block(let run, let mergeable, _) = pieces[i], mergeable else { continue }
            let joinsPrev = i > 0 && sameLine(run.firstVisibleFrame, Self.lastFrame(of: pieces[i - 1]))
            let joinsNext = i + 1 < pieces.count && sameLine(run.lastVisibleFrame, Self.firstFrame(of: pieces[i + 1]))
            if joinsPrev || joinsNext { resolved[i] = .inline(run) }
        }

        let allInline = resolved.allSatisfy {
            if case .inline = $0 { return true }
            return false
        }
        if allInline {
            var parts: [Part] = []
            for case .inline(let run) in resolved { parts.append(contentsOf: run.parts) }
            if info.subrole == "AXCodeStyleGroup" {
                for i in parts.indices { parts[i].isCode = true }
            }
            if isControl, info.role == "AXButton", Self.hasLinkStyle(info.domClasses) {
                Self.markLink(&parts, LinkMark(element: info.element, kind: .button))
            }
            let run = Run(parts: parts, role: info.role, treeIndex: index, element: info.element)
            if isInline { return .inline(run) }
            if isControl { return .block(run, mergeable: true, keepAlone: true) }
            let mergeable = info.role == "AXGroup" && (info.subrole == nil || info.subrole == "AXEmptyGroup")
            return .block(run, mergeable: mergeable, keepAlone: true)
        }

        var current: [Part] = []
        // The element of the run `current` holds, while it holds exactly one.
        var currentRuns = 0
        var currentElement: AXElement?
        func emitCurrent() {
            emitParagraph(current, role: info.role, index: index, block: currentRuns == 1 ? currentElement : nil)
            current = []
            currentRuns = 0
            currentElement = nil
        }
        for piece in resolved {
            switch piece {
            case .inline(let run):
                current.append(contentsOf: run.parts)
                currentRuns += 1
                currentElement = run.element
            case .block(let run, _, let keepAlone):
                emitCurrent()
                if keepAlone { emitParagraph(run.parts, role: run.role, index: run.treeIndex, block: run.element) }
            case .boundary:
                emitCurrent()
            case .none:
                break
            }
        }
        emitCurrent()
        return .boundary
    }

    /// Parts not inside a link yet belong to `mark` (the innermost link wins).
    static func markLink(_ parts: inout [Part], _ mark: LinkMark) {
        for i in parts.indices where parts[i].link == nil { parts[i].link = mark }
    }

    /// Emits what a scan root or item returned.
    func flush(_ piece: Piece) {
        switch piece {
        case .inline(let run):
            emitParagraph(run.parts, role: run.role, index: run.treeIndex, block: run.element)
        case .block(let run, _, let keepAlone):
            if keepAlone { emitParagraph(run.parts, role: run.role, index: run.treeIndex, block: run.element) }
        case .boundary, .none:
            break
        }
    }

    private func emitItem(_ info: AXNodeInfo, index: Int, _ state: VisitState) {
        var state = state
        state.inItem = true
        if granularity == .item {
            sinks.append([])
            let piece = visitContent(info, index: index, state)
            flush(piece)
            let collected = sinks.removeLast()
            guard let segment = Self.itemSegment(collected, role: info.role, index: index) else { return }
            emit(segment)
        } else {
            let piece = visitContent(info, index: index, state)
            flush(piece)
        }
    }

    /// The paragraphs of one rule item as one segment (granularity `.item`), joined with line breaks.
    static func itemSegment(_ collected: [RawSegment], role: String, index: Int) -> RawSegment? {
        guard let firstFrame = collected.first?.frame else { return nil }
        let frame = collected.dropFirst().reduce(firstFrame) { $0.union($1.frame) }
        var segment = RawSegment(
            text: collected.map(\.text).joined(separator: "\n"), frame: frame, role: role,
            isEditable: collected.contains { $0.isEditable }, treeIndex: index,
            filteredPerLine: collected.allSatisfy(\.filteredPerLine))
        segment.blockIndex = index
        // Each paragraph's links move by the text before it.
        var offset = 0
        for c in collected {
            segment.links += c.links.map { $0.shifted(by: offset) }
            offset += c.text.utf16.count + 1
        }
        segment.runFrames = collected.flatMap(\.runFrames)
        segment.runIsWhole = collected.flatMap(\.runIsWhole)
        segment.markerFrames = collected.flatMap(\.markerFrames)
        if collected.allSatisfy({ !$0.lineFrames.isEmpty }) { segment.lineFrames = collected.flatMap(\.lineFrames) }
        // The look of the longest paragraph stands for the item.
        if let li = collected.indices.max(by: { collected[$0].text.count < collected[$1].text.count }) {
            let longest = collected[li]
            // Only that paragraph's links are in its style source.
            let start = collected.prefix(li).reduce(0) { $0 + $1.text.utf16.count + 1 }
            let own = start..<(start + longest.text.utf16.count)
            for i in segment.links.indices where !own.contains(segment.links[i].range.lowerBound) {
                segment.links[i].styleText = nil
            }
            segment.style = longest.style
            segment.styleSource = longest.styleSource
            segment.dominantEm = longest.dominantEm
            segment.dominantHeight = longest.dominantHeight
        }
        return segment
    }

    /// `block`: an element whose own text is exactly `parts`, when there is one.
    func emitParagraph(_ parts: [Part], role: String, index: Int, block: AXElement? = nil) {
        // On screen only when some of its text is: a list marker alone (the item's text scrolled past the clip)
        // would put the whole item's translation into a sliver.
        guard !parts.isEmpty, parts.contains(where: { $0.visible && $0.role != "AXListMarker" }) else { return }
        if granularity == .element {
            for p in parts where p.visible {
                guard let f = p.frame else { continue }
                var segment = RawSegment(
                    text: p.text, frame: f, role: p.role, isEditable: false, treeIndex: p.treeIndex)
                // Elements of one paragraph whose frames cover each other (a run wrapping under its neighbours)
                // are merged back by SegmentMerger.
                segment.blockIndex = index
                segment.links = Self.links(of: [p], text: p.text, offsets: [0])
                Self.describeRuns([p], into: &segment)
                emit(segment)
            }
            return
        }
        guard let frame = Run(parts: parts, role: role, treeIndex: index).visibleFrame else { return }
        let joined = Self.joinWithOffsets(parts)
        var segment = RawSegment(
            text: joined.text, frame: frame, role: role, isEditable: false,
            treeIndex: parts.first?.treeIndex ?? index)
        segment.blockIndex = index
        segment.links = Self.links(of: parts, text: joined.text, offsets: joined.offsets)
        Self.describeRuns(parts, into: &segment, block: block)
        emit(segment)
    }

    /// Run frames for line geometry, and the dominant run for the font and color: the longest run of whichever
    /// kind (prose or inline code) holds most of the visible characters. Runs inside links are left out (a link
    /// is drawn in its own color), unless the paragraph is nothing but links. A paragraph with links whose
    /// `block` element holds exactly its text is read as a whole: its runs tell both the text's look (outside the
    /// links) and each link's color, in the same calls.
    static func describeRuns(_ parts: [Part], into segment: inout RawSegment, block: AXElement? = nil) {
        struct Pick {
            var prose: (part: Part, chars: Int)?
            var code: (part: Part, chars: Int)?
            var proseChars = 0
            var codeChars = 0

            mutating func add(_ p: Part, _ n: Int) {
                if p.isCode {
                    codeChars += n
                    if n > (code?.chars ?? -1) { code = (p, n) }
                } else {
                    proseChars += n
                    if n > (prose?.chars ?? -1) { prose = (p, n) }
                }
            }

            var isEmpty: Bool { prose == nil && code == nil }
            var mostlyCode: Bool { codeChars > proseChars }
            var dominant: Part? { ((mostlyCode ? code : prose) ?? code)?.part }
        }
        var text = Pick()
        var links = Pick()
        for p in parts where p.visible {
            guard let f = p.frame else { continue }
            if p.role == "AXListMarker" {
                segment.markerFrames.append(f)
                continue
            }
            segment.runFrames.append(f)
            segment.runIsWhole.append(p.isWhole)
            let n = p.text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
            guard p.element != nil else { continue }
            if p.link != nil { links.add(p, n) } else { text.add(p, n) }
        }
        let pick = text.isEmpty ? links : text
        if let d = pick.dominant, let el = d.element {
            if let block, !segment.links.isEmpty {
                segment.styleSource = StyleSource(element: block, location: nil, length: segment.text.utf16.count)
                for i in segment.links.indices {
                    segment.links[i].styleText = LinkText.substring(segment.text, segment.links[i].range)
                    segment.links[i].styleOffset = segment.links[i].range.lowerBound
                }
            } else {
                segment.styleSource = StyleSource(element: el, location: nil, length: d.text.utf16.count)
                // Only links: the run read is a link's, and its color is that link's.
                if let mark = d.link, let i = segment.links.firstIndex(where: { $0.element == mark.element }),
                    let r = LinkText.trimmed(0..<d.text.utf16.count, in: d.text)
                {
                    segment.links[i].styleText = LinkText.substring(d.text, r)
                    segment.links[i].styleOffset = r.lowerBound
                }
            }
            if d.isWhole, let f = d.frame, let em = cjkEm(d.text, width: f.width) {
                segment.dominantEm = em
                segment.dominantHeight = Double(f.height)
            }
        }
        if pick.mostlyCode { segment.style.isMonospaced = true }
    }

    /// Width per glyph of a run of (at least 90%) CJK text, which is set 1 em per glyph; others count half.
    static func cjkEm(_ text: String, width: CGFloat) -> Double? {
        var wide = 0
        var other = 0
        for c in text where !c.isWhitespace {
            if TextMetrics.cellWidth(c) == 2 { wide += 1 } else { other += 1 }
        }
        guard wide >= 4, wide * 10 >= (wide + other) * 9, width > 0 else { return nil }
        return Double(width) / (Double(wide) + 0.5 * Double(other))
    }

    /// Web buttons styled as links ("inline", "prose-link", mentions). Buttons without DOM classes (native apps,
    /// bare HTML) are push buttons: most of them are sized like their title too, so the geometry cannot tell.
    static func hasLinkStyle(_ classes: [String]) -> Bool {
        classes.contains { $0 == "inline" || $0.contains("link") || $0.contains("mention") }
    }

    /// A button whose title fits its frame like text of that height (icon buttons carry long labels in small
    /// frames; padded push buttons are much wider than their title).
    static func looksLikeInlineText(_ title: String, frame: CGRect?) -> Bool {
        guard let f = frame, f.height >= 6, f.width >= 4 else { return false }
        let cells = CGFloat(TextMetrics.cellWidth(title.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard cells > 0 else { return false }
        // A line box is about 1.2–1.8 em; a wrapped button spans two lines (its frame is their union).
        let em = min(f.height, 60) / 1.6
        return f.width >= 0.3 * em * cells && f.width <= 1.5 * em * cells + 24
    }

    // MARK: Geometry

    func visibility(_ frame: CGRect?, _ clip: CGRect) -> Visibility {
        guard let f = frame else { return .unknown }
        let minH = limits.minVisibleHeight
        // 1x1 wrappers (sr-only lists in Slack) can still hold visible children.
        if f.height < minH && f.width < minH { return .unknown }
        // Full-width but squashed: an off-screen virtual-list item.
        if f.height < minH || f.width < 1 { return .invisible }
        let i = f.intersection(clip)
        if i.isNull || i.width < 1 || i.height < 1 { return .invisible }
        return .visible
    }

    private func clipForChildren(_ info: AXNodeInfo, _ clip: CGRect) -> CGRect {
        guard let f = info.frame, f.height >= limits.minVisibleHeight, f.width >= limits.minVisibleHeight else {
            return clip
        }
        let clips =
            ExtractionRoles.clippingRoles.contains(info.role)
            || info.domClasses.contains { cls in
                ExtractionRoles.clippingDOMClasses.contains(cls)
                    || ExtractionRoles.clippingDOMPrefixes.contains { cls.hasPrefix($0) }
            }
        guard clips else { return clip }
        let i = clip.intersection(f)
        return i.isNull ? clip : i
    }

    func makePart(
        _ text: String, _ frame: CGRect?, _ clip: CGRect, _ role: String, _ index: Int, element: AXElement? = nil,
        link: LinkMark? = nil
    ) -> Part {
        guard let f = frame else {
            return Part(
                text: text, frame: nil, visible: false, role: role, treeIndex: index, element: element, link: link)
        }
        let c = f.intersection(clip)
        let visible = !c.isNull && c.height >= limits.minVisibleHeight && c.width >= 2
        return Part(
            text: text, frame: visible ? c : nil, visible: visible, role: role, treeIndex: index, element: element,
            isWhole: visible && c == f, link: link)
    }

    private func sameLine(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0 && overlap >= 0.5 * min(a.height, b.height)
    }

    private static func lastFrame(of piece: Piece) -> CGRect? {
        switch piece {
        case .inline(let run): return run.lastVisibleFrame
        case .block(let run, let mergeable, _): return mergeable ? run.lastVisibleFrame : nil
        default: return nil
        }
    }

    private static func firstFrame(of piece: Piece) -> CGRect? {
        switch piece {
        case .inline(let run): return run.firstVisibleFrame
        case .block(let run, let mergeable, _): return mergeable ? run.firstVisibleFrame : nil
        default: return nil
        }
    }

    /// Concatenates inline texts. DOM whitespace is usually inside the texts; a line break or a visible
    /// gap between adjacent elements becomes "\n" / " ".
    static func join(_ parts: [Part]) -> String { joinWithOffsets(parts).text }

    /// `join`, and where each part starts in the text (UTF-16 offsets).
    static func joinWithOffsets(_ parts: [Part]) -> (text: String, offsets: [Int]) {
        var out = ""
        var length = 0
        var offsets: [Int] = []
        offsets.reserveCapacity(parts.count)
        var prev: Part?
        for p in parts {
            if let q = prev, let sep = separator(q, p) {
                out += sep
                length += sep.utf16.count
            }
            offsets.append(length)
            out += p.text
            length += p.text.utf16.count
            prev = p
        }
        return (out, offsets)
    }

    private static func separator(_ a: Part, _ b: Part) -> String? {
        guard let last = a.text.last, let first = b.text.first else { return nil }
        if last.isWhitespace || first.isWhitespace { return nil }
        guard a.visible, b.visible, let fa = a.frame, let fb = b.frame else { return nil }
        if fb.minY >= fa.maxY - 1 { return "\n" }
        let overlap = min(fa.maxY, fb.maxY) - max(fa.minY, fb.minY)
        if overlap > 0, fb.minX - fa.maxX > 2 { return " " }
        return nil
    }

    // MARK: Text

    private func leafText(_ info: AXNodeInfo) -> String? {
        // Image descriptions (emoji names, alt text) are not part of the sentence.
        if info.role == "AXImage" { return nil }
        if let v = info.stringValue, !v.isEmpty { return v }
        if !valueInPlan, let v = info.element.string(AXAttr.value), !v.isEmpty { return v }
        if info.role != "AXStaticText", let t = nonEmpty(info.title) { return t }
        return nil
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// A container found by the rules search, with the frame correction that applies inside it.
struct FoundContainer {
    var element: AXElement
    var frame: CGRect?
    var transform: FrameTransform?
}

/// Maps frames reported in a wrong scale back to screen coordinates: origin + (p - origin) * scale.
struct FrameTransform: Equatable, Sendable {
    var origin: CGPoint
    var scale: CGFloat

    func apply(_ r: CGRect) -> CGRect {
        CGRect(
            x: origin.x + (r.minX - origin.x) * scale, y: origin.y + (r.minY - origin.y) * scale,
            width: r.width * scale, height: r.height * scale)
    }

    /// A web area that starts at its host view's origin but whose size is a uniform multiple of it.
    static func detect(webArea w: CGRect, host p: CGRect) -> FrameTransform? {
        guard w.width >= 50, w.height >= 50, p.width >= 50, p.height >= 50 else { return nil }
        guard abs(w.minX - p.minX) <= 2, abs(w.minY - p.minY) <= 2 else { return nil }
        let kx = p.width / w.width
        let ky = p.height / w.height
        guard abs(kx - ky) / kx < 0.03, kx > 1.2 || kx < 0.8, kx > 0.3, kx < 3.5 else { return nil }
        return FrameTransform(origin: w.origin, scale: (kx + ky) / 2)
    }
}
