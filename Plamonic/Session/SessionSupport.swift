import AppKit
import Foundation

/// What the menu bar shows about the session.
struct SessionStatus: Equatable, Sendable {
    var isRunning = false
    var frontmostAppName: String?
    var frontmostBundleID: String?
    /// Effective mode of the frontmost app (nil when no app is known).
    var frontmostMode: TranslationMode?
    /// Windows that currently get translations drawn.
    var activeWindowCount = 0
    /// A manual translation (or selection popup) is on screen.
    var manualActive = false
    /// Reading is stopped because a password is being typed (nil = not stopped). DESIGN §4.1.
    var passwordPause: PasswordPause?
}

/// Why reading is stopped while a password is typed, and in which app (for the menu).
struct PasswordPause: Equatable, Sendable {
    enum Reason: String, Sendable {
        /// Secure event input is on (a password field has focus, or a system password dialog).
        case secureInput
        /// The focused element of an app Plamonic reads is a password field.
        case secureField
        /// A terminal window waits for a password.
        case terminalPrompt
    }
    var reason: Reason
    /// The app that takes the password, when known.
    var appName: String?
}

/// When a partial scan (time budget hit, Chromium still building its tree) replaces what a window shows.
/// One that found fewer texts keeps the previous overlay, up to `maxKept` such scans in a row: applying it
/// would drop the missing texts, cancel their translations, and count them as new when they come back
/// (which can pause the final stage of 段階翻訳 for nothing). After a scroll the previous positions are stale,
/// so the partial scan is used at once.
enum PartialScanPolicy {
    static let maxKept = 3

    static func keepsPrevious(truncated: Bool, fewer: Bool, streak: Int, scrolled: Bool) -> Bool {
        truncated && fewer && streak < maxKept && !scrolled
    }

    /// The streak after a scan was applied. Only partial scans that lost texts count: one that found at least
    /// as many as the window showed is as good as a complete one for this purpose.
    static func streak(afterApplying truncated: Bool, fewer: Bool, streak: Int) -> Int {
        truncated && fewer ? streak + 1 : 0
    }
}

/// What a scroll or drag hides while 「スクロール中は隠す」 is on. A window whose scan found separately scrolling
/// areas (`WindowSnapshot.scrollRegions`: a chat panel and a side chat) hides only the translations in the area
/// under the pointer; a scroll in none of them (a thread list) hides nothing.
enum ScrollHidePolicy {
    enum Hit: Equatable {
        /// The whole window's overlay (its areas are unknown).
        case window
        /// The translations in these areas.
        case regions([CGRect])
        /// Nothing the window translates moves.
        case none
    }

    static func hit(at point: CGPoint, regions: [CGRect]) -> Hit {
        guard !regions.isEmpty else { return .window }
        let hit = regions.filter { $0.contains(point) }
        return hit.isEmpty ? .none : .regions(hit)
    }

    /// The items still drawn while the `hidden` areas scroll.
    static func visible(_ items: [OverlayItem], hiding hidden: [CGRect]) -> [OverlayItem] {
        guard !hidden.isEmpty else { return items }
        return items.filter { item in !hidden.contains { Self.overlaps($0, item.axFrame) } }
    }

    /// Touching edges do not count: areas side by side share an edge with each other's items.
    private static func overlaps(_ area: CGRect, _ frame: CGRect) -> Bool {
        let i = area.standardized.intersection(frame.standardized)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }
}

/// Passes mouse moves to the overlay at most once per `interval`. A point held back is followed by a trailing
/// update, so the overlay always learns where the pointer came to rest (its rest timers depend on it).
struct MouseMoveThrottle {
    enum Step: Equatable {
        case deliver(CGPoint)
        /// Held back: call `flush` after this many seconds (once; later moves only replace the point).
        case hold(flushAfter: CFAbsoluteTime)
    }

    let interval: CFAbsoluteTime
    private var lastDelivery: CFAbsoluteTime?
    private(set) var pending: CGPoint?

    init(interval: CFAbsoluteTime) {
        self.interval = interval
    }

