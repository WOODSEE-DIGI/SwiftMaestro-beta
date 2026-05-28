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
        self.messages = [
            Message(role: .system, content: "You are \(agent.name), a helpful AI assistant.")
        ]
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
            do {
                let stream = try await engine.generate(
                    messages: messages,
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
                errorMessage = error.localizedDescription
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
        messages = [
            Message(role: .system, content: "You are \(agent.name), a helpful AI assistant.")
        ]
    }
}
