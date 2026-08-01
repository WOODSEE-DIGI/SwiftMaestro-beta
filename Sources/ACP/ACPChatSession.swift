import Foundation

// MARK: - Headless ACP chat session
//
// A minimal, UI-free chat runner used when SwiftMaestro is launched as an ACP
// agent (e.g. by Xcode). It loads the default model, builds a system prompt,
// and streams the response back to the ACP client via the AgentClientProtocol.

@MainActor
final class ACPChatSession {
    private let engine: MLXInferenceEngine
    private let catalog: ModelCatalog
    private let workingDirectory: String?
    private let systemPrompt: String

    init(engine: MLXInferenceEngine, catalog: ModelCatalog, workingDirectory: String?, systemPrompt: String) {
        self.engine = engine
        self.catalog = catalog
        self.workingDirectory = workingDirectory
        self.systemPrompt = systemPrompt
    }

    /// Run a single prompt turn and stream text chunks through the handler.
    /// Returns when the turn completes or fails.
    func run(prompt: String, chunkHandler: @escaping @Sendable (String) -> Void) async -> String {
        guard let model = catalog.selectedModel else {
            return "No default model selected."
        }

        let messages: [Message] = [
            Message(role: .system, content: systemPrompt),
            Message(role: .user, content: prompt),
        ]

        do {
            var buffer = ""
            let stream = try await engine.generate(messages: messages, model: model)
            for await output in stream {
                if Task.isCancelled { break }
                switch output {
                case .token(let text):
                    buffer.append(text)
                    chunkHandler(text)
                case .toolCall(let name):
                    let note = "\n🔧 called `\(name)`\n"
                    buffer.append(note)
                    chunkHandler(note)
                case .info:
                    break
                }
            }
            return buffer.isEmpty ? "(no response)" : buffer
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Default system prompt for ACP mode

extension ACPChatSession {
    static func defaultSystemPrompt(workingDirectory: String?) -> String {
        var prompt = """
            You are SwiftMaestro, a local AI coding assistant running inside Xcode \
            via the Agent Client Protocol (ACP). You are powered by on-device models \
            and have access to local tools for file operations, shell commands, git, \
            and web search.

            - Work in the project directory Xcode provides.
            - Use tools to read, search, edit, build, and test code when needed.
            - Prefer edit_file for small changes and write_file for new files.
            - Do not commit or push unless explicitly asked.
            - Keep responses concise and actionable.
            """
        if let wd = workingDirectory {
            prompt += "\n\nWORKING DIRECTORY: \(wd)"
        }
        return prompt
    }
}
