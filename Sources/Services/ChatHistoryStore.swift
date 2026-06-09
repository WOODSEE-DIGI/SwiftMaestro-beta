import Foundation

/// Persists each agent's chat history (the conversation) separately from project
/// memory. Clearing a chat removes only this file — the project's ai-context
/// memory is never touched. History survives app restarts.
enum ChatHistoryStore {
    private static func chatsDir() -> URL {
        let dir = WorkspaceStore.appSupportDir().appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(agentId: UUID) -> URL {
        chatsDir().appendingPathComponent("\(agentId.uuidString).json")
    }

    static func load(agentId: UUID) -> [Message]? {
        guard let data = try? Data(contentsOf: fileURL(agentId: agentId)) else { return nil }
        return try? JSONDecoder().decode([Message].self, from: data)
    }

    static func save(_ messages: [Message], agentId: UUID) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: fileURL(agentId: agentId))
    }

    static func clear(agentId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(agentId: agentId))
    }
}
