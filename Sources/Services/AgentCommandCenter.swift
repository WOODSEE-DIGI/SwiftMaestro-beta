import Foundation

/// Central dispatcher for incoming external commands (Siri / App Intents,
/// Stream Deck via HTTP, etc.). The currently active ChatView registers a
/// handler so commands can be routed to the visible agent.
@MainActor
final class AgentCommandCenter {
    static let shared = AgentCommandCenter()

    /// Handler invoked when an external command asks the agent a question.
    /// The closure receives the plain-text question and should send it.
    var askAgentHandler: ((String) -> Void)?

    /// Whether the currently visible chat is the Navigator agent.
    /// Used to restrict audio input (mic, push-to-talk) to Navigator.
    var isNavigatorActive: Bool = false

    /// Dispatch a question to the active agent. If no handler is registered
    /// (e.g. app is closed), the command is ignored.
    func askAgent(question: String) {
        guard !question.isEmpty else { return }
        askAgentHandler?(question)
    }

    private init() {}
}
