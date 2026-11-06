import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// Stops every color capture while a password is being typed (DESIGN §4.1). Any thread.
final class ScreenCaptureGate: @unchecked Sendable {
    static let shared = ScreenCaptureGate()
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }
}

/// Measures the target window's own colors with ScreenCaptureKit (Screen Recording permission), so the overlay
/// can take the app's background and text colors instead of the theme's.
///
/// Only the target window is captured (a desktop-independent window filter, so Plamonic's panels above it never
/// show up), at a reduced scale. The pixels are reduced to a background and a text color per rect and dropped at
/// once: no image is kept, written or sent anywhere.
///
/// A window is captured at most about once a second: calls that come sooner wait for the next capture and share
/// it (each capture costs CPU and makes macOS show its screen-recording indicator).
final class ScreenColorSampler: ScreenColorSampling, @unchecked Sendable {
    /// A measurement that takes longer is abandoned; the overlay keeps its theme colors. A capture usually takes
    /// 50–250 ms, but several times that while a model is loading.
    static let timeBudget: TimeInterval = 1.5
    /// The window list is fetched at most about once a second (it costs tens of milliseconds).
    static let windowListLifetime: CFAbsoluteTime = 1.0
    /// Captured pixels at most. A window is captured at one pixel per point or smaller: colors do not need
    /// Retina detail, and a smaller image is faster to capture and to scan.
    static let maxPixels: Double = 2_000_000
    /// Extra points around each rect, so the background dominates even where text is dense.
    static let margin: Double = 2
    /// Captures still running (some may have outlived their budget). More are not started meanwhile, so a
    /// stuck capture server cannot pile up work.
    static let maxInFlight = 2
    /// Least time between two captures of the same window.
    static let minimumCaptureInterval: CFAbsoluteTime = 1.0
    /// How long a permission answer is reused. `CGPreflightScreenCaptureAccess` takes 25–50 ms, too slow for
    /// every overlay update on the main thread, so `isAuthorized` returns the stored answer and refreshes it in
    /// the background once it is older than this.
    static let permissionLifetime: CFAbsoluteTime = 5

    /// Rects waiting for the next capture of one window, and that capture.
    private final class Batch: @unchecked Sendable {
        var rects: [String: CGRect] = [:]
        var task: Task<[String: SampledColors], Never>?
    }

    private let lock = NSLock()
    // Guarded by `lock` (also each Batch's fields).
    private var windows: [CGWindowID: SCWindow] = [:]
    private var windowsFetchedAt: CFAbsoluteTime = -.infinity
    private var inFlight = 0
    private var waiting: [CGWindowID: Batch] = [:]
    private var lastCapture: [CGWindowID: CFAbsoluteTime] = [:]
    private var permission: (authorized: Bool, checkedAt: CFAbsoluteTime)?
    private var permissionRefreshing = false

    private let captureInterval: CFAbsoluteTime
    private let gate: ScreenCaptureGate
    private let authorizedCheck: @Sendable () -> Bool
    private let measureOverride: (@Sendable (CGWindowID, [String: CGRect]) async -> [String: SampledColors])?
    private let log = Logger(subsystem: "io.smdr.Plamonic", category: "ScreenColor")

    init() {
        captureInterval = Self.minimumCaptureInterval
        gate = .shared
        authorizedCheck = { CGPreflightScreenCaptureAccess() }
        measureOverride = nil
    }

    /// Tests: replaces the permission check and the capture itself.
    init(
        captureInterval: CFAbsoluteTime, gate: ScreenCaptureGate = .shared,
        authorized: @escaping @Sendable () -> Bool,
        measure: @escaping @Sendable (CGWindowID, [String: CGRect]) async -> [String: SampledColors]
    ) {
        self.captureInterval = captureInterval
        self.gate = gate
        authorizedCheck = authorized
        measureOverride = measure
    }

    /// The stored answer (checked at once only the first time); a stale one is refreshed off the main thread.
    var isAuthorized: Bool {
        let stored: (authorized: Bool, stale: Bool)? = lock.withLock {
            guard let permission else { return nil }
            let stale = CFAbsoluteTimeGetCurrent() - permission.checkedAt > Self.permissionLifetime
            if stale, !permissionRefreshing {
                permissionRefreshing = true
                return (permission.authorized, true)
            }
            return (permission.authorized, false)
        }
        guard let stored else { return refreshPermission() }
        if stored.stale {
            DispatchQueue.global(qos: .utility).async { [self] in
                refreshPermission()
                lock.withLock { permissionRefreshing = false }
            }
        }
        return stored.authorized
    }

