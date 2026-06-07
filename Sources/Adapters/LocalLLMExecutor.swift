import Foundation

// MARK: - Errors

enum LocalLLMError: LocalizedError {
    case badURL(String)
    case httpError(Int, String)
    case noContent
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .badURL(let url):          return "Invalid endpoint URL: \(url)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .noContent:                return "The model returned no content"
        case .invalidResponse:          return "The model returned an invalid response format"
        }
    }
}

// MARK: - Private SSE response types

private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning_content: String?
        }
        let delta: Delta
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

// MARK: - LocalLLMExecutor

/// Sends chat-completion requests to any OpenAI-compatible endpoint.
/// Supports SSE streaming for real-time token output.
final class LocalLLMExecutor {
    private let config: LocalLLMConfig
    private let apiKey: String?
    private let decoder = JSONDecoder()
    
    private var requestTimeoutSeconds: TimeInterval {
        max(30, config.requestTimeoutSeconds)
    }
    
    init(config: LocalLLMConfig, apiKey: String? = nil) {
        self.config = config
        self.apiKey = apiKey
    }
    
    // MARK: - Entry point
    
    func stream(messages: [Message]) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = config.chatCompletionURL else {
            throw LocalLLMError.badURL(config.endpointURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        
        if let resolved = Self.resolvedKey(from: apiKey), !resolved.isEmpty {
            request.setValue("Bearer \(resolved)", forHTTPHeaderField: "Authorization")
        }
        
        let body = try Self.buildRequestBody(
            messages: messages,
            modelID: config.modelIdentifier,
            stream: true
        )
        request.httpBody = body
        
        return AsyncThrowingStream { continuation in
            let session = URLSession(configuration: .default)
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: LocalLLMError.invalidResponse)
                    return
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let bodyString = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown error"
                    continuation.finish(throwing: LocalLLMError.httpError(httpResponse.statusCode, bodyString))
                    return
                }
                
                guard let data = data else {
                    continuation.finish(throwing: LocalLLMError.noContent)
                    return
                }
                
                // Parse SSE stream
                let content = String(data: data, encoding: .utf8) ?? ""
                for line in content.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if trimmed.hasPrefix("data: ") {
                        let jsonPart = String(trimmed.dropFirst(6))
                        
                        if jsonPart == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        
                        do {
                            if let chunk = try? self.decoder.decode(ChatCompletionChunk.self, from: Data(jsonPart.utf8)) {
                                if let content = chunk.choices.first?.delta.content {
                                    continuation.yield(content)
                                }
                                
                                if chunk.choices.first?.finishReason != nil {
                                    continuation.finish()
                                }
                            }
                        } catch {
                            // Skip malformed chunks
                        }
                    }
                }
                
                continuation.finish()
            }
            task.resume()
        }
    }
    
    // MARK: - Non-streaming version (for tool loops)
    
    func complete(messages: [Message], modelID: String? = nil) async throws -> String {
        guard let url = config.chatCompletionURL else {
            throw LocalLLMError.badURL(config.endpointURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let resolved = Self.resolvedKey(from: apiKey), !resolved.isEmpty {
            request.setValue("Bearer \(resolved)", forHTTPHeaderField: "Authorization")
        }
        
        let actualModelID = modelID ?? config.modelIdentifier
        let body = try Self.buildRequestBody(
            messages: messages,
            modelID: actualModelID,
            stream: false
        )
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalLLMError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LocalLLMError.httpError(httpResponse.statusCode, bodyString)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LocalLLMError.invalidResponse
        }
        
        return content
    }
    
    // MARK: - Private helpers
    
    private static func buildRequestBody(
        messages: [Message],
        modelID: String,
        stream: Bool
    ) throws -> Data {
        var body: [String: Any] = [
            "model": modelID,
            "messages": messages.map { apiMessage(from: $0) },
            "stream": stream
        ]
        
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }
    
    private static func apiMessage(from message: Message) -> [String: Any] {
        ["role": message.role.rawValue, "content": message.content]
    }

    /// Resolves the API key, supporting `secret://<name>` references that are
    /// looked up in the Keychain only at send time, so the raw value never
    /// appears in any object the model sees or that gets persisted.
    private static func resolvedKey(from apiKey: String?) -> String? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        if apiKey.hasPrefix(SecretsStore.referencePrefix) {
            return SecretsStore.resolve(reference: apiKey, currentProject: nil)
        }
        return apiKey
    }
}
