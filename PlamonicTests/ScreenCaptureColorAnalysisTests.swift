import CoreGraphics
import XCTest

@testable import Plamonic

/// WindowColorAnalysis on synthetic pixels: the background is the most common color, the text color the most
/// common one that contrasts with it.
final class ScreenCaptureColorAnalysisTests: XCTestCase {
    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    /// A grid filled with `background`, with `paint` deciding other pixels (premultiplied RGBA).
    private func grid(
        width: Int, height: Int, background: RGB, alpha: UInt8 = 255,
        paint: (Int, Int) -> (RGB, UInt8)? = { _, _ in nil }
    ) -> PixelGrid {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (color, a) = paint(x, y) ?? (background, alpha)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(Int(color.r) * Int(a) / 255)
                bytes[i + 1] = UInt8(Int(color.g) * Int(a) / 255)
                bytes[i + 2] = UInt8(Int(color.b) * Int(a) / 255)
                bytes[i + 3] = a
            }
        }
        return PixelGrid(width: width, height: height, bytes: bytes)
    }

    private func assertColor(
        _ color: RGBAColor?, _ expected: RGB, accuracy: Double = 0.01, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color else { return XCTFail("no color", file: file, line: line) }
        XCTAssertEqual(color.red, Double(expected.r) / 255, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(color.green, Double(expected.g) / 255, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(color.blue, Double(expected.b) / 255, accuracy: accuracy, file: file, line: line)
    }

    func testDarkTextOnLightBackgroundWithAntialiasing() {
        // Vertical stems of solid text color, each with a lighter antialiased edge.
        let g = grid(width: 200, height: 40, background: (250, 250, 250)) { x, y in
            guard (10..<30).contains(y) else { return nil }
            switch x % 8 {
            case 0, 1: return ((30, 30, 30), 255)
            case 2: return ((140, 140, 140), 255)
            case 3: return ((200, 200, 200), 255)
            default: return nil
            }
        }
        let colors = WindowColorAnalysis.measure(g, in: CGRect(x: 0, y: 8, width: 200, height: 24), margin: 2)
        assertColor(colors?.background, (250, 250, 250))
        assertColor(colors?.text, (30, 30, 30))
    }

    func testLightTextOnDarkBackground() {
        let g = grid(width: 120, height: 30, background: (19, 19, 19)) { x, y in
            (8..<20).contains(y) && x % 5 == 0 ? ((40, 232, 21), 255) : nil
        }
        let colors = WindowColorAnalysis.measure(g, in: CGRect(x: 0, y: 6, width: 120, height: 16), margin: 1)
        assertColor(colors?.background, (19, 19, 19))
        assertColor(colors?.text, (40, 232, 21))
        XCTAssertLessThan(colors?.background.luminance ?? 1, 0.05)
    }

    func testBackgroundOnlyHasNoTextColor() {
        let g = grid(width: 50, height: 20, background: (43, 45, 49))
        let colors = WindowColorAnalysis.measure(g, in: CGRect(x: 5, y: 5, width: 30, height: 10), margin: 2)
        assertColor(colors?.background, (43, 45, 49))
        XCTAssertNil(colors?.text)
    }

    func testLowContrastSpeckIsNotText() {
        // A slightly different shade (a hover highlight, a gradient) is not the text color.
        let g = grid(width: 60, height: 20, background: (255, 255, 255)) { x, _ in
            x < 20 ? ((235, 235, 235), 255) : nil
        }
        let colors = WindowColorAnalysis.measure(g, in: CGRect(x: 0, y: 0, width: 60, height: 20), margin: 0)
        assertColor(colors?.background, (255, 255, 255))
        XCTAssertNil(colors?.text)
    }

    func testTranslucentPixelsAreNotMeasured() {
        // A vibrancy sidebar: what shows through is not in a single-window capture.
        let g = grid(width: 40, height: 20, background: (200, 200, 200), alpha: 120)
        XCTAssertNil(WindowColorAnalysis.measure(g, in: CGRect(x: 0, y: 0, width: 40, height: 20), margin: 0))
    }

    func testPremultipliedNearlyOpaquePixelsAreUnpremultiplied() {
        let g = grid(width: 40, height: 20, background: (200, 100, 50), alpha: 240)
        let colors = WindowColorAnalysis.measure(g, in: CGRect(x: 0, y: 0, width: 40, height: 20), margin: 0)
        assertColor(colors?.background, (200, 100, 50), accuracy: 0.02)
    }

    func testRectOutsideTheImage() {
        let g = grid(width: 40, height: 20, background: (0, 0, 0))
        XCTAssertNil(WindowColorAnalysis.measure(g, in: CGRect(x: 100, y: 100, width: 20, height: 10), margin: 2))
        // Partly outside: only the inside part is measured.
        let partial = WindowColorAnalysis.measure(g, in: CGRect(x: 30, y: 10, width: 40, height: 30), margin: 2)
        assertColor(partial?.background, (0, 0, 0))
    }

    func testMarginLetsBackgroundWinInDenseText() {
        // Inside the rect, text covers 60% of the pixels; with the surrounding margin the background wins.
        let g = grid(width: 40, height: 40, background: (255, 255, 255)) { x, y in
            (10..<30).contains(x) && (10..<30).contains(y) && x % 5 < 3 ? ((0, 0, 0), 255) : nil
        }
        let colors = WindowColorAnalysis.measure(g, in: CGRect(x: 10, y: 10, width: 20, height: 20), margin: 8)
        assertColor(colors?.background, (255, 255, 255))
        assertColor(colors?.text, (0, 0, 0))
    }

    func testContrastRatio() {
        let black = RGBAColor(red: 0, green: 0, blue: 0)
        let white = RGBAColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(WindowColorAnalysis.contrast(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(WindowColorAnalysis.contrast(white, white), 1, accuracy: 0.0001)
    }
}

/// The sampler gives up on a slow capture instead of holding the overlay's color update.
final class ScreenCaptureTimeBudgetTests: XCTestCase {
    func testReturnsTheResultWhenInTime() async {
        let value = await ScreenColorSampler.withTimeBudget(1, fallback: 0) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testReturnsTheFallbackWhenTheBudgetRunsOut() async {
        let start = Date()
        let value = await ScreenColorSampler.withTimeBudget(0.1, fallback: 0) {
            // Ignores cancellation, like a capture that does not stop.
            usleep(1_000_000)
            return 42
        }
        XCTAssertEqual(value, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    }

    func testReturnsTheFallbackWhenTheCallerIsCancelled() async {
        let task = Task {
            await ScreenColorSampler.withTimeBudget(5, fallback: -1) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return 42
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        task.cancel()
        let value = await task.value
        XCTAssertEqual(value, -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}

/// Calls for one window share captures, at most one per interval.
final class ScreenCaptureCoalescingTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(time: Date, ids: Set<String>)] = []
        func record(_ ids: Set<String>) { lock.withLock { calls.append((Date(), ids)) } }
        var all: [(time: Date, ids: Set<String>)] { lock.withLock { calls } }
    }

    private func sampler(_ recorder: Recorder, interval: CFAbsoluteTime = 0.3, authorized: Bool = true)
        -> ScreenColorSampler
    {
        ScreenColorSampler(captureInterval: interval, authorized: { authorized }) { _, rects in
            recorder.record(Set(rects.keys))
            let colors = SampledColors(background: RGBAColor(red: 1, green: 1, blue: 1), text: nil)
            return rects.mapValues { _ in colors }
        }
    }

    func testCallsWhileWaitingShareOneCapture() async {
        let recorder = Recorder()
        let sampler = sampler(recorder)
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        _ = await sampler.sampleColors(windowID: 7, rects: ["a": rect])
        // Within the interval: both wait for the next capture and get only their own ids back.
        async let b = sampler.sampleColors(windowID: 7, rects: ["b": rect])
        async let c = sampler.sampleColors(windowID: 7, rects: ["c": rect])
        let (rb, rc) = await (b, c)
        XCTAssertEqual(Set(rb.keys), ["b"])
        XCTAssertEqual(Set(rc.keys), ["c"])
        let calls = recorder.all
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.ids, ["b", "c"])
        if calls.count == 2 {
            XCTAssertGreaterThan(calls[1].time.timeIntervalSince(calls[0].time), 0.25)
        }
    }

    func testWindowsAreIndependent() async {
        let recorder = Recorder()
        let sampler = sampler(recorder, interval: 5)
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let start = Date()
        _ = await sampler.sampleColors(windowID: 1, rects: ["a": rect])
        _ = await sampler.sampleColors(windowID: 2, rects: ["b": rect])
        XCTAssertEqual(recorder.all.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testNothingWithoutPermission() async {
        let recorder = Recorder()
        let sampler = sampler(recorder, authorized: false)
        let result = await sampler.sampleColors(windowID: 1, rects: ["a": CGRect(x: 0, y: 0, width: 5, height: 5)])
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(recorder.all.isEmpty)
        XCTAssertFalse(sampler.isAuthorized)
    }
}
