import Foundation

/// A markdown plan/design document the agent authors and maintains.
struct Plan: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

/// Where a plan lives. Personal plans belong to a single agent; project plans are
/// shared by every agent in a project (and authored/managed by the Navigator).
enum PlanScope: Hashable {
    case agent(UUID)
    case project(String)

    /// In-memory dictionary key.
    var key: String {
        switch self {
        case .agent(let id): return id.uuidString
        case .project(let name): return "project:\(name)"
        }
    }

    /// Rebuild a scope from its `key` (used to resolve a plan window's target).
    init?(key: String) {
        if key.hasPrefix("project:") {
            let name = String(key.dropFirst("project:".count))
            guard !name.isEmpty else { return nil }
            self = .project(name)
        } else if let id = UUID(uuidString: key) {
            self = .agent(id)
        } else {
            return nil
        }
    }

    /// Filesystem-safe base name. Agent scopes keep their bare UUID filename for
    /// backward compatibility with plans created before scoping existed.
    var fileBase: String {
        switch self {
        case .agent(let id):
            return id.uuidString
        case .project(let name):
            let safe = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: "_")
            return "project-\(safe.isEmpty ? "default" : safe)"
        }
    }
}

/// Store of markdown plan documents, scoped per-agent (personal) or per-project
/// (shared). Persisted so they survive relaunch, with a human-readable `.md`
/// mirror for each plan (Obsidian-friendly).
@Observable
@MainActor
final class PlanStore {
    /// Plans keyed by scope key (insertion order preserved).
    private(set) var plansByScope: [String: [Plan]] = [:]

    func plans(in scope: PlanScope) -> [Plan] {
        if let cached = plansByScope[scope.key] { return cached }
        let loaded = Self.load(scope)
        plansByScope[scope.key] = loaded
        return loaded
    }

    @discardableResult
    func create(title: String, content: String, in scope: PlanScope) -> Plan {
        var items = plans(in: scope)
        let plan = Plan(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content)
        items.append(plan)
        plansByScope[scope.key] = items
        Self.save(items, scope)
        Self.writeMarkdown(plan, scope)
        return plan
    }

    /// Update a plan's content and/or title. When `append` is true, content is
    /// appended (with a separating newline) instead of replacing. Returns the
    /// updated plan, or nil if no plan matches.
    @discardableResult
    func update(
        id: UUID, title: String?, content: String?, append: Bool, in scope: PlanScope
    ) -> Plan? {
        var items = plans(in: scope)
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
        plansByScope[scope.key] = items
        Self.save(items, scope)
        Self.writeMarkdown(items[idx], scope)
        return items[idx]
    }

    /// Resolve a plan by its id string or a case-insensitive title substring.
    func find(idOrTitle raw: String, in scope: PlanScope) -> Plan? {
        let items = plans(in: scope)
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: key), let p = items.first(where: { $0.id == uuid }) {
            return p
        }
        return items.first { $0.title.localizedCaseInsensitiveContains(key) }
    }

    @discardableResult
    func delete(id: UUID, in scope: PlanScope) -> Bool {
        var items = plans(in: scope)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: idx)
        plansByScope[scope.key] = items
        Self.save(items, scope)
        try? FileManager.default.removeItem(at: Self.markdownURL(scope, id))
        return true
    }

    func clear(in scope: PlanScope) {
        plansByScope[scope.key] = []
        Self.save([], scope)
    }

    // MARK: - Persistence (App Support/SwiftMaestro/plans/<base>.json + .md mirror)

    private nonisolated static func dir() -> URL {
        let base = WorkspaceStore.appSupportDir().appendingPathComponent("plans", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func fileURL(_ scope: PlanScope) -> URL {
        dir().appendingPathComponent("\(scope.fileBase).json")
    }

    /// Per-scope folder holding human-readable `.md` mirrors of each plan.
    private nonisolated static func markdownDir(_ scope: PlanScope) -> URL {
        let base = dir().appendingPathComponent(scope.fileBase, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func markdownURL(_ scope: PlanScope, _ planId: UUID) -> URL {
        markdownDir(scope).appendingPathComponent("\(planId.uuidString).md")
    }

    private nonisolated static func writeMarkdown(_ plan: Plan, _ scope: PlanScope) {
        let md = "# \(plan.title)\n\n\(plan.content)\n"
        try? md.data(using: .utf8)?.write(to: markdownURL(scope, plan.id))
    }

    nonisolated static func load(_ scope: PlanScope) -> [Plan] {
        guard let data = try? Data(contentsOf: fileURL(scope)) else { return [] }
        return (try? JSONDecoder().decode([Plan].self, from: data)) ?? []
    }

    nonisolated static func save(_ items: [Plan], _ scope: PlanScope) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL(scope))
        }
    }
}
