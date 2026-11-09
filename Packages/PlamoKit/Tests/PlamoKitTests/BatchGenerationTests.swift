import Foundation
import MLX
import XCTest

@testable import PlamoKit

/// Batched generation must give every request the output it gets alone (the Python reference outputs).
/// Skips when the model is not installed.
class Batch0_8BTests: XCTestCase {
    class var variant: PlamoModelVariant { .b0_8 }
    class var referenceNames: [String] { ["reference", "reference-long"] }

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

    /// Short and long prompts (1.5k and 2.9k tokens, past the 2,048-token window) mixed.
    func cases() throws -> [ReferenceFile.Case] {
        let cases = try Self.referenceNames.flatMap { try ReferenceFile.load($0)?.cases ?? [] }
        guard !cases.isEmpty else { throw XCTSkip("no reference fixtures") }
        return cases
    }

    private struct Run {
        var outputs: [Int: PlamoGenerationOutput] = [:]
        var errors: [Int: Error] = [:]
        var maxActive = 0
    }

    /// Submits the prompts (one every `stagger` steps, or all at once) and steps until the batch is empty.
    private func run(
        _ batch: PlamoBatchGenerator, _ prompts: [[Int]], maxNewTokens: Int, stagger: Int = 0,
        flags: [PlamoCancellationFlag]? = nil, beforeStep: ((Int) -> Void)? = nil
    ) throws -> Run {
        var result = Run()
        var next = 0
        var steps = 0
        func submitNext() {
            let index = next
            next += 1
            batch.submit(
                prompt: prompts[index], maxNewTokens: maxNewTokens, onText: nil,
                cancellation: flags?[index] ?? PlamoCancellationFlag()
            ) { outcome in
                switch outcome {
                case .success(let output): result.outputs[index] = output
                case .failure(let error): result.errors[index] = error
                }
            }
        }
        if stagger == 0 { while next < prompts.count { submitNext() } }
        while batch.hasWork || next < prompts.count {
            if stagger > 0, next < prompts.count, steps % stagger == 0 { submitNext() }
            beforeStep?(steps)
            try withError { try batch.step() }
            result.maxActive = max(result.maxActive, batch.activeCount)
            steps += 1
            XCTAssertLessThan(steps, 10_000)
            if steps >= 10_000 { break }
        }
        return result
    }

    private func assertMatchesReference(_ run: Run, _ cases: [ReferenceFile.Case], skipping: Set<Int> = []) {
        for (n, c) in cases.enumerated() where !skipping.contains(n) {
            guard let out = run.outputs[n] else {
                XCTFail("case \(n): no output (\(String(describing: run.errors[n])))")
                continue
            }
            XCTAssertEqual(scalars(out.text), scalars(c.output), "case \(n): \(out.text)")
            XCTAssertEqual(out.promptTokens, c.promptIDs.count)
        }
    }

    func testAllAtOnce() throws {
        let gen = try generator()
        gen.resetCache()
        let cases = try cases()
        let batch = PlamoBatchGenerator(generator: gen)
        batch.maxBatchSize = cases.count
        let result = try run(batch, cases.map(\.promptIDs), maxNewTokens: 128)
        // One prompt joins per step, so the shortest outputs may finish before the last prompts join.
        XCTAssertGreaterThanOrEqual(result.maxActive, cases.count - 2, "the requests decoded in one batch")
        assertMatchesReference(result, cases)
    }

    func testStaggeredJoinsWithFewRows() throws {
        let gen = try generator()
        gen.resetCache()
        let cases = try cases()
        let batch = PlamoBatchGenerator(generator: gen)
        batch.maxBatchSize = 3
        // Requests join while others decode, wait for a free row, and long prompts join short ones and back.
        let order = Array(cases.indices).sorted { ($0 * 5) % cases.count < ($1 * 5) % cases.count }
        let result = try run(batch, order.map { cases[$0].promptIDs }, maxNewTokens: 128, stagger: 3)
        XCTAssertEqual(result.maxActive, 3)
        let reordered = Run(
            outputs: Dictionary(uniqueKeysWithValues: result.outputs.map { (order[$0.key], $0.value) }),
            errors: Dictionary(uniqueKeysWithValues: result.errors.map { (order[$0.key], $0.value) }))
        assertMatchesReference(reordered, cases)
    }

    func testCancelledRowLeavesTheOthersIntact() throws {
        let gen = try generator()
        gen.resetCache()
        let cases = try cases()
        let batch = PlamoBatchGenerator(generator: gen)
        let flags = cases.map { _ in PlamoCancellationFlag() }
        let result = try run(batch, cases.map(\.promptIDs), maxNewTokens: 128, flags: flags) { step in
            if step == 4 { flags[1].cancel() }
        }
        XCTAssertTrue(result.errors[1] is CancellationError, "\(String(describing: result.errors[1]))")
        XCTAssertNil(result.outputs[1])
        assertMatchesReference(result, cases, skipping: [1])
    }

    func testTokenLimitAndSameResultAlone() throws {
        let gen = try generator()
        gen.resetCache()
        let cases = try cases()
        let batch = PlamoBatchGenerator(generator: gen)
        let result = try run(batch, [cases[0].promptIDs, cases[1].promptIDs], maxNewTokens: 3)
        for n in 0 ..< 2 {
            let out = try XCTUnwrap(result.outputs[n])
            XCTAssertTrue(out.hitTokenLimit)
            XCTAssertEqual(out.tokens.count, 3)
            XCTAssertTrue(scalars(cases[n].output).starts(with: scalars(out.text)))
        }
    }

    func testEngineBatchesConcurrentTranslations() async throws {
        guard let dir = TestModels.directory(Self.variant) else {
            throw XCTSkip("PLaMo \(Self.variant.displayName) is not installed")
        }
        let cases = try ReferenceFile.load(Self.referenceNames[0])?.cases ?? []
        let engine = PlamoTranslationEngine(idleUnloadMinutes: nil)
        try await engine.load(directory: dir)
        let started = Date()
        let results = try await withThrowingTaskGroup(of: (Int, PlamoTranslationResult).self) { group in
            for (n, c) in cases.enumerated() {
                group.addTask { (n, try await engine.translate(c.request, modelDirectory: dir)) }
            }
            var results: [Int: PlamoTranslationResult] = [:]
            for try await (n, r) in group { results[n] = r }
            return results
        }
        print("\(Self.variant.displayName): \(cases.count) concurrent translations in \(Date().timeIntervalSince(started)) s")
        for (n, c) in cases.enumerated() {
            XCTAssertEqual(scalars(results[n]?.text ?? ""), scalars(c.output), "case \(n)")
        }

        // A cancelled translation throws CancellationError; the engine keeps working.
        let slow = Task { try await engine.translate(cases[3].request, modelDirectory: dir) }
        let other = Task { try await engine.translate(cases[4].request, modelDirectory: dir) }
        slow.cancel()
        do {
            _ = try await slow.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let survivor = try await other.value
        XCTAssertEqual(scalars(survivor.text), scalars(cases[4].output))
    }
}

final class Batch2BTests: Batch0_8BTests {
    override class var variant: PlamoModelVariant { .b2 }
    override class var referenceNames: [String] { ["reference-2b", "reference-long-2b"] }
}
