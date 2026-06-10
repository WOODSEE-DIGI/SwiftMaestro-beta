import Foundation
import MLXLMCommon

// MARK: - In-process MLX backend
//
// Runs generation fully on-device via mlx-swift-lm (no external server), per
// WWDC26 "Run local agentic AI on the Mac using MLX". Renders the OpenAI-wire
// conversation into mlx `Chat.Message` form and delegates one generation round
// to `MLXInferenceEngine.generateRound`. Tool calls are parsed by mlx-swift-lm's
// model-specific parser (e.g. Qwen3.5/3.6 -> xmlFunction) and surfaced as
// `RoundToolCall` for the shared agentic loop in AgentExecutor.

final class InProcessMLXBackend: GenerationBackend {

    let engine: MLXInferenceEngine
    let model: MaestroModel

    init(engine: MLXInferenceEngine, model: MaestroModel) {
        self.engine = engine
        self.model = model
    }

    func streamRound(
        convo: [[String: Any]],
        toolSpecs: [ToolSpec],
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        continuation: AsyncThrowingStream<OMLXOutput, Error>.Continuation
    ) async throws -> (content: String, toolCalls: [RoundToolCall]) {
        let turns = Self.toChatTurns(convo)
        let tools: [ToolSpec]? = toolSpecs.isEmpty ? nil : toolSpecs
        return try await engine.generateRound(
            chatTurns: turns,
            toolSchemas: tools,
            model: model,
            temperature: temperature,
            topP: topP,
            thinkingEnabled: thinkingEnabled,
            onToken: { continuation.yield(.token($0)) },
            onInfo: { continuation.yield(.info(tokensPerSecond: $0)) }
        )
    }

    // MARK: - Conversion

    /// Convert OpenAI-wire messages to Sendable `ChatTurn`s (rebuilt into mlx
    /// `Chat.Message` on the engine's MainActor). Prior assistant `tool_calls`
    /// aren't structurally representable, so we keep their text content; tool
    /// results map to role `tool`. Multimodal content arrays are flattened to
    /// their text parts (this in-process path is text).
    private static func toChatTurns(_ convo: [[String: Any]]) -> [ChatTurn] {
        convo.compactMap { message in
            guard let role = message["role"] as? String else { return nil }
            return ChatTurn(role: role, content: text(from: message["content"]))
        }
    }

    private static func text(from content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap {
                ($0["type"] as? String) == "text" ? $0["text"] as? String : nil
            }.joined(separator: "\n")
        }
        return ""
    }
}
