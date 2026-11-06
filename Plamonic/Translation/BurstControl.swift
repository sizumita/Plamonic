import Foundation

/// 混雑時の一時停止 (DESIGN §5.1): decides when the final stage of 段階翻訳 pauses because a lot of new
/// text keeps arriving, and when it resumes. The coordinator keeps one per app. Pure state: the caller
/// passes the current time, so tests can drive it with any clock.
///
/// - Enter (either): `backlog >= threshold`, or at least `threshold` arrivals within `arrivalWindow`.
/// - Exit (both): at most one arrival within `quietSeconds`, and `backlog == 0`.
///
/// "Arrival" = a text that a window's new scan shows and its previous scan did not, with no cached
/// translation of any model, and that is not an earlier text changed in place (grown or cut at an edge).
/// "Backlog" = on-screen texts still waiting for their first translation.
struct BurstControl: Sendable {
    private struct Batch: Sendable {
        var date: Date
        var count: Int
    }

    /// Arrivals within this many seconds count toward entering the pause.
    let arrivalWindow: TimeInterval
    private(set) var settings: BurstControlSettings
    private(set) var isPaused = false
    /// One batch per scan that brought new text, oldest first.
    private var batches: [Batch] = []
    /// Arrivals up to this moment already caused a pause that has ended; they do not start another one.
    /// Without it a quiet period shorter than `arrivalWindow` would end the pause and re-enter it at once.
    private var consumedUntil: Date?

    init(settings: BurstControlSettings = BurstControlSettings(), arrivalWindow: TimeInterval = 2) {
        self.settings = settings
        self.arrivalWindow = max(0, arrivalWindow)
    }

    /// At least 1: a hand-edited 0 would keep the final stage paused forever.
    var threshold: Int { max(1, settings.threshold) }
    var quietSeconds: TimeInterval { settings.quietSeconds.isFinite ? max(0, settings.quietSeconds) : 0 }

    mutating func configure(_ settings: BurstControlSettings) {
        if self.settings != settings { self.settings = settings }
    }

    mutating func recordArrivals(_ count: Int, at now: Date) {
        guard count > 0 else { return }
        batches.append(Batch(date: now, count: count))
        prune(now: now)
    }

    /// Arrivals younger than `interval`, optionally only those after `start`.
    func arrivalCount(within interval: TimeInterval, now: Date, after start: Date? = nil) -> Int {
        var total = 0
        for batch in batches.reversed() {
            guard now.timeIntervalSince(batch.date) < interval else { break }
            if let start, batch.date <= start { break }
            total += batch.count
        }
        return total
    }

    /// Re-evaluates the pause. `isActive` is false when burst control is off or no tracked window
    /// translates in two stages; the pause then ends at once. Returns true when `isPaused` changed.
    @discardableResult
    mutating func evaluate(backlog: Int, isActive: Bool, now: Date) -> Bool {
        prune(now: now)
        let wasPaused = isPaused
        if !isActive {
            isPaused = false
        } else if isPaused {
            if backlog == 0 && arrivalCount(within: quietSeconds, now: now) <= 1 { isPaused = false }
        } else if backlog >= threshold
            || arrivalCount(within: arrivalWindow, now: now, after: consumedUntil) >= threshold
        {
            isPaused = true
        }
        if wasPaused && !isPaused { consumedUntil = now }
        return wasPaused != isPaused
    }

    /// When the quiet condition will hold if no more text arrives (the caller re-evaluates then, so the
    /// pause can end without a new scan). nil when not paused or the condition already holds; the
    /// remaining wait is then for drafts, whose completion triggers its own evaluation.
    func nextEvaluation(now: Date) -> Date? {
        guard isPaused else { return nil }
        var total = 0
        for batch in batches.reversed() {
            guard now.timeIntervalSince(batch.date) < quietSeconds else { break }
            total += batch.count
            // Once this batch ages out, at most one arrival is left in the quiet window.
            if total > 1 { return batch.date.addingTimeInterval(quietSeconds) }
        }
        return nil
    }

    mutating func reset() {
        isPaused = false
        batches.removeAll()
        consumedUntil = nil
    }

    private mutating func prune(now: Date) {
        // A clock that stepped back makes earlier arrivals look like they are in the future: they would
        // never age out and would hold the pause for as long as the step. Forget them instead.
        batches.removeAll { $0.date > now }
        if let consumedUntil, consumedUntil > now { self.consumedUntil = now }
        let keep = max(arrivalWindow, quietSeconds)
        if let index = batches.firstIndex(where: { now.timeIntervalSince($0.date) < keep }) {
            if index > 0 { batches.removeFirst(index) }
        } else {
            batches.removeAll()
        }
    }
}
