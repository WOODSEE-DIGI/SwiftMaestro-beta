import Foundation

/// A markdown plan/design document the agent authors and maintains.
struct Plan: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

/// Per-agent store of markdown plan documents the agent creates via native tools
/// and the chat UI can browse. Distinct from the live Todo checklist: plans are
/// longer-lived design/spec documents. Persisted per agent so they survive
/// relaunch, with a human-readable `.md` mirror for each plan (Obsidian-friendly).
@Observable
@MainActor
final class PlanStore {
    /// Plans keyed by agent id (insertion order preserved).
    private(set) var plans: [UUID: [Plan]] = [:]

    func plans(for agentId: UUID) -> [Plan] {
        if let cached = plans[agentId] { return cached }
        let loaded = Self.load(agentId)
        plans[agentId] = loaded
        return loaded
    }

    @discardableResult
    func create(title: String, content: String, for agentId: UUID) -> Plan {
        var items = plans(for: agentId)
        let plan = Plan(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content)
        items.append(plan)
        plans[agentId] = items
        Self.save(items, agentId)
        Self.writeMarkdown(plan, agentId)
        return plan
    }

    /// Update a plan's content and/or title. When `append` is true, content is
    /// appended (with a separating newline) instead of replacing. Returns the
    /// updated plan, or nil if no plan matches.
    @discardableResult
    func update(
        id: UUID, title: String?, content: String?, append: Bool, for agentId: UUID
    ) -> Plan? {
        var items = plans(for: agentId)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content {
            items[idx].content = append
                ? (items[idx].content.isEmpty ? content : items[idx].content + "\n" + content)
                : content
        }
        items[idx].updatedAt = Date()
        plans[agentId] = items
        Self.save(items, agentId)
        Self.writeMarkdown(items[idx], agentId)
        return items[idx]
    }

    /// Resolve a plan by its id string or a case-insensitive title substring.
    func find(idOrTitle raw: String, for agentId: UUID) -> Plan? {
        let items = plans(for: agentId)
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: key), let p = items.first(where: { $0.id == uuid }) {
            return p
        }
        return items.first { $0.title.localizedCaseInsensitiveContains(key) }
    }

    @discardableResult
    func delete(id: UUID, for agentId: UUID) -> Bool {
        var items = plans(for: agentId)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: idx)
        plans[agentId] = items
        Self.save(items, agentId)
        try? FileManager.default.removeItem(at: Self.markdownURL(agentId, id))
        return true
    }

    func clear(for agentId: UUID) {
        plans[agentId] = []
        Self.save([], agentId)
    }

    // MARK: - Persistence (App Support/SwiftMaestro/plans/<agentId>.json + .md mirror)

    private nonisolated static func dir() -> URL {
        let base = WorkspaceStore.appSupportDir().appendingPathComponent("plans", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func fileURL(_ agentId: UUID) -> URL {
        dir().appendingPathComponent("\(agentId.uuidString).json")
    }

    /// Per-agent folder holding human-readable `.md` mirrors of each plan.
    private nonisolated static func markdownDir(_ agentId: UUID) -> URL {
        let base = dir().appendingPathComponent(agentId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func markdownURL(_ agentId: UUID, _ planId: UUID) -> URL {
        markdownDir(agentId).appendingPathComponent("\(planId.uuidString).md")
    }

    private nonisolated static func writeMarkdown(_ plan: Plan, _ agentId: UUID) {
        let md = "# \(plan.title)\n\n\(plan.content)\n"
        try? md.data(using: .utf8)?.write(to: markdownURL(agentId, plan.id))
    }

    nonisolated static func load(_ agentId: UUID) -> [Plan] {
        guard let data = try? Data(contentsOf: fileURL(agentId)) else { return [] }
        return (try? JSONDecoder().decode([Plan].self, from: data)) ?? []
    }

    nonisolated static func save(_ items: [Plan], _ agentId: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL(agentId))
        }
    }
}
