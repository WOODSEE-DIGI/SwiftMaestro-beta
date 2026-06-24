import Foundation
import MLXLMCommon

// MARK: - Native (in-process) tools
//
// First-class tool source: these run directly in-app (no IPC, no subprocess),
// ideal for SwiftMaestro-owned / privileged / latency-sensitive capabilities.
// MCP-sourced tools join the *same* agentic loop in MLXInferenceEngine /
// AgentExecutor.
//
// The Navigator (conductor) additionally gets workspace + delegation tools so it
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

    /// Returns the real local date/time. Unambiguously verifiable: the model
    /// cannot know the true current time without calling this, so a correct
    /// answer proves the tool round-trip actually fired.
    static let getCurrentTime = Tool<NoToolArgs, CurrentTimeResult>(
        name: "get_current_time",
        description:
            "Get the current local date and time. Call this whenever the user asks "
            + "what the current time or date is.",
        parameters: []
    ) { _ in
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return CurrentTimeResult(
            current_time: formatter.string(from: Date()),
            timezone: TimeZone.current.identifier
        )
    }

    /// Base native tools exposed to every agent.
    static let all: [any ToolProtocol] = [getCurrentTime]

    /// Base tool schemas (every agent). Kept for back-compat with the native
    /// MLXInferenceEngine agentic loop.
    static var schemas: [ToolSpec] { all.map { $0.schema } }

    /// Tool schemas for an agent. Project agents get the base set; the Navigator
    /// additionally gets workspace + delegation tools.
    static func schemas(navigator: Bool) -> [ToolSpec] {
        // Every agent gets the live todo + plan + messaging tools; Navigator also
        // gets workspace/delegation tools.
        var specs = schemas + todoToolSpecs + planToolSpecs + messagingToolSpecs
            + memoryToolSpecs + fileToolSpecs + systemToolSpecs
        if navigator { specs += navigatorToolSpecs }
        return specs
    }

    // MARK: - Inter-agent messaging tools (caller agent_id injected by executor)

    private static let messagingToolNames: Set<String> = [
        "send_agent_message", "read_agent_messages",
    ]

    private static var messagingToolSpecs: [ToolSpec] {
        [
            rawSpec("send_agent_message",
                "Leave a message in another agent's inbox (durable across runs). Use to "
                + "hand off context or coordinate. Address the Navigator as agent \"Navigator\".",
                properties: [
                    "to_agent": ["type": "string", "description": "Recipient agent name (or 'Navigator')."],
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

    private static let todoToolNames: Set<String> = [
        "create_todo_list", "add_todos", "update_todo_status", "read_todos",
    ]

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
    static func rawSpec(
        _ name: String, _ description: String,
        properties: [String: any Sendable], required: [String]
    ) -> ToolSpec {
        let parameters: [String: any Sendable] = [
            "type": "object", "properties": properties, "required": required,
        ]
        return ["type": "function", "function": [
            "name": name, "description": description, "parameters": parameters,
        ] as [String: any Sendable]]
    }

    // MARK: - Plan tools (per-agent markdown design docs; agent_id injected by executor)

    private static let planToolNames: Set<String> = [
        "create_plan", "edit_plan", "read_plans", "read_plan",
    ]

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
            rawSpec("read_plans", "List plans with their ids, titles, and count.",
                properties: [
                    "project": ["type": "string", "description": projectScopeDesc],
                ], required: []),
            rawSpec("read_plan",
                "Read a plan's full markdown content, identified by 'plan_id' or 'title'.",
                properties: [
                    "plan_id": ["type": "string", "description": "Id of the plan to read."],
                    "title": ["type": "string", "description": "Alternative to plan_id: match by title text."],
                    "project": ["type": "string", "description": projectScopeDesc],
                ], required: []),
        ]
    }

    // MARK: - Navigator (workspace + delegation) tools

    /// Names of the Navigator-only workspace tools executed natively here.
    /// `ask_project_agent` is intentionally excluded — AgentExecutor runs it.
    private static let workspaceToolNames: Set<String> = [
        "create_project_agent", "list_workspace", "archive_project_agent",
    ]

    private static var navigatorToolSpecs: [ToolSpec] {
        [
            functionSpec(
                name: "create_project_agent",
                description:
                    "Create a long-lived project agent (creating the project if it "
                    + "does not exist). Use when the user wants ongoing, focused work "
                    + "on a specific project. Returns the created agent.",
                properties: [
                    "project": ["type": "string", "description": "Project name."],
                    "agent": ["type": "string", "description": "Name for the new project agent."],
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
                    "Delegate a task to a project agent and get its answer. The target "
                    + "agent runs scoped to its project's memory and its own chat history. "
                    + "Use this to coordinate work across projects, then synthesize the "
                    + "result for the user.",
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
        ]
    }

    /// Whether a native (in-process) tool owns the given name. Routes a tool call
    /// to the native registry before MCP. `ask_project_agent` is excluded so the
    /// executor's delegation interceptor handles it.
    static func handles(_ name: String) -> Bool {
        if workspaceToolNames.contains(name) || todoToolNames.contains(name)
            || planToolNames.contains(name) || messagingToolNames.contains(name)
            || memoryToolNames.contains(name) || fileToolNames.contains(name)
            || systemToolNames.contains(name) { return true }
        return schemas.contains { spec in
            (spec["function"] as? [String: any Sendable])?["name"] as? String == name
        }
    }

    /// Execute a parsed tool call and return a JSON string to feed back to the model.
    static func execute(_ call: ToolCall) async -> String {
        switch call.function.name {
        case getCurrentTime.name:
            do {
                let output = try await call.execute(with: getCurrentTime)
                return encode(output)
            } catch {
                return errorJSON(error.localizedDescription)
            }
        case "create_project_agent":
            return await createProjectAgent(call)
        case "list_workspace":
            return await listWorkspace()
        case "archive_project_agent":
            return await archiveProjectAgent(call)
        case "create_todo_list":
            return await todoCreate(call, replace: true)
        case "add_todos":
            return await todoCreate(call, replace: false)
        case "update_todo_status":
            return await todoUpdate(call)
        case "read_todos":
            return await todoRead(call)
        case "create_plan":
            return await planCreate(call)
        case "edit_plan":
            return await planEdit(call)
        case "read_plans":
            return await planReadList(call)
        case "read_plan":
            return await planReadOne(call)
        case "send_agent_message":
            return await sendAgentMessage(call)
        case "read_agent_messages":
            return await readAgentMessages(call)
        case "memory_write":
            return await memoryWrite(call)
        case "memory_read":
            return await memoryRead(call)
        case "memory_search":
            return await memorySearch(call)
        case "memory_list":
            return await memoryList(call)
        case "read_file":
            return await readFile(call)
        case "write_file":
            return await writeFile(call)
        case "list_dir":
            return await listDir(call)
        case "create_reminder":
            return await createReminder(call)
        case "list_reminders":
            return await listRemindersTool(call)
        case "create_calendar_event":
            return await createCalendarEvent(call)
        case "create_note":
            return await createNoteTool(call)
        case "open_url":
            return await openURLTool(call)
        case "list_rules":
            return listRulesTool()
        case "set_rule":
            return setRuleTool(call)
        case "list_shortcuts":
            return await listShortcutsTool()
        case "run_shortcut":
            return await runShortcutTool(call)
        case "create_shortcut":
            return await createShortcutTool(call)
        default:
            return errorJSON("unknown tool: \(call.function.name)")
        }
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
            items = list?.values ?? []
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
            title = try? c.decodeIfPresent(String.self, forKey: .title)
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

    /// Accepts an int as a number or a numeric string.
    private struct LenientInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i; return }
            if let s = try? c.decode(String.self) { value = Int(s); return }
            value = nil
        }
    }

    /// Accepts a bool as a boolean or a string like "true"/"false".
    private struct LenientBool: Decodable {
        let value: Bool?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { value = b; return }
            if let s = try? c.decode(String.self) { value = Bool(s.lowercased()); return }
            value = nil
        }
    }

    private static func agentUUID(_ raw: String?) -> UUID? { raw.flatMap { UUID(uuidString: $0) } }

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
            "\(i + 1). [\(item.done ? "x" : " ")] \(item.title)"
        }
        let doneCount = items.filter { $0.done }.count
        return "Task list (\(doneCount)/\(items.count) done):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Plan implementations

    private struct PlanCreateArgs: Codable {
        let title: String?; let content: String?; let project: String?; let agent_id: String?
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

    private static func planCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanCreateArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let scope = planScope(agentID: args.agent_id, project: args.project) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let title = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return errorJSON("'title' is required") }
        let content = args.content ?? ""
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            let plan = store.create(title: title, content: content, in: scope)
            return "Created \(scopeLabel(scope)) plan \"\(plan.title)\" (id \(plan.id.uuidString))."
        }
    }

    private static func planEdit(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanEditArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let scope = planScope(agentID: args.agent_id, project: args.project) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let key = (args.plan_id ?? args.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            guard let target = store.find(idOrTitle: key, in: scope) else {
                return errorJSON("no plan matching \"\(key)\".\n" + renderPlanList(store.plans(in: scope)))
            }
            guard let updated = store.update(
                id: target.id, title: args.new_title, content: args.content,
                append: append, in: scope)
            else { return errorJSON("failed to update plan") }
            let action = hasContent ? (append ? "appended to" : "rewrote") : "renamed"
            return "\(action.capitalized) plan \"\(updated.title)\" (now \(updated.content.count) chars):\n\n"
                + updated.content
        }
    }

    private static func planReadList(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanReadArgs.self),
              let scope = planScope(agentID: args.agent_id, project: args.project) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            return renderPlanList(store.plans(in: scope))
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
            guard let plan = store.find(idOrTitle: key, in: scope) else {
                return errorJSON("no plan matching \"\(key)\".\n" + renderPlanList(store.plans(in: scope)))
            }
            return renderPlan(plan)
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
            return errorJSON("'to_agent' (recipient name, or 'Navigator') is required")
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
            let fromName = agentUUID(args.agent_id).flatMap { ws.agent(id: $0)?.name } ?? "an agent"
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

    /// Resolve a recipient agent by name (+ optional project). "Navigator" maps to
    /// the conductor; otherwise prefer a project match, else any agent by name.
    @MainActor
    private static func resolveRecipient(
        _ ws: WorkspaceStore, name: String, project: String?
    ) -> AgentRecord? {
        if name.caseInsensitiveCompare("navigator") == .orderedSame { return ws.navigator }
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
    }

    private static func createProjectAgent(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ProjectAgentArgs.self),
              !args.project.trimmingCharacters(in: .whitespaces).isEmpty,
              !args.agent.trimmingCharacters(in: .whitespaces).isEmpty
        else { return errorJSON("create_project_agent requires non-empty 'project' and 'agent'") }

        return await MainActor.run {
            guard let ws = workspace else { return errorJSON("workspace unavailable") }
            let created = ws.createProjectAgent(projectName: args.project, agentName: args.agent)
            return jsonString([
                "status": "created",
                "project": args.project,
                "agent": created.name,
                "agentId": created.id.uuidString,
            ])
        }
    }

    private static func listWorkspace() async -> String {
        // Snapshot workspace state on MainActor, then format outside to avoid
        // deadlocking when the agentic loop's background task holds a reference.
        let snapshot: (navigator: String, projects: [(name: String, agents: [String])])? = await MainActor.run {
            guard let ws = workspace else { return nil }
            let projects = ws.projects.map { project in
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

    // MARK: - Helpers

    /// Decode mlx tool-call arguments (`[String: JSONValue]`) into a Codable type
    /// by round-tripping through JSON (JSONValue is Codable).
    static func decodeArgs<T: Decodable>(_ call: ToolCall, as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(call.function.arguments) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Build an OpenAI-style function `ToolSpec`. `properties` maps each parameter
    /// name to its `{"type": ..., "description": ...}` JSON-schema entry.
    private static func functionSpec(
        name: String,
        description: String,
        properties: [String: [String: String]],
        required: [String]
    ) -> ToolSpec {
        var props: [String: any Sendable] = [:]
        for (key, value) in properties { props[key] = value }
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

    private static func listRulesTool() -> String {
        let rules = SwiftMaestroSettingsStore.loadRules()
        let list: [[String: Any]] = rules.map { rule in
            var item: [String: Any] = [
                "id": rule.id.uuidString,
                "text": rule.text,
                "enabled": rule.enabled,
                "scope": rule.scope,
            ]
            return item
        }
        return jsonString(["rules": list, "count": list.count])
    }

    private static func setRuleTool(_ call: ToolCall) -> String {
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

    private static func listShortcutsTool() async -> String {
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

    private static func runShortcutTool(_ call: ToolCall) async -> String {
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

    private static func createShortcutTool(_ call: ToolCall) async -> String {
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
