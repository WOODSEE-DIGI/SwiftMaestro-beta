import Foundation

/// A message left by one agent in another agent's inbox.
struct AgentMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var fromName: String
    var fromAgentId: String?
    var subject: String
    var body: String
    var date: Date = Date()
    var read: Bool = false
}

/// Per-agent inbox of inter-agent messages. Lets agents leave durable messages
/// for one another (across runs) — the foundation for multi-agent coordination.
/// Persisted per recipient so messages survive relaunch.
@Observable
@MainActor
final class AgentMessageStore {
    /// Inboxes keyed by recipient agent id (oldest first).
    private(set) var inboxes: [UUID: [AgentMessage]] = [:]

    func inbox(for agentId: UUID) -> [AgentMessage] {
        if let cached = inboxes[agentId] { return cached }
        let loaded = Self.load(agentId)
        inboxes[agentId] = loaded
        return loaded
    }

    func unreadCount(for agentId: UUID) -> Int {
        inbox(for: agentId).filter { !$0.read }.count
    }

    @discardableResult
    func send(
        to recipientId: UUID, fromName: String, fromAgentId: String?,
        subject: String, body: String
    ) -> AgentMessage {
        var items = inbox(for: recipientId)
        let message = AgentMessage(
            fromName: fromName, fromAgentId: fromAgentId,
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body)
        items.append(message)
        inboxes[recipientId] = items
        Self.save(items, recipientId)
        return message
    }

    func markAllRead(for agentId: UUID) {
        var items = inbox(for: agentId)
        guard items.contains(where: { !$0.read }) else { return }
        for i in items.indices { items[i].read = true }
        inboxes[agentId] = items
        Self.save(items, agentId)
    }

    func clear(for agentId: UUID) {
        inboxes[agentId] = []
        Self.save([], agentId)
    }

    // MARK: - Persistence (App Support/SwiftMaestro/messages/<agentId>.json)

    private nonisolated static func dir() -> URL {
        let base = WorkspaceStore.appSupportDir()
            .appendingPathComponent("messages", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func fileURL(_ agentId: UUID) -> URL {
        dir().appendingPathComponent("\(agentId.uuidString).json")
    }

    nonisolated static func load(_ agentId: UUID) -> [AgentMessage] {
        guard let data = try? Data(contentsOf: fileURL(agentId)) else { return [] }
        return (try? JSONDecoder().decode([AgentMessage].self, from: data)) ?? []
    }

    nonisolated static func save(_ items: [AgentMessage], _ agentId: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL(agentId))
        }
    }
}
