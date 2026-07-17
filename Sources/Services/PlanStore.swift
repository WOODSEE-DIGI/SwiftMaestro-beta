import Foundation

/// Shared formatting helper for plan metadata surfaced in the UI.
enum PlanMetadataFormatter {
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relativeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func historyIcon(for kind: PlanHistoryKind) -> String {
        switch kind {
        case .created: return "doc.badge.plus"
        case .titleChanged: return "textformat"
        case .contentRewritten: return "pencil"
        case .contentAppended: return "plus.bubble"
        case .deleted: return "trash"
        }
    }
}

/// A single change/event recorded for a plan so the user can see what changed
/// and when.
struct PlanHistoryEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var kind: PlanHistoryKind
    /// Short, human-readable summary of what happened (e.g. "Title changed from 'X' to 'Y'").
    var summary: String
    /// Number of characters added/removed when the change was a content edit (optional).
    var characterDelta: Int?
}

enum PlanHistoryKind: String, Codable, Hashable {
    case created
    case titleChanged
    case contentRewritten
    case contentAppended
    case deleted
}

/// A markdown plan/design document the agent authors and maintains.
struct Plan: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Chronological change history for this plan (created + edits). Newest entries appended.
    var history: [PlanHistoryEntry] = []

    private enum CodingKeys: String, CodingKey {
        case id, title, content, createdAt, updatedAt, history
    }

    init(id: UUID = UUID(), title: String, content: String, createdAt: Date = Date(), updatedAt: Date = Date(), history: [PlanHistoryEntry] = []) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.content = try container.decode(String.self, forKey: .content)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let decodedHistory = try container.decodeIfPresent([PlanHistoryEntry].self, forKey: .history) ?? []
        // Backfill a synthetic creation entry for legacy plans that didn't store history.
        self.history = decodedHistory.isEmpty
            ? [PlanHistoryEntry(timestamp: self.createdAt, kind: .created, summary: "Plan created")]
            : decodedHistory
    }
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
/// (shared). Plans are persisted to the shared AI memory store
/// (`~/.ai-context/memory/knowledge/plans/`) so they survive app reinstalls,
/// workspace resets, and are accessible to other AI tools. A local `.md` mirror
/// is also kept for Obsidian-friendly browsing and backup.
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
        let timestamp = Date()
        let plan = Plan(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content,
            createdAt: timestamp,
            updatedAt: timestamp,
            history: [
                PlanHistoryEntry(
                    timestamp: timestamp,
                    kind: .created,
                    summary: "Plan created")
            ])
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
        let timestamp = Date()
        var plan = items[idx]
        var history = plan.history

        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != plan.title {
                history.append(PlanHistoryEntry(
                    timestamp: timestamp,
                    kind: .titleChanged,
                    summary: "Title changed from \"\(plan.title)\" to \"\(trimmed)\""))
                plan.title = trimmed
            }
        }
        if let content {
            let previousContent = plan.content
            let newContent = append
                ? (plan.content.isEmpty ? content : plan.content + "\n" + content)
                : content
            if newContent != previousContent {
                let delta = newContent.count - previousContent.count
                let kind: PlanHistoryKind = append ? .contentAppended : .contentRewritten
                let summary: String
                if append {
                    summary = "Appended \(content.count) character(s)"
                } else {
                    summary = "Content rewritten (\(previousContent.count) → \(newContent.count) characters)"
                }
                history.append(PlanHistoryEntry(
                    timestamp: timestamp,
                    kind: kind,
                    summary: summary,
                    characterDelta: delta))
                plan.content = newContent
            }
        }

        plan.updatedAt = timestamp
        plan.history = history
        items[idx] = plan
        plansByScope[scope.key] = items
        Self.save(items, scope)
        Self.writeMarkdown(plan, scope)
        return plan
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
        try? Self.memoryStore().delete(Self.planMarkdownURI(scope, id))
        return true
    }

    func clear(in scope: PlanScope) {
        plansByScope[scope.key] = []
        Self.save([], scope)
    }

    // MARK: - Shared-memory persistence

    private nonisolated static func memoryStore() -> SimpleMemoryStore { SimpleMemoryStore() }
    private static let migrationKey = "planStore.migratedToSharedMemory.v1"

    /// Canonical JSON location: ~/.ai-context/memory/knowledge/plans/<scope>.json
    private nonisolated static func planJSONURI(_ scope: PlanScope) -> MaestroURI {
        MaestroURI(kind: .knowledge, path: ["plans", "\(scope.fileBase).json"])
    }

    /// Markdown mirror location: ~/.ai-context/memory/knowledge/plans/<scope>/<id>.md
    private nonisolated static func planMarkdownURI(_ scope: PlanScope, _ planId: UUID) -> MaestroURI {
        MaestroURI(kind: .knowledge, path: ["plans", scope.fileBase, "\(planId.uuidString).md"])
    }

    private nonisolated static func writeMarkdown(_ plan: Plan, _ scope: PlanScope) {
        let md = "# \(plan.title)\n\n\(plan.content)\n"
        try? memoryStore().save(md, at: planMarkdownURI(scope, plan.id))
    }

    nonisolated static func load(_ scope: PlanScope) -> [Plan] {
        // Shared memory is the canonical source of truth.
        let jsonURI = planJSONURI(scope)
        if let json = try? memoryStore().load(jsonURI),
           let data = json.data(using: .utf8),
           let plans = try? JSONDecoder().decode([Plan].self, from: data),
           !plans.isEmpty {
            return plans
        }

        // Fallback to legacy local storage (pre-shared-memory builds).
        return legacyLoad(scope)
    }

    nonisolated static func save(_ items: [Plan], _ scope: PlanScope) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items),
           let json = String(data: data, encoding: .utf8) {
            try? memoryStore().save(json, at: planJSONURI(scope))
        }
        // Keep markdown mirrors in sync.
        for plan in items {
            writeMarkdown(plan, scope)
        }
        // Remove stale markdown mirrors for plans that no longer exist.
        let existingIDs = Set(items.map { $0.id })
        if let dir = try? memoryStore().listChildren(of: MaestroURI(kind: .knowledge, path: ["plans", scope.fileBase])) {
            for child in dir {
                let name = child.name
                if name.hasSuffix(".md"),
                   let id = UUID(uuidString: String(name.dropLast(3))),
                   !existingIDs.contains(id) {
                    try? memoryStore().delete(child)
                }
            }
        }
    }

    // MARK: - Legacy local storage (fallback + migration source)

    /// Old local data directory: ~/Library/Application Support/SwiftMaestro/data/plans/
    private nonisolated static func legacyDir() -> URL {
        SwiftMaestroPaths.dataDir.appendingPathComponent("plans", isDirectory: true)
    }

    private nonisolated static func legacyFileURL(_ scope: PlanScope) -> URL {
        legacyDir().appendingPathComponent("\(scope.fileBase).json")
    }

    private nonisolated static func legacyLoad(_ scope: PlanScope) -> [Plan] {
        guard let data = try? Data(contentsOf: legacyFileURL(scope)) else { return [] }
        return (try? JSONDecoder().decode([Plan].self, from: data)) ?? []
    }

    /// One-time migration from local app storage to the shared memory store.
    /// Orphaned agent plans (whose agent no longer exists) are reassigned to the
    /// current Navigator so they remain visible. Project-scoped plans keep their
    /// project name. Safe to call on every launch (gated by UserDefaults).
    func migrateFromLegacyStorage(navigatorID: UUID) {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else {
            return
        }
        defer { UserDefaults.standard.set(true, forKey: Self.migrationKey) }

        let fm = FileManager.default
        let legacyDirs = [
            Self.legacyDir(),
            SwiftMaestroPaths.appSupportDir.appendingPathComponent("plans", isDirectory: true),
        ]

        var migratedCount = 0
        var migratedScopes: Set<String> = []
        for legacyDir in legacyDirs {
            guard let files = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil)
            else { continue }

            for file in files where file.pathExtension == "json" {
                let base = file.deletingPathExtension().lastPathComponent
                guard let scope = PlanScope(fileBase: base) else { continue }
                guard let data = try? Data(contentsOf: file),
                      let legacyPlans = try? JSONDecoder().decode([Plan].self, from: data),
                      !legacyPlans.isEmpty else { continue }

                // Agent plans whose agent no longer exists get reassigned to the Navigator.
                var targetScope = scope
                if case .agent(let id) = scope, id != navigatorID {
                    targetScope = .agent(navigatorID)
                }

                var merged = Self.load(targetScope)
                let existingIDs = Set(merged.map { $0.id })
                let newPlans = legacyPlans.filter { !existingIDs.contains($0.id) }
                guard !newPlans.isEmpty else { continue }

                merged.append(contentsOf: newPlans)
                Self.save(merged, targetScope)
                migratedCount += newPlans.count
                migratedScopes.insert(targetScope.key)

                // Also migrate markdown mirrors if present.
                let legacyMirrorDir = legacyDir.appendingPathComponent(base, isDirectory: true)
                if let mirrors = try? fm.contentsOfDirectory(at: legacyMirrorDir, includingPropertiesForKeys: nil) {
                    for mirror in mirrors where mirror.pathExtension == "md" {
                        let mirrorName = mirror.deletingPathExtension().lastPathComponent
                        if let planID = UUID(uuidString: mirrorName),
                           let md = try? String(contentsOf: mirror, encoding: .utf8) {
                            try? Self.memoryStore().save(md, at: Self.planMarkdownURI(targetScope, planID))
                        }
                    }
                }
            }
        }

        if migratedCount > 0 {
            NSLog("[PLANSTORE] migrated \(migratedCount) plan(s) to shared memory for scopes: \(migratedScopes.sorted().joined(separator: ", "))")
        }
    }
}

// MARK: - PlanScope reconstruction from a legacy filename base

private extension PlanScope {
    init?(fileBase: String) {
        if fileBase.hasPrefix("project-") {
            let name = String(fileBase.dropFirst("project-".count))
                .replacingOccurrences(of: "_", with: " ")
            self = .project(name)
        } else if let id = UUID(uuidString: fileBase) {
            self = .agent(id)
        } else {
            return nil
        }
    }
}
