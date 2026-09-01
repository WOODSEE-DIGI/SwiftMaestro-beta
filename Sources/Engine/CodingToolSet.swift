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
    /// This list is shared by Local Coder and Online Coder; Online Coder also
    /// receives every enabled MCP tool, giving it full OpenCode-style parity.
    static let nativeToolNames: Set<String> = [
        // File operations (OpenCode core)
        "read_file",
        "write_file",
        "edit_file",
        "multi_file_edit",
        "list_dir",
        "glob_files",
        "grep_code",
        "copy_file",
        "move_file",
        "create_directory",
        "delete_file",

        // Shell / build
        "execute_command",
        "list_background_processes",
        "stop_background_process",

        // Git
        "git_status",
        "git_diff",
        "git_log",
        "git_branch",

        // Web research
        "web_search",
        "fetch_url",
        "deep_fetch",
        "web_crawl",
        "site_map",

        // Indexing / RAG
        "index_directory",
        "save_index",
        "spotlight_search",
        "index_document",
        "search_chunks",
        "read_chunk",

        // Delegation / workspace
        "task",
        "ask_project_agent",
        "ask_project_agents",
        "ask_swiftHelper",
        "ask_search",
        "list_workspace",
        "create_project_agent",
        "set_agent_model",
        "list_models",

        // Shared context / memory
        "memory_write",
        "memory_read",
        "memory_search",
        "memory_list",
        "context_read",
        "fact_remember",
        "fact_query",

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

        // Rules
        "list_rules",
        "set_rule",
        "read_project_rules",

        // SQLite
        "execute_sqlite",

        // Utilities
        "get_current_time",
    ]

    /// Whether this agent should use the focused coding surface.
    static func isCodingAgent(_ agent: AgentRecord?) -> Bool {
        guard let agent else { return false }
        if agent.kind == .coder || agent.kind == .onlineCoder { return true }
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
