import XCTest
@testable import Plamonic

final class PlaceholderTests: XCTestCase {
    func testSettingsRoundTrip() throws {
        var doc = SettingsDocument()
        doc.global.draftModel = nil
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(SettingsDocument.self, from: data)
        XCTAssertEqual(back, doc)
        let empty = try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.global.draftModel, .b0_8)
    }
}
