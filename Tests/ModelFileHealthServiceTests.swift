import XCTest
@testable import SwiftMaestro

/// Regression coverage for the shard-completeness check added after a real
/// crash: an interrupted download left `gemma-4-26B-A4B-it-MLX-4bit` with 2 of
/// 3 weight shards on disk, and mlx-swift-lm's `Module.update(modules:)` hit
/// an internal `try!` on the partial weight set, crashing the whole app
/// (`UpdateError.mismatchedContainers`) instead of throwing something
/// catchable. `MaestroModel.hasLocalWeights` didn't catch this because it
/// only checks "does at least one .safetensors file exist somewhere."
final class ModelFileHealthServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelFileHealthServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeModel() -> MaestroModel {
        MaestroModel(
            id: "test-model", displayName: "Test Model", huggingFaceID: "test/test-model",
            isVision: false, localPath: tempDir.path, estimatedMemoryGB: 1)
    }

    private func writeIndex(shards: [String: String]) throws {
        let payload: [String: Any] = ["weight_map": shards]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: tempDir.appendingPathComponent("model.safetensors.index.json"))
    }

    private func writeFile(_ name: String, bytes: Int = 8) throws {
        try Data(repeating: 0, count: bytes).write(to: tempDir.appendingPathComponent(name))
    }

    func testCompleteMultiShardModelPasses() throws {
        try writeIndex(shards: [
            "model.embed.weight": "model-00001-of-00002.safetensors",
            "model.layers.0.weight": "model-00002-of-00002.safetensors",
        ])
        try writeFile("model-00001-of-00002.safetensors")
        try writeFile("model-00002-of-00002.safetensors")

        let model = makeModel()
        XCTAssertTrue(ModelFileHealthService.weightsAreComplete(for: model))
        XCTAssertTrue(ModelFileHealthService.missingWeightShards(for: model).isEmpty)
    }

    func testMissingMiddleShardFails() throws {
        // Reproduces the exact real-world case: shards 1 and 3 present, shard
        // 2 missing, no index... first with an index present but a shard gone.
        try writeIndex(shards: [
            "model.embed.weight": "model-00001-of-00003.safetensors",
            "model.layers.10.weight": "model-00002-of-00003.safetensors",
            "model.norm.weight": "model-00003-of-00003.safetensors",
        ])
        try writeFile("model-00001-of-00003.safetensors")
        // model-00002-of-00003.safetensors intentionally NOT written.
        try writeFile("model-00003-of-00003.safetensors")

        let model = makeModel()
        XCTAssertFalse(ModelFileHealthService.weightsAreComplete(for: model))
        XCTAssertEqual(ModelFileHealthService.missingWeightShards(for: model), ["model-00002-of-00003.safetensors"])
    }

    func testMissingIndexStillCatchesMissingShardViaSelfDescribingFilenames() throws {
        // The EXACT real-world failure that caused the crash: index.json
        // itself is ALSO missing (the download died before it was ever
        // written), leaving only shards 1 and 3 of 3 present. HuggingFace's
        // sharded-safetensors filenames are self-describing
        // (model-00001-of-00003.safetensors declares "3 total shards" right
        // in the name), so this must be caught even with no index to read.
        // An earlier version of this fix fell back to "at least one
        // .safetensors exists" here and wrongly reported this as complete -
        // this test guards against regressing that.
        try writeFile("model-00001-of-00003.safetensors")
        // model-00002-of-00003.safetensors intentionally NOT written.
        try writeFile("model-00003-of-00003.safetensors")

        let model = makeModel()
        XCTAssertFalse(ModelFileHealthService.weightsAreComplete(for: model))
        XCTAssertEqual(ModelFileHealthService.missingWeightShards(for: model), ["model-00002-of-00003.safetensors"])
    }

    func testCompleteShardSetWithNoIndexPasses() throws {
        // No index.json at all, but all 3 self-describing shard files present.
        try writeFile("model-00001-of-00003.safetensors")
        try writeFile("model-00002-of-00003.safetensors")
        try writeFile("model-00003-of-00003.safetensors")

        let model = makeModel()
        XCTAssertTrue(ModelFileHealthService.weightsAreComplete(for: model))
    }

    func testSingleShardModelWithNoIndexPasses() throws {
        try writeFile("model.safetensors", bytes: 1024)

        let model = makeModel()
        XCTAssertTrue(ModelFileHealthService.weightsAreComplete(for: model))
    }

    func testEmptyDirectoryFails() throws {
        let model = makeModel()
        XCTAssertFalse(ModelFileHealthService.weightsAreComplete(for: model))
    }

    func testHasCompleteLocalWeightsMatchesWeightsAreComplete() throws {
        try writeIndex(shards: ["a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"])
        try writeFile("model-00001-of-00002.safetensors")
        // shard 2 missing

        let model = makeModel()
        XCTAssertTrue(model.hasLocalWeights, "lenient check should still see the one present shard")
        XCTAssertFalse(model.hasCompleteLocalWeights, "strict check must catch the missing shard")
    }

    // MARK: - Stale upstream index repair (Qwen3-VL-8B phantom-shard family)

    /// Write a minimal but structurally valid safetensors file: 8-byte LE
    /// header length + JSON header + a couple of fake tensor bytes.
    private func writeSafetensors(_ name: String, tensors: [String]) throws {
        var header: [String: Any] = [:]
        for tensor in tensors {
            header[tensor] = ["dtype": "F16", "shape": [1], "data_offsets": [0, 2]]
        }
        let headerData = try JSONSerialization.data(withJSONObject: header)
        var len = UInt64(headerData.count)
        var data = Data()
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(headerData)
        data.append(Data(repeating: 0, count: 2))
        try data.write(to: tempDir.appendingPathComponent(name))
    }

    func testStaleIndexIsRepairedFromCompleteOnDiskShards() throws {
        // Production case: repo ships 2 four-bit shards (of-00002) but its
        // index.json references 4 phantom shards (of-00004) from the
        // unquantized source repo — verification could never pass.
        try writeIndex(shards: [
            "language_model.layers.0.weight": "model-00001-of-00004.safetensors",
            "language_model.layers.1.weight": "model-00002-of-00004.safetensors",
            "language_model.layers.2.weight": "model-00003-of-00004.safetensors",
            "language_model.layers.3.weight": "model-00004-of-00004.safetensors",
        ])
        try writeSafetensors("model-00001-of-00002.safetensors",
                             tensors: ["model.layers.0.weight", "model.embed.weight"])
        try writeSafetensors("model-00002-of-00002.safetensors",
                             tensors: ["model.layers.1.weight", "model.norm.weight"])

        let model = makeModel()
        XCTAssertTrue(ModelFileHealthService.missingWeightShards(for: model).isEmpty)

        // The index was regenerated from the on-disk shards and the upstream
        // file backed up alongside.
        let data = try Data(contentsOf: tempDir.appendingPathComponent("model.safetensors.index.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let map = json?["weight_map"] as? [String: String]
        XCTAssertEqual(Set((map ?? [:]).values), [
            "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
        ])
        XCTAssertEqual(map?.count, 4)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("model.safetensors.index.json.upstream-broken.bak").path))
    }

    func testStaleIndexIsNOTRepairedOverIncompleteOnDiskShards() throws {
        // Safety: if the real shard set is only half-downloaded, the stale
        // index must be left alone — never bless a partial weight set.
        try writeIndex(shards: [
            "language_model.layers.0.weight": "model-00001-of-00004.safetensors",
            "language_model.layers.1.weight": "model-00002-of-00004.safetensors",
        ])
        try writeSafetensors("model-00001-of-00002.safetensors",
                             tensors: ["model.layers.0.weight"])

        XCTAssertFalse(ModelFileHealthService.repairStaleWeightIndexIfNeeded(in: tempDir))
        // Index untouched: still reports the phantom shards as missing.
        let model = makeModel()
        XCTAssertEqual(ModelFileHealthService.missingWeightShards(for: model),
                       ["model-00001-of-00004.safetensors", "model-00002-of-00004.safetensors"])
    }

    func testSafetensorsTensorNamesParsesHeader() throws {
        try writeSafetensors("model.safetensors",
                             tensors: ["a.weight", "b.weight", "__metadata__"])
        let names = ModelFileHealthService.safetensorsTensorNames(
            tempDir.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(names, ["a.weight", "b.weight"])
    }
}
