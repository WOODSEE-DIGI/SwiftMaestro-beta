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
    case messaging
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
    case whatsapp
    case web
    case vault

    var id: String { rawValue }

    /// Whether this category's tools can be deferred behind the
    /// `search_tools`/`call_tool` meta-tool pair in "Compact Tool Mode"
    /// instead of always advertising full schemas. Small, frequently-needed
    /// control categories (workspace/memory/rules/time) stay always-on since
    /// deferring them would just add a search hop to things every turn
    /// already needs; the larger, less-constantly-used domain/app categories
    /// are the ones actually worth deferring to save prompt tokens.
    ///
    /// `.mcp` is excluded even though it's a "large/less-constant" category:
    /// MCP tool schemas come from a live `MCPClientService` instance passed
    /// in per-call at each call site, not from `MaestroTools.schemas()`'s own
    /// static tool tables, so `search_tools`/`call_tool` (which only know
    /// about the static native registry) can't see or dispatch them yet.
    /// Deferring MCP would need call_tool to hold a reference to the live MCP
    /// service too — a reasonable follow-up, not done here.
    var isDeferrable: Bool {
        switch self {
        case .workspace, .memory, .messaging, .rules, .time, .mcp:
            return false
        case .file, .shell, .server, .index, .system, .sqlite,
             .notes, .kanban, .canvas, .numbers, .whatsapp, .web, .vault:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .file: return "Files"
        case .shell: return "Shell"
        case .server: return "Server"
        case .index: return "Index"
        case .memory: return "Memory"
        case .messaging: return "Messaging"
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
        case .whatsapp: return "WhatsApp"
        case .web: return "Web"
        case .vault: return "Vault"
        }
    }

    var icon: String {
        switch self {
        case .file: return "doc.text"
        case .shell: return "terminal"
        case .server: return "network"
        case .index: return "magnifyingglass.circle"
        case .memory: return "brain"
        case .messaging: return "bubble.left.and.bubble.right"
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
        case .whatsapp: return "message"
        case .web: return "globe"
        case .vault: return "lock.square"
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
            ]
        case .messaging:
            return ["send_agent_message", "read_agent_messages"]
        case .system:
            return [
                "create_reminder", "list_reminders", "list_reminder_lists",
                "create_calendar_event", "list_calendar_events",
                "open_url", "list_shortcuts", "run_shortcut", "create_shortcut",
                "search_contacts", "create_contact", "update_contact", "delete_contact",
            ]
        case .sqlite:
            return ["execute_sqlite"]
        case .workspace:
            return [
                "create_project_agent", "list_workspace", "archive_project_agent",
                "ask_project_agent", "ask_project_agents", "set_agent_model",
                "list_models", "open_panel",
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
        case .whatsapp:
            return [
                "whatsapp_status", "start_whatsapp_bridge", "stop_whatsapp_bridge",
                "list_whatsapp_chats", "read_whatsapp_messages", "send_whatsapp_message",
            ]
        case .web:
            return ["web_search", "fetch_url"]
        case .vault:
            return ["search_vault", "read_note", "write_note", "list_vault"]
        case .mcp:
            return []
        }
    }

    /// Categories visible in the tool picker for a given agent kind.
    static func visible(for kind: AgentKind) -> [ToolCategory] {
        switch kind {
        case .navigator:
            return [
                .workspace, .memory, .system, .rules, .time, .web, .vault,
                .notes, .kanban, .canvas, .numbers, .whatsapp,
            ]
        case .project:
            return [
                .file, .shell, .server, .index, .memory, .messaging, .system, .mcp, .sqlite, .web, .vault,
                .notes, .kanban, .canvas, .numbers, .whatsapp,
            ]
        }
    }

    /// Default enabled categories for an agent kind.
    static func defaultEnabled(for kind: AgentKind) -> Set<ToolCategory> {
        Set(visible(for: kind))
    }

    /// What an agent kind gets when `MaestroTools.schemas(enabledCategories:)`
    /// is called with NO explicit set at all — NOT the same as `visible(for:)`/
    /// `defaultEnabled(for:)`, which are a narrower UI-curation concept (which
    /// toggles show by default in the picker row). This instead matches the
    /// historical hard-coded behavior from before the tool registry existed,
    /// where each agent kind's schema-building code unconditionally
    /// concatenated a specific set of spec arrays regardless of category:
    /// navigator got everything except `.sqlite` and `.messaging`
    /// (it delegates instead of messaging directly); project agents got
    /// everything except `.workspace` (delegation is navigator-only).
    /// Real call sites always pass a concrete `enabledCategories` (from
    /// `WorkspaceStore.enabledToolCategories`), so this only matters for
    /// tests and edge startup timing before that store is wired up.
    static func unfilteredCategories(for kind: AgentKind) -> Set<ToolCategory> {
        switch kind {
        case .navigator:
            return Set(allCases).subtracting([.sqlite, .messaging])
        case .project:
            return Set(allCases).subtracting([.workspace])
        }
    }

    /// Determine the category for a native tool name.
    static func category(for toolName: String) -> ToolCategory? {
        for category in allCases where category.toolNames.contains(toolName) {
            return category
        }
        return nil
    }
}
