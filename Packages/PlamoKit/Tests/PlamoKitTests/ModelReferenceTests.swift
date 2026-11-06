import Foundation
import MLX
import XCTest

@testable import PlamoKit

/// Compares the MLX port with Python mlx-lm reference outputs. Skips when the model is not installed.
class Model0_8BReferenceTests: XCTestCase {
    class var variant: PlamoModelVariant { .b0_8 }
    class var referenceName: String { "reference" }

    private static var generators: [PlamoModelVariant: PlamoGenerator] = [:]

    func generator() throws -> PlamoGenerator {
        let variant = Self.variant
        if let g = Self.generators[variant] { return g }
        guard let dir = TestModels.directory(variant) else {
            throw XCTSkip("PLaMo \(variant.displayName) is not installed")
        }
        let g = try PlamoGenerator(directory: dir)
        Self.generators[variant] = g
        return g
    }

    func reference() throws -> ReferenceFile {
        guard let ref = try ReferenceFile.load(Self.referenceName) else {
            throw XCTSkip("no \(Self.referenceName).json fixture")
        }
        return ref
    }

    func testPromptIDs() throws {
        let gen = try generator()
        for c in try reference().cases {
            XCTAssertEqual(gen.tokenizer.encode(try PlamoPromptBuilder.prompt(for: c.request)), c.promptIDs)
        }
    }

    func testTop5Logits() throws {
        let gen = try generator()
        var maxDiff = 0.0
        defer { print("\(Self.variant.displayName) \(Self.referenceName): max top-5 logit difference \(maxDiff)") }
        for (n, c) in try reference().cases.enumerated() {
            let logits = gen.promptLogits(c.promptIDs).asArray(Float.self)
            for (id, expected) in zip(c.top5, c.top5Logits) { maxDiff = max(maxDiff, abs(Double(logits[id]) - expected)) }
            let order = logits.indices.sorted { logits[$0] != logits[$1] ? logits[$0] > logits[$1] : $0 < $1 }
            let top = Array(order.prefix(5))
            XCTAssertEqual(top[0], c.top5[0], "case \(n) top-1")
            XCTAssertEqual(Set(top), Set(c.top5), "case \(n) top-5 \(top) vs \(c.top5)")
            for (id, expected) in zip(c.top5, c.top5Logits) {
                XCTAssertEqual(Double(logits[id]), expected, accuracy: 0.1, "case \(n) logit of \(id)")
            }
        }
    }

    func testGreedyOutputsFreshCache() throws {
        let gen = try generator()
        gen.reusePromptPrefix = false
        defer { gen.reusePromptPrefix = true }
        for (n, c) in try reference().cases.enumerated() {
            gen.resetCache()
            let out = try gen.generate(prompt: c.promptIDs, maxNewTokens: 256)
            XCTAssertEqual(scalars(out.text), scalars(c.output), "case \(n): \(out.text)")
            XCTAssertFalse(out.hitTokenLimit)
        }
    }

    func testGreedyOutputsWithPrefixReuse() throws {
        let gen = try generator()
        gen.resetCache()
        gen.reusePromptPrefix = true
        var reusedTotal = 0
        for (n, c) in try reference().cases.enumerated() {
            let out = try gen.generate(prompt: c.promptIDs, maxNewTokens: 256)
            reusedTotal += out.reusedPromptTokens
            XCTAssertEqual(scalars(out.text), scalars(c.output), "case \(n): \(out.text)")
        }
        // All prompts share "<bos><tag>dataset<msg>translation<tag>..." so later ones reuse the cache.
        XCTAssertGreaterThan(reusedTotal, 0)

        // Asking the same prompt twice reuses everything but the last token.
        let c = try reference().cases[0]
        let first = try gen.generate(prompt: c.promptIDs, maxNewTokens: 256)
        let again = try gen.generate(prompt: c.promptIDs, maxNewTokens: 256)
        XCTAssertEqual(again.reusedPromptTokens, c.promptIDs.count - 1)
        XCTAssertEqual(scalars(first.text), scalars(again.text))
    }

