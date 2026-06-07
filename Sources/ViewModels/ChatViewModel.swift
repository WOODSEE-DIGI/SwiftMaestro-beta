import Foundation

/// ChatViewModel — uses native MLX inference as primary backend.
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message]
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?

    private let agent: Agent
    private var generateTask: Task<Void, Never>?

    init(agent: Agent) {
        self.agent = agent
        self.messages = [Self.systemMessage(for: agent)]
    }

    func send(engine: MLXInferenceEngine, model: MaestroModel?) {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        guard let model else {
            errorMessage = "No model selected. Open Settings (⌘,) to configure."
            return
        }

        inputText = ""
        errorMessage = nil
        messages.append(Message(role: .user, content: prompt))
        messages.append(Message(role: .assistant, content: ""))
        isStreaming = true

        generateTask = Task {
            let requestMessages = messagesForInference()
            do {
                let stream = try await engine.generate(
                    messages: requestMessages,
                    model: model
                )
                for await output in stream {
                    guard !Task.isCancelled else { break }
                    if case .token(let token) = output {
                        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                            messages[idx].content += token
                        }
                    }
                }
            } catch {
                do {
                    let defaults = UserDefaults.standard
                    let endpoint = defaults.string(forKey: "models.endpointURL") ?? "http://localhost:8012"
                    let configuredModel = defaults.string(forKey: "models.modelID") ?? ""
                    let discoveredModelID = await Self.discoverEndpointModelID(endpointURL: endpoint)
                    let resolvedModelID: String

                    if !configuredModel.isEmpty {
                        resolvedModelID = configuredModel
                    } else if let discoveredModelID {
                        resolvedModelID = discoveredModelID
                    } else {
                        resolvedModelID = model.huggingFaceID
                    }

                    let fallbackConfig = LocalLLMConfig(
                        name: "Endpoint Fallback",
                        endpointURL: endpoint,
                        modelIdentifier: resolvedModelID,
                        requiresAPIKey: defaults.bool(forKey: "models.requiresAPIKey"),
                        runtimeBackend: .omLX,
                        requestTimeoutSeconds: 300
                    )
                    let executor = LocalLLMExecutor(config: fallbackConfig)
                    let fallbackStream = try await executor.stream(messages: requestMessages)
                    for try await token in fallbackStream {
                        guard !Task.isCancelled else { break }
                        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                            messages[idx].content += token
                        }
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            isStreaming = false
        }
    }

    func cancel(engine: MLXInferenceEngine) {
        generateTask?.cancel()
        engine.cancel()
        isStreaming = false
    }

    func clearHistory() {
        messages = [Self.systemMessage(for: agent)]
    }

    /// Builds the seed system message, appending any enabled rules that apply
    /// to this agent (global "All" rules plus rules scoped to the agent name).
    private static func systemMessage(for agent: Agent) -> Message {
        var content = "You are \(agent.name), a helpful AI assistant."
        let applicable = SwiftMaestroSettingsStore.loadRules().filter { rule in
            rule.enabled
                && !rule.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (rule.scope == "All" || rule.scope == agent.name)
        }
        if !applicable.isEmpty {
            let list = applicable
                .map { "- \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: "\n")
            content += "\n\nFollow these rules at all times:\n\(list)"
        }
        return Message(role: .system, content: content)
    }

    private func messagesForInference() -> [Message] {
        var output = messages
        if let last = output.last, last.role == .assistant, last.content.isEmpty {
            output.removeLast()
        }
        return output
    }

    nonisolated private static func discoverEndpointModelID(endpointURL: String) async -> String? {
        guard let url = URL(string: endpointURL + "/v1/models") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataArray = json["data"] as? [[String: Any]]
            else {
                return nil
            }
            return dataArray.compactMap { $0["id"] as? String }.first
        } catch {
            return nil
        }
    }
}
