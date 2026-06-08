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
                    switch output {
                    case .token(let token):
                        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                            messages[idx].content += token
                        }
                    case .toolCall(let name):
                        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                            messages[idx].content += "\n🔧 called `\(name)`\n"
                        }
                    case .info:
                        break
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

    /// Hard rules governing tool use. The tools wired into this app are REAL and
    /// run on the user's machine, so fabricated calls/outputs are actively harmful.
    /// This is injected into every agent's system prompt.
    private static let toolDiscipline = """
        TOOL USE — STRICT RULES:
        - Your tools are REAL and execute on the user's actual system. Use them by \
        making a real tool call. NEVER write a tool call, shell command, JSON, or a \
        tool's output as plain text or inside a code block to simulate it.
        - NEVER invent, guess, paraphrase, or pre-write tool results. Only state what \
        a tool ACTUALLY returned to you after you called it.
        - Make ONE tool call at a time, then wait for its real result before deciding \
        the next step. Do not narrate a sequence of imaginary calls.
        - If a tool returns empty or no output, say exactly that — do not fabricate a \
        plausible-looking result (e.g. fake file listings, paths, or timestamps).
        - If you cannot or did not call a tool, say so plainly. Never claim an action \
        (creating a file, running a command) happened unless a real tool result \
        confirms it.
        """

    /// Builds the seed system message, appending any enabled rules that apply
    /// to this agent (global "All" rules plus rules scoped to the agent name).
    private static func systemMessage(for agent: Agent) -> Message {
        let base: String
        switch agent.name {
        case "Coding":
            base = "You are a coding assistant skilled across many languages "
                + "(Swift, JavaScript, Python, Rust, and more). Help with software "
                + "development, debugging, and code review. Do not assume a specific "
                + "programming language unless the user states one — ask if it's unclear."
        default:
            base = "You are \(agent.name), a helpful AI assistant."
        }
        var content = base + "\n\n" + Self.toolDiscipline
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
        // Strip the display-only "🔧 called `name`" markers we inject for the UI.
        // They are NOT real tool-call tokens; if replayed as assistant history
        // the model imitates them as plain text and fabricates tool calls/results.
        var output: [Message] = messages.compactMap { message in
            guard message.role == .assistant else { return message }
            let cleaned = Self.stripToolMarkers(message.content)
            // Drop assistant turns that were nothing but tool-call markers.
            if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message.content.isEmpty ? message : nil
            }
            var copy = message
            copy.content = cleaned
            return copy
        }
        if let last = output.last, last.role == .assistant, last.content.isEmpty {
            output.removeLast()
        }
        return output
    }

    /// Remove lines containing the injected tool-call indicator.
    private static func stripToolMarkers(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("🔧 called") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
