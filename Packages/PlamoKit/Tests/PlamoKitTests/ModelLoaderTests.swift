import Foundation
import MLX
import XCTest

@testable import PlamoKit

/// Malformed or mismatched model files must throw `invalidModel`; MLX failures inside the C++
/// library would otherwise abort the whole process.
final class ModelLoaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlamoLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// config.json of a one-layer model: hidden 64, 2 heads + 1 KV head of 32, MLP 64, vocab 16.
    private func tinyConfig() -> [String: Any] {
        [
            "hidden_size": 64, "num_hidden_layers": 1, "num_attention_heads": 2, "num_key_value_heads": 1,
            "head_dim": 32, "intermediate_size": 64, "vocab_size": 16, "window_size": 16,
            "sliding_window_pattern": 8, "tie_word_embeddings": true,
            "plamo_rope_inv_freq": ["full": Array(repeating: 0.5, count: 16), "local": Array(repeating: 0.25, count: 16)],
            "quantization": ["group_size": 32, "bits": 4, "mode": "affine", "model.embed_tokens": false],
        ]
    }

    /// Weights that match `tinyConfig()`; linear layers are 4-bit quantized with groups of 32.
    private func writeTinyModel(config: [String: Any]) throws -> URL {
        let dir = root.appendingPathComponent("model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))

        var weights = [String: MLXArray]()
        func float(_ shape: [Int]) -> MLXArray { (MLXRandom.normal(shape) * 0.02).asType(.bfloat16) }
        func linear(_ path: String, _ outputs: Int, _ inputs: Int) {
            let (wq, scales, biases) = MLX.quantized(MLXRandom.normal([outputs, inputs]), groupSize: 32, bits: 4)
            weights["\(path).weight"] = wq
            weights["\(path).scales"] = scales.asType(.float16)
            weights["\(path).biases"] = biases!.asType(.float16)
        }
        let p = "model.layers.layers.0"
        linear("\(p).mixer.qkv_proj", 128, 64)
        linear("\(p).mixer.o_proj", 64, 64)
        linear("\(p).mlp.gate_up_proj", 128, 64)
        linear("\(p).mlp.down_proj", 64, 64)
        weights["\(p).mixer.q_norm.weight"] = float([32])
        weights["\(p).mixer.k_norm.weight"] = float([32])
        for norm in ["pre_mixer_norm", "post_mixer_norm", "pre_mlp_norm", "post_mlp_norm"] {
            weights["\(p).\(norm).weight"] = float([64])
        }
        weights["model.embed_tokens.weight"] = float([16, 64])
        weights["model.norm.weight"] = float([64])
        try MLX.save(arrays: weights, url: dir.appendingPathComponent("model.safetensors"))
        return dir
    }

    private func assertInvalidModel<T>(
        _ body: @autoclosure () throws -> T, mentioning text: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case PlamoError.invalidModel(let reason) = error else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(text), "\(reason)", file: file, line: line)
        }
    }

    func testTinyModelLoadsAndRuns() throws {
        let dir = try writeTinyModel(config: tinyConfig())
        let model = try withError { try PlamoModelLoader.load(directory: dir) }
        let logits = try withError {
            let out = model(MLXArray([Int32(1), 2, 3]).expandedDimensions(axis: 0), caches: model.makeCaches())
            eval(out)
            return out
        }
        XCTAssertEqual(logits.shape, [1, 3, 16])
    }

    func testWeightShapesMustMatchConfig() throws {
        var config = tinyConfig()
        config["num_key_value_heads"] = 2
        assertInvalidModel(
            try PlamoModelLoader.load(directory: try writeTinyModel(config: config)), mentioning: "qkv_proj")

        config = tinyConfig()
        config["intermediate_size"] = 32
        assertInvalidModel(
            try PlamoModelLoader.load(directory: try writeTinyModel(config: config)), mentioning: "gate_up_proj")

        config = tinyConfig()
        config["vocab_size"] = 32
        assertInvalidModel(
            try PlamoModelLoader.load(directory: try writeTinyModel(config: config)), mentioning: "embed_tokens")

        // packed weights still fit, but there is one scale per 64 inputs instead of 32
        config = tinyConfig()
        config["quantization"] = ["group_size": 64, "bits": 4, "model.embed_tokens": false]
        assertInvalidModel(
            try PlamoModelLoader.load(directory: try writeTinyModel(config: config)), mentioning: "scales")

        config = tinyConfig()
        config["quantization"] = ["group_size": 32, "bits": 8, "model.embed_tokens": false]
        assertInvalidModel(
            try PlamoModelLoader.load(directory: try writeTinyModel(config: config)), mentioning: "weight")
    }

    func testConfigurationRanges() {
        func config(_ changes: [String: Any]) -> [String: Any] {
            tinyConfig().merging(changes) { $1 }
        }
        XCTAssertNoThrow(try Plamo3Configuration(json: tinyConfig()))
        assertInvalidModel(try Plamo3Configuration(json: config(["sliding_window_pattern": 0])), mentioning: "sliding_window_pattern")
        assertInvalidModel(try Plamo3Configuration(json: config(["num_hidden_layers": -1])), mentioning: "num_hidden_layers")
        assertInvalidModel(try Plamo3Configuration(json: config(["window_size": 0])), mentioning: "window_size")
        assertInvalidModel(try Plamo3Configuration(json: config(["hidden_size": 1 << 40])), mentioning: "hidden_size")
        assertInvalidModel(
            try Plamo3Configuration(json: config(["num_attention_heads": 3, "num_key_value_heads": 2])),
            mentioning: "num_key_value_heads")
        assertInvalidModel(
            try Plamo3Configuration(
                json: config([
                    "head_dim": 3, "plamo_rope_inv_freq": ["full": [0.5], "local": [0.5]],
                ])), mentioning: "head_dim")
        assertInvalidModel(
            try Plamo3Configuration(json: config(["quantization": ["group_size": 32, "bits": 7]])), mentioning: "bits")
        assertInvalidModel(
            try Plamo3Configuration(
                json: config(["quantization": ["group_size": 32, "bits": 4, "lm_head": ["group_size": 16]]])),
            mentioning: "group_size")
        assertInvalidModel(try Plamo3Configuration(json: config(["rope_scaling_factor": -1])), mentioning: "rope_scaling_factor")
    }

    /// The reported crash: real 0.8B weights with a config.json from another model.
    func testEngineRejectsMismatchedRealModel() async throws {
        guard let source = TestModels.directory(.b0_8) else { throw XCTSkip("PLaMo 0.8B is not installed") }
        let dir = root.appendingPathComponent("mixed")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name != "config.json" && !name.hasPrefix(".") {
            try fm.createSymbolicLink(
                at: dir.appendingPathComponent(name), withDestinationURL: source.appendingPathComponent(name))
        }
        var config = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("config.json")))
                as? [String: Any])
        config["num_key_value_heads"] = 2
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))

        let engine = PlamoTranslationEngine(store: PlamoModelStore(rootDirectory: root), idleUnloadMinutes: nil)
        do {
            try await engine.load(directory: dir)
            XCTFail("expected an error")
        } catch PlamoError.invalidModel(let reason) {
            XCTAssertTrue(reason.contains("qkv_proj"), reason)
        }
    }
}
