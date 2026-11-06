import AppKit
import XCTest

@testable import Plamonic

final class OverlayTextFitterTests: XCTestCase {
    /// Monospaced model: every character is `fontSize` wide, lines are 1.25 × fontSize, wrapping by character.
    private static func gridMeasure(_ text: String, _ fontSize: CGFloat, _ maxWidth: CGFloat) -> CGSize {
        let count = text.count
        guard count > 0 else { return .zero }
        let perLine = max(1, Int((maxWidth / fontSize).rounded(.down)))
        let lines = (count + perLine - 1) / perLine
        return CGSize(width: CGFloat(min(count, perLine)) * fontSize, height: ceil(CGFloat(lines) * fontSize * 1.25))
    }

    private func linearSearch(_ text: String, box: CGSize, min: CGFloat, max: CGFloat, step: CGFloat) -> CGFloat? {
        var best: CGFloat?
        var size = min
        while size <= max + 0.0001 {
            let s = Self.gridMeasure(text, size, box.width)
            if s.width <= box.width + 0.5, s.height <= box.height { best = size }
            size += step
        }
        return best
    }

    func testBinarySearchMatchesLinearScan() {
        let fitter = TextFitter(measure: Self.gridMeasure)
        let texts = ["あ", "設定", "翻訳されたテキスト", String(repeating: "長", count: 40)]
        for text in texts {
            for width in stride(from: 20.0, through: 300.0, by: 37.0) {
                for height in stride(from: 10.0, through: 120.0, by: 13.0) {
                    let box = CGSize(width: width, height: height)
                    let fit = fitter.fit(text, in: box, minFontSize: 9, maxFontSize: 16)
                    let expected = linearSearch(text, box: box, min: 9, max: 16, step: 0.5)
                    if let expected {
                        XCTAssertTrue(fit.fits, "\(text.count) chars in \(box)")
                        XCTAssertEqual(fit.fontSize, expected, "\(text.count) chars in \(box)")
                    } else {
                        XCTAssertFalse(fit.fits)
                        XCTAssertEqual(fit.fontSize, 9)
                    }
                }
            }
        }
    }

    func testReturnsMaxWhenEverythingFits() {
        let fitter = TextFitter(measure: Self.gridMeasure)
        let fit = fitter.fit("短い", in: CGSize(width: 500, height: 100), minFontSize: 9, maxFontSize: 16)
        XCTAssertEqual(fit, TextFit(fontSize: 16, textSize: CGSize(width: 32, height: 20), fits: true))
    }

    func testReportsOverflowAtMinimum() {
        let fitter = TextFitter(measure: Self.gridMeasure)
        let fit = fitter.fit(String(repeating: "字", count: 100), in: CGSize(width: 90, height: 20), minFontSize: 9, maxFontSize: 16)
        XCTAssertFalse(fit.fits)
        XCTAssertEqual(fit.fontSize, 9)
        // 10 per line -> 10 lines of 11.25pt.
        XCTAssertEqual(fit.textSize.height, ceil(10 * 9 * 1.25))
    }

    func testFittedTextIsNeverTallerThanTheBox() {
        let fitter = TextFitter(measure: Self.gridMeasure)
        // 10 per line -> 2 lines of 11.25pt, measured as 23pt: a 22.5pt box cannot hold them.
        let text = String(repeating: "字", count: 20)
        XCTAssertFalse(fitter.fit(text, in: CGSize(width: 90, height: 22.5), minFontSize: 9, maxFontSize: 9).fits)
        XCTAssertTrue(fitter.fit(text, in: CGSize(width: 90, height: 23), minFontSize: 9, maxFontSize: 9).fits)
        for height in stride(from: 10.0, through: 60.0, by: 0.1) {
            let fit = fitter.fit(text, in: CGSize(width: 90, height: height), minFontSize: 9, maxFontSize: 16)
            if fit.fits { XCTAssertLessThanOrEqual(fit.textSize.height, height) }
        }
    }

