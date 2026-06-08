import Foundation
import MLXLMCommon

// MARK: - Native (in-process) tools
//
// First-class tool source: these run directly in-app (no IPC, no subprocess),
// ideal for SwiftMaestro-owned / privileged / latency-sensitive capabilities.
// MCP-sourced tools will later join the *same* agentic loop in MLXInferenceEngine.

/// Input for tools that take no arguments.
struct NoToolArgs: Codable {}

/// Result of the `get_current_time` tool.
struct CurrentTimeResult: Codable {
    let current_time: String
    let timezone: String
}

/// Registry of native, in-process Swift tools available to the agent.
enum MaestroTools {

    /// Returns the real local date/time. Unambiguously verifiable: the model
    /// cannot know the true current time without calling this, so a correct
    /// answer proves the tool round-trip actually fired.
    static let getCurrentTime = Tool<NoToolArgs, CurrentTimeResult>(
        name: "get_current_time",
        description:
            "Get the current local date and time. Call this whenever the user asks "
            + "what the current time or date is.",
        parameters: []
    ) { _ in
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return CurrentTimeResult(
            current_time: formatter.string(from: Date()),
            timezone: TimeZone.current.identifier
        )
    }

    /// All native tools exposed to the model.
    static let all: [any ToolProtocol] = [getCurrentTime]

    /// Tool schemas to advertise to the model via `UserInput(tools:)`.
    static var schemas: [ToolSpec] { all.map { $0.schema } }

    /// Whether a native (in-process) tool owns the given name. Used by the
    /// agentic loop to route a tool call to the native registry before MCP.
    static func handles(_ name: String) -> Bool {
        schemas.contains { spec in
            (spec["function"] as? [String: any Sendable])?["name"] as? String == name
        }
    }

    /// Execute a parsed tool call and return a JSON string to feed back to the model.
    static func execute(_ call: ToolCall) async -> String {
        switch call.function.name {
        case getCurrentTime.name:
            do {
                let output = try await call.execute(with: getCurrentTime)
                return encode(output)
            } catch {
                return #"{"error": "\#(error.localizedDescription)"}"#
            }
        default:
            return #"{"error": "unknown tool: \#(call.function.name)"}"#
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
