import CoreGraphics
import Foundation

/// Measures the colors under each item of one window through `ScreenColorSampling`, without measuring on
/// every update. A measurement belongs to the place it was taken: an item that changed (moved, or its text
/// changed, which also gives it a new id) and lies mostly inside a place measured before takes that place's
/// colors at once, and such reused colors are measured again at most every `refreshInterval` seconds
/// (scrolling and streaming text do not change the colors under them). An item in a new place is measured
/// soon: requests wait until those items have been stable for `debounce` seconds (at most `maximumWait` while
/// they keep changing). Only one request per window is in flight; its answer is kept for items that changed
/// meanwhile when it measured most of where they are now. When nothing could be measured or kept (the capture
/// failed or timed out, or everything changed while it ran), the next request waits `retryDelay`, doubling up
/// to `maximumRetryDelay`.
@MainActor
final class OverlayColorSampleScheduler {
    /// What one item is measured for: its visible original text (AX coordinates) and that text.
    struct Target: Equatable, Sendable {
        var axRect: CGRect
        var original: String
        /// Only the text around an item's links (`OverlayController.nonLinkSampleID`). Such a measurement never
        /// stands in for an item's, and only takes over another one of its kind (a measurement over a whole
        /// paragraph can have a link's color as its text color).
        var isNonLinkText = false
    }

    private struct Entry {
        /// The item these colors stand for now.
        var target: Target
        var colors: SampledColors?
        /// Where the colors were measured (AX); differs from `target.axRect` when they were reused.
        var place: CGRect
        /// Measured for exactly `target`; false = reused from where it (or another item) was measured.
        var isExact: Bool
    }

    /// A place measured before is reused for a rect it covers at least this much of.
    static let reuseCoverage: CGFloat = 0.5

    /// While true no window is captured for its colors: a password is being typed (DESIGN §4.1). Nothing is
    /// requested meanwhile; what changed is requested once it turns false.
    private(set) static var capturesPaused = false
    /// Every scheduler alive, to tell them when captures may run again.
    private static let live = NSHashTable<OverlayColorSampleScheduler>.weakObjects()

    /// Pauses or resumes every color capture (the schedulers and the sampler's own gate).
    static func setCapturesPaused(_ paused: Bool) {
        ScreenCaptureGate.shared.isPaused = paused
        guard paused != capturesPaused else { return }
        capturesPaused = paused
        for scheduler in live.allObjects { scheduler.capturePauseChanged() }
    }

    let debounce: TimeInterval
    let maximumWait: TimeInterval
    let retryDelay: TimeInterval
    let maximumRetryDelay: TimeInterval
    /// Least time between two requests when only reused colors are waiting to be measured again.
    let refreshInterval: TimeInterval
    /// Called on the main actor after new colors arrived.
    var onColorsChanged: (() -> Void)?
    /// Requests sent to the sampler so far (tests and diagnostics).
    private(set) var requestCount = 0
    /// While true (the window is hidden while it scrolls) nothing is requested; what changed meanwhile is
    /// requested once it turns false.
    var isSuspended = false {
        didSet { if oldValue != isSuspended { schedule() } }
    }

    private var sampler: (any ScreenColorSampling)?
    private var windowID: UInt32?
    /// Every item that should have colors now.
    private var targets: [String: Target] = [:]
    /// The last measurement of each item (kept while a newer one is pending, so colors do not flicker).
    private var entries: [String: Entry] = [:]
    /// The items in new places the running timer waits on.
    private var waiting: [String: Target] = [:]
    private var timerGeneration = 0
    private var timerRunning = false
    /// The running timer only refreshes reused colors (it does not wait on `waiting`).
    private var timerRefreshes = false
    private var timerStarted: TimeInterval = 0
    private var inFlight: [String: Target]?
    private var lastRequest: TimeInterval = -.infinity
    /// No request before this time (after a request that gave nothing usable).
    private var retryAfter: TimeInterval = 0
    private var nextRetryDelay: TimeInterval

    init(
        debounce: TimeInterval = 0.25, maximumWait: TimeInterval = 1.0, retryDelay: TimeInterval = 2,
        maximumRetryDelay: TimeInterval = 30, refreshInterval: TimeInterval = 5
    ) {
        self.debounce = debounce
        self.maximumWait = max(debounce, maximumWait)
        self.retryDelay = retryDelay
        self.maximumRetryDelay = max(retryDelay, maximumRetryDelay)
        self.refreshInterval = refreshInterval
        nextRetryDelay = retryDelay
        Self.live.add(self)
    }

