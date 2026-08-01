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
}
