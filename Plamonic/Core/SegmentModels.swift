import CoreGraphics
import Foundation

// Shared types between Extraction, Translation, Session and Overlay.
// All rectangles named `axFrame` / `axRect` are in AX global coordinates:
// origin at the top-left of the primary screen, y grows downward.

/// Identifies one window of one process across scans.
struct WindowKey: Hashable, Sendable, CustomStringConvertible {
    var pid: pid_t
    /// CGWindowID when it could be resolved, otherwise a hash of the AX window element.
    var windowID: UInt32

    var description: String { "\(pid):\(windowID)" }
}

/// An sRGB color with components in 0...1.
struct RGBAColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    /// WCAG relative luminance (alpha ignored), 0...1.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

/// How the original text looks, as far as the app (or the screen) tells. Used to draw the translation
/// so it reads like the app's own text. Every field is optional: unknown values fall back to the overlay's theme.
struct TextStyleHint: Hashable, Sendable {
    /// Point size of the original text (the dominant size within the segment).
    var fontSize: Double?
    /// Distance between the tops of consecutive lines of the original, in points.
    var lineHeight: Double?
    /// The original is monospaced (terminal text, code).
    var isMonospaced: Bool = false
    /// Text color of the original (dominant run), when the app reports it.
    var textColor: RGBAColor?
    /// The app marks part of the original as links that are not in `TextSegment.links` (native text views'
    /// AXLink runs), so a color measured over the whole paragraph may be a link's.
    var hasLinkRuns = false

    init(fontSize: Double? = nil, lineHeight: Double? = nil, isMonospaced: Bool = false, textColor: RGBAColor? = nil) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.isMonospaced = isMonospaced
        self.textColor = textColor
    }
}

/// Colors measured from the target window's own pixels inside one item's area.
struct SampledColors: Hashable, Sendable {
    var background: RGBAColor
    /// The most common color that contrasts with the background (the original text), when found.
    var text: RGBAColor?
}

/// What kind of clickable thing a link inside a segment is.
enum SegmentLinkKind: String, Hashable, Sendable {
    /// An AXLink (web links, Slack/Discord links, mentions and channels drawn as links).
    case link
    /// A button drawn inline as part of the text (Claude's file references, Discord mentions).
    case button
    /// A URL found in plain text by `NSDataDetector` (terminals): there is no element to press.
    case detected
}

/// A link inside a segment's original text. DESIGN §6.1.
struct SegmentLink: Hashable, Sendable {
    /// UTF-16 offsets of the link's text within `TextSegment.text`.
    var range: Range<Int>
    /// The link's text (`TextSegment.text` at `range`).
    var text: String
    var kind: SegmentLinkKind = .link
    /// Where it leads, when the app reports it (AXURL) or the text is a URL. nil for app-internal links
    /// (mentions, channels, buttons): those are opened only by pressing `element`.
    var url: URL? = nil
    /// The link in the original, one rectangle per visual line, AX coordinates. Clicks there are kept from
    /// reaching it while a translation covers it.
    var frames: [CGRect] = []
    /// Pressed (AXPress) to open the link the way the app itself does. nil for `.detected`.
    var element: AXElement? = nil
    /// The original link's text color, when the app reports it.
    var color: RGBAColor? = nil
    var isUnderlined: Bool = false

    init(
        range: Range<Int>, text: String, kind: SegmentLinkKind = .link, url: URL? = nil, frames: [CGRect] = [],
        element: AXElement? = nil, color: RGBAColor? = nil, isUnderlined: Bool = false
    ) {
        self.range = range
        self.text = text
        self.kind = kind
        self.url = url
        self.frames = frames
        self.element = element
        self.color = color
        self.isUnderlined = isUnderlined
    }
}

/// A link inside a translation: where the original link's text ended up. DESIGN §6.1.
struct OverlayLink: Hashable, Sendable {
    /// UTF-16 offsets within `OverlayItem.translation`.
    var range: Range<Int>
    /// Index into `OverlayItem.originalLinks`.
    var linkIndex: Int
}

/// One unit of text to translate, found on screen.
struct TextSegment: Hashable, Sendable {
    /// Stable across scans while the same text stays in the same place in the tree:
    /// derived from the text plus its occurrence index within the window (not from the frame).
    var id: String
    var text: String
    var axFrame: CGRect
    var role: String
    var isEditable: Bool
    /// Reading order within the window (top-to-bottom, left-to-right).
    var order: Int
    /// The original's look (size, line spacing, color), when known.
    var style: TextStyleHint = TextStyleHint()
    /// One rectangle per visual line of the original, top to bottom, AX coordinates. Empty = unknown
    /// (only `axFrame` is known). Lets the overlay cover exactly the original lines.
    var lineFrames: [CGRect] = []
    /// Links inside the text, in text order. Empty = none (or unknown).
    var links: [SegmentLink] = []
}

/// Result of scanning one window.
struct WindowSnapshot: Sendable {
    var key: WindowKey
    var pid: pid_t
    var bundleID: String
    /// The window's frame in AX coordinates.
    var axWindowFrame: CGRect
    /// Visible region for overlays (scroll area / window content), AX coordinates. nil = the whole window.
    var axClipRect: CGRect?
    var segments: [TextSegment]
    var nodeCount: Int
    var scanDuration: TimeInterval
    /// true when the scan stopped early because of the node or time budget.
    var truncated: Bool
    /// Visible content that is not translated and is not part of any segment (names, timestamps, buttons,
    /// excluded parts, terminal borders and prompts), AX coordinates. The overlay keeps translations off it.
    var obstacles: [CGRect] = []
    /// Areas of the window that scroll on their own (the visible part of each rule container: a chat panel,
    /// a side chat), AX coordinates. Empty = unknown: a scroll anywhere in the window moves everything.
    var scrollRegions: [CGRect] = []
    /// Terminal mode: the line with the insertion point or the last non-empty line waits for a password
    /// (`Password:`, `[sudo] password for …:`, `パスワード:`…; see TerminalPasswordPrompt). The session stops
    /// reading that window until its content changes. Set by the extraction.
    var passwordPrompt: Bool = false
}

enum OverlayItemState: String, Hashable, Sendable {
    case pending  // waiting for the first translation; the original stays visible
    case streaming  // partial translation is being generated
    case draft  // translated by the draft (small) model; a better translation may follow
    case final  // translated by the final model
    case failed  // translation failed; the original stays visible
}

/// What the overlay draws for one segment.
struct OverlayItem: Hashable, Sendable {
    var id: String
    var axFrame: CGRect
    var original: String
    var translation: String
    var state: OverlayItemState
    /// Copied from the segment: the original's look and line rectangles.
    var style: TextStyleHint = TextStyleHint()
    var lineFrames: [CGRect] = []
    /// The segment's links (in the original).
    var originalLinks: [SegmentLink] = []
    /// Where those links are in `translation`, in text order. A link whose text could not be found in the
    /// translation has no entry: it stays reachable through the original (hover, or a click on the text).
    var links: [OverlayLink] = []
}

struct OverlayStyle: Equatable, Sendable {
    var displayStyle: DisplayStyle
    var appearance: OverlayAppearance
    var interaction: OverlayInteractionSettings = OverlayInteractionSettings()
}
