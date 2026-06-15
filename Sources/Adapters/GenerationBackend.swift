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
// One implementation exists:
//   - InProcessMLXBackend: fully in-process via mlx-swift-lm (no external server).

/// Streamed output from a generation round / the agentic loop.
enum OMLXOutput: Sendable {
    case token(String)
    case toolCall(name: String)
    case info(tokensPerSecond: Double)
    /// A mid-run user steer was injected at a round boundary: the UI should
    /// finalize the current assistant bubble and open a fresh one for the steered
    /// continuation (so reasoning is re-armed and bubbles stay readable).
    case turnBreak
}

/// A backend-neutral, Sendable chat turn. Used to hand a conversation across the
/// actor boundary into the in-process MLX engine (mlx `Chat.Message` is not
/// Sendable, so it is rebuilt on the engine's MainActor from these).
struct ChatTurn: Sendable {
    let role: String   // system | user | assistant | tool
    let content: String
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

/// Resolves a delegated target agent's own backend + wire model id, so each
/// sub-agent can run its assigned model. Built on the MainActor (needs the
/// engine + catalog). Returns `nil` when the agent/model can't be resolved.
typealias DelegateBackendResolver =
    @Sendable (_ agentID: UUID) async -> (backend: GenerationBackend, modelID: String)?
