import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native (in-process) tools
//
// First-class tool source: these run directly in-app (no IPC, no subprocess),
// ideal for SwiftMaestro-owned / privileged / latency-sensitive capabilities.
// MCP-sourced tools join the *same* agentic loop in MLXInferenceEngine /
// AgentExecutor.
//
// Maestro (conductor) additionally gets workspace + delegation tools so it
// can spin up long-lived project agents and hand work to them. `ask_project_agent`
// is advertised here but executed by AgentExecutor (it needs the live
// endpoint/model/MCP to run the target agent's loop).

/// Input for tools that take no arguments.
struct NoToolArgs: Codable {}

/// Result of the `get_current_time` tool.
struct CurrentTimeResult: Codable {
    let current_time: String
    let timezone: String
}

/// Registry of native, in-process Swift tools available to the agent.
enum MaestroTools {

    /// Working directory set by the caller before each agent loop. File tools
    /// treat this as an implicit authorized root so the agent can freely create
    /// and edit files under its working directory without requiring the user to
    /// manually add every sub-folder in Settings → Context.
    nonisolated(unsafe) static var workingDirectory: String?

    /// Extra authorized roots inherited from the parent agent during delegation.
    /// Cleared at the start of each top-level run so stale roots don't leak.
    nonisolated(unsafe) static var inheritedRoots: [String] = []

    /// The calling agent's enabled tool categories for the run currently being
    /// dispatched, set by each call site right alongside where it builds
    /// `toolSpecs` (mirrors `inheritedRoots`'s "set immediately before use"
    /// convention). `nil` means unrestricted (matches `schemas(enabledCategories:)`'s
    /// `nil` = "no filtering"). Read by `search_tools`/`call_tool` (Compact Tool
    /// Mode) to scope results to categories the agent actually has enabled,
    /// since those meta-tools are static dispatchers with no other way to see
    /// per-call agent context. Like `inheritedRoots`, this is a simple global
    /// and not safe against fully concurrent overlapping runs — acceptable
    /// given the existing pattern already accepts that tradeoff.
    nonisolated(unsafe) static var currentEnabledCategories: Set<ToolCategory>?

    /// Companion to `currentEnabledCategories`: whether the run currently
    /// being dispatched belongs to Maestro (vs. a project agent).
    /// `search_tools` needs this to reconstruct the same candidate tool list
    /// `schemas(navigator:)` would have built for this specific agent kind
    /// (Maestro and project agents get slightly different tool sets even
    /// within the same deferrable categories, e.g. OCR vs. SQLite).
    nonisolated(unsafe) static var currentIsNavigator: Bool = false

    /// Working directories of agents that have been delegated to during the
    /// current run. The parent agent can read/write files under these paths so
    /// it can verify or continue work a sub-agent created under its own project
    /// directory.
    nonisolated(unsafe) static var delegatedAgentWorkingDirectories: [String] = []

    /// Returns the calling agent's authorized roots (global Settings + working
    /// directory) so delegation can pass them to the child.
    static func authorizedRootsForParent() -> [String] {
        // Full Disk Access: bypass all restrictions.
        if SwiftMaestroSettingsStore.loadFullDiskAccess() {
            return ["/"]
        }
        var roots = SwiftMaestroSettingsStore.loadAuthorizedFolders()
            .filter { $0.enabled }
            .map { URL(fileURLWithPath: unescapeShellPath(($0.path as NSString).expandingTildeInPath)).standardizedFileURL.path }
            .filter { !$0.isEmpty }
        if let wd = workingDirectory, !wd.isEmpty {
            let standardized = URL(fileURLWithPath: unescapeShellPath(wd)).standardizedFileURL.path
            if !roots.contains(standardized) {
                roots.append(standardized)
            }
        }
        return roots
    }

    /// Shared workspace store, set once at app launch. Weak so the store's
    /// lifetime stays owned by the app. Workspace tools hop to the MainActor to
    /// touch it.
    @MainActor static weak var workspace: WorkspaceStore?

    /// Shared live-todo store (per-agent task checklists). Set at app launch.
    @MainActor static weak var todoStore: TodoStore?

    /// Shared plan store (per-agent markdown plan documents). Set at app launch.
    @MainActor static weak var planStore: PlanStore?

    /// Shared inter-agent message store (per-agent inboxes). Set at app launch.
    @MainActor static weak var messageStore: AgentMessageStore?

    /// Shared workspace layout state (panel grid). Set at app launch.
    @MainActor static weak var workspaceLayout: WorkspaceLayoutState?

    /// Shared model catalog. Set at app launch.
    @MainActor static weak var catalog: ModelCatalog?

    /// Shared bus worker service. Set at app launch.
    @MainActor static weak var busWorker: BusWorker?

    /// Returns the real local date/time. The current date/time (with
    /// timezone) is already injected at the top of the system prompt, so the
    /// description steers the model away from habitual calls — this tool is
    /// for a FRESH reading after a long-running task, not for planning.
    static let getCurrentTime = Tool<NoToolArgs, CurrentTimeResult>(
        name: "get_current_time",
        description:
            "Get the current local date and time. The current date and time are already "
            + "provided at the top of your system prompt — call this ONLY when you need a "
            + "fresh, precise reading mid-task (e.g. measuring elapsed time), never just "
            + "to learn the date.",
        parameters: []
    ) { _ in
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return CurrentTimeResult(
            current_time: formatter.string(from: Date()),
            timezone: TimeZone.current.identifier
        )
    }

    static func registerTimeTools() async {
        await ToolRegistry.shared.register(
            ToolDefinition(
                name: "get_current_time", spec: getCurrentTime.schema,
                category: ToolCategory.time.rawValue,
                handler: { call in
                    do {
                        let output = try await call.execute(with: getCurrentTime)
                        return encode(output)
                    } catch {
                        return errorJSON(error.localizedDescription)
                    }
                }
            )
        )
    }

    /// Base native tools exposed to every agent.
    static let all: [any ToolProtocol] = [getCurrentTime]

    /// Base tool schemas (every agent). Kept for back-compat with the native
    /// MLXInferenceEngine agentic loop.
    static var schemas: [ToolSpec] { all.map { $0.schema } }

    /// Approximates the old liteMode tool set (memory/file/shell/server/
    /// index/sqlite) via categories, for the ONLY case that still matters:
    /// no explicit `enabledCategories` was supplied at all. Not byte-for-byte
    /// identical to the pre-registry list (that one hand-picked
    /// todo/plan/memory but explicitly excluded messaging, which is awkward
    /// to express as a plain category set since all three share `.memory`
    /// today) - accepted as a reasonable approximation since this whole path
    /// is already documented as deprecated and is superseded by real
    /// per-agent category toggles in practice.
    private static let liteModeCategories: Set<ToolCategory> = [.memory, .file, .shell, .server, .index, .sqlite]

    /// Caches tool schema arrays per (navigator, categories, compactMode).
    /// Tool definitions are static after app startup, so the cache is valid
    /// until a new tool provider is registered dynamically.
    private actor ToolSchemaCache {
        struct Key: Hashable {
            let navigator: Bool
            let categories: Set<String>
            let compactMode: Bool
        }
        private var cache: [Key: [ToolSpec]] = [:]

        func schemas(for key: Key, build: () async -> [ToolSpec]) async -> [ToolSpec] {
            if let cached = cache[key] { return cached }
            let built = await build()
            cache[key] = built
            return built
        }

        func invalidate() { cache.removeAll() }
    }
    private static let toolSchemaCache = ToolSchemaCache()

    /// Call after any dynamic tool registration (e.g., plugin load) to ensure
    /// subsequent schema requests reflect the new tools.
    static func invalidateToolSchemaCache() async {
        await toolSchemaCache.invalidate()
    }

    /// Tool schemas for an agent, sourced entirely from `ToolRegistry` (see
    /// that file's migration notes - this used to be a hand-built
    /// concatenation of per-file spec arrays plus a manual category filter;
    /// now every native tool is registered once with its own category, and
    /// this is just a category-scoped read of that registry).
    ///
    /// - Parameters:
    ///   - navigator: `true` for the Maestro agent. Only used to pick the
    ///     default category scope when `enabledCategories` is nil - real
    ///     call sites always pass a concrete `enabledCategories` (from
    ///     `WorkspaceStore.enabledToolCategories`, itself defaulting to
    ///     `ToolCategory.defaultEnabled(for:)` when never customized), so
    ///     this fallback mostly matters for tests / edge startup timing.
    ///   - liteMode: Deprecated; only consulted when `enabledCategories` is
    ///     nil (see `liteModeCategories`'s doc comment - restores this
    ///     function's own pre-existing documented intent, which the old
    ///     implementation didn't actually honor: it checked `liteMode`
    ///     unconditionally, before even looking at `enabledCategories`).
    ///   - enabledCategories: If provided, only tools whose category is in this
    ///     set are returned (tools with no category, e.g. get_current_time,
    ///     are always included).
    ///   - compactMode: When `true`, categories where `ToolCategory.isDeferrable`
    ///     is true are NOT advertised as full schemas — instead they're replaced
    ///     by the `search_tools`/`call_tool` meta-tool pair, which the agent uses
    ///     to discover and invoke them on demand. Always-on control categories
    ///     (workspace/memory/rules/time) are unaffected. Defaults to `false` so
    ///     existing behavior is completely unchanged unless explicitly opted in.
    static func schemas(
        navigator: Bool,
        liteMode: Bool = false,
        enabledCategories: Set<ToolCategory>? = nil,
        compactMode: Bool = false
    ) async -> [ToolSpec] {
        let resolvedCategories: Set<ToolCategory>
        if let enabledCategories {
            resolvedCategories = enabledCategories
        } else if liteMode {
            resolvedCategories = liteModeCategories
        } else {
            resolvedCategories = ToolCategory.unfilteredCategories(for: navigator ? .navigator : .project)
        }
        let categoryScope = Set(resolvedCategories.map(\.rawValue))
        let key = ToolSchemaCache.Key(
            navigator: navigator,
            categories: categoryScope,
            compactMode: compactMode)

        return await toolSchemaCache.schemas(for: key) {
            let filtered = await ToolRegistry.shared.allDefinitions().filter { definition in
                // search_tools/call_tool are never part of the normal listing —
                // they're a discovery mechanism FOR hidden tools, added back
                // explicitly below only when compactMode is on AND something is
                // actually deferred. Registered with category: nil (like
                // get_current_time) for a different reason (they have no
                // meaningful category to gate them behind), which would
                // otherwise make this same "uncategorized = always on" rule
                // wrongly include them here too.
                guard definition.name != "search_tools" && definition.name != "call_tool" else { return false }
                guard let category = definition.category else { return true } // uncategorized always on
                return categoryScope.contains(category)
            }

            guard compactMode else { return filtered.map(\.spec) }

            // Split into always-on specs and specs belonging to a deferrable
            // category; the latter are replaced by the two meta-tool schemas.
            let alwaysOn = filtered.filter { definition in
                guard let category = definition.category.flatMap({ ToolCategory(rawValue: $0) }) else { return true }
                return !category.isDeferrable
            }
            let anyDeferred = filtered.contains { definition in
                guard let category = definition.category.flatMap({ ToolCategory(rawValue: $0) }) else { return false }
                return category.isDeferrable
            }
            return anyDeferred ? alwaysOn.map(\.spec) + metaToolSpecs : alwaysOn.map(\.spec)
        }
    }

