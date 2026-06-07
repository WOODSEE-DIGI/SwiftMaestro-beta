import Foundation

/// Remote client for LM Studio models
final class RemoteLMStudioClient {
    let config: LMStudioConfig
    
    init(config: LMStudioConfig = LMStudioConfig()) {
        self.config = config
    }
    
    /// Stream chat completions from remote model
    func stream(
        messages: [Message],
        model: String = LMStudioConfig.codingModel,
        temperature: Double = 0.7,
        maxTokens: Int? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            nonisolated(unsafe) let client = self
            Task {
                do {
                    try await client.runStreamingRequest(
                        messages: messages,
                        model: model,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func runStreamingRequest(
        messages: [Message],
        model: String,
        temperature: Double,
        maxTokens: Int?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let url = config.chatCompletionURL else {
            throw RemoteModelError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Support `secret://<name>` references resolved from Keychain at send time.
        let resolvedKey = config.apiKey.hasPrefix(SecretsStore.referencePrefix)
            ? (SecretsStore.resolve(reference: config.apiKey, currentProject: nil) ?? "")
            : config.apiKey
        if !resolvedKey.isEmpty {
            request.setValue("Bearer \(resolvedKey)", forHTTPHeaderField: "Authorization")
        }
        
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
            "temperature": temperature
        ]
        
        if let maxTokens = maxTokens {
            body["max_tokens"] = maxTokens
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                continuation.finish(throwing: error)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                continuation.finish(throwing: RemoteModelError.invalidResponse)
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let bodyString = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown error"
                continuation.finish(throwing: RemoteModelError.httpError(httpResponse.statusCode, bodyString))
                return
            }
            
            guard let data = data else {
                continuation.finish(throwing: RemoteModelError.noContent)
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

                    let jsonData = Data(jsonPart.utf8)
                    if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let delta = firstChoice["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        continuation.yield(content)
                    }
                }
            }
            
            continuation.finish()
        }
        task.resume()
    }
}

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
