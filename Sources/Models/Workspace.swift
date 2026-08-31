import Foundation

// MARK: - Workspace model
//
// Hierarchy: a persistent Maestro/Conductor agent (top level, no project) plus
// Projects, each owning one or more long-lived project agents. Project memory
// lives in the shared ai-context store keyed by project name; an agent's chat
// history is stored separately (see ChatHistoryStore) so it can be cleared
// without touching project memory.

enum AgentKind: String, Codable, Hashable {
    case navigator   // the always-present general/conductor agent
    case project     // a long-lived agent that belongs to a project
    case swiftHelper // the always-present self-repair/support engineer ("Swift Helper")
    case coder       // the always-present bundled coding agent (DeepSeek Coder V2 Lite)
    case search      // the always-present search/research agent (web, local, network)

    /// Agent kinds persisted by older builds under a different raw value, mapped
    /// to their current case so existing `workspace.json` files keep decoding.
    /// The "mechanic" support agent was renamed to "Swift Helper".
    private static let legacyRawValues: [String: AgentKind] = [
        "mechanic": .swiftHelper,
    ]

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let kind = AgentKind(rawValue: raw) ?? AgentKind.legacyRawValues[raw] {
            self = kind
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown AgentKind raw value: \(raw)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Hidden projects are not shown in the main sidebar or in Maestro workspace lists,
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
    /// Subagent category (e.g. coding, research, design). `nil` means use
    /// heuristics based on the agent name. Optional so existing workspace.json
    /// decodes and upgrades lazily.
    var category: AgentCategory?
    /// Panel-driven tool categories: when on (the default), categories linked to
    /// an app panel (Books, MaestroDB, Kanban, Notes, …) are only advertised to
    /// the model while that panel is open — core/non-panel categories are
    /// unaffected. The saved set is never mutated by this; turning it off
    /// restores the saved set exactly. Optional so existing workspace.json
    /// decodes (nil = on).
    var autoToolCategories: Bool?
    init(id: UUID = UUID(), name: String, kind: AgentKind, projectId: UUID? = nil,
         modelID: String? = nil, workingDirectory: String? = nil,
         enabledToolCategories: [String]? = nil, compactToolMode: Bool? = nil,
         category: AgentCategory? = nil, autoToolCategories: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.projectId = projectId
        self.modelID = modelID
        self.workingDirectory = workingDirectory
        self.enabledToolCategories = enabledToolCategories
        self.compactToolMode = compactToolMode
        self.category = category
        self.autoToolCategories = autoToolCategories
    }
}

private struct WorkspaceData: Codable {
    var projects: [Project]
    var agents: [AgentRecord]
}

/// Source of truth for projects + agents, persisted to Application Support.
/// Start-clean: on first run only Maestro exists (no preset projects).
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
        let nav = AgentRecord(name: "Maestro", kind: .navigator)
        agents.insert(nav, at: 0)
        save()
        return nav
    }

    /// The always-present self-repair/support agent (created if missing).
    /// "Swift Helper" defaults to the bundled Qwen3-4B model when it's on disk —
    /// small enough to coexist with whatever the user is running, so help is
    /// available even on Light installs with no chat model configured.
    var swiftHelper: AgentRecord {
        if var mech = agents.first(where: { $0.kind == .swiftHelper }) {
            var mechChanged = false
            // The SwiftHelper's diagnostic role requires its full toolset (shell,
            // system health, files) regardless of which panels are open —
            // Auto tool mode would strip .shell whenever the Terminal panel is
            // closed, breaking Maestro→SwiftHelper delegation. Pin it off.
            if mech.autoToolCategories ?? true {
                mech.autoToolCategories = false
                mechChanged = true
            }
            // One-time: drop any saved tool-category customization so the
            // SwiftHelper re-defaults to the curated support set (the previously
            // saved full menu + MCP flood produced a 252-tool/40K-token prompt
            // that crashed the 4B model). Users can re-customize afterwards.
            // The guard honors the legacy "mechanic.*" key too so an existing
            // user who already had the reset applied is never reset a second time.
            let resetKey = "swiftHelper.curatedToolset.v1"
            let legacyResetKey = "mechanic.curatedToolset.v1"
            let alreadyReset = UserDefaults.standard.bool(forKey: resetKey)
                || UserDefaults.standard.bool(forKey: legacyResetKey)
            if !alreadyReset, mech.enabledToolCategories != nil {
                mech.enabledToolCategories = nil
                mechChanged = true
            }
            UserDefaults.standard.set(true, forKey: resetKey)
            if mechChanged, let idx = agents.firstIndex(where: { $0.id == mech.id }) {
                agents[idx] = mech
                save()
            }
            return mech
        }
        var mech = AgentRecord(name: "Swift Helper", kind: .swiftHelper)
        mech.autoToolCategories = false
        if ModelCatalog.swiftHelperModelAvailable {
            mech.modelID = ModelCatalog.swiftHelperModelID
        }
        let insertAt = agents.isEmpty ? 0 : 1  // right after the navigator
        agents.insert(mech, at: min(insertAt, agents.count))
        save()
        return mech
    }

    /// The always-present coding agent (created if missing). Defaults to the
    /// bundled DeepSeek Coder V2 Lite model when it's on disk — an 8 GB coding
    /// specialist bundled in the DMG so coding help works out of the box with
    /// no downloads. Its toolset is pinned (Auto tool mode off) so panel state
    /// can never strip the file/shell tools the role depends on.
    var coder: AgentRecord {
        if var c = agents.first(where: { $0.kind == .coder }) {
            var coderChanged = false
            if c.autoToolCategories ?? true {
                c.autoToolCategories = false
                coderChanged = true
            }
            // One-time: drop the explicit category set by the initial
            // implementation — the category baseline (.coding includes .mcp)
            // overrode the curated kind-level toolset and flooded this small
            // model with 170+ MCP tools. Sidebar grouping still infers
            // .coding from the agent name.
            let categoryResetKey = "coder.noCategoryBaseline.v1"
            if !UserDefaults.standard.bool(forKey: categoryResetKey), c.category != nil {
                c.category = nil
                coderChanged = true
            }
            UserDefaults.standard.set(true, forKey: categoryResetKey)
            if coderChanged, let idx = agents.firstIndex(where: { $0.id == c.id }) {
                agents[idx] = c
                save()
            }
            return c
        }
        var c = AgentRecord(name: "Coder", kind: .coder)
        c.autoToolCategories = false
        // Deliberately NO explicit category: the category baseline (.coding
        // includes .mcp → all MCP server tools) would override the curated
        // kind-level set and flood this 2.4B-active-param model's prompt.
        // Sidebar grouping still infers .coding from the name.
        if ModelCatalog.coderModelAvailable {
            c.modelID = ModelCatalog.coderModelID
        }
        let insertAt = agents.isEmpty ? 0 : min(2, agents.count)  // after navigator + swiftHelper
        agents.insert(c, at: insertAt)
        save()
        return c
    }

    /// The always-present search/research agent (created if missing). Handles
    /// web search, local file discovery, network drive search, and Maps queries.
    /// Its toolset is pinned (Auto tool mode off) so panel state can never strip
    /// the search tools the role depends on.
    var searcher: AgentRecord {
        if var s = agents.first(where: { $0.kind == .search }) {
            var searchChanged = false
            if s.autoToolCategories ?? true {
                s.autoToolCategories = false
                searchChanged = true
            }
            // One-time: drop any saved tool-category customization so the
            // searcher re-defaults to the curated search set.
            let resetKey = "searcher.curatedToolset.v1"
            if !UserDefaults.standard.bool(forKey: resetKey), s.enabledToolCategories != nil {
                s.enabledToolCategories = nil
                searchChanged = true
            }
            UserDefaults.standard.set(true, forKey: resetKey)
            if searchChanged, let idx = agents.firstIndex(where: { $0.id == s.id }) {
                agents[idx] = s
                save()
            }
            return s
        }
        var s = AgentRecord(name: "Searcher", kind: .search)
        s.autoToolCategories = false
        let insertAt = agents.isEmpty ? 0 : min(3, agents.count)  // after navigator + swiftHelper + coder
        agents.insert(s, at: insertAt)
        save()
        return s
    }

    /// Projects that should appear in the main sidebar and in Maestro-facing lists.
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

    /// Effective category for an agent. Explicitly-set category wins; otherwise
    /// infer from the agent name.
    func resolvedCategory(for agent: AgentRecord) -> AgentCategory {
        agent.category ?? AgentCategory.infer(from: agent.name)
    }

    /// All visible project agents grouped by their resolved category.
    /// Agents whose project is hidden (e.g. infrastructure BusWorkers) are excluded.
    func projectAgentsByCategory() -> [(category: AgentCategory, agents: [AgentRecord])] {
        let hiddenProjectIDs = Set(projects.filter { $0.isHidden }.map(\.id))
        let grouped = Dictionary(grouping: agents.filter {
            $0.kind == .project && !($0.projectId.map { hiddenProjectIDs.contains($0) } ?? false)
        }) {
            resolvedCategory(for: $0)
        }
        return AgentCategory.allCases.compactMap { category in
            let list = grouped[category] ?? []
            return list.isEmpty ? nil : (category, list.sorted(by: { $0.name < $1.name }))
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
        workingDirectory: String? = nil, modelID: String? = nil,
        category: AgentCategory? = nil
    ) -> AgentRecord {
        let resolvedCategory = category ?? AgentCategory.infer(from: name)
        let a = AgentRecord(
            name: name, kind: .project, projectId: project.id,
            modelID: modelID, workingDirectory: workingDirectory,
            enabledToolCategories: Array(resolvedCategory.defaultToolCategories.map(\.rawValue)),
            category: resolvedCategory)
        agents.append(a)
        save()
        return a
    }

    /// Create (or return existing) a project agent, creating the project if new.
    @discardableResult
    func createProjectAgent(
        projectName: String, agentName: String,
        workingDirectory: String? = nil, modelID: String? = nil,
        category: AgentCategory? = nil
    ) -> AgentRecord {
        let p = ensureProject(named: projectName)
        if let existing = findAgent(projectName: projectName, agentName: agentName) { return existing }
        return createAgent(
            name: agentName, in: p,
            workingDirectory: workingDirectory, modelID: modelID,
            category: category)
    }

    /// Set (or clear with `nil`) an agent's category and persist.
    func setCategory(_ category: AgentCategory?, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[i].category = category
        save()
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

    /// Hide a project from the main sidebar and Maestro-facing lists.
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
        let baseline = agent.category?.defaultToolCategories
        if let saved = agent.enabledToolCategories {
            let valid = Set(saved.compactMap { ToolCategory(rawValue: $0) })
            if !valid.isEmpty {
                // If a category baseline exists (e.g. .coding → 11 tools), narrow
                // the saved set to only categories the agent actually needs. This
                // prevents legacy migrations from keeping all 28 categories / 177
                // tools loaded for a coding agent that only needs 11.
                if let baseline, valid.count > baseline.count {
                    return valid.intersection(baseline)
                }
                return valid
            }
        }
        // Fall back to the agent's CATEGORY defaults (e.g. .coding → 11 tools),
        // not the kind defaults (e.g. .project → 28 tools / 177 tool schemas).
        if let baseline {
            return baseline
        }
        return ToolCategory.defaultEnabled(for: agent.kind)
    }

    /// One-time migration: ensure every agent's saved enabled categories include
    /// the categories its baseline requires. For categorized agents the baseline
    /// is the category's default tool set; for uncategorized agents it is the
    /// kind's default set. This is called once at app startup after the workspace
    /// is loaded, so it does not mutate state during a SwiftUI view render.
    func migrateEnabledToolCategories() {
        var changed = false
        for i in agents.indices {
            let kind = agents[i].kind
            let saved = Set(agents[i].enabledToolCategories?.compactMap { ToolCategory(rawValue: $0) } ?? [])
            // If nothing is saved, the defaults will already provide the right baseline.
            // If a saved set exists, NARROW it to the agent's baseline — the old
            // code unioned baseline into saved which only ever grew the set; agents
            // that started with all 28 categories stayed at 28 forever.
            let baseline = agents[i].category?.defaultToolCategories
                ?? Set(ToolCategory.defaultEnabled(for: kind))
            if !saved.isEmpty {
                let narrowed = saved.intersection(baseline)
                if narrowed != saved {
                    agents[i].enabledToolCategories = Array(narrowed.map(\.rawValue))
                    changed = true
                }
            }
        }
        if changed {
            save()
            NSLog("[WORKSPACE] migrated enabled tool categories to baseline defaults")
        }
    }

    /// Replace the enabled tool categories for an agent and persist.
    func setEnabledToolCategories(_ categories: Set<ToolCategory>, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[i].enabledToolCategories = Array(categories.map(\.rawValue))
        save()
    }

    /// Whether panel-driven tool categories are on for an agent. Defaults to
    /// `true` (nil) — app-domain tools only exist in the prompt while their
    /// window is open, keeping schemas lean.
    func autoToolCategories(for agentID: UUID) -> Bool {
        agent(id: agentID)?.autoToolCategories ?? true
    }

    /// Set panel-driven tool categories for an agent and persist.
    func setAutoToolCategories(_ enabled: Bool, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[i].autoToolCategories = enabled
        save()
    }

    /// The tool categories actually advertised to the model for the next run.
    /// With Auto on, panel-linked categories (Books, MaestroDB, Kanban, Notes…)
    /// are included only while one of their panels is open; every other
    /// category passes through from the saved set untouched.
    func effectiveToolCategories(for agentID: UUID) -> Set<ToolCategory> {
        Self.effectiveCategories(
            saved: enabledToolCategories(for: agentID),
            auto: autoToolCategories(for: agentID),
            isOpen: { WorkspaceLayoutState.shared.isOpen($0) })
    }

    /// Pure filter behind `effectiveToolCategories`, extracted so tests can
    /// drive it without touching the live layout (WorkspaceLayoutState
    /// persists on every mutation — tests must never open/close real panels).
    nonisolated static func effectiveCategories(
        saved: Set<ToolCategory>, auto: Bool,
        isOpen: (WorkspacePanelKind) -> Bool
    ) -> Set<ToolCategory> {
        guard auto else { return saved }
        return saved.filter { category in
            let panels = category.linkedPanelKinds
            return panels.isEmpty || panels.contains(where: isOpen)
        }
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
                // Keep always-present agents (navigator/swiftHelper/coder) and
                // agents whose project still exists. Without the explicit
                // always-present kinds, the Swift Helper was silently dropped on
                // every load and re-created with a fresh UUID on next access —
                // orphaning its settings and chat history each launch.
                a.kind == .navigator || a.kind == .swiftHelper || a.kind == .coder
                    || projects.contains { $0.id == a.projectId }
            }
            if uniqueProjects.count != ws.projects.count { save() }
        }
        // Start clean: guarantee exactly one Maestro, no preset projects/agents.
        if !agents.contains(where: { $0.kind == .navigator }) {
            agents.insert(AgentRecord(name: "Maestro", kind: .navigator), at: 0)
        }

        // One-time rename: if the conductor still has the old default name "Navigator",
        // update it to "Maestro". Custom names are left untouched.
        if let i = agents.firstIndex(where: { $0.kind == .navigator && $0.name == "Navigator" }) {
            agents[i].name = "Maestro"
            save()
            NSLog("[WORKSPACE] renamed conductor agent from Navigator to Maestro")
        }

        // One-time rename: the self-repair support agent was renamed from
        // "Mechanic" to "Swift Helper". Agents persisted before the rename keep
        // the old name, so update it (case-insensitively, trimmed) on load and
        // persist so the agents panel shows "Swift Helper".
        if let i = agents.firstIndex(where: {
            $0.kind == .swiftHelper
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Mechanic") == .orderedSame
        }) {
            agents[i].name = "Swift Helper"
            save()
            NSLog("[WORKSPACE] renamed support agent from Mechanic to Swift Helper")
        }

        // One-time model-ID migration: the bundled Swift Helper model id was
        // renamed from swiftmaestro-mechanic-qwen3-4b to
        // swiftmaestro-swifthelper-qwen3-4b. Any agent still pinned to the old
        // id would show an invalid Picker tag and fail to resolve.
        let legacySwiftHelperModelID = ModelCatalog.legacySwiftHelperModelID
        let swiftHelperModelID = ModelCatalog.swiftHelperModelID
        var modelIDMigrationChanged = false
        for i in agents.indices where agents[i].modelID == legacySwiftHelperModelID {
            agents[i].modelID = swiftHelperModelID
            modelIDMigrationChanged = true
        }
        if modelIDMigrationChanged {
            save()
            NSLog("[WORKSPACE] migrated %d agent(s) from legacy Swift Helper model id", agents.filter { $0.modelID == swiftHelperModelID }.count)
        }

        // One-time category migration: infer a category for existing project
        // agents that don't have one yet. This lets the new sidebar group
        // existing agents immediately without requiring manual assignment.
        // Also seed the default tool categories for the inferred category.
        let categoryMigrationKey = "com.woodseedigi.swiftmaestro.categoryMigrationDone"
        if !UserDefaults.standard.bool(forKey: categoryMigrationKey) {
            var didChange = false
            for i in agents.indices where agents[i].kind == .project {
                if agents[i].category == nil {
                    let inferred = AgentCategory.infer(from: agents[i].name)
                    agents[i].category = inferred
                    didChange = true
                }
                if agents[i].enabledToolCategories == nil,
                   let category = agents[i].category {
                    agents[i].enabledToolCategories = Array(
                        category.defaultToolCategories.map(\.rawValue))
                    didChange = true
                }
            }
            if didChange {
                save()
                NSLog("[WORKSPACE] inferred categories and tool sets for existing project agents")
            }
            UserDefaults.standard.set(true, forKey: categoryMigrationKey)
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
        let data: Data
        do {
            data = try JSONEncoder().encode(ws)
        } catch {
            NSLog("[PERSIST] workspace ENCODE failed (\(ws.projects.count) projects, \(ws.agents.count) agents): \(error.localizedDescription)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[PERSIST] workspace WRITE failed to \(fileURL.path): \(error.localizedDescription)")
        }
    }

    nonisolated static func appSupportDir() -> URL { SwiftMaestroPaths.appSupportDir }

    /// Data subdirectory: chats, plans, todos, workspace.json.
    nonisolated static func dataDir() -> URL { SwiftMaestroPaths.dataDir }
}
