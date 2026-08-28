import XCTest
import MLX
import MLXLMCommon
import MLXLLM
@testable import SwiftMaestro

/// Regression tests for deepseek_v2 support in the shared DeepseekV3
/// implementation (registered as "deepseek_v2" in LLMTypeRegistry).
/// DeepSeek-Coder-V2-Lite's config has `q_lora_rank: null`,
/// `scoring_func: "softmax"`, `topk_method: "greedy"` — all three previously
/// broke or mis-routed under the V3-only code path.
final class DeepseekV2ConfigTests: XCTestCase {

    /// Trimmed to the load-bearing fields of the real config.json from
    /// mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx.
    private let v2LiteConfigJSON = """
        {
            "model_type": "deepseek_v2",
            "vocab_size": 102400,
            "hidden_size": 2048,
            "intermediate_size": 10944,
            "moe_intermediate_size": 1408,
            "num_hidden_layers": 27,
            "num_attention_heads": 16,
            "num_key_value_heads": 16,
            "n_shared_experts": 2,
            "n_routed_experts": 64,
            "routed_scaling_factor": 1.0,
            "kv_lora_rank": 512,
            "q_lora_rank": null,
            "qk_rope_head_dim": 64,
            "v_head_dim": 128,
            "qk_nope_head_dim": 128,
            "norm_topk_prob": false,
            "n_group": 1,
            "topk_group": 1,
            "num_experts_per_tok": 6,
            "moe_layer_freq": 1,
            "first_k_dense_replace": 1,
            "max_position_embeddings": 163840,
            "rms_norm_eps": 1e-06,
            "rope_theta": 10000,
            "rope_scaling": {"beta_fast": 32, "beta_slow": 1, "factor": 40, "mscale": 0.707, "mscale_all_dim": 1.0, "type": "yarn"},
            "attention_bias": false,
            "scoring_func": "softmax",
            "topk_method": "greedy",
            "tie_word_embeddings": false
        }
        """

    /// The exact failure the app hit: "Unsupported model type: deepseek_v2".
    /// The registry must resolve the type AND decode the config — the null
    /// `q_lora_rank` would throw from the decoder, and the model construction
    /// exercises the nil-qLoRA attention path and MoE wiring (weights are not
    /// loaded here).
    func testRegistryCreatesDeepseekV2Model() async throws {
        let data = Data(v2LiteConfigJSON.utf8)
        let model = try await LLMTypeRegistry.shared.createModel(
            configuration: data, modelType: "deepseek_v2")
        XCTAssertTrue(String(describing: type(of: model)).contains("DeepseekV3Model"))
    }

    /// V2 checkpoints carry no `e_score_correction_bias` (that's V3's noaux_tc
    /// bias), but the shared MoEGate declares it as a stored parameter —
    /// without synthesized zeros the weight application fails with
    /// "Key …gate.e_score_correction_bias not found" (the app's first V2 load).
    func testSanitizeSynthesizesMissingGateBias() async throws {
        let model = try await LLMTypeRegistry.shared.createModel(
            configuration: Data(v2LiteConfigJSON.utf8), modelType: "deepseek_v2")
        // Minimal marker: gate.weight present at MoE layer 1 (layer 0 is dense).
        let weights: [String: MLXArray] = [
            "model.layers.1.mlp.gate.weight": MLXArray.zeros([64, 2048])
        ]
        let out = model.sanitize(weights: weights)
        let bias = out["model.layers.1.mlp.gate.e_score_correction_bias"]
        XCTAssertNotNil(bias, "sanitize must synthesize the missing V3 gate bias for V2 checkpoints")
        XCTAssertEqual(bias?.shape, [64])
    }

    /// Logit probe: dump the top-5 next tokens for a fixed prompt so the
    /// Swift forward can be compared token-for-token against Python mlx_lm.
    func testDeepseekV2LiteLogitProbe() async throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()
            + "/Ai-models/models/swiftmaestro-models/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("model not installed")
        }
        let configuration = ModelConfiguration(directory: dir, toolCallFormat: .deepseek)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: LocalDirectoryDownloader(directory: dir),
            using: MaestroTokenizerLoader(),
            configuration: configuration)
        try await container.perform { context in
            let input = UserInput(chat: [.user("Say hello in one word.")])
            nonisolated(unsafe) let capturedInput = input
            let lmInput = try await context.processor.prepare(input: capturedInput)
            let ids = lmInput.text.tokens.asArray(Int.self)
            print("[PROBE] prompt ids tail:", ids.suffix(6))
            let tokens2d = MLXArray(ids.map { Int32($0) })[.newAxis, 0...]  // [1, seq]
            let output = context.model(
                LMInput.Text(tokens: tokens2d), cache: nil, state: nil)
            var logits = output.logits
            print("[PROBE] logits shape:", logits.shape, "ndim:", logits.ndim)
            if logits.ndim >= 3 { logits = logits[0..., -1, 0...] }
            if logits.ndim == 1 { logits = logits[.newAxis, 0...] }
            eval(logits)
            print("[PROBE] normalized logits shape:", logits.shape)
            let vocabSize = logits.dim(-1)
            let row = logits[0]
            let top = argSort(-row, axis: -1)
            let topIds = top[0..<5].asArray(Int32.self)
            var line = "[PROBE] top5:"
            for id in topIds {
                let tid = Int(id)
                let logit = row[tid].item(Float.self)
                let piece = (try? context.tokenizer.decode(tokenIds: [tid])) ?? "?"
                line += " (\(tid), \(String(format: "%.3f", logit)), \(piece.debugDescription))"
            }
            print(line)
            try? line.write(toFile: "/tmp/deepseek_probe.txt", atomically: true, encoding: .utf8)
        }
    }

    /// Heavy end-to-end: load the real 8.2 GB checkpoint through the app's
    /// exact path (LLMModelFactory + MaestroTokenizerLoader + .deepseek format)
    /// and generate a few tokens. Presence-gated: runs only when the model is
    /// on disk. Regression for the cacheless-generation bug (empty kvHeads →
    /// degenerate "search search…" output from token 2 onward).
    func testDeepseekV2LiteLoadsAndGenerates() async throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()
            + "/Ai-models/models/swiftmaestro-models/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("model not installed at \(dir.path)")
        }
        let configuration = ModelConfiguration(directory: dir, toolCallFormat: .deepseek)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: LocalDirectoryDownloader(directory: dir),
            using: MaestroTokenizerLoader(),
            configuration: configuration)
        let input = UserInput(chat: [.user("Say hello in one word.")])
        nonisolated(unsafe) let capturedInput = input
        let stream = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: capturedInput)
            return try MLXLMCommon.generate(
                input: lmInput,
                parameters: .init(maxTokens: 16, temperature: 0.0),
                context: context)
        }
        var text = ""
        for await generation in stream {
            if case .chunk(let chunk) = generation { text += chunk }
        }
        print("[E2E] DeepSeek generated: \(text.debugDescription)")
        try? text.write(toFile: "/tmp/deepseek_e2e_output.txt", atomically: true, encoding: .utf8)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "model generated nothing")
    }
}

