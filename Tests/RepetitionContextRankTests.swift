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
}