    /// Colors for an item: its own last measurement (or the one it reuses), else (until it is measured) the
    /// measurement of the nearest measured item, so a new item does not first appear in the theme colors.
    func colors(for id: String) -> SampledColors? {
        if let own = entries[id]?.colors { return own }
        guard let target = targets[id], !target.isNonLinkText else { return nil }
        var best: (distance: CGFloat, colors: SampledColors)?
        for (otherID, entry) in entries where otherID != id && !entry.target.isNonLinkText {
            guard let colors = entry.colors else { continue }
            let distance = abs(entry.target.axRect.midY - target.axRect.midY)
                + abs(entry.target.axRect.minX - target.axRect.minX)
            if let current = best, current.distance <= distance { continue }
            best = (distance, colors)
        }
        return best?.colors
    }

    /// Sets what should be measured. Cheap; call it on every update. `sampler` nil (sampling off, not
    /// authorized, or no window number) forgets everything.
    func update(targets newTargets: [String: Target], windowID: UInt32?, sampler: (any ScreenColorSampling)?) {
        guard let sampler, let windowID else {
            stop()
            return
        }
        if windowID != self.windowID { entries.removeAll() }
        self.sampler = sampler
        self.windowID = windowID
        targets = newTargets

        var kept: [String: Entry] = [:]
        for (id, target) in newTargets {
            if let entry = entries[id], entry.target == target {
                kept[id] = entry
            } else if let place = Self.bestPlace(for: target, among: entries.values) {
                // Changed in a place measured before (scrolled a little, streaming text): reuse it.
                kept[id] = Entry(target: target, colors: place.colors, place: place.place, isExact: false)
            } else if let entry = entries[id] {
                // A new place: the old colors stay until it is measured there.
                kept[id] = entry
            }
        }
        entries = kept
        schedule()
    }

    /// Stops waiting (the window is off screen) but keeps what was measured.
    func pause() {
        cancelTimer()
    }

    func stop() {
        cancelTimer()
        targets.removeAll()
        entries.removeAll()
        sampler = nil
        windowID = nil
    }

    // MARK: - Private

    /// Items not measured for exactly what they are now (new places and reused colors).
    private func unmeasured() -> [String: Target] {
        targets.filter { id, target in
            guard let entry = entries[id] else { return true }
            return !entry.isExact || entry.target != target
        }
    }

    /// The pause ended: nothing measured meanwhile was a failure, so no retry delay is left.
    private func capturePauseChanged() {
        if !Self.capturesPaused {
            retryAfter = 0
            nextRetryDelay = retryDelay
        }
        schedule()
    }

