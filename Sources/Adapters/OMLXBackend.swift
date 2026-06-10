import Foundation
import MLXLMCommon

// MARK: - oMLX HTTP backend
//
// Talks to the local oMLX OpenAI-compatible endpoint (/v1/chat/completions) with
// streaming + standard function-calling (`tools` + `tool_calls`). Decodes this
// hybrid GDN+MoE model faster at prefill than the in-process path, with a
// server-side prefix cache.

final class OMLXBackend: GenerationBackend {

    let endpointURL: String
    let modelID: String

    init(endpointURL: String, modelID: String) {
        self.endpointURL = endpointURL
        self.modelID = modelID
    }

    /// Stream one completion. Yields content tokens live; returns the full
    /// content and any tool calls requested this round.
    func streamRound(
        convo: [[String: Any]],
        toolSpecs: [ToolSpec],
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        continuation: AsyncThrowingStream<OMLXOutput, Error>.Continuation
    ) async throws -> (content: String, toolCalls: [RoundToolCall]) {
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
        var toolCalls: [RoundToolCall] = []
        var genTokenCount = 0
        // Decode-rate timing: measured from the FIRST generated content token, not
        // from request start, so prefill (time-to-first-token) doesn't make short,
        // tool-heavy turns report a misleadingly slow rate.
        var firstTokenAt: Date?
        var lastTokenAt: Date?

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
                    let now = Date()
                    if firstTokenAt == nil { firstTokenAt = now }
                    lastTokenAt = now
                    continuation.yield(.token(chunk))
                }
                if let deltaCalls = delta["tool_calls"] as? [[String: Any]] {
                    Self.mergeToolCallDeltas(deltaCalls, into: &toolCalls)
                }
            }

            if choice["finish_reason"] is String { break }
        }

        if let firstTokenAt, let lastTokenAt, genTokenCount > 1 {
            let decodeSpan = lastTokenAt.timeIntervalSince(firstTokenAt)
            if decodeSpan > 0 {
                continuation.yield(.info(tokensPerSecond: Double(genTokenCount - 1) / decodeSpan))
            }
        }
        return (content, toolCalls)
    }

    /// Merge streamed tool_call deltas (keyed by `index`) into the accumulator.
    private static func mergeToolCallDeltas(
        _ deltas: [[String: Any]], into calls: inout [RoundToolCall]
    ) {
        for d in deltas {
            let index = (d["index"] as? Int) ?? 0
            while calls.count <= index { calls.append(RoundToolCall()) }
            if let id = d["id"] as? String, !id.isEmpty { calls[index].id = id }
            if let fn = d["function"] as? [String: Any] {
                if let name = fn["name"] as? String, !name.isEmpty { calls[index].name = name }
                if let args = fn["arguments"] as? String { calls[index].arguments += args }
            }
        }
    }
}
