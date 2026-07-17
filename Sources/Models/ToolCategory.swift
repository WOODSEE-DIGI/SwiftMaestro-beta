import Foundation

/// Broad tool categories for per-agent tool-set configuration.
///
/// Instead of a sweeping "lite mode" reduction, each agent can have its own
/// enabled categories shown as a compact row of toggles in the chat title bar.
enum ToolCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case file
    case shell
    case server
    case index
    case memory
    case system
    case mcp
    case sqlite
    case workspace
    case rules
    case time
    case notes
    case kanban
    case canvas
    case numbers

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .file: return "Files"
        case .shell: return "Shell"
        case .server: return "Server"
        case .index: return "Index"
        case .memory: return "Memory"
        case .system: return "System"
        case .mcp: return "MCP"
        case .sqlite: return "SQLite"
        case .workspace: return "Workspace"
        case .rules: return "Rules"
        case .time: return "Time"
        case .notes: return "Notes"
        case .kanban: return "Kanban"
        case .canvas: return "Canvas"
        case .numbers: return "Numbers"
        }
    }

    var icon: String {
        switch self {
        case .file: return "doc.text"
        case .shell: return "terminal"
        case .server: return "network"
        case .index: return "magnifyingglass.circle"
        case .memory: return "brain"
        case .system: return "gearshape.2"
        case .mcp: return "server.rack"
        case .sqlite: return "cylinder.split.1x2"
        case .workspace: return "person.3"
        case .rules: return "list.bullet.rectangle"
        case .time: return "clock"
        case .notes: return "note.text"
        case .kanban: return "rectangle.split.3x1"
        case .canvas: return "rectangle.3.group"
        case .numbers: return "tablecells"
        }
    }

    /// Native tool names belonging to this category. MCP tools are handled
    /// separately because their names are not known at compile time.
    var toolNames: [String] {
        switch self {
        case .file:
            return ["read_file", "write_file", "list_dir", "ocr_image"]
        case .shell:
            return ["execute_command", "list_background_processes", "stop_background_process"]
        case .server:
            return ["start_server", "stop_server", "list_servers"]
        case .index:
            return [
                "index_directory", "save_index", "spotlight_search",
                "index_document", "search_chunks", "read_chunk",
            ]
        case .memory:
            return [
                "memory_write", "memory_read", "memory_search", "memory_list",
                "create_todo_list", "add_todos", "update_todo_status", "read_todos",
                "create_plan", "edit_plan", "read_plans", "read_plan",
                "send_agent_message", "read_agent_messages",
            ]
        case .system:
            return [
                "create_reminder", "list_reminders", "create_calendar_event", "list_calendar_events",
                "open_url", "list_shortcuts", "run_shortcut", "create_shortcut",
                "search_contacts", "create_contact", "update_contact", "delete_contact",
            ]
        case .sqlite:
            return ["execute_sqlite"]
        case .workspace:
            return [
                "create_project_agent", "list_workspace", "archive_project_agent",
                "ask_project_agent", "ask_project_agents",
            ]
        case .rules:
            return ["list_rules", "set_rule", "read_project_rules"]
        case .time:
            return ["get_current_time"]
        case .notes:
            return [
                "create_note", "list_notes", "read_note", "write_note", "search_notes",
                "list_apple_note_folders", "list_apple_notes", "read_apple_note",
            ]
        case .kanban:
            return [
                "list_kanban_boards", "create_kanban_board", "list_kanban_cards",
                "create_kanban_card", "move_kanban_card", "update_kanban_card", "delete_kanban_card",
            ]
        case .canvas:
            return ["list_canvas_boards", "create_canvas_board", "delete_canvas_board"]
        case .numbers:
            return [
                "list_numbers_documents", "create_numbers_document", "open_numbers_document",
                "list_numbers_sheets", "list_numbers_tables", "read_numbers_table",
                "write_numbers_cell", "export_numbers_document",
            ]
        case .mcp:
            return []
        }
    }

    /// Categories visible in the tool picker for a given agent kind.
    static func visible(for kind: AgentKind) -> [ToolCategory] {
        switch kind {
        case .navigator:
            return [.workspace, .memory, .system, .rules, .time, .notes, .kanban, .canvas, .numbers]
        case .project:
            return [
                .file, .shell, .server, .index, .memory, .system, .mcp, .sqlite,
                .notes, .kanban, .canvas, .numbers,
            ]
        }
    }

    /// Default enabled categories for an agent kind.
    static func defaultEnabled(for kind: AgentKind) -> Set<ToolCategory> {
        Set(visible(for: kind))
    }

    /// Determine the category for a native tool name.
    static func category(for toolName: String) -> ToolCategory? {
        for category in allCases where category.toolNames.contains(toolName) {
            return category
        }
        return nil
    }
}
