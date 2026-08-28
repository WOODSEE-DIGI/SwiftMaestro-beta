import XCTest
import MLX
import MLXLMCommon
@testable import SwiftMaestro

/// Probes for the Gemma 4 repetitionPenalty crash (mlx-swift-lm issue #258):
/// a broadcast error between (repetitionContextSize) and (promptLength) the
/// moment a Gemma 4 model generates with a non-nil repetition penalty. The
/// processor path is model-agnostic, so the difference must be the RANK of
/// the logits Gemma 4 hands to `RepetitionContext.process`. This test drives
/// the processor directly with synthetic logits at every plausible rank —
/// no 26 GB model load required.
final class RepetitionContextRankTests: XCTestCase {

    private let vocab = 262_144   // Gemma 4 vocab size
    private let contextSize = 64  // issue's repetitionContextSize
    private let promptLength = 80 // issue's prompt length (> contextSize)

    private func makeContext() -> RepetitionContext {
        var ctx = RepetitionContext(
            repetitionPenalty: 1.1, repetitionContextSize: contextSize)
        var values: [Int32] = []
        values.reserveCapacity(promptLength)
        for i in 0..<promptLength {
            values.append(Int32((i * 977) % vocab))
        }
        ctx.prompt(MLXArray(values))
        return ctx
    }

    func testRank1_vocabOnly() {
        var ctx = makeContext()
        let logits = MLXArray.zeros([vocab], type: Float32.self)
        _ = ctx.process(logits: logits)  // must not trap
    }

    func testRank2_batchVocab() {
        var ctx = makeContext()
        let logits = MLXArray.zeros([1, vocab], type: Float32.self)
        _ = ctx.process(logits: logits)
    }

    func testRank2_seqVocab() {
        var ctx = makeContext()
        let logits = MLXArray.zeros([promptLength, vocab], type: Float32.self)
        _ = ctx.process(logits: logits)
    }

    func testRank3_batchSeqVocab() {
        var ctx = makeContext()
        let logits = MLXArray.zeros([1, promptLength, vocab], type: Float32.self)
        _ = ctx.process(logits: logits)
    }

    /// The exact shape convertToToken feeds the processor in the stock
    /// generate() path: `logits[0..., -1, 0...]` — for a [1, seq, vocab]
    /// model output that's [1, vocab] (2-D), NOT 1-D.
    func testConvertToTokenSliceShape() {
        let logits = MLXArray.zeros([1, promptLength, vocab], type: Float32.self)
        let sliced = logits[0..., -1, 0...]
        XCTAssertEqual(sliced.ndim, 2, "convertToToken's slice yields [batch, vocab] (2-D)")
    }

    /// LogitProcessor contract: process() must return the SAME shape it
    /// receives. The sampler's output rank depends on the logits rank
    /// (categorical drops the sampled axis), so a processor that squeezes
    /// [batch, vocab] → [vocab] turns the sampled token from [1] into a
    /// 0-D scalar — the next TokenIterator.step then feeds a rank-1 token
    /// array to the model and the round degenerates (Mechanic gen=0 bug).
    func testProcessPreservesRank2D() {
        var ctx = makeContext()
        let logits = MLXArray.zeros([1, vocab], type: Float32.self)
        let out = ctx.process(logits: logits)
        XCTAssertEqual(out.ndim, logits.ndim,
            "process() must preserve the input rank (got \(out.ndim), want \(logits.ndim))")
        XCTAssertEqual(out.shape, logits.shape,
            "process() must preserve the input shape (got \(out.shape), want \(logits.shape))")
    }

    /// categorical() drops the sampled axis: 2-D [1, vocab] in → [1] out.
    /// This is the shape TokenIterator's next-step input depends on.
    func testTopPSamplerTokenRankFrom2D() {
        let sampler = TopPSampler(temperature: 0.3, topP: 0.95)
        let logits = MLXArray.zeros([1, 1024], type: Float32.self)
        let token = sampler.sample(logits: logits)
        XCTAssertEqual(token.ndim, 1, "2-D logits must yield a [1] token (got ndim=\(token.ndim))")
        XCTAssertEqual(token.shape, [1])
    }

    /// …and 1-D [vocab] in → 0-D scalar out. This documents why a
    /// rank-squeezing processor breaks the next model call: `.newAxis` on a
    /// 0-D token yields [1] (1-D) instead of the [1, 1] the model expects.
    func testTopPSamplerTokenRankFrom1D() {
        let sampler = TopPSampler(temperature: 0.3, topP: 0.95)
        let logits = MLXArray.zeros([1024], type: Float32.self)
        let token = sampler.sample(logits: logits)
        XCTAssertEqual(token.ndim, 0, "1-D logits yield a 0-D scalar token (got ndim=\(token.ndim))")
    }

    /// Full chain exactly as convertToToken drives it for a 3-D model output:
    /// slice → process → sample. The sampled token must be [1] so that
    /// `token[.newAxis]` is [1, 1] for the next model call.
    func testConvertToTokenChainProducesRank1Token() {
        var ctx = makeContext()
        let modelOut = MLXArray.zeros([1, promptLength, vocab], type: Float32.self)
        let sliced = modelOut[0..., -1, 0...]          // [1, vocab] — convertToToken's slice
        let processed = ctx.process(logits: sliced)
        let token = TopPSampler(temperature: 0.3, topP: 0.95).sample(logits: processed)
        XCTAssertEqual(token.shape, [1],
            "the sampled token must be [1]; got shape \(token.shape) — "
            + "token[.newAxis] would be \(token.ndim + 1)-D instead of the [1, 1] the model needs")
    }

    /// Value-level regression for the penalty math (mirrors the vendored
    /// SampleTests.testRepetitionContextPenalizesSeenTokens, which cannot run
    /// standalone because the vendored test bundle lacks the MLX metallib).
    /// Prompt tokens [1, 1, 3] with penalty 2.0: positive logits for seen
    /// tokens are divided by the penalty; negative ones are multiplied.
    func testPenaltyValuesPreservedAfterRankFix() throws {
        var ctx = makeContext()  // repetitionPenalty = 2.0, prompt = [1, 1, 3] pattern
        let small: [Float] = [1.0, 2.0, 3.0, 4.0]
        let logits = MLXArray(small)[.newAxis, .ellipsis]  // [1, 4]
        let processed = ctx.process(logits: logits)
        XCTAssertEqual(processed.shape, [1, 4])
        let values = processed[0].asArray(Float.self)
        // The ring keeps only the LAST `capacity` prompt tokens
        // (TokenRing.loadPrompt). Penalized ids = ids in that window.
        // makeContext uses vocab=262144 so ids 0...3 appear iff
        // (i * 977) % 262144 ∈ {0,1,2,3} for i in the window.
        // Deterministic; compute expected:
        var expected = small
        var seen = Set<Int>()
        for i in max(0, promptLength - contextSize)..<promptLength {
            let id = (i * 977) % vocab
            if id < 4, seen.insert(id).inserted {
                expected[id] = expected[id] < 0 ? expected[id] * 2.0 : expected[id] / 2.0
            }
        }
        for (got, want) in zip(values, expected) {
            XCTAssertEqual(got, want, accuracy: 1e-6)
        }
    }
}
