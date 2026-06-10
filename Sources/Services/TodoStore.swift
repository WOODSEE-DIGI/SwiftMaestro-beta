import Foundation

/// One item in an agent's live task list.
struct TodoItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var done: Bool = false
}

/// Live, per-agent task list the agent manages via native tools and the chat UI
/// shows in real time. This is distinct from the bridge's `add_todo`, which logs
/// tasks to long-term project memory; this is an ephemeral, in-session checklist
/// (persisted per agent so it survives relaunch).
@Observable
@MainActor
final class TodoStore {
    /// Task lists keyed by agent id.
    private(set) var lists: [UUID: [TodoItem]] = [:]

    func todos(for agentId: UUID) -> [TodoItem] {
        if let cached = lists[agentId] { return cached }
        let loaded = Self.load(agentId)
        lists[agentId] = loaded
        return loaded
    }

    @discardableResult
    func setList(_ titles: [String], for agentId: UUID) -> [TodoItem] {
        let items = titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { TodoItem(title: $0) }
        lists[agentId] = items
        Self.save(items, agentId)
        return items
    }

    @discardableResult
    func add(_ titles: [String], for agentId: UUID) -> [TodoItem] {
        var items = todos(for: agentId)
        items.append(contentsOf: titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { TodoItem(title: $0) })
        lists[agentId] = items
        Self.save(items, agentId)
        return items
    }

    /// Mark the item at a 1-based index done/undone. Returns the updated list,
    /// or nil if the index is out of range.
    @discardableResult
    func setDone(oneBasedIndex: Int, done: Bool, for agentId: UUID) -> [TodoItem]? {
        var items = todos(for: agentId)
        let idx = oneBasedIndex - 1
        guard items.indices.contains(idx) else { return nil }
        items[idx].done = done
        lists[agentId] = items
        Self.save(items, agentId)
        return items
    }

    func clear(for agentId: UUID) {
        lists[agentId] = []
        Self.save([], agentId)
    }

    // MARK: - Persistence (App Support/SwiftMaestro/todos/<agentId>.json)

    private nonisolated static func dir() -> URL {
        let base = WorkspaceStore.appSupportDir().appendingPathComponent("todos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func fileURL(_ agentId: UUID) -> URL {
        dir().appendingPathComponent("\(agentId.uuidString).json")
    }

    nonisolated static func load(_ agentId: UUID) -> [TodoItem] {
        guard let data = try? Data(contentsOf: fileURL(agentId)) else { return [] }
        return (try? JSONDecoder().decode([TodoItem].self, from: data)) ?? []
    }

    nonisolated static func save(_ items: [TodoItem], _ agentId: UUID) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL(agentId))
        }
    }
}