    func testTokenLimitAndStreaming() throws {
        let gen = try generator()
        let c = try reference().cases[0]
        var partials = [String]()
        gen.partialInterval = 0
        defer { gen.partialInterval = 0.05 }
        let out = try gen.generate(prompt: c.promptIDs, maxNewTokens: 3) { partials.append($0) }
        XCTAssertTrue(out.hitTokenLimit)
        XCTAssertEqual(out.tokens.count, 3)
        XCTAssertFalse(partials.isEmpty)
        // partial texts only grow
        for (a, b) in zip(partials, partials.dropFirst()) { XCTAssertTrue(b.hasPrefix(a)) }
        XCTAssertTrue(scalars(c.output).starts(with: scalars(out.text)))
    }
}

final class Model2BReferenceTests: Model0_8BReferenceTests {
    override class var variant: PlamoModelVariant { .b2 }
    override class var referenceName: String { "reference-2b" }
}

final class WindowMaskTests: XCTestCase {
    func testWindowedCausalMaskMatchesMLXLM() {
        // create_causal_mask(N=3, offset=4, window_size=3)
        let mask = Plamo3Model.windowedCausalMask(length: 3, offset: 4, window: 3)
        XCTAssertEqual(mask.shape, [3, 7])
        let values = mask.asArray(Bool.self)
        let expected: [[Bool]] = [
            [false, false, true, true, true, false, false],
            [false, false, false, true, true, true, false],
            [false, false, false, false, true, true, true],
        ]
        XCTAssertEqual(values, expected.flatMap { $0 })
    }
}

/// Prompts of 1.5k and 2.9k tokens: the second one exercises the sliding-window mask.
class LongContext0_8BTests: Model0_8BReferenceTests {
    override class var referenceName: String { "reference-long" }

    func testGreedyOutputsWithPythonChunking() throws {
        let gen = try generator()
        gen.reusePromptPrefix = false
        // mlx-lm prefills in 2048-token steps
        gen.prefillChunkSize = 2048
        defer {
            gen.reusePromptPrefix = true
            gen.prefillChunkSize = 512
        }
        for (n, c) in try reference().cases.enumerated() {
            gen.resetCache()
            let out = try gen.generate(prompt: c.promptIDs, maxNewTokens: 128)
            XCTAssertEqual(scalars(out.text), scalars(c.output), "case \(n): \(out.text)")
        }
    }

    override func testGreedyOutputsFreshCache() throws {
        let gen = try generator()
        gen.reusePromptPrefix = false
        defer { gen.reusePromptPrefix = true }
        for (n, c) in try reference().cases.enumerated() {
            gen.resetCache()
            let out = try gen.generate(prompt: c.promptIDs, maxNewTokens: 128)
            XCTAssertEqual(scalars(out.text), scalars(c.output), "case \(n): \(out.text)")
        }
    }

    override func testGreedyOutputsWithPrefixReuse() throws {
        let gen = try generator()
        gen.resetCache()
        for (n, c) in try reference().cases.enumerated() {
            let out = try gen.generate(prompt: c.promptIDs, maxNewTokens: 128)
            XCTAssertEqual(scalars(out.text), scalars(c.output), "case \(n): \(out.text)")
        }
    }

    override func testPromptIDs() throws {
        let gen = try generator()
        for c in try reference().cases {
            XCTAssertEqual(gen.tokenizer.encode(c.prompt), c.promptIDs)
            XCTAssertEqual(try PlamoPromptBuilder.prompt(for: c.request), c.prompt)
        }
        XCTAssertGreaterThan(try reference().cases.map(\.promptIDs.count).max() ?? 0, 2048)
    }
}

final class LongContext2BTests: LongContext0_8BTests {
    override class var variant: PlamoModelVariant { .b2 }
    override class var referenceName: String { "reference-long-2b" }
}