    /// Extract the function name from a tool spec dictionary.
    static func toolName(from spec: ToolSpec) -> String? {
        (spec["function"] as? [String: any Sendable])?["name"] as? String
    }

    // MARK: - Inter-agent messaging tools (caller agent_id injected by executor)

    static func registerMessagingTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "send_agent_message", spec: messagingToolSpecs[0],
                category: ToolCategory.messaging.rawValue,
                handler: { call in await sendAgentMessage(call) }),
            ToolDefinition(
                name: "read_agent_messages", spec: messagingToolSpecs[1],
                category: ToolCategory.messaging.rawValue,
                handler: { call in await readAgentMessages(call) }),
        ])
    }

    private static var messagingToolSpecs: [ToolSpec] {
        [
            rawSpec("send_agent_message",
                "Leave a message in another agent's inbox (durable across runs). Use to "
                + "hand off context or coordinate. Address the conductor as agent \"Maestro\".",
                properties: [
                    "to_agent": ["type": "string", "description": "Recipient agent name (or 'Maestro')."],
                    "to_project": ["type": "string", "description": "Optional project to disambiguate the recipient."],
                    "subject": ["type": "string", "description": "Short subject line."],
                    "message": ["type": "string", "description": "The message body."],
                ], required: ["to_agent", "message"]),
            rawSpec("read_agent_messages",
                "Read the messages in YOUR inbox (and mark them read).",
                properties: [:], required: []),
        ]
    }

    // MARK: - Live todo tools (per-agent checklist; agent_id injected by executor)

    /// Categorized as `.memory` (matches ToolCategory's existing list exactly
    /// - todo/plan fall under the same "memory" toggle as memory_write/etc.;
    /// messaging has its own `.messaging` category since Maestro needs to
    /// get memory tools but NOT messaging - a distinction plain category
    /// membership can't express if they shared one category).
    static func registerTodoTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "create_todo_list", spec: todoToolSpecs[0],
                category: ToolCategory.memory.rawValue,
                handler: { call in await todoCreate(call, replace: true) }),
            ToolDefinition(
                name: "add_todos", spec: todoToolSpecs[1],
                category: ToolCategory.memory.rawValue,
                handler: { call in await todoCreate(call, replace: false) }),
            ToolDefinition(
                name: "update_todo_status", spec: todoToolSpecs[2],
                category: ToolCategory.memory.rawValue,
                handler: { call in await todoUpdate(call) }),
            ToolDefinition(
                name: "read_todos", spec: todoToolSpecs[3],
                category: ToolCategory.memory.rawValue,
                handler: { call in await todoRead(call) }),
        ])
    }

    private static var todoToolSpecs: [ToolSpec] {
        let items: [String: any Sendable] = [
            "type": "array", "items": ["type": "string"],
            "description": "Ordered task titles.",
        ]
        return [
            rawSpec("create_todo_list",
                "Create or REPLACE your live task checklist for this chat (shown to the user). "
                + "Use at the START of a multi-step task to lay out the plan.",
                properties: ["items": items], required: ["items"]),
            rawSpec("add_todos", "Append tasks to your live checklist.",
                properties: ["items": items], required: ["items"]),
            rawSpec("update_todo_status",
                "Mark a task done (or reopen it). Identify the task by its 1-based "
                + "number from read_todos (the first task is 1, NOT 0) OR by 'title'. "
                + "Update items as you complete them.",
                properties: [
                    "index": ["type": "integer", "description": "1-based task number (first task = 1)."],
                    "title": ["type": "string", "description": "Alternative to index: text of the task to match."],
                    "done": ["type": "boolean", "description": "true = done (default), false = reopen."],
                ], required: []),
            rawSpec("read_todos", "Read your current task checklist with numbers and status.",
                properties: [:], required: []),
        ]
    }

    /// Build a function ToolSpec from already-formed JSON-schema property values
    /// (supports nested schemas like arrays, unlike `functionSpec`).
    /// Parameter descriptions are stripped for simple types (string/integer/boolean/number)
    /// to save prompt tokens — the parameter name is self-explanatory.
    static func rawSpec(
        _ name: String, _ description: String,
        properties: [String: any Sendable], required: [String]
    ) -> ToolSpec {
        var slimProps: [String: any Sendable] = [:]
        for (key, value) in properties {
            if let dict = value as? [String: any Sendable] {
                let t = (dict["type"] as? String) ?? ""
                if ["string", "integer", "boolean", "number"].contains(t) {
                    var slimmed = dict
                    slimmed.removeValue(forKey: "description")
                    slimProps[key] = slimmed
                } else {
                    slimProps[key] = value
                }
            } else {
                slimProps[key] = value
            }
        }
        let parameters: [String: any Sendable] = [
            "type": "object", "properties": slimProps, "required": required,
        ]
        return ["type": "function", "function": [
            "name": name, "description": description, "parameters": parameters,
        ] as [String: any Sendable]]
    }

    // MARK: - Plan tools (per-agent markdown design docs; agent_id injected by executor)

    static func registerPlanTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "create_plan", spec: planToolSpecs[0],
                category: ToolCategory.memory.rawValue,
                handler: { call in await planCreate(call) }),
            ToolDefinition(
                name: "edit_plan", spec: planToolSpecs[1],
                category: ToolCategory.memory.rawValue,
                handler: { call in await planEdit(call) }),
            ToolDefinition(
                name: "read_plans", spec: planToolSpecs[2],
                category: ToolCategory.memory.rawValue,
                handler: { call in await planReadList(call) }),
            ToolDefinition(
                name: "read_plan", spec: planToolSpecs[3],
                category: ToolCategory.memory.rawValue,
                handler: { call in await planReadOne(call) }),
        ])
    }

    private static let projectScopeDesc =
        "Optional project name to scope this plan to that project's SHARED plans "
        + "(visible to the project's agents). Omit for your own personal plans."

    private static var planToolSpecs: [ToolSpec] {
        [
            rawSpec("create_plan",
                "Create a new markdown PLAN / design document the user can review. "
                + "Use for laying out a multi-step approach before implementing.",
                properties: [
                    "title": ["type": "string", "description": "Short plan title."],
                    "content": ["type": "string", "description": "Plan body in markdown."],
                    "project": ["type": "string", "description": projectScopeDesc],
                    "force": ["type": "boolean", "description": "true = create even when a similar plan already exists in another scope (skips the near-duplicate guard)."],
                ], required: ["title", "content"]),
            rawSpec("edit_plan",
                "Edit an existing plan, identified by 'plan_id' (preferred) or 'title'. "
                + "You MUST put the new text in 'content' (describing the change in chat "
                + "does NOT change the plan). Set append=true to ADD to the plan (content = "
                + "just the new text); omit append to REPLACE it (content = full new text). "
                + "Optionally rename via 'new_title'.",
                properties: [
                    "plan_id": ["type": "string", "description": "Id of the plan to edit."],
                    "title": ["type": "string", "description": "Alternative to plan_id: match by title text."],
                    "new_title": ["type": "string", "description": "Optional new title."],
                    "content": ["type": "string", "description": "The new/added markdown text (required to change the body)."],
                    "append": ["type": "boolean", "description": "true = append content; false/omit = replace."],
                    "project": ["type": "string", "description": projectScopeDesc],
                ], required: []),
            rawSpec("read_plans", "List ALL plans (personal + project-scoped). Optionally filter by project.",
                properties: [
                    "project": ["type": "string", "description": projectScopeDesc],
                ], required: []),
            rawSpec("read_plan",
                "Read a plan's full markdown content by 'plan_id' or 'title'. Searches all scopes.",
                properties: [
                    "plan_id": ["type": "string", "description": "Id of the plan to read."],
                    "title": ["type": "string", "description": "Alternative to plan_id: match by title text."],
                    "project": ["type": "string", "description": projectScopeDesc],
                ], required: []),
        ]
    }

    // MARK: - Maestro (workspace + delegation) tools

    /// Names of the Maestro-only workspace tools executed natively here.
    /// `ask_project_agent`/`ask_project_agents` are intentionally excluded -
    /// AgentExecutor's own delegation interceptor runs those directly and
    /// never reaches MaestroTools.execute() for them at all, so they're not
    /// registered here even though their schemas live in navigatorToolSpecs.
    static func registerWorkspaceTools() async {
        // ask_project_agent/ask_project_agents ARE registered (for correct
        // schema advertisement + handles() reporting) even though their
        // handlers here should never actually fire: AgentExecutor checks
        // `tc.name == "ask_project_agent"`/`"ask_project_agents"` and
        // intercepts them BEFORE it ever calls MaestroTools.handles()/
        // execute() (see AgentExecutor.swift around that exact check) - it
        // needs the live model/endpoint/MCP context to actually run the
        // target agent's loop, which this static registry has no access to.
        // These defensive handlers exist only to fail loudly, not silently,
        // if that invariant is ever broken.
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "create_project_agent", spec: navigatorToolSpecs[0],
                category: ToolCategory.workspace.rawValue,
                handler: { call in await createProjectAgent(call) }),
            ToolDefinition(
                name: "list_workspace", spec: navigatorToolSpecs[1],
                category: ToolCategory.workspace.rawValue,
                handler: { _ in await listWorkspace() }),
            ToolDefinition(
                name: "archive_project_agent", spec: navigatorToolSpecs[2],
                category: ToolCategory.workspace.rawValue,
                handler: { call in await archiveProjectAgent(call) }),
            ToolDefinition(
                name: "ask_project_agent", spec: navigatorToolSpecs[3],
                category: ToolCategory.workspace.rawValue,
                handler: { _ in
                    errorJSON("ask_project_agent must be intercepted by AgentExecutor, not dispatched directly.")
                }),
            ToolDefinition(
                name: "ask_project_agents", spec: navigatorToolSpecs[4],
                category: ToolCategory.workspace.rawValue,
                handler: { _ in
                    errorJSON("ask_project_agents must be intercepted by AgentExecutor, not dispatched directly.")
                }),
            ToolDefinition(
                name: "set_agent_model", spec: navigatorToolSpecs[5],
                category: ToolCategory.workspace.rawValue,
                handler: { call in await setAgentModel(call) }),
            ToolDefinition(
                name: "list_models", spec: navigatorToolSpecs[6],
                category: ToolCategory.workspace.rawValue,
                handler: { _ in await listModels() }),
            ToolDefinition(
                name: "open_panel", spec: navigatorToolSpecs[7],
                category: ToolCategory.workspace.rawValue,
                handler: { call in await openPanelTool(call) }),
            ToolDefinition(
                name: "task", spec: navigatorToolSpecs[8],
                category: ToolCategory.workspace.rawValue,
                handler: { _ in
                    errorJSON("task must be intercepted by AgentExecutor, not dispatched directly.")
                }),
            ToolDefinition(
                name: "close_panel", spec: navigatorToolSpecs[9],
                category: ToolCategory.workspace.rawValue,
                handler: { call in await closePanelTool(call) }),
            ToolDefinition(
                name: "ask_mechanic", spec: navigatorToolSpecs[10],
                category: ToolCategory.workspace.rawValue,
                handler: { _ in
                    errorJSON("ask_mechanic must be intercepted by AgentExecutor, not dispatched directly.")
                }),
            ToolDefinition(
                name: "ask_search", spec: navigatorToolSpecs[11],
                category: ToolCategory.workspace.rawValue,
                handler: { _ in
                    errorJSON("ask_search must be intercepted by AgentExecutor, not dispatched directly.")
                }),
        ])
    }

    private static var navigatorToolSpecs: [ToolSpec] {
        [
            functionSpec(
                name: "create_project_agent",
                description:
                    "CREATE a new project agent (one-time setup only). WARNING: Before "
                    + "calling this, ALWAYS call list_workspace first to check if an agent "
                    + "with a similar name already exists. If one does, use ask_project_agent "
                    + "instead. Do NOT create duplicate agents. This tool ONLY creates the "
                    + "agent shell — it does NOT assign work or send tasks.",
                properties: [
                    "project": ["type": "string", "description": "Project name."],
                    "agent": ["type": "string", "description": "Name for the new project agent."],
                    "workingDirectory": ["type": "string", "description": "Optional absolute working directory for the agent. Inherited from the creating agent when omitted."],
                    "model": ["type": "string", "description": "Optional model identifier. Use 'coding' to select the coding-specialist model, or pass a full MaestroModel id (e.g. 'local-qwen3.5-122b'). Defaults to the global default model."],
                ],
                required: ["project", "agent"]
            ),
            functionSpec(
                name: "list_workspace",
                description: "List all projects and their project agents.",
                properties: [:],
                required: []
            ),
            functionSpec(
                name: "archive_project_agent",
                description:
                    "Remove a project agent that is no longer needed (also clears its "
                    + "chat history). The project is pruned if it has no remaining agents.",
                properties: [
                    "project": ["type": "string", "description": "Project name."],
                    "agent": ["type": "string", "description": "Project agent name to remove."],
                ],
                required: ["project", "agent"]
            ),
            functionSpec(
                name: "ask_project_agent",
                description:
                    "DELEGATE a task to an EXISTING project agent and wait for its answer. "
                    + "This actually runs the agent — it executes the task, uses tools, and "
                    + "returns the result. Use this whenever you need a project agent to DO "
                    + "something (read files, analyse data, write reports, etc). Do NOT use "
                    + "create_project_agent to give work to an existing agent.",
                properties: [
                    "project": ["type": "string", "description": "Project name of the target agent."],
                    "agent": ["type": "string", "description": "Target project agent name."],
                    "task": ["type": "string", "description": "The task or question to hand off."],
                ],
                required: ["project", "agent", "task"]
            ),
            rawSpec("ask_project_agents",
                "Delegate tasks to SEVERAL project agents in one call and get all their "
                + "answers back together. Provide 'requests', a list of {project, agent, task}. "
                + "Use to coordinate multiple specialists, then synthesize their results.",
                properties: [
                    "requests": [
                        "type": "array",
                        "description": "The delegations to run.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "project": ["type": "string", "description": "Project name of the target agent."],
                                "agent": ["type": "string", "description": "Target project agent name."],
                                "task": ["type": "string", "description": "Task/question for that agent."],
                            ] as [String: any Sendable],
                            "required": ["agent", "task"],
                        ] as [String: any Sendable],
                    ] as [String: any Sendable],
                ], required: ["requests"]),
            functionSpec(
                name: "set_agent_model",
                description:
                    "CHANGE the model used by an existing project agent. The agent must "
                    + "already exist (use list_workspace to find it first). Pass 'model' with "
                    + "a model id (e.g. 'local-qwen3.5-122b'), a shorthand like 'coding' for "
                    + "the coding-specialist model, or 'default' to clear the override and "
                    + "revert to the global default.",
                properties: [
                    "project": ["type": "string", "description": "Project name the agent belongs to."],
                    "agent": ["type": "string", "description": "Name of the agent whose model to change."],
                    "model": ["type": "string", "description": "New model id, shorthand ('coding'), or 'default' to clear the override."],
                ],
                required: ["project", "agent", "model"]
            ),
            functionSpec(
                name: "list_models",
                description:
                    "LIST all available models in the catalog. Returns each model's id, "
                    + "display name, estimated memory, whether it has local weights "
                    + "(downloaded and ready to load), and which is the current global "
                    + "default. Use the model id from this list when calling "
                    + "set_agent_model or create_project_agent.",
                properties: [:],
                required: []
            ),
            functionSpec(
                name: "open_panel",
                description:
                    "OPEN (or focus) an app panel inside SwiftMaestro. Your system prompt "
                    + "lists the CURRENTLY OPEN PANELS — do NOT call this for those; "
                    + "re-opening an open panel just focuses it and wastes a tool round. "
                    + "The panel docks into the workspace grid. "
                    + "Opening an app's panel also ACTIVATES that app's tools "
                    + "(Auto tool mode): e.g. open 'database' before using db_* tools, "
                    + "'books' before invoice_*, 'kanban' before kanban tools. After "
                    + "opening a panel, call the app's tools in your NEXT tool call — "
                    + "do NOT deliberate about whether they're available; once the "
                    + "panel is open, its tools work. "
                    + "Panels (alias — display name the user sees): database — MaestroDB, "
                    + "books — MaestroBooks, docs — MaestroDocs, dam — MaestroDAM (photo/asset "
                    + "browser), canvas — Whiteboard, browser — SwiftBrowser, voiceNotes — "
                    + "Voice Notes, htmlBuilder — HTML Builder, backup — Backup, plus kanban, "
                    + "numbers, maps, photos, mail, whatsapp, discord, notesMD, appleNotes, "
                    + "terminal, calendar, reminders, contacts, bus, audio, agents, apps, "
                    + "cameras, scenes, mixer, broadcast, ndi — or an agent name to open its "
                    + "chat panel. Use close_panel to close a panel. "
                    + "IMPORTANT: 'MaestroDAM' is the photo/asset manager (alias 'dam'); "
                    + "'MaestroDB' is the database (alias 'database') — do not confuse them.",
                properties: [
                    "panel": ["type": "string", "description": "Panel name, alias, or display name (e.g. 'database', 'dam', 'MaestroDAM', 'SwiftBrowser') or an agent name."],
                    "zone": ["type": "string", "description": "Where to dock: 'right' (default, side-by-side), 'bottom' (below existing panels), or 'float'. Omit for default."],
                ],
                required: ["panel"]
            ),
            functionSpec(
                name: "task",
                description:
                    "Spin up a temporary one-shot subagent for a single task, wait for its "
                    + "answer, then tear it down. Use this exactly like OpenCode's task tool: "
                    + "when you need a specialist to explore, code, or analyze something and return "
                    + "a concise result. The agent is created, used, and archived automatically.",
                properties: [
                    "agent": ["type": "string", "description": "Short name for the temporary specialist agent (e.g. 'swift-explorer', 'doc-writer')."],
                    "task": ["type": "string", "description": "The task or question to hand to the subagent."],
                    "project": ["type": "string", "description": "Optional project name to scope the agent. Defaults to a temporary task project."],
                    "workingDirectory": ["type": "string", "description": "Optional absolute working directory. Inherited from the creating agent when omitted."],
                    "model": ["type": "string", "description": "Optional model identifier or shorthand ('coding', 'default'). Uses the global default model when omitted."],
                ],
                required: ["agent", "task"]
            ),
            functionSpec(
                name: "close_panel",
                description:
                    "CLOSE an app panel that is currently open in SwiftMaestro (docked or "
                    + "floating). Use when the user asks to close/hide/dismiss a panel or app, "
                    + "or to tidy up the workspace. Panel names are the same as open_panel — "
                    + "including display names like 'MaestroDAM', 'MaestroDB', 'SwiftBrowser', "
                    + "'Whiteboard', 'Voice Notes' — or an agent name to close its chat panel. "
                    + "Closing is always safe: the user can re-open any panel from the sidebar.",
                properties: [
                    "panel": ["type": "string", "description": "Name of the open panel to close (e.g. 'database', 'dam', 'MaestroDAM', 'browser') or an agent name."],
                ],
                required: ["panel"]
            ),
            functionSpec(
                name: "ask_mechanic",
                description:
                    "Ask SwiftHelper — SwiftMaestro's built-in support agent — to "
                    + "diagnose or fix a problem. SwiftHelper has the tools you don't: "
                    + "shell commands (execute_command), crash/console diagnostics, settings "
                    + "backup/restore, and bug-report filing. USE THIS whenever the user asks "
                    + "you to run a command (brew, defaults, git, scripts), change a system or "
                    + "app setting, diagnose a crash/hang/slowdown, or fix something that isn't "
                    + "working. NEVER tell the user you 'can't run commands' — hand the task to "
                    + "SwiftHelper instead. Write the task as clear instructions with full "
                    + "context; SwiftHelper reports back what it did.",
                properties: [
                    "task": ["type": "string", "description": "What SwiftHelper should do, with all needed context (e.g. 'Run brew update and brew upgrade, then report what was upgraded')."],
                ],
                required: ["task"]
            ),
            functionSpec(
                name: "ask_search",
                description:
                    "Ask the Searcher — SwiftMaestro's built-in search agent — to find "
                    + "information FAST from any source: web, local files, network drives, "
                    + "Maps, or Obsidian vaults. The Searcher is FASTER than manual Google "
                    + "search because it searches multiple sources simultaneously. USE THIS "
                    + "whenever the user asks you to search, find, look up, or research "
                    + "anything. The Searcher knows when it has enough info to search and "
                    + "when to ask for clarification. Write the task as a clear search query "
                    + "with location/context when relevant.",
                properties: [
                    "task": ["type": "string", "description": "What to search for, with all needed context (e.g. 'Find HVAC installers in Sydney 2010 with phone numbers')."],
                ],
                required: ["task"]
            ),
        ]
    }


    /// Whether a native (in-process) tool owns the given name. Routes a tool call
    /// to the native registry before MCP. `ask_project_agent` is excluded so the
    /// executor's delegation interceptor handles it.
    static func handles(_ name: String) async -> Bool {
        await ToolRegistry.shared.handles(name)
    }

    /// Execute a parsed tool call and return a JSON string to feed back to the model.
    ///
    /// Every native tool is now registered with `ToolRegistry` (see that
    /// file's header comment for the migration this completed) — this is a
    /// thin wrapper, not a dispatcher itself anymore. `schemas()`/`handles()`
    /// still use their own name-set/concatenation logic independently (not
    /// yet converted to be registry-driven) — see those functions' own
    /// migration-status comments for what's left before the registry becomes
    /// the single source of truth end to end.
    static func execute(_ call: ToolCall) async -> String {
        await ToolRegistry.shared.execute(call)
    }

    // MARK: - Live todo implementations

    // Lenient arg structs: small local models emit `items` and `index` in varied
    // shapes, so custom decoders normalize them instead of throwing (a throw
    // would surface as a misleading "missing agent context" error).
    private struct TodoCreateArgs: Codable {
        let items: [String]
        let agent_id: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agent_id = try? c.decodeIfPresent(String.self, forKey: .agent_id)
            let list = (try? c.decodeIfPresent(StringList.self, forKey: .items)) ?? nil
            items = (list?.values ?? [])
                .map { MaestroTools.sanitizeModelText($0) }
                .filter { !$0.isEmpty }
        }
        enum CodingKeys: String, CodingKey { case items, agent_id }
    }

    private struct TodoUpdateArgs: Codable {
        let index: Int?
        let title: String?
        let done: Bool?
        let agent_id: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agent_id = try? c.decodeIfPresent(String.self, forKey: .agent_id)
            title = (try? c.decodeIfPresent(String.self, forKey: .title))
                .map { MaestroTools.sanitizeModelText($0) }
            let b = (try? c.decodeIfPresent(LenientBool.self, forKey: .done)) ?? nil
            done = b?.value
            let i = (try? c.decodeIfPresent(LenientInt.self, forKey: .index)) ?? nil
            index = i?.value
        }
        enum CodingKeys: String, CodingKey { case index, title, done, agent_id }
    }

    private struct TodoReadArgs: Codable { let agent_id: String? }

    /// Accepts a string list as `[String]`, a single `String`, or an array of
    /// objects keyed by title/text/name/task/item.
    private struct StringList: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let arr = try? c.decode([String].self) { values = arr; return }
            if let s = try? c.decode(String.self) {
                // Small models sometimes JSON-encode the whole array into a single
                // string (e.g. "[\"a\", \"b\"]"); unwrap that into real items.
                if let data = s.data(using: .utf8),
                   let arr = try? JSONDecoder().decode([String].self, from: data) {
                    values = arr; return
                }
                values = s.isEmpty ? [] : [s]; return
            }
            if let objs = try? c.decode([[String: JSONValue]].self) {
                values = objs.compactMap { obj in
                    for key in ["title", "text", "name", "task", "item"] {
                        if case .string(let s)? = obj[key] { return s }
                    }
                    return nil
                }
                return
            }
            values = []
        }
    }

    /// Accepts an int as a number or a numeric string. Small models mangle the value
    /// (e.g. `"3}"`, `\"3\"`), so clean it before parsing and, as a last resort, pull
    /// the leading integer run out of whatever's left.
    internal struct LenientInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i; return }
            if let s = try? c.decode(String.self) {
                let cleaned = MaestroTools.cleanScalarString(s)
                if let i = Int(cleaned) { value = i; return }
                let digits = cleaned.prefix(while: { $0 == "-" || $0 == "+" || $0.isNumber })
                value = Int(digits)
                return
            }
            value = nil
        }
    }

    /// Accepts a bool as a boolean or a string like "true"/"false" (also 1/0, yes/no).
    /// Cleans small-model mangling (e.g. `"true\"}"`) before parsing.
    internal struct LenientBool: Decodable {
        let value: Bool?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { value = b; return }
            if let s = try? c.decode(String.self) {
                switch MaestroTools.cleanScalarString(s).lowercased() {
                case "true", "1", "yes", "y": value = true
                case "false", "0", "no", "n": value = false
                default: value = nil
                }
                return
            }
            value = nil
        }
    }

    /// Parse a UUID from a model-supplied string, tolerating the small-model
    /// artifacts that otherwise break `UUID(uuidString:)`: the Gemma `<|"|>`
    /// escape token, escaped slashes, and stray surrounding quotes/braces/commas
    /// (e.g. `AB0BE3B2-…"}`). Used for agent_id, tab_id, plan_id, etc.
    static func agentUUID(_ raw: String?) -> UUID? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "<|\"|>", with: "")
        s = s.replacingOccurrences(of: "\\/", with: "/")
        // Backslash residue too — Gemma 4 glues literal escape junk onto ids:
        // `\"E74A27FF-…\"}` failed UUID parsing and cost a 4-round error loop
        // before the model pivoted to the clean id (15:26 run).
        while let last = s.last, ["\"", "'", "}", "]", ",", "\\"].contains(last) { s.removeLast() }
        while let first = s.first, ["\"", "'", "{", "[", ",", "\\"].contains(first) { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: s)
    }

    /// Strip small-model mangling from a scalar argument VALUE (int/bool): the Gemma
    /// `<|"|>` escape token, backslashes (escape residue), and surrounding
    /// quotes/braces/brackets/commas. Only used for scalar parsing, where none of
    /// these characters are ever legitimate — not for free-form strings.
    static func cleanScalarString(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<|\"|>", with: "")
        s = s.replacingOccurrences(of: "\\", with: "")
        let junk: [Character] = ["\"", "'", "{", "}", "[", "]", ",", " "]
        while let first = s.first, junk.contains(first) { s.removeFirst() }
        while let last = s.last, junk.contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize a model-supplied short string (title/label) for display. This is
    /// a NON-destructive safety net: the Gemma 4 escape token `<|"|>` is now
    /// decoded properly by the tool-call parser (mlx-swift-lm GemmaFunctionParser),
    /// so well-formed arguments arrive clean. This only (a) converts any residual
    /// `<|"|>` token to a real quote and (b) unwraps surrounding double quotes —
    /// it never strips brackets or unwraps arrays, so a legitimately bracketed or
    /// quoted title (e.g. "[Draft] Foo") is left intact.
    static func sanitizeModelText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<|\"|>", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Normalize the Gemma `<|"|>` escape token to a real quote inside free-form
    /// content (notes, plan bodies, descriptions). Non-destructive: only the token
    /// is converted; all other structure, whitespace, and punctuation is preserved.
    static func sanitizeModelInline(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<|\"|>", with: "\"")
    }

    private static func todoCreate(_ call: ToolCall, replace: Bool) async -> String {
        guard let args = decodeArgs(call, as: TodoCreateArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let id = agentUUID(args.agent_id) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        guard !args.items.isEmpty else {
            return errorJSON("'items' must be a non-empty array of task title strings")
        }
        return await MainActor.run {
            guard let store = todoStore else { return errorJSON("todo store unavailable") }
            let items = replace ? store.setList(args.items, for: id) : store.add(args.items, for: id)
            // In-band next-step nudge: small models often stop here and only
            // narrate the follow-up. Remind them to actually make the next call.
            return renderTodos(items)
                + "\n\nThe list is saved. If the user's request also involves changing a "
                + "task's status, you must NOW call update_todo_status (do not just say you will)."
        }
    }

    private static func todoUpdate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TodoUpdateArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let id = agentUUID(args.agent_id) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let done = args.done ?? true
        return await MainActor.run {
            guard let store = todoStore else { return errorJSON("todo store unavailable") }
            let current = store.todos(for: id)
            // Resolve the target: prefer an explicit 1-based index; otherwise match
            // by title (case-insensitive substring) so a wrong/absent index still works.
            var oneBased = args.index
            if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
               let match = current.firstIndex(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
                oneBased = match + 1
            }
            guard let idx = oneBased else {
                return errorJSON("provide 'index' (1-based task number) or 'title'. Current list:\n" + renderTodos(current))
            }
            guard let items = store.setDone(oneBasedIndex: idx, done: done, for: id) else {
                return errorJSON("no task at index \(idx) (tasks are numbered 1...\(current.count)). Current list:\n" + renderTodos(current))
            }
            return renderTodos(items)
        }
    }

    private static func todoRead(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TodoReadArgs.self), let id = agentUUID(args.agent_id) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        return await MainActor.run {
            guard let store = todoStore else { return errorJSON("todo store unavailable") }
            return renderTodos(store.todos(for: id))
        }
    }

    private static func renderTodos(_ items: [TodoItem]) -> String {
        guard !items.isEmpty else { return "Task list is empty." }
        let lines = items.enumerated().map { i, item in
            "\(i + 1). [\(item.done ? "x" : " ")] \(sanitizeModelText(item.title))"
        }
        let doneCount = items.filter { $0.done }.count
        return "Task list (\(doneCount)/\(items.count) done):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Plan implementations

    private struct PlanCreateArgs: Codable {
        let title: String?; let content: String?; let project: String?; let agent_id: String?
        let force: Bool?
    }
    private struct PlanEditArgs: Decodable {
        let plan_id: String?; let title: String?; let new_title: String?
        let content: String?; let append: Bool?; let project: String?; let agent_id: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plan_id = try? c.decodeIfPresent(String.self, forKey: .plan_id)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            new_title = try? c.decodeIfPresent(String.self, forKey: .new_title)
            // Accept the body under common synonyms small models use.
            var resolved: String?
            for key in [CodingKeys.content, .text, .body, .step, .steps] {
                if let v = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil, !v.isEmpty {
                    resolved = v; break
                }
            }
            content = resolved
            let b = (try? c.decodeIfPresent(LenientBool.self, forKey: .append)) ?? nil
            append = b?.value
            project = try? c.decodeIfPresent(String.self, forKey: .project)
            agent_id = try? c.decodeIfPresent(String.self, forKey: .agent_id)
        }
        enum CodingKeys: String, CodingKey {
            case plan_id, title, new_title, content, text, body, step, steps, append, project, agent_id
        }
    }
    private struct PlanReadArgs: Codable { let project: String?; let agent_id: String? }
    private struct PlanReadOneArgs: Codable {
        let plan_id: String?; let title: String?; let project: String?; let agent_id: String?
    }

    /// Resolve the plan scope: a named project (shared) takes precedence; otherwise
    /// the calling agent's personal scope.
    private static func planScope(agentID: String?, project: String?) -> PlanScope? {
        if let p = project?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return .project(p)
        }
        if let id = agentUUID(agentID) { return .agent(id) }
        return nil
    }

    private static func scopeLabel(_ scope: PlanScope) -> String {
        switch scope {
        case .agent: return "personal"
        case .project(let name): return "project '\(name)'"
        }
    }

    /// Lowercased, alnum-only token set form of a plan title.
    private static func planTitleTokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// Fuzzy title match for the create_plan near-duplicate guard: catches
    /// "YouTube Audio Bridge Implementation Plan" vs an existing
    /// "YouTube-to-Resolve Bridge Implementation Plan" (word-order/punctuation
    /// differences) via normalized containment or ≥60% token overlap of the
    /// smaller title (minimum 3 shared tokens, so generic words alone don't
    /// trip it).
    private static func planTitlesSimilar(_ a: String, _ b: String) -> Bool {
        let tokensA = planTitleTokens(a), tokensB = planTitleTokens(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }
        if tokensA == tokensB { return true }
        let normalizedA = tokensA.isEmpty ? "" : a.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let normalizedB = b.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if normalizedA.contains(normalizedB) || normalizedB.contains(normalizedA) { return true }
        let overlap = tokensA.intersection(tokensB).count
        let smaller = min(tokensA.count, tokensB.count)
        return overlap >= 3 && Double(overlap) / Double(smaller) >= 0.6
    }

    /// Every scope worth searching for a plan: scopes already cached in the
    /// store PLUS any project scope persisted on disk — including scopes a
    /// model invented (which match no workspace project and were never loaded
    /// this session, so `plansByScope` alone would miss them).
    @MainActor
    private static func allSearchableScopes(store: PlanStore) -> [PlanScope] {
        var scopes = store.plansByScope.keys.compactMap { PlanScope(key: $0) }
        for name in store.knownProjectNames() {
            let scope = PlanScope.project(name)
            if !scopes.contains(scope) { scopes.append(scope) }
        }
        return scopes
    }

    private static func planCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanCreateArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let requestedScope = planScope(agentID: args.agent_id, project: args.project) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let title = sanitizeModelText(args.title ?? "")
        guard !title.isEmpty else { return errorJSON("'title' is required") }
        let content = sanitizeModelInline(args.content ?? "")
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            // Phantom-scope guard: a model can pass ANY string as `project`,
            // which would create a scope no Plans panel or sheet ever shows
            // (panels list workspace projects only) — the plan would vanish
            // from the UI even though it saved fine. Normalize real project
            // names to their canonical casing; redirect unknown ones to the
            // agent's personal scope and say so.
            var scope = requestedScope
            var scopeNote = ""
            if case .project(let name) = requestedScope {
                if let match = workspace?.visibleProjects.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    scope = .project(match.name)
                } else if let id = agentUUID(args.agent_id) {
                    scope = .agent(id)
                    scopeNote = " NOTE: there is no project named \"\(name)\" in the workspace, "
                        + "so the plan was saved to your PERSONAL plans instead — a project "
                        + "scope that matches nothing would be invisible in the Plans UI. "
                        + "To share it project-wide, create the project first or pass an "
                        + "existing project name."
                }
            }
            // Duplicate guard: small models re-issue the identical create_plan call
            // a round later (production: same title twice, two UUIDs) — return the
            // EXISTING plan and point at edit_plan instead of stacking duplicates.
            if let existing = store.plans(in: scope).first(where: {
                $0.title.caseInsensitiveCompare(title) == .orderedSame
            }) {
                return "Plan \"\(existing.title)\" already exists (id \(existing.id.uuidString)) "
                    + "in \(scopeLabel(scope)) — do NOT create it again. Use edit_plan with "
                    + "this plan_id to change it."
            }
            // Cross-scope near-duplicate guard: a fuzzy same-topic title in ANY
            // scope means this should almost certainly be an edit, not a new plan
            // (production: "YouTube Audio Bridge Implementation Plan" created while
            // "YouTube-to-Resolve Bridge Implementation Plan" already existed in
            // another scope — two plans for one project).
            if args.force != true {
                for candidateScope in allSearchableScopes(store: store) {
                    if let similar = store.plans(in: candidateScope).first(where: {
                        planTitlesSimilar($0.title, title)
                    }) {
                        return "A similar plan already exists: \"\(similar.title)\" "
                            + "(id \(similar.id.uuidString)) in \(scopeLabel(candidateScope)). "
                            + "If the user means THAT plan, use edit_plan with its plan_id "
                            + "instead of creating a new one. To deliberately create a "
                            + "separate plan, call create_plan again with force=true."
                    }
                }
            }
            let plan = store.create(title: title, content: content, in: scope)
            return "Created \(scopeLabel(scope)) plan \"\(plan.title)\" (id \(plan.id.uuidString)).\(scopeNote)"
        }
    }

    private static func planEdit(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanEditArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let scope = planScope(agentID: args.agent_id, project: args.project) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let key = (args.plan_id ?? args.title).map { sanitizeModelText($0) }
        guard let key, !key.isEmpty else {
            return errorJSON("provide 'plan_id' or 'title' to identify the plan")
        }
        let hasContent = (args.content?.isEmpty == false)
        let hasRename = (args.new_title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        guard hasContent || hasRename else {
            return errorJSON(
                "edit_plan changed nothing: you must pass the new text in 'content'. "
                + "To ADD to the plan set append=true with content = just the new text; "
                + "to rewrite it, set content = the full new text.")
        }
        let append = args.append ?? false
        let sanitizedNewTitle = args.new_title.map { sanitizeModelText($0) }
        let sanitizedContent = args.content.map { sanitizeModelInline($0) }
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            // Find the plan: try specified scope first, then search all scopes
            // (including disk-only project scopes not yet loaded this session).
            var target: Plan?
            var foundScope = scope
            if let t = store.find(idOrTitle: key, in: scope) {
                target = t
            } else {
                for fallbackScope in allSearchableScopes(store: store) where fallbackScope != scope {
                    if let t = store.find(idOrTitle: key, in: fallbackScope) {
                        target = t
                        foundScope = fallbackScope
                        break
                    }
                }
            }
            guard let target else {
                return errorJSON("no plan matching \"\(key)\".\n" + renderPlanList(store.plans(in: scope)))
            }
            guard let updated = store.update(
                id: target.id, title: sanitizedNewTitle, content: sanitizedContent,
                append: append, in: foundScope)
            else { return errorJSON("failed to update plan") }
            let action = hasContent ? (append ? "appended to" : "rewrote") : "renamed"
            return "\(action.capitalized) plan \"\(updated.title)\" (now \(updated.content.count) chars):\n\n"
                + updated.content
        }
    }

    private static func planReadList(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanReadArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            // When no project is specified, show ALL plans: agent's personal plans
            // plus all project-scoped plans. This lets the model discover plans
            // regardless of scope. When project IS specified, show that project's
            // plans plus the agent's personal plans as fallback.
            let agentScope = agentUUID(args.agent_id).map { PlanScope.agent($0) }
            var allPlans: [Plan] = []
            if let agentScope {
                allPlans += store.plans(in: agentScope)
            }
            if let projectName = args.project?.trimmingCharacters(in: .whitespacesAndNewlines),
               !projectName.isEmpty {
                allPlans += store.plans(in: .project(projectName))
            } else if agentScope != nil {
                // No project filter: include all project-scoped plans too —
                // from disk, so scopes created this session (or invented by a
                // model) are discoverable, not just the cached ones.
                for name in store.knownProjectNames() {
                    allPlans += store.plans(in: .project(name))
                }
            }
            // Deduplicate by plan ID
            var seen = Set<UUID>()
            let unique = allPlans.filter { seen.insert($0.id).inserted }
            return renderPlanList(unique)
        }
    }

    private static func planReadOne(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanReadOneArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let scope = planScope(agentID: args.agent_id, project: args.project) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let key = (args.plan_id ?? args.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            return errorJSON("provide 'plan_id' or 'title' to identify the plan")
        }
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            // Try the specified scope first, then fall back to all scopes.
            if let plan = store.find(idOrTitle: key, in: scope) {
                return renderPlan(plan)
            }
            // Search across all scopes (cached + disk-persisted project scopes).
            for fallbackScope in allSearchableScopes(store: store) where fallbackScope != scope {
                if let plan = store.find(idOrTitle: key, in: fallbackScope) {
                    return renderPlan(plan)
                }
            }
            // Also try loading from disk for scopes not yet cached
            let agentScope = agentUUID(args.agent_id).map { PlanScope.agent($0) }
            var allScopes: [PlanScope] = []
            if let agentScope { allScopes.append(agentScope) }
            if let projectName = args.project?.trimmingCharacters(in: .whitespacesAndNewlines),
               !projectName.isEmpty {
                allScopes.append(.project(projectName))
            }
            for s in allScopes where s != scope {
                let plans = store.plans(in: s)
                if let plan = plans.first(where: {
                    ($0.id.uuidString == key) || $0.title.localizedCaseInsensitiveContains(key)
                }) {
                    return renderPlan(plan)
                }
            }
            return errorJSON("no plan matching \"\(key)\".\n" + renderPlanList(store.plans(in: scope)))
        }
    }

    private static func renderPlanList(_ plans: [Plan]) -> String {
        guard !plans.isEmpty else { return "No plans yet." }
        let lines = plans.map { "- \"\($0.title)\" (id \($0.id.uuidString))" }
        return "Plans (\(plans.count)):\n" + lines.joined(separator: "\n")
    }

    private static func renderPlan(_ plan: Plan) -> String {
        "Plan \"\(plan.title)\" (id \(plan.id.uuidString)):\n\n\(plan.content)"
    }

    // MARK: - Messaging implementations

    private struct SendMessageArgs: Decodable {
        let to_agent: String?; let to_project: String?
        let subject: String?; let message: String?; let agent_id: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            to_agent = try? c.decodeIfPresent(String.self, forKey: .to_agent)
            to_project = try? c.decodeIfPresent(String.self, forKey: .to_project)
            subject = try? c.decodeIfPresent(String.self, forKey: .subject)
            // Accept the body under common synonyms.
            var resolved: String?
            for key in [CodingKeys.message, .body, .text, .content] {
                if let v = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil, !v.isEmpty {
                    resolved = v; break
                }
            }
            message = resolved
            agent_id = try? c.decodeIfPresent(String.self, forKey: .agent_id)
        }
        enum CodingKeys: String, CodingKey {
            case to_agent, to_project, subject, message, body, text, content, agent_id
        }
    }
    private struct ReadMessagesArgs: Codable { let agent_id: String? }

    private static func sendAgentMessage(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SendMessageArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        let toName = (args.to_agent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toName.isEmpty else {
            return errorJSON("'to_agent' (recipient name, or 'Maestro') is required")
        }
        let body = (args.message ?? "")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorJSON("'message' (the body text) is required")
        }
        let subject = (args.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return await MainActor.run {
            guard let ws = workspace else { return errorJSON("workspace unavailable") }
            guard let store = messageStore else { return errorJSON("message store unavailable") }
            guard let recipient = resolveRecipient(ws, name: toName, project: args.to_project) else {
                let where_ = args.to_project.map { " in project '\($0)'" } ?? ""
                return errorJSON("no agent named '\(toName)'\(where_). Use list_workspace to see agents.")
            }
            // Self-messaging is always a model error: agents preserve their
            // OWN context via memory/plans, not by posting to their own
            // inbox (confirmed live: Maestro "sent a status update to the
            // Maestro agent" to preserve investigation context, which parked
            // a confusing self-addressed message in its own inbox).
            let senderUUID = agentUUID(args.agent_id)
            if let senderUUID, recipient.id == senderUUID {
                return errorJSON(
                    "cannot send a message to yourself (\(recipient.name)). The inbox is for "
                        + "talking to OTHER agents. To preserve your own context, use "
                        + "memory_write or create_plan instead.")
            }
            let fromName = senderUUID.flatMap { ws.agent(id: $0)?.name } ?? "an agent"
            store.send(
                to: recipient.id, fromName: fromName, fromAgentId: args.agent_id,
                subject: subject.isEmpty ? "(no subject)" : subject, body: body)
            return jsonString([
                "status": "sent", "to": recipient.name,
                "subject": subject.isEmpty ? "(no subject)" : subject,
            ])
        }
    }

    private static func readAgentMessages(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadMessagesArgs.self),
              let id = agentUUID(args.agent_id) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        return await MainActor.run {
            guard let store = messageStore else { return errorJSON("message store unavailable") }
            let msgs = store.inbox(for: id)
            let rendered = renderMessages(msgs)
            store.markAllRead(for: id)
            return rendered
        }
    }

    /// Resolve a recipient agent by name (+ optional project). "Maestro" maps to
    /// the conductor; otherwise prefer a project match, else any agent by name.
    @MainActor
    private static func resolveRecipient(
        _ ws: WorkspaceStore, name: String, project: String?
    ) -> AgentRecord? {
        if name.caseInsensitiveCompare("navigator") == .orderedSame
            || name.caseInsensitiveCompare("maestro") == .orderedSame {
            return ws.navigator
        }
        if let project, !project.trimmingCharacters(in: .whitespaces).isEmpty {
            return ws.findAgent(projectName: project, agentName: name)
        }
        return ws.agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func renderMessages(_ msgs: [AgentMessage]) -> String {
        guard !msgs.isEmpty else { return "Your inbox is empty." }
        let df = DateFormatter()
        df.dateStyle = .short; df.timeStyle = .short
        let blocks = msgs.enumerated().map { i, m -> String in
            "\(i + 1). From \(m.fromName) — \(m.subject) (\(df.string(from: m.date)))\n   \(m.body)"
        }
        let unread = msgs.filter { !$0.read }.count
        return "Inbox (\(msgs.count) message(s), \(unread) unread):\n" + blocks.joined(separator: "\n")
    }

    // MARK: - Workspace tool implementations

    private struct ProjectAgentArgs: Codable {
        let project: String
        let agent: String
        let workingDirectory: String?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case project, agent, workingDirectory, model
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            project = try c.decode(String.self, forKey: .project)
            agent = try c.decode(String.self, forKey: .agent)
            workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
            model = try c.decodeIfPresent(String.self, forKey: .model)
        }
    }

    /// Resolve a free-form model hint into a known `MaestroModel.id`.
    /// Supported: "coding"/"coder" → the local Qwen 3 Coder Next model; otherwise
    /// the raw string is kept if it matches a known model id. Also does a
    /// case-insensitive display-name match so the model picker's visible labels
    /// resolve correctly.
    @MainActor
    static func resolveAgentModelID(
        _ hint: String?, agentName: String? = nil, catalog: ModelCatalog?
    ) -> String? {
        let resolvedHint = hint?.trimmingCharacters(in: .whitespaces)
        if let resolvedHint, !resolvedHint.isEmpty {
            let lower = resolvedHint.lowercased()
            // The explicit "coding" shorthand selects the coding-specialist model.
            if lower == "coding" || lower == "coder" || lower == "code" {
                return "local-qwen3-coder-next"
            }
            // If the hint matches a known catalog id, display name, or HF id,
            // return the canonical catalog id (so stored modelIDs are stable).
            // When multiple models match, prefer the one whose weights are actually
            // installed on disk so the user isn't forced to download a model.
            if let catalog {
                let candidates = catalog.matchingModels(for: resolvedHint)
                if let match = candidates.first(where: { $0.hasLocalWeights }) ?? candidates.first {
                    return match.id
                }
            }
            return resolvedHint
        }
        return nil
    }

    private static func createProjectAgent(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ProjectAgentArgs.self),
              !args.project.trimmingCharacters(in: .whitespaces).isEmpty,
              !args.agent.trimmingCharacters(in: .whitespaces).isEmpty
        else { return errorJSON("create_project_agent requires non-empty 'project' and 'agent'") }

        return await MainActor.run {
            guard let ws = workspace else { return errorJSON("workspace unavailable") }
            // Prevent duplicate agents: fuzzy match — if any agent name contains
            // the requested name (or vice versa), treat it as a duplicate.
            // Strip spurious wrapping quotes the model sometimes emits.
            let cleanAgent = sanitizeModelText(args.agent)
            let cleanProject = sanitizeModelText(args.project)
            let lowerAgent = cleanAgent.lowercased()
            if let existing = ws.agents.first(where: {
                let existingName = $0.name.lowercased()
                return existingName == lowerAgent
                    || existingName.contains(lowerAgent)
                    || lowerAgent.contains(existingName)
            }) {
                let proj = ws.projectName(for: existing) ?? cleanProject
                return jsonString([
                    "status": "already_exists",
                    "project": proj,
                    "agent": existing.name,
                    "agentId": existing.id.uuidString,
                    "note": "An agent named '\(existing.name)' already exists in project '\(proj)'. "
                        + "Use ask_project_agent to delegate work to it. Do NOT create a new agent.",
                ])
            }

            let catalog = ModelCatalog()
            let modelID = resolveAgentModelID(args.model, agentName: cleanAgent, catalog: catalog)
            let created = ws.createProjectAgent(
                projectName: cleanProject, agentName: cleanAgent,
                workingDirectory: args.workingDirectory, modelID: modelID)
            return jsonString([
                "status": "created",
                "project": args.project,
                "agent": created.name,
                "agentId": created.id.uuidString,
                "modelID": created.modelID ?? NSNull(),
                "workingDirectory": created.workingDirectory ?? NSNull(),
            ])
        }
    }

    private static func listWorkspace() async -> String {
        // Snapshot workspace state on MainActor, then format outside to avoid
        // deadlocking when the agentic loop's background task holds a reference.
        let snapshot: (navigator: String, projects: [(name: String, agents: [String])])? = await MainActor.run {
            guard let ws = workspace else { return nil }
            let projects = ws.visibleProjects.map { project in
                (name: project.name, agents: ws.projectAgents(in: project.id).map { $0.name })
            }
            return (ws.navigator.name, projects)
        }
        guard let snap = snapshot else { return errorJSON("workspace unavailable") }
        let projects: [[String: Any]] = snap.projects.map { ["project": $0.name, "agents": $0.agents] }
        return jsonString(["navigator": snap.navigator, "projects": projects])
    }

    private static func archiveProjectAgent(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ProjectAgentArgs.self) else {
            return errorJSON("archive_project_agent requires 'project' and 'agent'")
        }
        return await MainActor.run {
            guard let ws = workspace else { return errorJSON("workspace unavailable") }
            guard let target = ws.findAgent(projectName: args.project, agentName: args.agent) else {
                return errorJSON("no agent '\(args.agent)' in project '\(args.project)'")
            }
            ws.archiveAgent(id: target.id)
            return jsonString(["status": "archived", "project": args.project, "agent": args.agent])
        }
    }

    private static func setAgentModel(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ProjectAgentArgs.self),
              !args.project.trimmingCharacters(in: .whitespaces).isEmpty,
              !args.agent.trimmingCharacters(in: .whitespaces).isEmpty,
              let modelHint = args.model?.trimmingCharacters(in: .whitespaces),
              !modelHint.isEmpty
        else { return errorJSON("set_agent_model requires 'project', 'agent', and 'model'") }

        return await MainActor.run {
            guard let ws = workspace else { return errorJSON("workspace unavailable") }
            guard let target = ws.findAgent(projectName: args.project, agentName: args.agent) else {
                return errorJSON("no agent '\(args.agent)' in project '\(args.project)'")
            }
            let catalog = ModelCatalog()
            let newModelID: String?
            if modelHint.lowercased() == "default" || modelHint.lowercased() == "reset" {
                newModelID = nil
            } else {
                newModelID = resolveAgentModelID(modelHint, agentName: target.name, catalog: catalog)
            }
            ws.setModel(newModelID, for: target.id)
            return jsonString([
                "status": "updated",
                "project": args.project,
                "agent": target.name,
                "modelID": newModelID ?? NSNull(),
                "note": newModelID != nil
                    ? "Model changed to '\(newModelID!)'. The agent will use this model on its next task."
                    : "Model override cleared. The agent will use the global default model.",
            ])
        }
    }

    private static func listModels() async -> String {
        let result: String = await MainActor.run {
            let catalog = ModelCatalog()
            let defaultID = catalog.selectedModelID
            let items: [[String: Any]] = catalog.models.map { m in
                var entry: [String: Any] = [
                    "id": m.id,
                    "displayName": m.displayName,
                    "memoryGB": m.estimatedMemoryGB,
                    "hasLocalWeights": m.hasLocalWeights,
                    "isDefault": m.id == defaultID,
                ]
                if m.isVision { entry["vision"] = true }
                if let active = m.activeParamsB { entry["activeParamsB"] = active }
                return entry
            }
            return jsonString([
                "models": items,
                "defaultModelID": defaultID ?? NSNull(),
            ])
        }
        return result
    }

    private struct OpenPanelArgs: Codable {
        let panel: String
        let zone: String?

        enum CodingKeys: String, CodingKey { case panel, zone }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            panel = try c.decode(String.self, forKey: .panel)
            zone = try c.decodeIfPresent(String.self, forKey: .zone)
        }
    }

    private struct ClosePanelArgs: Codable {
        let panel: String

        enum CodingKeys: String, CodingKey { case panel }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            panel = try c.decode(String.self, forKey: .panel)
        }
    }

    /// Maps a free-form panel name (from the model) to a `WorkspacePanelKind`.
    /// Every static panel is reachable — app-tool panels matter most (opening
    /// one activates its tool category under Auto mode), but monitors,
    /// launchers, and the streaming suite are included too. Agent names are
    /// resolved by fuzzy-matching against workspace agents. Plugin panels are
    /// data-driven and intentionally not resolvable here.
    @MainActor
    private static func resolvePanelKind(_ name: String) -> WorkspacePanelKind? {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        switch lower {
        // App-tool panels (Auto mode activates the matching category).
        case "database", "db", "maestrodb", "airtable": return .maestroDB
        case "books", "maestrobooks", "invoices", "invoicing": return .maestroBooks
        case "docs", "maestrodocs", "documents": return .maestroDocs
        case "kanban", "board": return .kanban
        case "canvas", "draw", "whiteboard", "white board": return .canvas
        case "numbers", "spreadsheet": return .numbers
        case "maps", "map": return .maps
        case "photos", "photo", "pictures": return .photos
        case "stocks", "stock", "shares", "market", "markets": return .stocks
        case "mail", "email", "apple mail": return .mail
        case "whatsapp", "wa": return .whatsapp
        case "discord", "dc": return .discord
        case "browser", "web browser", "webbrowser", "swiftbrowser": return .webBrowser
        case "notes.md", "notesmd", "md notes": return .notesMD
        case "apple notes", "applenotes", "notes": return .appleNotes
        // General panels.
        case "terminal", "shell", "term": return .terminal
        case "calendar", "cal": return .calendar
        case "reminders", "todo", "tasks": return .reminders
        case "contacts", "people": return .contacts
        case "dam", "maestrodam", "assets", "asset browser": return .damBrowser
        case "bus", "bus monitor", "busmonitor": return .busMonitor
        case "audio", "audio control": return .audioControl
        case "agents", "agent list": return .agents
        case "apps", "launcher", "app launcher": return .appLauncher
        case "cameras", "tethering", "tether": return .tethering
        case "stream ingest", "ingest": return .streamIngest
        case "broadcast", "publisher": return .broadcast
        case "mixer", "stream mixer": return .streamMixer
        case "ndi", "ndi browser": return .ndiBrowser
        case "color", "color adjustments", "lut": return .colorAdjustments
        case "scenes", "scene composer": return .scenes
        case "voice notes", "voicenotes", "voice memos": return .voiceNotes
        case "html builder", "htmlbuilder", "html": return .htmlBuilder
        case "backup", "backups": return .backup
        case "pomodoro", "timer", "focus timer": return .pomodoro
        default:
            // Display-name pass: match the app names users actually SEE (and
            // therefore the names they say to the agent — "MaestroDAM",
            // "Voice Notes", "SwiftBrowser"…), normalized to lowercase
            // alphanumerics so case/spacing can't matter. This catches the
            // Maestro* family confusions (e.g. "MaestroDAM" → MaestroDB)
            // even when the model invents its own spelling.
            let normalized = lower.filter { $0.isLetter || $0.isNumber }
            if !normalized.isEmpty {
                if let exact = panelDisplayNames.first(where: { $0.1 == normalized }) {
                    return exact.0
                }
                let prefixed = panelDisplayNames.filter {
                    $0.1.hasPrefix(normalized) || normalized.hasPrefix($0.1)
                }
                if prefixed.count == 1 { return prefixed[0].0 }
                let contained = panelDisplayNames.filter {
                    $0.1.contains(normalized) || normalized.contains($0.1)
                }
                if contained.count == 1 { return contained[0].0 }
            }

            // Try fuzzy-matching against agent names
            guard let ws = workspace else { return nil }
            if let match = ws.agents.first(where: {
                $0.name.lowercased() == lower
                    || $0.name.lowercased().contains(lower)
                    || lower.contains($0.name.lowercased())
            }) {
                return .agentChat(match.id)
            }
            return nil
        }
    }

    /// Panel kinds ↔ normalized UI display names (lowercase, alphanumerics
    /// only) for the display-name resolution pass in `resolvePanelKind`.
    /// Only names that ADD coverage beyond the alias switch are listed.
    private static let panelDisplayNames: [(WorkspacePanelKind, String)] = [
        (.maestroDB, "maestrodb"),
        (.maestroBooks, "maestrobooks"),
        (.maestroDocs, "maestrodocs"),
        (.damBrowser, "maestrodam"),
        (.webBrowser, "swiftbrowser"),
        (.canvas, "whiteboard"),
        (.voiceNotes, "voicenotes"),
        (.htmlBuilder, "htmlbuilder"),
        (.backup, "backup"),
        (.pomodoro, "pomodoro"),
        (.busMonitor, "busmonitor"),
        (.audioControl, "audiocontrol"),
        (.streamIngest, "streamingest"),
        (.streamMixer, "streammixer"),
        (.ndiBrowser, "ndibrowser"),
        (.colorAdjustments, "coloradjustments"),
        (.notesMD, "notesmd"),
    ]

    /// Panel list used in open_panel/close_panel error messages — includes the
    /// display names users actually say, so the model can self-correct.
    private static let panelListForErrors =
        "database (MaestroDB), books (MaestroBooks), docs (MaestroDocs), "
        + "dam (MaestroDAM — photo/asset browser), canvas (Whiteboard), "
        + "browser (SwiftBrowser), voiceNotes (Voice Notes), htmlBuilder, backup, "
        + "kanban, numbers, maps, photos, stocks, mail, whatsapp, discord, notesMD, "
        + "appleNotes, terminal, calendar, reminders, contacts, bus, audio, "
        + "agents, apps, cameras, scenes, mixer, broadcast, ndi — or an agent name."

    private static func openPanelTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: OpenPanelArgs.self),
              !args.panel.trimmingCharacters(in: .whitespaces).isEmpty
        else { return errorJSON("open_panel requires 'panel'") }

        return await MainActor.run {
            guard let layout = workspaceLayout else { return errorJSON("workspace layout unavailable") }
            guard let kind = resolvePanelKind(args.panel) else {
                return errorJSON("unknown panel '\(args.panel)'. Available: \(panelListForErrors)")
            }
            let zone: TilingDropZone? = {
                // Database panels default to bottom so the user can see data entry
                // below the chat and browser panels. Resolved from the KIND so
                // display-name inputs ("MaestroDB") get the same treatment.
                if kind == .maestroDB && args.zone == nil { return .bottom }

                switch args.zone?.lowercased() {
                case "bottom": return .bottom
                case "float":  return nil
                default:       return .right
                }
            }()
            let result = layout.open(kind, zone: zone)
            switch result {
            case .dockedDirectly:
                return jsonString([
                    "status": "opened",
                    "panel": args.panel,
                    "mode": "docked",
                    "note": "Panel is now visible in the workspace.",
                ])
            case .floated:
                // Force-dock into the workspace grid so the agent can see it
                // without needing a separate openWindow() call.
                layout.dock(kind)
                return jsonString([
                    "status": "opened",
                    "panel": args.panel,
                    "mode": "docked",
                    "note": "Panel is now visible in the workspace.",
                ])
            case .alreadyOpen:
                // Still honor the "or focus" half of the contract.
                NotificationCenter.default.post(name: .bringWorkspacePanelToFront, object: kind)
                return jsonString([
                    "status": "already_open",
                    "panel": args.panel,
                    "note": "Panel was already open; brought to front.",
                ])
            }
        }
    }

    private static func closePanelTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ClosePanelArgs.self),
              !args.panel.trimmingCharacters(in: .whitespaces).isEmpty
        else { return errorJSON("close_panel requires 'panel'") }

        return await MainActor.run {
            guard let layout = workspaceLayout else { return errorJSON("workspace layout unavailable") }
            guard let kind = resolvePanelKind(args.panel) else {
                return errorJSON("unknown panel '\(args.panel)'. Available: \(panelListForErrors)")
            }
            // Closing a panel the user can re-open is safe; only report honestly
            // when it wasn't open in the first place.
            guard layout.allOpenPanels.contains(kind) else {
                return jsonString([
                    "status": "not_open",
                    "panel": args.panel,
                    "note": "That panel is not currently open.",
                ])
            }
            // Floating windows observe the floating-set and dismiss themselves;
            // docked panels are removed from the canvas grid.
            layout.close(kind)
            return jsonString([
                "status": "closed",
                "panel": args.panel,
                "note": "Panel closed.",
            ])
        }
    }

    // MARK: - Helpers

    /// Decode mlx tool-call arguments (`[String: JSONValue]`) into a Codable type
    /// by round-tripping through JSON (JSONValue is Codable).
    static func decodeArgs<T: Decodable>(_ call: ToolCall, as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(call.function.arguments) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Short description of what actually arrived in a tool call's arguments
    /// (key names + JSON types), for error messages. Strict decodes fail on
    /// the WHOLE struct when one value has the wrong type, which used to
    /// produce misleading "requires 'x'" errors that left the model guessing
    /// which argument was at fault (the glob_files/write_file meltdowns).
    /// String values are truncated and never included — only key/type pairs.
    static func argDiagnostics(_ call: ToolCall) -> String {
        let arguments = call.function.arguments
        guard !arguments.isEmpty else { return "no arguments received" }
        let pairs = arguments.keys.sorted().map { key in
            let typeName: String
            switch arguments[key] {
            case .string: typeName = "string"
            case .int, .double: typeName = "number"
            case .bool: typeName = "bool"
            case .array: typeName = "array"
            case .object: typeName = "object"
            case .null, .none: typeName = "null"
            }
            return "\(key):\(typeName)"
        }
        return "received [\(pairs.joined(separator: ", "))]"
    }

    /// Build an OpenAI-style function `ToolSpec`. `properties` maps each parameter
    /// name to its `{"type": ..., "description": ...}` JSON-schema entry.
    /// Parameter descriptions are stripped for simple types to save tokens.
    private static func functionSpec(
        name: String,
        description: String,
        properties: [String: [String: String]],
        required: [String]
    ) -> ToolSpec {
        var props: [String: any Sendable] = [:]
        for (key, value) in properties {
            let t = value["type"] ?? ""
            if ["string", "integer", "boolean", "number"].contains(t) {
                props[key] = value.filter { $0.key != "description" }
            } else {
                props[key] = value
            }
        }
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": props,
            "required": required,
        ]
        let function: [String: any Sendable] = [
            "name": name,
            "description": description,
            "parameters": parameters,
        ]
        return ["type": "function", "function": function]
    }

    // MARK: - Rules tools

    static func listRulesTool() -> String {
        let rules = SwiftMaestroSettingsStore.loadRules()
        let list: [[String: Any]] = rules.map { rule in
            let item: [String: Any] = [
                "id": rule.id.uuidString,
                "text": rule.text,
                "enabled": rule.enabled,
                "scope": rule.scope,
            ]
            return item
        }
        return jsonString(["rules": list, "count": list.count])
    }

    static func setRuleTool(_ call: ToolCall) -> String {
        struct SetRuleArgs: Decodable {
            let text: String
            let enabled: Bool?
            let scope: String?
        }
        guard let args = decodeArgs(call, as: SetRuleArgs.self), !args.text.isEmpty else {
            return errorJSON("set_rule requires 'text'")
        }
        let enabled = args.enabled ?? true
        let scope = args.scope ?? "All"
        var rules = SwiftMaestroSettingsStore.loadRules()
        if let idx = rules.firstIndex(where: { $0.text == args.text }) {
            rules[idx].enabled = enabled
            rules[idx].scope = scope
        } else {
            rules.append(AgentRule(text: args.text, enabled: enabled, scope: scope))
        }
        SwiftMaestroSettingsStore.saveRules(rules)
        return jsonString(["status": "ok", "text": args.text, "enabled": enabled, "scope": scope])
    }

    // MARK: - Shortcuts tools

    static func listShortcutsTool() async -> String {
        let script = #"tell application "Shortcuts" to get name of every shortcut"#
        guard let appleScript = NSAppleScript(source: script) else {
            return errorJSON("could not compile AppleScript")
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            return errorJSON(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        }
        var names: [String] = []
        for i in 1...result.numberOfItems {
            if let name = result.atIndex(i)?.stringValue {
                names.append(name)
            }
        }
        return jsonString(["shortcuts": names, "count": names.count])
    }

    static func runShortcutTool(_ call: ToolCall) async -> String {
        struct RunShortcutArgs: Decodable {
            let name: String
            let input: String?
        }
        guard let args = decodeArgs(call, as: RunShortcutArgs.self), !args.name.isEmpty else {
            return errorJSON("run_shortcut requires 'name'")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        var processArgs = ["run", args.name]
        if let input = args.input, !input.isEmpty {
            // Write input to a temp file for the shortcut
            let tmpDir = FileManager.default.temporaryDirectory
            let tmpFile = tmpDir.appendingPathComponent("shortcut-input-\(UUID().uuidString).txt")
            try? input.write(to: tmpFile, atomically: true, encoding: .utf8)
            processArgs += ["--input-path", tmpFile.path]
        }
        process.arguments = processArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                return jsonString(["status": "ran", "shortcut": args.name, "output": output.isEmpty ? "(no output)" : output])
            } else {
                return errorJSON("shortcut '\(args.name)' failed: \(output)")
            }
        } catch {
            return errorJSON("could not run shortcut: \(error.localizedDescription)")
        }
    }

    static func createShortcutTool(_ call: ToolCall) async -> String {
        struct CreateShortcutArgs: Decodable {
            let name: String
            let actions: [ShortcutAction]
        }
        struct ShortcutAction: Decodable {
            let type: String
            let url: String?
            let title: String?
            let notes: String?
            let body: String?
            let to: String?
            let value: String?
            let text: String?
            let seconds: Int?
            let name: String?
        }
        guard let args = decodeArgs(call, as: CreateShortcutArgs.self),
              !args.name.isEmpty, !args.actions.isEmpty else {
            return errorJSON("create_shortcut requires 'name' and non-empty 'actions'")
        }
        // Build the shortcut plist
        let actions = args.actions.map { action -> [String: Any] in
            var actionDict: [String: Any] = [:]
            switch action.type {
            case "open_url":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.openurl"
                actionDict["WFWorkflowActionParameters"] = ["WFInput": action.url ?? ""]
            case "create_reminder":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.addnewreminder"
                var params: [String: Any] = ["WFReminderTitle": action.title ?? ""]
                if let notes = action.notes { params["WFReminderNotes"] = notes }
                actionDict["WFWorkflowActionParameters"] = params
            case "create_note":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.createnote"
                actionDict["WFWorkflowActionParameters"] = [
                    "WFNoteTitle": action.title ?? "",
                    "WFNoteBody": action.body ?? ""
                ]
            case "send_message":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.sendmessage"
                actionDict["WFWorkflowActionParameters"] = [
                    "WFSendMessageActionRecipients": [action.to ?? ""],
                    "WFSendMessageContent": action.body ?? ""
                ]
            case "get_current_date":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.date"
                actionDict["WFWorkflowActionParameters"] = ["WFDateActionMode": "Current Date"]
            case "text":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.gettext"
                actionDict["WFWorkflowActionParameters"] = ["WFTextActionText": action.value ?? ""]
            case "show_result":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.alert"
                actionDict["WFWorkflowActionParameters"] = [
                    "WFAlertActionTitle": action.title ?? "Result",
                    "WFAlertActionMessage": action.text ?? ""
                ]
            case "wait":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.delay"
                actionDict["WFWorkflowActionParameters"] = ["WFDelayTime": action.seconds ?? 1]
            case "set_volume":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.setvolume"
                actionDict["WFWorkflowActionParameters"] = ["WFVolume": (Double(action.value ?? "50") ?? 50) / 100]
            case "play_sound":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.playsound"
                actionDict["WFWorkflowActionParameters"] = [:]
            case "run_shortcut":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.runworkflow"
                actionDict["WFWorkflowActionParameters"] = ["WFWorkflowName": action.name ?? ""]
            case "get_contents_of_url":
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.downloadurl"
                actionDict["WFWorkflowActionParameters"] = [
                    "WFHTTPMethod": "GET",
                    "WFURL": action.url ?? ""
                ]
            default:
                actionDict["WFWorkflowActionIdentifier"] = "is.workflow.actions.nothing"
                actionDict["WFWorkflowActionParameters"] = [:]
            }
            return actionDict
        }
        let shortcut: [String: Any] = [
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": 4282601983,
                "WFWorkflowIconGlyphNumber": 59746
            ],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowTypes": ["NCWidget", "WatchKit"],
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowOutputContentItemClasses": [],
            "WFWorkflowActions": actions
        ]
        // Write to Desktop
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let safeName = args.name.replacingOccurrences(of: "/", with: "-")
        let fileURL = desktop.appendingPathComponent("\(safeName).shortcut")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: shortcut, format: .xml, options: 0)
            try data.write(to: fileURL)
            // Sign the shortcut so it can be imported
            let signProcess = Process()
            signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            signProcess.arguments = ["sign", "--mode", "anyone", "--input", fileURL.path, "--output", fileURL.path]
            try signProcess.run()
            signProcess.waitUntilExit()
            return jsonString([
                "status": "created",
                "name": args.name,
                "path": fileURL.path,
                "message": "Shortcut saved to Desktop. Double-click \(safeName).shortcut to import it into the Shortcuts app."
            ])
        } catch {
            return errorJSON("could not create shortcut: \(error.localizedDescription)")
        }
    }

    static func errorJSON(_ message: String) -> String {
        jsonString(["error": message])
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else { return #"{"error": "failed to encode result"}"# }
        return string
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
