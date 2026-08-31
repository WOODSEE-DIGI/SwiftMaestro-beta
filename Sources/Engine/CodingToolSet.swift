import Foundation
import MLXLMCommon

// MARK: - Coding Tool Set
//
// OpenCode-style focused tool surface for coding agents. Maestro and general
// agents keep the full MaestroTools surface; agents with category `.coding`
// (or the bundled `.coder` kind) advertise only this lean native set plus
// whatever MCP servers the user has enabled.

enum CodingToolSet {

    /// Native tools advertised to coding agents. Everything else is dropped
    /// from the prompt; MCP tools are added separately by the executor.
    static let nativeToolNames: Set<String> = [
        // File operations (OpenCode core)
        "read_file",
        "write_file",
        "edit_file",
        "glob_files",
        "grep_code",

        // Shell / build
        "execute_command",

        // Git
        "git_status",
        "git_diff",
        "git_log",
        "git_branch",

        // Web research
        "web_search",
        "fetch_url",

        // Delegation (limited)
        "task",

        // Shared context / memory
        "memory_write",
        "memory_read",
        "memory_search",
        "memory_list",

        // ai-context-bridge coordination
        "add_decision",
        "add_todo",
        "report_error",
        "update_session",
        "list_active_contexts",

        // Planning
        "create_plan",
        "edit_plan",
        "read_plans",
        "read_plan",

        // Task tracking
        "create_todo_list",
        "add_todos",
        "update_todo_status",
        "read_todos",

        // Utilities
        "get_current_time",
    ]

    /// Whether this agent should use the focused coding surface.
    static func isCodingAgent(_ agent: AgentRecord?) -> Bool {
        guard let agent else { return false }
        if agent.kind == .coder { return true }
        return agent.category == .coding
    }

    /// Filter a full MaestroTools schema list down to the coding whitelist.
    static func filterNativeSchemas(_ schemas: [ToolSpec]) -> [ToolSpec] {
        schemas.filter { spec in
            guard let name = MaestroTools.toolName(from: spec) else { return false }
            return nativeToolNames.contains(name)
        }
    }

    /// Whether a coding agent is allowed to invoke the given native tool name.
    static func allowsNativeTool(_ name: String) -> Bool {
        nativeToolNames.contains(name)
    }
}