    func testSwappedOrEqualBounds() {
        let fitter = TextFitter(measure: Self.gridMeasure)
        XCTAssertEqual(fitter.fit("字", in: CGSize(width: 100, height: 100), minFontSize: 12, maxFontSize: 12).fontSize, 12)
        XCTAssertEqual(fitter.fit("字", in: CGSize(width: 100, height: 100), minFontSize: 16, maxFontSize: 9).fontSize, 16)
    }

    func testEmptyText() {
        let fitter = TextFitter(measure: Self.gridMeasure)
        let fit = fitter.fit("", in: CGSize(width: 10, height: 10), minFontSize: 9, maxFontSize: 16)
        XCTAssertTrue(fit.fits)
        XCTAssertEqual(fit.textSize, .zero)
    }

    func testResultsAreCached() {
        let fitter = TextFitter(measure: Self.gridMeasure)
        _ = fitter.fit("キャッシュ", in: CGSize(width: 50, height: 40), minFontSize: 9, maxFontSize: 16)
        let count = fitter.measureCount
        XCTAssertGreaterThan(count, 0)
        for _ in 0..<10 {
            _ = fitter.fit("キャッシュ", in: CGSize(width: 50, height: 40), minFontSize: 9, maxFontSize: 16)
            // A box a fraction larger reuses the quantized result.
            _ = fitter.fit("キャッシュ", in: CGSize(width: 50.2, height: 40.3), minFontSize: 9, maxFontSize: 16)
        }
        XCTAssertEqual(fitter.measureCount, count)
        // Bounded search: about log2((16 - 9) / 0.5) + 2 measurements.
        XCTAssertLessThanOrEqual(count, 7)
    }

    // MARK: - Real text system

    func testJapaneseWrapsWithoutSpaces() {
        let fitter = TextFitter()
        let text = "これはスペースを含まない日本語の文章で、枠の幅に合わせて文字単位で折り返されます。"
        let box = CGSize(width: 120, height: 200)
        let fit = fitter.fit(text, in: box, minFontSize: 9, maxFontSize: 16)
        XCTAssertTrue(fit.fits)
        XCTAssertLessThanOrEqual(fit.textSize.width, box.width)
        XCTAssertGreaterThan(fit.textSize.height, fitter.lineHeight(fontSize: fit.fontSize) * 2)
    }

    func testLargestSizeIsMaximal() {
        let fitter = TextFitter()
        let text = "翻訳結果がこの枠にちょうど収まる最大の文字サイズを探します"
        let box = CGSize(width: 180, height: 40)
        let fit = fitter.fit(text, in: box, minFontSize: 9, maxFontSize: 16)
        XCTAssertTrue(fit.fits)
        XCTAssertLessThan(fit.fontSize, 16)
        let measured = TextFitter.measureSystemText(text, fontSize: fit.fontSize, maxWidth: box.width)
        XCTAssertLessThanOrEqual(measured.height, box.height)
        let bigger = TextFitter.measureSystemText(text, fontSize: fit.fontSize + 0.5, maxWidth: box.width)
        XCTAssertGreaterThan(bigger.height, box.height)
    }

    func testLongWordBreaksByCharacter() {
        let measured = TextFitter.measureSystemText(
            "Supercalifragilisticexpialidocious_with_no_spaces_at_all", fontSize: 13, maxWidth: 80)
        XCTAssertLessThanOrEqual(measured.width, 80)
        XCTAssertGreaterThan(measured.height, 40)
    }

    func testSingleLineLabelFitsFrameHeight() {
        let fitter = TextFitter()
        // A 17pt-high single-line label: the translation must not be taller than the frame.
        let fit = fitter.fit("設定", in: CGSize(width: 60, height: 17), minFontSize: 9, maxFontSize: 16)
        XCTAssertTrue(fit.fits)
        XCTAssertLessThanOrEqual(fit.textSize.height, 17)
        XCTAssertGreaterThanOrEqual(fit.fontSize, 12)
    }
}