    /// Starts, keeps or cancels the timer for the next request.
    private func schedule() {
        guard sampler != nil, !isSuspended, !Self.capturesPaused else {
            cancelTimer()
            return
        }
        let missing = unmeasured()
        if missing.isEmpty {
            cancelTimer()
            return
        }
        if let inFlight, missing.allSatisfy({ inFlight[$0.key] == $0.value }) {
            // The request in flight covers them.
            cancelTimer()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let newPlaces = missing.filter { entries[$0.key]?.target != $0.value }
        if newPlaces.isEmpty {
            // Only reused colors: measure them again, but not often (a running timer comes sooner).
            guard !timerRunning else { return }
            startTimer(
                fresh: true, refreshes: true,
                after: max(debounce, lastRequest + refreshInterval - now, retryAfter - now))
            return
        }
        let restart = !timerRunning || timerRefreshes
        guard restart || newPlaces != waiting else { return }
        waiting = newPlaces
        // Keeps waiting while things move (scrolling), but not forever while new text keeps coming.
        if !restart, now - timerStarted >= maximumWait - debounce { return }
        startTimer(fresh: restart, refreshes: false, after: max(debounce, retryAfter - now))
    }

    /// (Re)starts the timer. `fresh` = a new wait begins (not a restart of a running one).
    private func startTimer(fresh: Bool, refreshes: Bool, after seconds: TimeInterval) {
        timerGeneration += 1
        let generation = timerGeneration
        if fresh || !timerRunning { timerStarted = ProcessInfo.processInfo.systemUptime }
        timerRunning = true
        timerRefreshes = refreshes
        let delay = UInt64(max(0, seconds) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, self.timerGeneration == generation else { return }
            self.timerRunning = false
            self.waiting.removeAll()
            self.fire()
        }
    }

    private func cancelTimer() {
        timerGeneration += 1
        timerRunning = false
        waiting.removeAll()
    }

    private func fire() {
        // A request in flight schedules the next one when it ends.
        guard inFlight == nil, !isSuspended, !Self.capturesPaused, let sampler, let windowID else { return }
        let batch = unmeasured()
        guard !batch.isEmpty else { return }
        // A timer started while the last request ran can come due before the limits its answer set (the retry
        // delay after an answer nothing could use; the refresh interval when only reused colors are left).
        let now = ProcessInfo.processInfo.systemUptime
        let refreshOnly = batch.allSatisfy { entries[$0.key]?.target == $0.value }
        let earliest = max(retryAfter, refreshOnly ? lastRequest + refreshInterval : -.infinity)
        if now < earliest {
            startTimer(fresh: true, refreshes: refreshOnly, after: earliest - now)
            return
        }
        inFlight = batch
        requestCount += 1
        lastRequest = ProcessInfo.processInfo.systemUptime
        let rects = batch.mapValues(\.axRect)
        Task { @MainActor [weak self] in
            let result = await sampler.sampleColors(windowID: windowID, rects: rects)
            self?.finish(batch, result: result, windowID: windowID)
        }
    }

    private func finish(_ batch: [String: Target], result: [String: SampledColors], windowID: UInt32) {
        inFlight = nil
        guard windowID == self.windowID else { return }
        if result.isEmpty, Self.capturesPaused {
            // Not captured because of the pause: not a failure. The end of the pause asks again.
            return
        }
        var kept = false
        var changed = false
        func set(_ id: String, _ entry: Entry) {
            if entry.colors != entries[id]?.colors { changed = true }
            entries[id] = entry
        }
        // Measurements of items that changed or left while the capture ran.
        var elsewhere: [Entry] = []
        for (id, asked) in batch where !result.isEmpty {
            // An item the sampler could not measure keeps its earlier colors and is not asked for again
            // until it changes.
            let measured = Entry(
                target: asked, colors: result[id] ?? entries[id]?.colors, place: asked.axRect, isExact: true)
            let current = targets[id]
            if current == asked {
                set(id, measured)
                kept = true
                continue
            }
            guard result[id] != nil else { continue }
            elsewhere.append(measured)
            // Moved to a new place meanwhile: these colors until it is measured there.
            if let current, entries[id]?.target != current { set(id, measured) }
        }
        // Items that changed meanwhile take the new measurement of the place they are in now.
        for (id, target) in targets {
            if let entry = entries[id], entry.isExact, entry.target == target { continue }
            guard let place = Self.bestPlace(for: target, among: elsewhere) else { continue }
            set(id, Entry(target: target, colors: place.colors, place: place.place, isExact: false))
            kept = true
        }
        if changed { onColorsChanged?() }
        let now = ProcessInfo.processInfo.systemUptime
        if kept {
            nextRetryDelay = retryDelay
            retryAfter = 0
        } else {
            // The capture failed, or everything changed while it ran: ask again later, less and less often.
            retryAfter = now + nextRetryDelay
            nextRetryDelay = min(nextRetryDelay * 2, maximumRetryDelay)
        }
        schedule()
    }

    /// The measurement of the same kind (with colors) whose place covers the largest part of the target's rect,
    /// at least `reuseCoverage`.
    private static func bestPlace(for target: Target, among entries: some Sequence<Entry>) -> Entry? {
        let rect = target.axRect
        let area = rect.width * rect.height
        guard area > 0 else { return nil }
        var best: (shared: CGFloat, entry: Entry)?
        for entry in entries where entry.colors != nil && entry.target.isNonLinkText == target.isNonLinkText {
            let shared = entry.place.intersection(rect)
            guard !shared.isNull else { continue }
            let size = shared.width * shared.height
            if size >= area * reuseCoverage, size > (best?.shared ?? 0) { best = (size, entry) }
        }
        return best?.entry
    }
}
