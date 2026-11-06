import Foundation
import XCTest

@testable import PlamoKit

final class ModelStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlamoStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testVariantNaming() {
        XCTAssertEqual(PlamoModelVariant.b2.repoID, "pfnet/plamo-3-translate-2b-MLX-4bit")
        XCTAssertEqual(PlamoModelVariant.b0_8.displayName, "0.8B")
        let store = PlamoModelStore(rootDirectory: root)
        XCTAssertEqual(
            store.directory(for: .b8).path,
            root.appendingPathComponent("pfnet/plamo-3-translate-8b-MLX-4bit").path)
        XCTAssertTrue(PlamoModelStore.defaultRootDirectory.path.hasSuffix("Library/Application Support/Plamonic/Models"))
    }

    func testRemoteFileSelection() {
        let listing: [[String: Any]] = [
            ["type": "directory", "path": "figures", "size": 0],
            ["type": "directory", "path": "LICENSE", "size": 0],
            ["type": "file", "path": ".gitattributes", "size": 1699],
            ["type": "file", "path": "README.md", "size": 38744],
            ["type": "file", "path": "LICENSE.mlx-lm", "size": 1066],
            ["type": "file", "path": "chat_template.jinja", "size": 5206],
            ["type": "file", "path": "config.json", "size": 22914, "oid": "blob-config"],
            [
                "type": "file", "path": "model-00001-of-00002.safetensors", "size": 134, "oid": "pointer",
                "lfs": ["size": 1_073_592_520, "oid": "sha256-1"],
            ],
            ["type": "file", "path": "model-00002-of-00002.safetensors", "size": 134, "lfs": ["size": 5]],
            ["type": "file", "path": "model.safetensors.index.json", "size": 37969],
            ["type": "file", "path": "modeling_plamo_mlx.py", "size": 12873],
            ["type": "file", "path": "requirements-mlx.txt", "size": 30],
            ["type": "file", "path": "server.py", "size": 5851],
            ["type": "file", "path": "tokenizer.jsonl", "size": 3_526_723],
            ["type": "file", "path": "tokenizer_config.json", "size": 1575],
            ["type": "file", "path": "figures/plot.png", "size": 10],
        ]
        let files = PlamoModelStore.selectFiles(listing)
        XCTAssertEqual(
            files.map(\.path),
            [
                "chat_template.jinja", "config.json", "model-00001-of-00002.safetensors",
                "model-00002-of-00002.safetensors", "model.safetensors.index.json", "tokenizer.jsonl",
                "tokenizer_config.json",
            ])
        XCTAssertEqual(files.first { $0.path.hasPrefix("model-00001") }?.size, 1_073_592_520)
        XCTAssertEqual(files.first { $0.path.hasPrefix("model-00001") }?.oid, "sha256-1")
        XCTAssertEqual(files.first { $0.path == "config.json" }?.oid, "blob-config")
        XCTAssertNil(files.first { $0.path == "tokenizer.jsonl" }?.oid)
    }

    /// A safetensors file whose header promises `dataBytes` bytes of data, with `actualBytes` present.
    private func safetensors(dataBytes: Int, actualBytes: Int) -> Data {
        let header = Data(#"{"a":{"dtype":"U8","shape":[\#(dataBytes)],"data_offsets":[0,\#(dataBytes)]}}"#.utf8)
        var length = UInt64(header.count).littleEndian
        return Data(bytes: &length, count: 8) + header + Data(count: actualBytes)
    }

    func testSafetensorsHeaderRejectsBadOffsets() throws {
        func expectedSize(_ header: String) throws -> Int64? {
            let url = root.appendingPathComponent("\(UUID().uuidString).safetensors")
            var length = UInt64(header.utf8.count).littleEndian
            try (Data(bytes: &length, count: 8) + Data(header.utf8)).write(to: url)
            return SafetensorsHeader.expectedFileSize(url)
        }
        let good = #"{"a":{"dtype":"F32","shape":[4],"data_offsets":[0,16]}}"#
        XCTAssertEqual(try expectedSize(good), 8 + Int64(good.utf8.count) + 16)
        // would overflow Int64 when added to the header size
        XCTAssertNil(try expectedSize(#"{"a":{"dtype":"U8","shape":[1],"data_offsets":[0,9223372036854775800]}}"#))
        XCTAssertNil(try expectedSize(#"{"a":{"dtype":"U8","shape":[1],"data_offsets":[0,-5]}}"#))
        XCTAssertNil(try expectedSize(#"{"a":{"dtype":"U8","shape":[1],"data_offsets":[8,4]}}"#))
    }

    func testIndexShardsMustStayInModelDirectory() throws {
        let store = PlamoModelStore(rootDirectory: root)
        let dir = store.directory(for: .b2)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ["plamo_rope_inv_freq": ["full": [1.0], "local": [1.0]], "pad": String(repeating: "x", count: 600)] as [String: Any]
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 0x20, count: 1_100_000).write(to: dir.appendingPathComponent("tokenizer.jsonl"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer_config.json"))
        // a complete weight file outside the model directory
        try safetensors(dataBytes: 4, actualBytes: 4).write(to: root.appendingPathComponent("outside.safetensors"))
        try safetensors(dataBytes: 4, actualBytes: 4).write(to: dir.appendingPathComponent("model-1.safetensors"))

        func writeIndex(_ shard: String) throws {
            let index = ["weight_map": ["a": shard]]
            try JSONSerialization.data(withJSONObject: index)
                .write(to: dir.appendingPathComponent("model.safetensors.index.json"))
        }
        try writeIndex("model-1.safetensors")
        XCTAssertNil(PlamoModelStore.validationProblem(directory: dir))
        for shard in ["../../outside.safetensors", "sub/model-1.safetensors", ".hidden.safetensors", "config.json"] {
            try writeIndex(shard)
            XCTAssertNotNil(PlamoModelStore.validationProblem(directory: dir), shard)
            XCTAssertThrowsError(try PlamoModelLoader.weightFiles(in: dir), shard)
        }
    }

    func testPartialDownloadKeepsOnlyFinishedFiles() throws {
        let store = PlamoModelStore(rootDirectory: root)
        let partial = store.partialDirectory(for: .b2)
        XCTAssertEqual(partial.deletingLastPathComponent().path, store.directory(for: .b2).deletingLastPathComponent().path)
        let fm = FileManager.default
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        func write(_ name: String, _ data: Data) throws { try data.write(to: partial.appendingPathComponent(name)) }
        let shard = safetensors(dataBytes: 16, actualBytes: 16)
        try write("config.json", Data("{}".utf8))
        try write("model-00001-of-00004.safetensors", shard)
        try write("model-00002-of-00004.safetensors", shard)
        try write("model-00003-of-00004.safetensors", safetensors(dataBytes: 16, actualBytes: 8))
        try write("model-00004-of-00004.safetensors", shard)
        try write("stale.safetensors", shard)
        try PlamoModelStore.writeManifest(
            [
                "config.json": "c1", "model-00001-of-00004.safetensors": "s1", "model-00002-of-00004.safetensors": "old",
                "model-00003-of-00004.safetensors": "s3", "stale.safetensors": "x",
            ], in: partial)

        let size = Int64(shard.count)
        let files = [
            PlamoModelStore.RemoteFile(path: "config.json", size: 2, oid: "c1"),
            PlamoModelStore.RemoteFile(path: "model-00001-of-00004.safetensors", size: size, oid: "s1"),
            PlamoModelStore.RemoteFile(path: "model-00002-of-00004.safetensors", size: size, oid: "s2"),  // new version
            PlamoModelStore.RemoteFile(path: "model-00003-of-00004.safetensors", size: size, oid: "s3"),  // cut short
            PlamoModelStore.RemoteFile(path: "model-00004-of-00004.safetensors", size: size, oid: "s4"),  // not recorded
            PlamoModelStore.RemoteFile(path: "tokenizer.jsonl", size: 5, oid: nil),
        ]
        let kept = try PlamoModelStore.preparePartialDirectory(partial, for: files)
        XCTAssertEqual(kept, ["config.json": "c1", "model-00001-of-00004.safetensors": "s1"])
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: partial.path).sorted(),
            [PlamoModelStore.partialManifestName, "config.json", "model-00001-of-00004.safetensors"])
        // the rewritten manifest lists just the kept files
        XCTAssertEqual(try PlamoModelStore.preparePartialDirectory(partial, for: files), kept)

        XCTAssertGreaterThan(store.partialDownloadBytes(.b2), size)
        XCTAssertFalse(store.isInstalled(.b2))
        try store.delete(.b2)
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        XCTAssertEqual(store.partialDownloadBytes(.b2), 0)
    }

    func testTransientDownloadErrors() {
        XCTAssertTrue(PlamoModelStore.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(PlamoModelStore.isTransient(URLError(.timedOut)))
        XCTAssertFalse(PlamoModelStore.isTransient(URLError(.badURL)))
        XCTAssertFalse(PlamoModelStore.isTransient(URLError(.cancelled)))
        XCTAssertFalse(PlamoModelStore.isTransient(PlamoError.downloadFailed("x")))
        XCTAssertTrue(PlamoModelStore.isTransient(httpStatus: 503))
        XCTAssertTrue(PlamoModelStore.isTransient(httpStatus: 429))
        XCTAssertFalse(PlamoModelStore.isTransient(httpStatus: 404))
    }

    func testValidationDetectsIncompleteWeights() throws {
        let store = PlamoModelStore(rootDirectory: root)
        let dir = store.directory(for: .b0_8)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(store.isInstalled(.b0_8))

        let config = ["hidden_size": 8, "plamo_rope_inv_freq": ["full": [1.0], "local": [1.0]], "pad": String(repeating: "x", count: 600)] as [String: Any]
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 0x20, count: 1_100_000).write(to: dir.appendingPathComponent("tokenizer.jsonl"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer_config.json"))

        // A safetensors file whose header promises 16 data bytes.
        let header = Data(#"{"a":{"dtype":"F32","shape":[4],"data_offsets":[0,16]}}"#.utf8)
        var file = Data()
        var length = UInt64(header.count).littleEndian
        file.append(Data(bytes: &length, count: 8))
        file.append(header)
        try (file + Data(count: 8)).write(to: dir.appendingPathComponent("model.safetensors"))
        XCTAssertNotNil(PlamoModelStore.validationProblem(directory: dir))
        XCTAssertFalse(store.isInstalled(.b0_8))

        try (file + Data(count: 16)).write(to: dir.appendingPathComponent("model.safetensors"))
        XCTAssertNil(PlamoModelStore.validationProblem(directory: dir))
        XCTAssertTrue(store.isInstalled(.b0_8))
        XCTAssertTrue(try store.markInstalledIfValid(.b0_8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path))
        XCTAssertGreaterThan(store.installedBytes(.b0_8), 1_100_000)

        try store.delete(.b0_8)
        XCTAssertFalse(store.isInstalled(.b0_8))
        XCTAssertEqual(store.installedBytes(.b0_8), 0)
    }

    func testMarkerAloneCountsAsInstalled() throws {
        let store = PlamoModelStore(rootDirectory: root)
        let dir = store.directory(for: .b31)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PlamoModelStore.writeMarker(in: dir, files: [])
        XCTAssertTrue(store.isInstalled(.b31))
    }

    func testDownloadCancellationLeavesNothingBehind() async throws {
        guard ProcessInfo.processInfo.environment["PLAMO_TEST_NETWORK"] != nil else {
            throw XCTSkip(
                "set PLAMO_TEST_NETWORK=1 (TEST_RUNNER_PLAMO_TEST_NETWORK=1 with xcodebuild) to test downloads")
        }
        let store = PlamoModelStore(rootDirectory: root)
        let task = Task { try await store.download(.b0_8) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {}
        let parent = store.directory(for: .b0_8).deletingLastPathComponent()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }
}

final class OutputCheckTests: XCTestCase {
    func testLooksWrong() {
        let english = "The deployment pipeline is blocked until the QA team signs off on the release."
        XCTAssertTrue(PlamoOutputCheck.looksWrong(input: english, output: english, targetLanguage: "ja"))
        XCTAssertFalse(
            PlamoOutputCheck.looksWrong(input: english, output: "QA チームが承認するまでデプロイは止まっています。", targetLanguage: "ja"))
        XCTAssertTrue(PlamoOutputCheck.looksWrong(input: "hello", output: "", targetLanguage: "en"))
        XCTAssertTrue(
            PlamoOutputCheck.looksWrong(
                input: "short", output: String(repeating: "あ", count: 300), targetLanguage: "ja"))
        // Short Latin text such as product names may stay as-is.
        XCTAssertFalse(PlamoOutputCheck.looksWrong(input: "GitHub", output: "GitHub", targetLanguage: "ja"))
        XCTAssertFalse(PlamoOutputCheck.looksWrong(input: english, output: english, targetLanguage: "en"))
    }
}

final class EngineTests: XCTestCase {
    func engine() throws -> (PlamoTranslationEngine, PlamoModelVariant) {
        guard TestModels.directory(.b0_8) != nil else { throw XCTSkip("PLaMo 0.8B is not installed") }
        return (PlamoTranslationEngine(idleUnloadMinutes: nil), .b0_8)
    }

    func testTranslateWithHistoryAndPartials() async throws {
        let (engine, variant) = try engine()
        let ref = try XCTUnwrap(ReferenceFile.load("reference"))
        let collector = PartialCollector()
        let result = try await engine.translate(ref.cases[4].request, variant: variant) { collector.add($0) }
        XCTAssertEqual(scalars(result.text), scalars(ref.cases[4].output))
        XCTAssertEqual(result.promptTokens, ref.cases[4].promptIDs.count)
        XCTAssertFalse(result.retriedWithoutHistory)
        XCTAssertFalse(result.looksWrong)
        XCTAssertGreaterThan(result.generatedTokens, 0)
        XCTAssertGreaterThan(result.timings.load, 0)
        let loaded = await engine.loadedVariants
        XCTAssertEqual(loaded, [variant])
        XCTAssertTrue(engine.isLoadedSnapshot(variant))
        XCTAssertFalse(engine.isLoadedSnapshot(.b31))

        // second call: model already loaded, shared prefix reused
        let second = try await engine.translate(ref.cases[0].request, variant: variant)
        XCTAssertEqual(second.timings.load, 0)
        XCTAssertGreaterThan(second.reusedPromptTokens, 0)
        XCTAssertEqual(scalars(second.text), scalars(ref.cases[0].output))
        // the first chunk is always reported; later ones are throttled
        XCTAssertFalse(collector.values.isEmpty)
        XCTAssertTrue(collector.values.allSatisfy { scalars(ref.cases[4].output).starts(with: scalars($0)) })
        await engine.unloadAll()
        let after = await engine.loadedVariants
        XCTAssertEqual(after, [])
        XCTAssertFalse(engine.isLoadedSnapshot(variant))
    }

    func testCancellation() async throws {
        let (engine, variant) = try engine()
        try await engine.load(variant)
        let long = String(repeating: "This is a sentence that keeps going and going. ", count: 40)
        let task = Task {
            try await engine.translate(
                PlamoTranslationRequest(text: long, targetLanguage: "ja", maxNewTokens: 2000), variant: variant)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // the engine still works and the cache bookkeeping is consistent
        let ref = try XCTUnwrap(ReferenceFile.load("reference"))
        let r = try await engine.translate(ref.cases[1].request, variant: variant)
        XCTAssertEqual(scalars(r.text), scalars(ref.cases[1].output))
    }

    func testIdleUnload() async throws {
        let (engine, variant) = try engine()
        try await engine.load(variant)
        XCTAssertTrue(engine.isLoadedSnapshot(variant))
        await engine.setIdleUnloadMinutes(1.0 / 60.0)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let loaded = await engine.loadedVariants
        XCTAssertEqual(loaded, [])
        XCTAssertFalse(engine.isLoadedSnapshot(variant), "an idle unload shows in the snapshot")
    }

    func testMissingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlamoEmpty-\(UUID().uuidString)")
        let engine = PlamoTranslationEngine(store: PlamoModelStore(rootDirectory: root), idleUnloadMinutes: nil)
        do {
            _ = try await engine.translate(PlamoTranslationRequest(text: "hi", targetLanguage: "ja"), variant: .b8)
            XCTFail("expected an error")
        } catch PlamoError.modelNotInstalled(let v) {
            XCTAssertEqual(v, .b8)
        }
    }
}

final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func add(_ s: String) { lock.withLock { values.append(s) } }
}
