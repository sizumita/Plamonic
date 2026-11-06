import Foundation
import XCTest

@testable import PlamoKit

final class TokenizerTests: XCTestCase {
    private static var cached: PlamoTokenizer?

    private func tokenizer() throws -> PlamoTokenizer {
        if let t = Self.cached { return t }
        guard let dir = TestModels.directory(.b0_8) ?? TestModels.directory(.b2) else {
            throw XCTSkip("no PLaMo model installed")
        }
        let t = try PlamoTokenizer(directory: dir)
        Self.cached = t
        return t
    }

    func testReferenceTokenizerCases() throws {
        let tok = try tokenizer()
        let ref = try XCTUnwrap(ReferenceFile.load("reference"))
        XCTAssertFalse(ref.tokenizer.isEmpty)
        for c in ref.tokenizer {
            XCTAssertEqual(tok.encode(c.text), c.ids, "encode \(scalars(c.text))")
            XCTAssertEqual(scalars(tok.decode(c.ids)), scalars(c.decoded), "decode \(c.ids)")
        }
    }

    func testReferencePromptIDs() throws {
        let tok = try tokenizer()
        let ref = try XCTUnwrap(ReferenceFile.load("reference"))
        for c in ref.cases {
            XCTAssertEqual(tok.encode(c.prompt), c.promptIDs)
        }
    }

    func testRandomizedCasesFromPython() throws {
        // Optional larger corpus produced by the HF tokenizer (Fixtures/tokenizer-cases.json).
        guard let url = Bundle.module.url(forResource: "tokenizer-cases", withExtension: "json", subdirectory: "Fixtures")
        else { throw XCTSkip("no tokenizer-cases.json") }
        let tok = try tokenizer()
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        var mismatches = 0
        for c in cases {
            let text = c["text"] as! String
            let ids = (c["ids"] as! [NSNumber]).map(\.intValue)
            if tok.encode(text) != ids { mismatches += 1 }
            if scalars(tok.decode(ids)) != scalars(c["decoded"] as! String) { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "of \(cases.count) cases")
    }

    func testSpecialTokensAndBoundaries() throws {
        let tok = try tokenizer()
        XCTAssertEqual(tok.encode("<|plamo:bos|>"), [PlamoTokenizer.bosTokenID])
        XCTAssertEqual(tok.encode("<|plamo:tag|>"), [PlamoTokenizer.tagTokenID])
        XCTAssertEqual(tok.encode(""), [])
        // The internal boundary character never produces a token.
        XCTAssertEqual(tok.encode("\u{EE00}"), [])
        XCTAssertEqual(tok.decode(tok.encode("a\u{EE00}b")), "ab")
    }

    func testBoundaryRegexes() throws {
        let tok = try tokenizer()
        let b = PlamoTokenizer.boundaryChar
        func run(_ s: String) -> [UInt32] {
            tok.insertRunBoundaries(tok.insertSpecialTokenBoundaries(s.unicodeScalars.map(\.value)))
        }
        let a = UInt32(0x61), sp = UInt32(0x20), nl = UInt32(0x0A)
        XCTAssertEqual(run("aaaa"), [b, a, a, a, a, b])
        XCTAssertEqual(run("aaa"), [a, a, a])
        XCTAssertEqual(run("  "), [b, sp, sp, b])
        XCTAssertEqual(run(" "), [sp])
        XCTAssertEqual(run("\n\n\n\n"), [nl, nl, nl, nl])  // "." does not match newline
        let special = "<|plamo:x|>".unicodeScalars.map(\.value)
        XCTAssertEqual(run("<|plamo:x|>"), [b] + special + [b])
        XCTAssertEqual(run("<|plamo:a b|>"), "<|plamo:a b|>".unicodeScalars.map(\.value))
        let long = "<|plamo:" + String(repeating: "y", count: 65) + "|>"
        XCTAssertFalse(run(long).prefix(1).contains(b))
    }

    func testDecodeByteFallbackAndStreaming() throws {
        let tok = try tokenizer()
        let text = "emoji 🚀🎉 and 👨‍👩‍👧 done"
        let ids = tok.encode(text)
        XCTAssertEqual(scalars(tok.decode(ids)), scalars(text))

        var decoder = tok.makeStreamingDecoder()
        var pieces = [String]()
        for id in ids {
            let chunk = decoder.append(id)
            // every emitted chunk is valid text on its own
            XCTAssertFalse(chunk.unicodeScalars.contains("\u{FFFD}"))
            pieces.append(chunk)
        }
        decoder.finish()
        XCTAssertEqual(scalars(pieces.joined()), scalars(text))
        XCTAssertEqual(scalars(decoder.text), scalars(text))
    }

    func testStreamingDecoderHoldsIncompleteSequence() {
        XCTAssertEqual(PlamoStreamingDecoder.completePrefixLength([0x61, 0xF0, 0x9F]), 1)
        XCTAssertEqual(PlamoStreamingDecoder.completePrefixLength([0xF0, 0x9F, 0x9A, 0x80]), 4)
        XCTAssertEqual(PlamoStreamingDecoder.completePrefixLength([0xE3, 0x81]), 0)
        XCTAssertEqual(PlamoStreamingDecoder.completePrefixLength([0x61, 0x62]), 2)
    }

    func testScoreOutOfInt32RangeThrows() {
        // A placeholder at id 0, the 256 byte-fallback tokens every vocabulary needs, one ordinary token.
        func rows(score: Double) -> [VocabRow] {
            let bytes = (0 ..< 256).map { b in
                VocabRow(scalars: String(format: "<0x%02X>", b).unicodeScalars.map(\.value), score: 0, isByte: true)
            }
            let unknown = VocabRow(scalars: Array("<unk>".unicodeScalars.map(\.value)), score: 0, isByte: false)
            return [unknown] + bytes + [VocabRow(scalars: [0x61], score: score, isByte: false)]
        }
        XCTAssertNoThrow(
            try PlamoTokenizer(rows: rows(score: -5), breakAroundConsecutiveSpaces: nil, breakAroundRepeatedChars: nil))
        for score in [1e6, -1e6] {
            XCTAssertThrowsError(
                try PlamoTokenizer(rows: rows(score: score), breakAroundConsecutiveSpaces: nil, breakAroundRepeatedChars: nil)
            ) { error in
                guard case PlamoTokenizerError.invalidVocabulary = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testLoadTime() throws {
        guard let dir = TestModels.directory(.b0_8) ?? TestModels.directory(.b2) else {
            throw XCTSkip("no PLaMo model installed")
        }
        let start = Date()
        let tok = try PlamoTokenizer(directory: dir)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(tok.vocabSize, 107_520)
        // Release builds load in about 0.1 s; Debug builds are several times slower.
        XCTAssertLessThan(elapsed, 3.0)
        print("tokenizer load: \(Int(elapsed * 1000)) ms")
    }
}
