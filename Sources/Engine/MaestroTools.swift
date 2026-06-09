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
        navigator ? schemas + navigatorToolSpecs : schemas
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
        if workspaceToolNames.contains(name) { return true }
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
        default:
            return errorJSON("unknown tool: \(call.function.name)")
        }
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
