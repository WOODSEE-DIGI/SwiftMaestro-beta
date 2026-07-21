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
    /// Hidden projects are not shown in the main sidebar or in Navigator workspace lists,
    /// but they are still persisted and can be used by infrastructure such as bus workers.
    var hidden: Bool? = nil
    init(id: UUID = UUID(), name: String, hidden: Bool? = nil) {
        self.id = id
        self.name = name
        self.hidden = hidden
    }

    var isHidden: Bool { hidden ?? false }
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
    /// Per-agent working directory. Injected into the system prompt and used as
    /// the default cwd for shell/file tools. `nil` means no fixed directory.
    /// Optional so existing `workspace.json` (written before this field) decodes.
    var workingDirectory: String?
    /// Per-agent enabled tool categories. `nil` means use the defaults for the
    /// agent kind. Stored as raw strings so older decoders ignore unknown values.
    var enabledToolCategories: [String]?
    /// Per-agent Compact Tool Mode: defers deferrable-category tools behind
    /// the search_tools/call_tool meta-tools instead of advertising full
    /// schemas for them. `nil`/`false` (the default) means unchanged legacy
    /// behavior — this is opt-in. Optional so existing `workspace.json`
    /// (written before this field) still decodes.
    var compactToolMode: Bool?
    init(id: UUID = UUID(), name: String, kind: AgentKind, projectId: UUID? = nil,
         modelID: String? = nil, workingDirectory: String? = nil,
         enabledToolCategories: [String]? = nil, compactToolMode: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.projectId = projectId
        self.modelID = modelID
        self.workingDirectory = workingDirectory
        self.enabledToolCategories = enabledToolCategories
        self.compactToolMode = compactToolMode
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
        self.fileURL = WorkspaceStore.dataDir().appendingPathComponent("workspace.json")
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

    /// Projects that should appear in the main sidebar and in Navigator-facing lists.
    var visibleProjects: [Project] { projects.filter { !$0.isHidden } }

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
        NSLog("[WORKSPACE] created project '\(name)' (\(p.id))")
        save()
        return p
    }

    @discardableResult
    func createAgent(
        name: String, in project: Project,
        workingDirectory: String? = nil, modelID: String? = nil
    ) -> AgentRecord {
        let a = AgentRecord(
            name: name, kind: .project, projectId: project.id,
            modelID: modelID, workingDirectory: workingDirectory)
        agents.append(a)
        save()
        return a
    }

    /// Create (or return existing) a project agent, creating the project if new.
    @discardableResult
    func createProjectAgent(
        projectName: String, agentName: String,
        workingDirectory: String? = nil, modelID: String? = nil
    ) -> AgentRecord {
        let p = ensureProject(named: projectName)
        if let existing = findAgent(projectName: projectName, agentName: agentName) { return existing }
        return createAgent(
            name: agentName, in: p,
            workingDirectory: workingDirectory, modelID: modelID)
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

    /// Hide a project from the main sidebar and Navigator-facing lists.
    /// Hidden projects remain persisted and their agents keep working.
    func hideProject(id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].hidden = true
        save()
    }

    /// Remove all agents in a project (and their chat history), then remove the project.
    func archiveProject(id: UUID) {
        let agentsInProject = projectAgents(in: id)
        for a in agentsInProject {
            ChatHistoryStore.clear(agentId: a.id)
        }
        agents.removeAll { $0.projectId == id }
        projects.removeAll { $0.id == id }
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

    /// Set (or clear with `nil`) a per-agent working directory and persist.
    func setWorkingDirectory(_ path: String?, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let trimmed = path?.trimmingCharacters(in: .whitespaces)
        agents[i].workingDirectory = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    /// Enabled tool categories for an agent. Returns saved values if present,
    /// otherwise the defaults for the agent's kind.
    func enabledToolCategories(for agentID: UUID) -> Set<ToolCategory> {
        guard let agent = agent(id: agentID) else { return [] }
        if let saved = agent.enabledToolCategories {
            let valid = Set(saved.compactMap { ToolCategory(rawValue: $0) })
            if !valid.isEmpty { return valid }
        }
        return ToolCategory.defaultEnabled(for: agent.kind)
    }

    /// One-time migration: ensure every agent's saved enabled categories include
    /// all categories currently visible for its kind. This is called once at app
    /// startup after the workspace is loaded, so it does not mutate state during
    /// a SwiftUI view render.
    func migrateEnabledToolCategories() {
        var changed = false
        for i in agents.indices {
            let kind = agents[i].kind
            let saved = Set(agents[i].enabledToolCategories?.compactMap { ToolCategory(rawValue: $0) } ?? [])
            let visible = Set(ToolCategory.visible(for: kind))
            // If nothing is saved, defaults will already include everything visible.
            // If saved set is non-empty, merge any new categories in.
            if !saved.isEmpty {
                let merged = saved.union(visible)
                if merged != saved {
                    agents[i].enabledToolCategories = Array(merged.map(\.rawValue))
                    changed = true
                }
            }
        }
        if changed {
            save()
            NSLog("[WORKSPACE] migrated enabled tool categories to include new categories")
        }
    }

    /// Replace the enabled tool categories for an agent and persist.
    func setEnabledToolCategories(_ categories: Set<ToolCategory>, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[i].enabledToolCategories = Array(categories.map(\.rawValue))
        save()
    }

    /// Whether Compact Tool Mode is enabled for an agent. Defaults to `false`
    /// (legacy behavior) when never set.
    func compactToolMode(for agentID: UUID) -> Bool {
        agent(id: agentID)?.compactToolMode ?? false
    }

    /// Set Compact Tool Mode for an agent and persist.
    func setCompactToolMode(_ enabled: Bool, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[i].compactToolMode = enabled
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let ws = try? JSONDecoder().decode(WorkspaceData.self, from: data) {
            // Deduplicate projects by name (case-insensitive) — keep first occurrence
            var seen = Set<String>()
            var uniqueProjects: [Project] = []
            for p in ws.projects {
                let key = p.name.lowercased()
                if seen.contains(key) {
                    NSLog("[WORKSPACE] dropping duplicate project '\(p.name)' (\(p.id))")
                    // Remove orphaned agents for this duplicate project
                    agents.removeAll { $0.projectId == p.id }
                } else {
                    seen.insert(key)
                    uniqueProjects.append(p)
                }
            }
            projects = uniqueProjects
            agents = ws.agents.filter { a in
                // Keep navigator and agents whose project still exists
                a.kind == .navigator || projects.contains { $0.id == a.projectId }
            }
            if uniqueProjects.count != ws.projects.count { save() }
        }
        // Start clean: guarantee exactly one Navigator, no preset projects/agents.
        if !agents.contains(where: { $0.kind == .navigator }) {
            agents.insert(AgentRecord(name: "Navigator", kind: .navigator), at: 0)
            save()
        }

        // One-time cleanup: hide the infrastructure BusWorkers project and remove
        // leftover test projects that were created during early development.
        let cleanupKey = "com.woodseedigi.swiftmaestro.workspaceSidebarCleanupDone"
        if !UserDefaults.standard.bool(forKey: cleanupKey) {
            let testProjectNames = Set(["testlab", "existing", "newname"])
            var didChange = false
            for project in projects {
                if project.name.caseInsensitiveCompare("BusWorkers") == .orderedSame {
                    hideProject(id: project.id)
                    didChange = true
                } else if testProjectNames.contains(project.name.lowercased()) {
                    archiveProject(id: project.id)
                    didChange = true
                }
            }
            if didChange {
                UserDefaults.standard.set(true, forKey: cleanupKey)
            }
        }
    }

    func save() {
        let ws = WorkspaceData(projects: projects, agents: agents)
        guard let data = try? JSONEncoder().encode(ws) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }

    nonisolated static func appSupportDir() -> URL { SwiftMaestroPaths.appSupportDir }

    /// Data subdirectory: chats, plans, todos, workspace.json.
    nonisolated static func dataDir() -> URL { SwiftMaestroPaths.dataDir }
}
