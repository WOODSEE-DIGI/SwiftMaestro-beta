import Foundation
import MLXLMCommon

// MARK: - Pluggable generation backend
//
// The agentic loop (AgentExecutor) is backend-agnostic: it manages the
// conversation, executes tools (with project/working-dir injection + delegation),
// and streams activity. A `GenerationBackend` provides ONE generation round —
// given the conversation (OpenAI wire format) and advertised tools, it streams
// content tokens and returns the round's content + any requested tool calls.
//
// Two implementations exist:
//   - OMLXBackend: the local oMLX OpenAI-compatible HTTP endpoint.
//   - InProcessMLXBackend: fully in-process via mlx-swift-lm (no external server).

/// Streamed output from a generation round / the agentic loop.
enum OMLXOutput: Sendable {
    case token(String)
    case toolCall(name: String)
    case info(tokensPerSecond: Double)
}

/// One tool call accumulated during a generation round (OpenAI function-calling).
struct RoundToolCall: Sendable {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""

    /// OpenAI wire representation for the assistant `tool_calls` array.
    var wire: [String: Any] {
        ["id": id, "type": "function",
         "function": ["name": name, "arguments": arguments]]
    }
}

/// A model backend that produces one generation round. Implementations stream
/// content tokens (and a decode-rate `.info`) via `continuation`, and return the
/// full content plus any tool calls the model requested this round.
protocol GenerationBackend: Sendable {
    func streamRound(
        convo: [[String: Any]],
        toolSpecs: [ToolSpec],
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        continuation: AsyncThrowingStream<OMLXOutput, Error>.Continuation
    ) async throws -> (content: String, toolCalls: [RoundToolCall])
}
