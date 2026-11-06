import CoreGraphics
import Foundation

/// Budgets and size limits for one scan.
struct ExtractionLimits: Equatable, Sendable {
    /// Elements fetched per scan before stopping (sets `truncated`).
    var maxNodes: Int = 5000
    /// Maximum tree depth below the scan root. Chromium trees are ~30-45 deep.
    var maxDepth: Int = 80
    /// Wall-clock budget per scan (sets `truncated`).
    var timeBudget: TimeInterval = 0.2
    /// Segments kept per window, in reading order (`GlobalSettings.maxSegmentsPerScan`).
    var maxSegments: Int = 80
    /// Longer segments are dropped (`GlobalSettings.maxSegmentCharacters`).
    var maxSegmentCharacters: Int = 2000
    /// Elements shorter than this are treated as invisible (Chromium squashes off-screen items to 1 pt).
    var minVisibleHeight: CGFloat = 3
    /// Lines read from a terminal screen.
    var maxTerminalLines: Int = 300
    /// How long matched rule containers are reused before they are searched again.
    var containerCacheLifetime: TimeInterval = 5
    /// New font / color reads per scan (about two AX calls each); cached reads are free. A window full of new
    /// text gets its look over a few scans.
    var styleLookupsPerScan: Int = 40
    /// Reads still made after the time budget is spent, so an app that is always slow gets its look too.
    var minStyleLookupsPerScan: Int = 4
    /// New link URL reads per scan (one AX call each); cached reads are free.
    var linkLookupsPerScan: Int = 60
    /// URL reads still made after the time budget is spent.
    var minLinkLookupsPerScan: Int = 8

    init() {}

    init(global: GlobalSettings) {
        maxSegments = max(1, global.maxSegmentsPerScan)
        maxSegmentCharacters = max(1, global.maxSegmentCharacters)
    }
}
