import Foundation
import MLXLMCommon

// MARK: - oMLX agentic executor
//
// Runs generation against the local oMLX OpenAI-compatible endpoint, which
// decodes this hybrid GDN+MoE model ~3x faster than the in-process mlx-swift
// path. Tool calling uses the standard OpenAI function-calling protocol
// (`tools` + `tool_calls`), and tool execution reuses the same native
// (MaestroTools) and MCP sources as the native engine's agentic loop.

/// Streamed output from the oMLX agentic loop.
enum OMLXOutput: Sendable {
    case token(String)
    case toolCall(name: String)
    case info(tokensPerSecond: Double)
}

final class OMLXAgentExecutor: Sendable {

    private let endpointURL: String
    private let modelID: String
    private let maxToolIterations = 5

    init(endpointURL: String, modelID: String) {
        self.endpointURL = endpointURL
        self.modelID = modelID
    }

    // MARK: - Entry point

    /// Run the agentic loop. `toolSpecs` are OpenAI function schemas (empty to
    /// disable tools). `mcp` handles MCP-sourced tool execution.
    func run(
        messages: [Message],
        toolSpecs: [ToolSpec],
        mcp: MCPClientService?,
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool
    ) -> AsyncThrowingStream<OMLXOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Conversation in OpenAI wire format; we append assistant
                    // tool_calls and tool results across rounds.
                    var convo: [[String: Any]] = messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }

                    iterations: for _ in 0 ..< maxToolIterations {
                        let (content, toolCalls) = try await streamRound(
                            convo: convo,
                            toolSpecs: toolSpecs,
                            temperature: temperature,
                            topP: topP,
                            thinkingEnabled: thinkingEnabled,
                            continuation: continuation
                        )

                        guard !Task.isCancelled else { break iterations }

                        if toolCalls.isEmpty {
                            break iterations  // final answer already streamed
                        }

                        // Record the assistant turn that requested the tools.
                        convo.append([
                            "role": "assistant",
                            "content": content,
                            "tool_calls": toolCalls.map { $0.wire },
                        ])

                        // Execute each tool and feed the result back.
                        for tc in toolCalls {
                            continuation.yield(.toolCall(name: tc.name))
                            let result = await Self.execute(tc, mcp: mcp)
                            convo.append([
                                "role": "tool",
                                "tool_call_id": tc.id,
                                "content": result,
                            ])
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - One streaming round

    /// A tool call accumulated from streaming deltas.
    private struct PendingToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
        var wire: [String: Any] {
            ["id": id, "type": "function",
             "function": ["name": name, "arguments": arguments]]
        }
    }

    /// Stream one completion. Yields content tokens live; returns the full
    /// content and any tool calls requested this round.
    private func streamRound(
        convo: [[String: Any]],
        toolSpecs: [ToolSpec],
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        continuation: AsyncThrowingStream<OMLXOutput, Error>.Continuation
    ) async throws -> (content: String, toolCalls: [PendingToolCall]) {
        guard let url = URL(string: endpointURL.trimmingCharacters(in: .whitespaces) + "/v1/chat/completions") else {
            throw LocalLLMError.badURL(endpointURL)
        }

        var body: [String: Any] = [
            "model": modelID,
            "messages": convo,
            "stream": true,
            "temperature": temperature,
            "top_p": topP,
            // Qwen thinking toggle; oMLX forwards chat_template_kwargs to the template.
            "chat_template_kwargs": ["enable_thinking": thinkingEnabled],
        ]
        if !toolSpecs.isEmpty {
            body["tools"] = toolSpecs
            body["tool_choice"] = "auto"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalLLMError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LocalLLMError.httpError(http.statusCode, "oMLX request failed")
        }

        var content = ""
        var toolCalls: [PendingToolCall] = []
        var genTokenCount = 0
        let start = Date()

        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard
                let data = payload.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let choice = choices.first
            else { continue }

            if let delta = choice["delta"] as? [String: Any] {
                if let chunk = delta["content"] as? String, !chunk.isEmpty {
                    content += chunk
                    genTokenCount += 1
                    continuation.yield(.token(chunk))
                }
                if let deltaCalls = delta["tool_calls"] as? [[String: Any]] {
                    Self.mergeToolCallDeltas(deltaCalls, into: &toolCalls)
                }
            }

            if choice["finish_reason"] is String { break }
        }

        let elapsed = Date().timeIntervalSince(start)
        if genTokenCount > 0, elapsed > 0 {
            continuation.yield(.info(tokensPerSecond: Double(genTokenCount) / elapsed))
        }
        return (content, toolCalls)
    }

    /// Merge streamed tool_call deltas (keyed by `index`) into the accumulator.
    private static func mergeToolCallDeltas(
        _ deltas: [[String: Any]], into calls: inout [PendingToolCall]
    ) {
        for d in deltas {
            let index = (d["index"] as? Int) ?? 0
            while calls.count <= index { calls.append(PendingToolCall()) }
            if let id = d["id"] as? String, !id.isEmpty { calls[index].id = id }
            if let fn = d["function"] as? [String: Any] {
                if let name = fn["name"] as? String, !name.isEmpty { calls[index].name = name }
                if let args = fn["arguments"] as? String { calls[index].arguments += args }
            }
        }
    }

    // MARK: - Tool execution (shared with the native loop)

    private static func execute(_ tc: PendingToolCall, mcp: MCPClientService?) async -> String {
        let call = toolCall(name: tc.name, argumentsJSON: tc.arguments)
        if MaestroTools.handles(tc.name) {
            return await MaestroTools.execute(call)
        }
        if let mcp, await mcp.handles(tc.name) {
            return await mcp.execute(call)
        }
        return await MaestroTools.execute(call)
    }

    /// Build an mlx `ToolCall` from an OpenAI tool call so we can reuse the
    /// existing native/MCP execution paths.
    private static func toolCall(name: String, argumentsJSON: String) -> ToolCall {
        let args: [String: JSONValue]
        if let data = argumentsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            args = decoded
        } else {
            args = [:]
        }
        return ToolCall(function: .init(name: name, arguments: args))
    }
}
