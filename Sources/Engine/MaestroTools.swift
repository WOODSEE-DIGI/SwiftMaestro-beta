import Foundation
import MLXLMCommon

// MARK: - Native (in-process) tools
//
// First-class tool source: these run directly in-app (no IPC, no subprocess),
// ideal for SwiftMaestro-owned / privileged / latency-sensitive capabilities.
// MCP-sourced tools join the *same* agentic loop in MLXInferenceEngine /
// OMLXAgentExecutor.
//
// The Navigator (conductor) additionally gets workspace + delegation tools so it
// can spin up long-lived project agents and hand work to them. `ask_project_agent`
// is advertised here but executed by OMLXAgentExecutor (it needs the live
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
        // Every agent gets the live todo + plan tools; Navigator also gets workspace tools.
        var specs = schemas + todoToolSpecs + planToolSpecs
        if navigator { specs += navigatorToolSpecs }
        return specs
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
    private static func rawSpec(
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

    private static var planToolSpecs: [ToolSpec] {
        [
            rawSpec("create_plan",
                "Create a new markdown PLAN / design document the user can review. "
                + "Use for laying out a multi-step approach before implementing.",
                properties: [
                    "title": ["type": "string", "description": "Short plan title."],
                    "content": ["type": "string", "description": "Plan body in markdown."],
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
                ], required: []),
            rawSpec("read_plans", "List your plans with their ids, titles, and count.",
                properties: [:], required: []),
            rawSpec("read_plan",
                "Read a plan's full markdown content, identified by 'plan_id' or 'title'.",
                properties: [
                    "plan_id": ["type": "string", "description": "Id of the plan to read."],
                    "title": ["type": "string", "description": "Alternative to plan_id: match by title text."],
                ], required: []),
        ]
    }

    // MARK: - Navigator (workspace + delegation) tools

    /// Names of the Navigator-only workspace tools executed natively here.
    /// `ask_project_agent` is intentionally excluded — OMLXAgentExecutor runs it.
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
        ]
    }

    /// Whether a native (in-process) tool owns the given name. Routes a tool call
    /// to the native registry before MCP. `ask_project_agent` is excluded so the
    /// executor's delegation interceptor handles it.
    static func handles(_ name: String) -> Bool {
        if workspaceToolNames.contains(name) || todoToolNames.contains(name)
            || planToolNames.contains(name) { return true }
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
        let title: String?; let content: String?; let agent_id: String?
    }
    private struct PlanEditArgs: Decodable {
        let plan_id: String?; let title: String?; let new_title: String?
        let content: String?; let append: Bool?; let agent_id: String?
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
            agent_id = try? c.decodeIfPresent(String.self, forKey: .agent_id)
        }
        enum CodingKeys: String, CodingKey {
            case plan_id, title, new_title, content, text, body, step, steps, append, agent_id
        }
    }
    private struct PlanReadArgs: Codable { let agent_id: String? }
    private struct PlanReadOneArgs: Codable {
        let plan_id: String?; let title: String?; let agent_id: String?
    }

    private static func planCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanCreateArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let id = agentUUID(args.agent_id) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let title = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return errorJSON("'title' is required") }
        let content = args.content ?? ""
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            let plan = store.create(title: title, content: content, for: id)
            return "Created plan \"\(plan.title)\" (id \(plan.id.uuidString))."
        }
    }

    private static func planEdit(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanEditArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let id = agentUUID(args.agent_id) else {
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
            guard let target = store.find(idOrTitle: key, for: id) else {
                return errorJSON("no plan matching \"\(key)\".\n" + renderPlanList(store.plans(for: id)))
            }
            guard let updated = store.update(
                id: target.id, title: args.new_title, content: args.content,
                append: append, for: id)
            else { return errorJSON("failed to update plan") }
            let action = hasContent ? (append ? "appended to" : "rewrote") : "renamed"
            return "\(action.capitalized) plan \"\(updated.title)\" (now \(updated.content.count) chars):\n\n"
                + updated.content
        }
    }

    private static func planReadList(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanReadArgs.self), let id = agentUUID(args.agent_id) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            return renderPlanList(store.plans(for: id))
        }
    }

    private static func planReadOne(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PlanReadOneArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        guard let id = agentUUID(args.agent_id) else {
            return errorJSON("missing agent context (agent_id is injected automatically; just call the tool again)")
        }
        let key = (args.plan_id ?? args.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            return errorJSON("provide 'plan_id' or 'title' to identify the plan")
        }
        return await MainActor.run {
            guard let store = planStore else { return errorJSON("plan store unavailable") }
            guard let plan = store.find(idOrTitle: key, for: id) else {
                return errorJSON("no plan matching \"\(key)\".\n" + renderPlanList(store.plans(for: id)))
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
        await MainActor.run {
            guard let ws = workspace else { return errorJSON("workspace unavailable") }
            let projects: [[String: Any]] = ws.projects.map { project in
                [
                    "project": project.name,
                    "agents": ws.projectAgents(in: project.id).map { $0.name },
                ]
            }
            return jsonString([
                "navigator": ws.navigator.name,
                "projects": projects,
            ])
        }
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

    static func errorJSON(_ message: String) -> String {
        jsonString(["error": message])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
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
