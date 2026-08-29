import Foundation
import MLXLMCommon

// MARK: - Pluggable generation backend
//
// The agentic loop (an app's AgentExecutor) is backend-agnostic: it manages the
// conversation, executes tools (with project/working-dir injection + delegation),
// and streams activity. A `GenerationBackend` provides ONE generation round —
// given the conversation (OpenAI wire format) and advertised tools, it streams
// content tokens and returns the round's content + any requested tool calls.
//
// Two implementations exist in SwiftMaestro today:
//   - InProcessMLXBackend: fully in-process via mlx-swift-lm (no external server).
//   - RemoteLMStudioBackend: HTTP to a remote LM Studio server.
// Both stay app-side (they wrap concrete, app-specific engine/session types);
// only this backend-neutral protocol + its Sendable wire types live in the kit.

/// Streamed output from a generation round / the agentic loop.
public enum AgentOutput: Sendable {
    case token(String)
    case toolCall(name: String, arguments: String)
    case info(tokensPerSecond: Double)
    /// A mid-run user steer was injected at a round boundary: the UI should
    /// finalize the current assistant bubble and open a fresh one for the steered
    /// continuation (so reasoning is re-armed and bubbles stay readable).
    case turnBreak
    /// Token from a delegated sub-agent. The UI streams this into the target
    /// agent's chat window in real-time so the user can see sub-agent activity.
    case delegateToken(agentID: String, token: String)
    /// Delegation started — the UI should append an empty assistant message
    /// to the target agent's chat and prepare for streaming.
    /// `modelID` is the effective (possibly promoted) wire model ID for the sub-agent.
    case delegateStart(agentID: String, modelID: String)
    /// Delegation finished — the UI should save the target agent's history.
    case delegateFinish(agentID: String)
}

/// A backend-neutral, Sendable chat turn. Used to hand a conversation across the
/// actor boundary into an in-process engine (mlx `Chat.Message` is not
/// Sendable, so it is rebuilt on the engine's MainActor from these).
public struct ChatTurn: Sendable {
    public let role: String   // system | user | assistant | tool
    public let content: String
    /// Raw image bytes (PNG/JPEG) attached to this turn. Only populated for
    /// user messages with multimodal content.
    public let images: [Data]

    public init(role: String, content: String, images: [Data]) {
        self.role = role
        self.content = content
        self.images = images
    }
}

/// One tool call accumulated during a generation round (OpenAI function-calling).
public struct RoundToolCall: Sendable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String = "", name: String = "", arguments: String = "") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// OpenAI wire representation for the assistant `tool_calls` array.
    public var wire: [String: Any] {
        ["id": id, "type": "function",
         "function": ["name": name, "arguments": arguments]]
    }
}

/// A model backend that produces one generation round. Implementations stream
/// content tokens (and a decode-rate `.info`) via `continuation`, and return the
/// full content plus any tool calls the model requested this round.
public protocol GenerationBackend: Sendable {
    func streamRound(
        convo: [[String: Any]],
        toolSpecs: [ToolSpec],
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        maxTokens: Int,
        continuation: AsyncThrowingStream<AgentOutput, Error>.Continuation
    ) async throws -> (content: String, toolCalls: [RoundToolCall])
}

/// Resolves a delegated target agent's own backend, wire model id, and per-run
/// token budget, so each sub-agent runs its assigned model (or a promoted model
/// if the assigned one is too weak for tool-calling work). Returns `nil` when
/// the agent/model can't be resolved.
public typealias DelegateBackendResolver =
    @Sendable (_ agentID: UUID) async -> (backend: GenerationBackend, modelID: String, maxTokens: Int)?
