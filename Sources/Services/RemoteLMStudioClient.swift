import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Remote LM Studio backend
//
// Runs generation on a remote LM Studio server via its OpenAI-compatible
// `/v1/chat/completions` endpoint. Conforms to `GenerationBackend` so the
// agentic loop (AgentExecutor) can use it interchangeably with the local
// in-process MLX backend. Tool calls are parsed from the SSE stream in
// OpenAI function-calling format.

final class RemoteLMStudioBackend: GenerationBackend, @unchecked Sendable {

    let config: LMStudioConfig
    let model: MaestroModel

    init(config: LMStudioConfig, model: MaestroModel) {
        self.config = config
        self.model = model
    }

    func streamRound(
        convo: [[String: Any]],
        toolSpecs: [ToolSpec],
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        maxTokens: Int,
        continuation: AsyncThrowingStream<AgentOutput, Error>.Continuation
    ) async throws -> (content: String, toolCalls: [RoundToolCall]) {
        guard let url = config.chatCompletionURL else {
            throw RemoteModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.requestTimeout

        // Resolve secret:// API key from Keychain at send time.
        let resolvedKey = config.apiKey.hasPrefix(SecretsStore.referencePrefix)
            ? (SecretsStore.resolve(reference: config.apiKey, currentProject: nil) ?? "")
            : config.apiKey
        if !resolvedKey.isEmpty {
            request.setValue("Bearer \(resolvedKey)", forHTTPHeaderField: "Authorization")
        }

        // Build request body — conversation is already OpenAI wire format.
        var body: [String: Any] = [
            "model": model.huggingFaceID,
            "messages": convo,
            "stream": true,
            "temperature": temperature,
            "top_p": topP,
            "max_tokens": maxTokens,
        ]

        // Convert ToolSpec (OpenAI function schema) to the `tools` array.
        if !toolSpecs.isEmpty {
            body["tools"] = toolSpecs.map { spec in
                // ToolSpec is [String: any Sendable] with "type" and "function" keys.
                var tool: [String: Any] = [:]
                for (key, value) in spec {
                    tool[key] = value
                }
                return tool
            }
            // Some OpenAI-compatible servers (notably LM Studio with certain
            // model templates) silently IGNORE the tools array unless the
            // choice is made explicit — the model then freestyles tool calls
            // as plain text instead of emitting structured tool_calls deltas.
            // "auto" engages native function calling where supported; servers
            // that don't support it at all still fall through to the
            // executor's raw-text tool-call recovery.
            body["tool_choice"] = "auto"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        NSLog("[REMOTE] POST %@ model=%@ tools=%d", url.absoluteString, model.huggingFaceID, toolSpecs.count)

        let startTime = Date()
        var content = ""
        var toolCalls: [RoundToolCall] = []
        // Accumulate tool call deltas keyed by index (OpenAI streams args incrementally).
        var toolCallBuffers: [Int: (id: String, name: String, arguments: String)] = [:]

        // Use URLSession.bytes for true SSE streaming.
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            NSLog("[REMOTE] CONNECTION FAILED after %.2fs: %@", elapsed, error.localizedDescription)
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteModelError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var bodyData = Data()
            for try await byte in bytes { bodyData.append(byte) }
            let bodyString = String(data: bodyData, encoding: .utf8) ?? "Unknown error"
            throw RemoteModelError.httpError(httpResponse.statusCode, bodyString)
        }

        var buffer = ""
        for try await byte in bytes {
            buffer.append(Character(UnicodeScalar(byte)))
            // SSE lines are terminated by \n.
            guard buffer.contains("\n") else { continue }

            for line in buffer.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard trimmed.hasPrefix("data: ") else { continue }

                let jsonPart = String(trimmed.dropFirst(6))
                if jsonPart == "[DONE]" {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let tps = elapsed > 0 ? Double(content.count) / elapsed : 0
                    NSLog("[REMOTE] done: %d chars, %d tool calls in %.2fs (%.0f chars/s)",
                          content.count, toolCalls.count, elapsed, tps)
                    continuation.yield(.info(tokensPerSecond: tps))
                    continuation.finish()
                    // Finalize: convert accumulated tool call buffers.
                    toolCalls = toolCallBuffers.sorted(by: { $0.key < $1.key }).map { _, buf in
                        RoundToolCall(id: buf.id, name: buf.name, arguments: buf.arguments)
                    }
                    return (content, toolCalls)
                }

                guard let jsonData = jsonPart.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let delta = firstChoice["delta"] as? [String: Any] else {
                    continue
                }

                // Content token.
                if let token = delta["content"] as? String, !token.isEmpty {
                    content += token
                    continuation.yield(.token(token))
                }

                // Tool call delta (OpenAI function-calling format).
                if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] {
                    for tcDelta in toolCallDeltas {
                        guard let index = tcDelta["index"] as? Int else { continue }
                        var buffer = toolCallBuffers[index] ?? (id: "", name: "", arguments: "")

                        if let id = tcDelta["id"] as? String, !id.isEmpty {
                            buffer.id = id
                        }
                        if let function = tcDelta["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty {
                                buffer.name = name
                            }
                            if let args = function["arguments"] as? String {
                                buffer.arguments += args
                            }
                        }
                        toolCallBuffers[index] = buffer
                    }
                }
            }
            buffer = ""
        }

        // Stream ended without [DONE] — finalize what we have.
        let elapsed = Date().timeIntervalSince(startTime)
        NSLog("[REMOTE] stream ended (no [DONE]): %d chars, %d tool calls in %.2fs",
              content.count, toolCalls.count, elapsed)
        continuation.finish()
        toolCalls = toolCallBuffers.sorted(by: { $0.key < $1.key }).map { _, buf in
            RoundToolCall(id: buf.id, name: buf.name, arguments: buf.arguments)
        }
        return (content, toolCalls)
    }
}

// MARK: - Errors

enum RemoteModelError: LocalizedError {
    case invalidURL
    case invalidResponse
    case noContent
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid model endpoint URL"
        case .invalidResponse: return "Invalid response from model server"
        case .noContent: return "No content returned from model"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}
