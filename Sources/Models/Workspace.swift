import Foundation

// MARK: - Workspace model
//
// Hierarchy: a persistent Navigator/Conductor agent (top level, no project) plus
// Projects, each owning one or more long-lived project agents. Project memory
// lives in the shared ai-context store keyed by project name; an agent's chat
// history is stored separately (see ChatHistoryStore) so it can be cleared
// without touching project memory.

enum AgentKind: String, Codable, Hashable {
    case navigator   // the always-present general/conductor agent
    case project     // a long-lived agent that belongs to a project
}

struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

struct AgentRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: AgentKind
    var projectId: UUID?   // nil for the navigator
    /// Per-agent model override (a `MaestroModel.id`, e.g. `local-qwen3.5-122b`).
    /// `nil` means use the global default model. Optional so existing
    /// `workspace.json` (written before this field) still decodes.
    var modelID: String?
    init(id: UUID = UUID(), name: String, kind: AgentKind, projectId: UUID? = nil,
         modelID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.projectId = projectId
        self.modelID = modelID
    }
}

private struct WorkspaceData: Codable {
    var projects: [Project]
    var agents: [AgentRecord]
}

/// Source of truth for projects + agents, persisted to Application Support.
/// Start-clean: on first run only the Navigator exists (no preset projects).
@Observable
@MainActor
final class WorkspaceStore {
    private(set) var projects: [Project] = []
    private(set) var agents: [AgentRecord] = []

    private let fileURL: URL

    init() {
        self.fileURL = WorkspaceStore.appSupportDir().appendingPathComponent("workspace.json")
        load()
    }

    // MARK: - Queries

    /// The always-present conductor agent (created if somehow missing).
    var navigator: AgentRecord {
        if let nav = agents.first(where: { $0.kind == .navigator }) { return nav }
        let nav = AgentRecord(name: "Navigator", kind: .navigator)
        agents.insert(nav, at: 0)
        save()
        return nav
    }

    func projectAgents(in projectId: UUID) -> [AgentRecord] {
        agents.filter { $0.kind == .project && $0.projectId == projectId }
    }

    func projectName(for agent: AgentRecord) -> String? {
        guard let pid = agent.projectId else { return nil }
        return projects.first(where: { $0.id == pid })?.name
    }

    func project(named name: String) -> Project? {
        projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func agent(id: UUID) -> AgentRecord? { agents.first { $0.id == id } }

    func findAgent(projectName: String, agentName: String) -> AgentRecord? {
        guard let p = project(named: projectName) else { return nil }
        return agents.first {
            $0.projectId == p.id && $0.name.caseInsensitiveCompare(agentName) == .orderedSame
        }
    }

    // MARK: - Mutations

    @discardableResult
    func ensureProject(named name: String) -> Project {
        if let existing = project(named: name) { return existing }
        let p = Project(name: name)
        projects.append(p)
        save()
        return p
    }

    @discardableResult
    func createAgent(name: String, in project: Project) -> AgentRecord {
        let a = AgentRecord(name: name, kind: .project, projectId: project.id)
        agents.append(a)
        save()
        return a
    }

    /// Create (or return existing) a project agent, creating the project if new.
    @discardableResult
    func createProjectAgent(projectName: String, agentName: String) -> AgentRecord {
        let p = ensureProject(named: projectName)
        if let existing = findAgent(projectName: projectName, agentName: agentName) { return existing }
        return createAgent(name: agentName, in: p)
    }

    /// Remove a project agent (and its chat history); prune the project if empty.
    func archiveAgent(id: UUID) {
        guard let a = agent(id: id), a.kind == .project else { return }
        agents.removeAll { $0.id == id }
        ChatHistoryStore.clear(agentId: id)
        if let pid = a.projectId, projectAgents(in: pid).isEmpty {
            projects.removeAll { $0.id == pid }
        }
        save()
    }

    func renameProject(id: UUID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = name
        save()
    }

    func renameAgent(id: UUID, to name: String) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].name = name
        save()
    }

    /// Set (or clear with `nil`) a per-agent model override and persist.
    func setModel(_ modelID: String?, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let trimmed = modelID?.trimmingCharacters(in: .whitespaces)
        agents[i].modelID = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let ws = try? JSONDecoder().decode(WorkspaceData.self, from: data) {
            projects = ws.projects
            agents = ws.agents
        }
        // Start clean: guarantee exactly one Navigator, no preset projects/agents.
        if !agents.contains(where: { $0.kind == .navigator }) {
            agents.insert(AgentRecord(name: "Navigator", kind: .navigator), at: 0)
            save()
        }
    }

    func save() {
        let ws = WorkspaceData(projects: projects, agents: agents)
        guard let data = try? JSONEncoder().encode(ws) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }

    nonisolated static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SwiftMaestro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