    /// Checks the permission now and stores the answer (after the user may have changed it: the permission
    /// page, the request button, Plamonic coming to the front).
    @discardableResult
    func refreshPermission() -> Bool {
        let authorized = authorizedCheck()
        lock.withLock { permission = (authorized, CFAbsoluteTimeGetCurrent()) }
        return authorized
    }

    func sampleColors(windowID: UInt32, rects: [String: CGRect]) async -> [String: SampledColors] {
        // Without the permission, asking ScreenCaptureKit for content would put up the system prompt.
        guard !rects.isEmpty, windowID != 0, !gate.isPaused, authorizedCheck() else { return [:] }
        let id = CGWindowID(windowID)
        let task: Task<[String: SampledColors], Never> = lock.withLock {
            if let batch = waiting[id], let task = batch.task {
                // The newest frame of an item wins.
                batch.rects.merge(rects) { _, new in new }
                return task
            }
            let now = CFAbsoluteTimeGetCurrent()
            let delay = max(0, (lastCapture[id] ?? -.infinity) + captureInterval - now)
            let batch = Batch()
            batch.rects = rects
            let task = Task { [self] in await capture(batch, window: id, after: delay) }
            batch.task = task
            waiting[id] = batch
            return task
        }
        let measured = await task.value
        return measured.filter { rects[$0.key] != nil }
    }

    /// Waits for the window's next capture slot, then measures every rect gathered in the batch by then.
    private func capture(_ batch: Batch, window id: CGWindowID, after delay: CFAbsoluteTime) async
        -> [String: SampledColors]
    {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        // A password may have begun to be typed while this capture waited for its slot.
        let paused = gate.isPaused
        let rects: [String: CGRect]? = lock.withLock {
            if waiting[id] === batch { waiting[id] = nil }
            guard !paused, inFlight < Self.maxInFlight else { return nil }
            inFlight += 1
            let now = CFAbsoluteTimeGetCurrent()
            lastCapture = lastCapture.filter { now - $0.value < 60 }
            lastCapture[id] = now
            return batch.rects
        }
        guard let rects else { return [:] }
        return await Self.withTimeBudget(Self.timeBudget, fallback: [:]) { [self] in
            defer { lock.withLock { inFlight -= 1 } }
            if let measureOverride { return await measureOverride(id, rects) }
            return await measure(windowID: id, rects: rects)
        }
    }

    // MARK: - Capture

    private func measure(windowID: CGWindowID, rects: [String: CGRect]) async -> [String: SampledColors] {
        // The current frame (the cached SCWindow's frame may be up to a second old).
        guard let frame = Self.windowBounds(windowID), frame.width >= 1, frame.height >= 1 else { return [:] }
        let wanted = rects.filter { $0.value.intersects(frame) }
        guard !wanted.isEmpty, let window = await shareableWindow(windowID), !Task.isCancelled else { return [:] }

        guard !gate.isPaused else { return [:] }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, (Self.maxPixels / Double(frame.width * frame.height)).squareRoot())
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            // Most often the window closed since the list was fetched.
            lock.withLock { windowsFetchedAt = -.infinity }
            log.debug("capture failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        guard !Task.isCancelled, let grid = PixelGrid(image: image) else { return [:] }
        let sx = Double(grid.width) / Double(frame.width)
        let sy = Double(grid.height) / Double(frame.height)
        var result: [String: SampledColors] = [:]
        for (id, rect) in wanted {
            let local = CGRect(
                x: (rect.minX - frame.minX) * sx, y: (rect.minY - frame.minY) * sy,
                width: rect.width * sx, height: rect.height * sy)
            if let colors = WindowColorAnalysis.measure(grid, in: local, margin: Self.margin * sx) {
                result[id] = colors
            }
        }
        return result
    }

    /// The SCWindow for a window ID, from a window list kept for about a second.
    private func shareableWindow(_ id: CGWindowID) async -> SCWindow? {
        let now = CFAbsoluteTimeGetCurrent()
        let (cached, age) = lock.withLock { (windows[id], now - windowsFetchedAt) }
        if age < Self.windowListLifetime {
            if let cached { return cached }
            // Not in a list fetched a moment ago: the window is most likely gone; do not fetch again right away.
            if age < 0.25 { return nil }
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return nil }
        var map: [CGWindowID: SCWindow] = [:]
        for window in content.windows { map[window.windowID] = window }
        lock.withLock {
            windows = map
            windowsFetchedAt = CFAbsoluteTimeGetCurrent()
        }
        return map[id]
    }

