import XCTest

@testable import Plamonic

/// Partial scans keep the previous overlay for a few scans in a row, counting only those that lost texts.
final class SessionPartialScanTests: XCTestCase {
    /// Runs scans through the policy; each is (truncated, segments). Returns which ones were applied.
    private func applied(_ scans: [(Bool, Int)], shown: Int, scrolled: Bool = false) -> [Bool] {
        var streak = 0
        var count = shown
        return scans.map { truncated, segments in
            let fewer = segments < count
            if PartialScanPolicy.keepsPrevious(truncated: truncated, fewer: fewer, streak: streak, scrolled: scrolled) {
                streak += 1
                return false
            }
            streak = PartialScanPolicy.streak(afterApplying: truncated, fewer: fewer, streak: streak)
            count = segments
            return true
        }
    }

    func testCompleteScansAlwaysApply() {
        XCTAssertEqual(applied([(false, 12), (false, 3), (false, 0)], shown: 12), [true, true, true])
    }

    func testPartialScansThatLoseTextsAreKeptThreeTimes() {
        XCTAssertEqual(
            applied([(true, 2), (true, 0), (true, 5), (true, 1)], shown: 12), [false, false, false, true])
    }

    func testPartialScanWithAllTheTextsResetsTheStreak() {
        // Measured on a loaded machine (Claude): kept, applied with everything, kept, then an empty partial scan.
        // The empty one used to be applied (the applied scan counted toward the streak), dropping every text.
        XCTAssertEqual(
            applied([(true, 2), (true, 12), (true, 0), (true, 0), (false, 12)], shown: 12),
            [false, true, false, false, true])
    }

    func testAfterAScrollThePartialScanIsUsedAtOnce() {
        XCTAssertEqual(applied([(true, 2)], shown: 12, scrolled: true), [true])
    }
}