    mutating func move(to point: CGPoint, at now: CFAbsoluteTime) -> Step {
        if let last = lastDelivery, now - last < interval {
            pending = point
            return .hold(flushAfter: interval - (now - last))
        }
        lastDelivery = now
        pending = nil
        return .deliver(point)
    }

    /// The trailing update: the latest point held back, if it was not delivered meanwhile.
    mutating func flush(at now: CFAbsoluteTime) -> CGPoint? {
        guard let point = pending else { return nil }
        pending = nil
        lastDelivery = now
        return point
    }

    mutating func reset() {
        pending = nil
        lastDelivery = nil
    }
}

/// Passes the global monitor's mouse moves to the overlay through a `MouseMoveThrottle`. The trailing update
/// delivers where the pointer is now, not the point held back: the click panels send their own moves straight
/// to the overlay (the global monitor sees nothing over them), so the held point can be older than one the
/// overlay already has. Delivering it would move the pointer back off a translated link, and resting there
/// would show the original under the pointer (DESIGN §6.1).
@MainActor
final class MouseMoveForwarder {
    private var throttle: MouseMoveThrottle
    private var flushScheduled = false
    private let pointer: () -> CGPoint
    private let deliver: (CGPoint) -> Void

    /// `pointer` reads the current pointer position (AX coordinates).
    init(
        interval: CFAbsoluteTime, pointer: @escaping () -> CGPoint = { AXGeometry.mouseLocationAX() },
        deliver: @escaping (CGPoint) -> Void
    ) {
        throttle = MouseMoveThrottle(interval: interval)
        self.pointer = pointer
        self.deliver = deliver
    }

    func move(to point: CGPoint, at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        switch throttle.move(to: point, at: now) {
        case .deliver(let point):
            deliver(point)
        case .hold(let delay):
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    func reset() {
        throttle.reset()
    }

    private func flush() {
        flushScheduled = false
        guard throttle.flush(at: CFAbsoluteTimeGetCurrent()) != nil else { return }
        deliver(pointer())
    }
}

/// Collects AX notifications on the hub thread and hands them to the main actor in batches,
/// so a burst of Chromium notifications costs one main-thread hop.
final class AXEventCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [pid_t: Set<AXEventKind>] = [:]
    private var scheduled = false
    private let deliver: @MainActor ([pid_t: Set<AXEventKind>]) -> Void

    init(deliver: @escaping @MainActor ([pid_t: Set<AXEventKind>]) -> Void) {
        self.deliver = deliver
    }

    func add(_ event: AXEvent) {
        lock.lock()
        pending[event.pid, default: []].insert(event.kind)
        let needsHop = !scheduled
        scheduled = true
        lock.unlock()
        guard needsHop else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let batch = pending
            pending.removeAll()
            scheduled = false
            lock.unlock()
            MainActor.assumeIsolated { deliver(batch) }
        }
    }
}

/// Masks text for logs: Latin letters -> x, other letters -> 字, digits -> 9. Keeps punctuation and spaces.
enum TextMasker {
    static func mask(_ text: String, limit: Int = 60) -> String {
        var out = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit {
                out += "…"
                break
            }
            let props = scalar.properties
            if props.isAlphabetic, scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value) {
                out += "x"
            } else if props.numericType != nil, props.generalCategory == .decimalNumber {
                out += "9"
            } else if props.isAlphabetic {
                out += "字"
            } else if scalar == "\n" {
                out += "⏎"
            } else if props.generalCategory == .otherSymbol || props.isEmojiPresentation {
                out += "*"
            } else if scalar.value >= 0x80, !props.isWhitespace,
                props.generalCategory != .otherPunctuation, props.generalCategory != .openPunctuation,
                props.generalCategory != .closePunctuation, props.generalCategory != .dashPunctuation
            {
                // Other non-ASCII marks (accents etc.) could still identify words.
                out += "x"
            } else {
                out.unicodeScalars.append(scalar)
            }
            count += 1
        }
        return out
    }
}