    /// The window's frame in global top-left coordinates (the same space as AX), from the window server.
    private static func windowBounds(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
            let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
            let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// Runs `body`, but returns `fallback` once `seconds` passed or the caller was cancelled, without waiting
    /// for `body` (a capture does not always stop when its task is cancelled).
    static func withTimeBudget<T: Sendable>(
        _ seconds: TimeInterval, fallback: T, _ body: @escaping @Sendable () async -> T
    ) async -> T {
        let gate = OnceGate<T>()
        let work = Task { gate.finish(await body()) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.wait(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                    gate.finish(fallback)
                    work.cancel()
                }
            }
        } onCancel: {
            gate.finish(fallback)
            work.cancel()
        }
    }
}

/// Resumes one continuation with the first value it is given.
private final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var value: T?
    private var finished = false

    func wait(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value {
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: T) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            value = result
            lock.unlock()
        }
    }
}

/// 8-bit RGBA pixels (sRGB, premultiplied alpha), row by row without padding.
struct PixelGrid {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Converts the image to sRGB RGBA bytes.
    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// Finds the background and the text color inside a rect of window pixels.
enum WindowColorAnalysis {
    /// Pixels more transparent than this are skipped: a translucent (vibrancy) window shows whatever is behind
    /// it, which a single-window capture does not contain.
    static let minimumAlpha = 217  // 85%
    /// Below this share of usable pixels the rect is not measured.
    static let minimumOpaqueShare = 0.5
    /// WCAG contrast ratio a color needs against the background to count as text.
    static let minimumTextContrast = 2.0

    /// `rect` is in pixels, top-left origin. The background is the most frequent color (4 bits per channel)
    /// in the rect plus `margin`; the text color is the most frequent color with enough contrast to it.
    /// Each color is the mean of the pixels in its bucket, so it is exact for flat colors.
    static func measure(_ grid: PixelGrid, in rect: CGRect, margin: Double) -> SampledColors? {
        let bounds = CGRect(x: 0, y: 0, width: grid.width, height: grid.height)
        let area = rect.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds)
        guard !area.isNull, area.width >= 2, area.height >= 2 else { return nil }
        let x0 = Int(area.minX)
        let x1 = Int(area.maxX)
        let y0 = Int(area.minY)
        let y1 = Int(area.maxY)

        var counts = [Int](repeating: 0, count: 4096)
        var sums = [Int](repeating: 0, count: 4096 * 3)
        var used = 0
        grid.bytes.withUnsafeBufferPointer { pixels in
            for y in y0..<y1 {
                var i = (y * grid.width + x0) * 4
                for _ in x0..<x1 {
                    let a = Int(pixels[i + 3])
                    if a >= minimumAlpha {
                        var r = Int(pixels[i])
                        var g = Int(pixels[i + 1])
                        var b = Int(pixels[i + 2])
                        if a < 255 {
                            r = min(255, r * 255 / a)
                            g = min(255, g * 255 / a)
                            b = min(255, b * 255 / a)
                        }
                        let bucket = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                        counts[bucket] += 1
                        sums[bucket * 3] += r
                        sums[bucket * 3 + 1] += g
                        sums[bucket * 3 + 2] += b
                        used += 1
                    }
                    i += 4
                }
            }
        }
        let total = (x1 - x0) * (y1 - y0)
        guard used > 0, Double(used) >= Double(total) * minimumOpaqueShare else { return nil }

        func mean(_ bucket: Int) -> RGBAColor {
            let n = Double(counts[bucket]) * 255
            return RGBAColor(
                red: Double(sums[bucket * 3]) / n, green: Double(sums[bucket * 3 + 1]) / n,
                blue: Double(sums[bucket * 3 + 2]) / n)
        }

        var backgroundBucket = 0
        for bucket in 1..<4096 where counts[bucket] > counts[backgroundBucket] { backgroundBucket = bucket }
        let background = mean(backgroundBucket)

        // Antialiased edges spread over many buckets; the solid strokes of the glyphs gather in one.
        let minimumCount = max(3, used / 200)
        var text: (count: Int, contrast: Double, color: RGBAColor)?
        for bucket in 0..<4096 where bucket != backgroundBucket && counts[bucket] >= minimumCount {
            let color = mean(bucket)
            let ratio = contrast(color, background)
            guard ratio >= minimumTextContrast else { continue }
            if let best = text,
                best.count > counts[bucket] || (best.count == counts[bucket] && best.contrast >= ratio)
            {
                continue
            }
            text = (counts[bucket], ratio, color)
        }
        return SampledColors(background: background, text: text?.color)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let la = a.luminance
        let lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
