import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native "app" tools: Notes.md, Kanban, Canvas, richer Apple Notes, Calendar listing
//
// Exposes the SwiftMaestro-native panels (Notes.md, Kanban, Canvas) and the
// richer parts of Apple Notes/Calendar that `MaestroTools+System.swift` didn't
// cover (that file only ever had a bare one-shot `create_note`/`create_calendar_event` —
// no listing/reading). Each service already backs a UI panel; these tools call
// the SAME underlying stores/services so agent actions and the UI panels stay
// in sync.
extension MaestroTools {

    /// This file's specs span four categories (notes/kanban/canvas/numbers,
    /// plus list_calendar_events which is `.system`) - matches ToolCategory's
    /// existing per-name lists exactly.
    static func registerAppsTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(name: "list_notes", spec: appsToolSpecs[0], category: ToolCategory.notes.rawValue,
                handler: { call in await listNotes(call) }),
            ToolDefinition(name: "read_note", spec: appsToolSpecs[1], category: ToolCategory.notes.rawValue,
                handler: { call in await readNote(call) }),
            ToolDefinition(name: "write_note", spec: appsToolSpecs[2], category: ToolCategory.notes.rawValue,
                handler: { call in await writeNote(call) }),
            ToolDefinition(name: "search_notes", spec: appsToolSpecs[3], category: ToolCategory.notes.rawValue,
                handler: { call in await searchNotes(call) }),
            ToolDefinition(name: "list_kanban_boards", spec: appsToolSpecs[4], category: ToolCategory.kanban.rawValue,
                handler: { _ in await listKanbanBoards() }),
            ToolDefinition(name: "create_kanban_board", spec: appsToolSpecs[5], category: ToolCategory.kanban.rawValue,
                handler: { call in await createKanbanBoard(call) }),
            ToolDefinition(name: "list_kanban_cards", spec: appsToolSpecs[6], category: ToolCategory.kanban.rawValue,
                handler: { call in await listKanbanCards(call) }),
            ToolDefinition(name: "create_kanban_card", spec: appsToolSpecs[7], category: ToolCategory.kanban.rawValue,
                handler: { call in await createKanbanCard(call) }),
            ToolDefinition(name: "move_kanban_card", spec: appsToolSpecs[8], category: ToolCategory.kanban.rawValue,
                handler: { call in await moveKanbanCard(call) }),
            ToolDefinition(name: "update_kanban_card", spec: appsToolSpecs[9], category: ToolCategory.kanban.rawValue,
                handler: { call in await updateKanbanCard(call) }),
            ToolDefinition(name: "delete_kanban_card", spec: appsToolSpecs[10], category: ToolCategory.kanban.rawValue,
                handler: { call in await deleteKanbanCard(call) }),
            ToolDefinition(name: "whiteboard_list_boards", spec: appsToolSpecs[11], category: ToolCategory.whiteboard.rawValue,
                handler: { _ in await listWhiteboardBoards() }),
            ToolDefinition(name: "whiteboard_create_board", spec: appsToolSpecs[12], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await createWhiteboardBoard(call) }),
            ToolDefinition(name: "whiteboard_delete_board", spec: appsToolSpecs[13], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await deleteWhiteboardBoard(call) }),
            ToolDefinition(name: "list_apple_note_folders", spec: appsToolSpecs[14], category: ToolCategory.notes.rawValue,
                handler: { _ in await listAppleNoteFolders() }),
            ToolDefinition(name: "list_apple_notes", spec: appsToolSpecs[15], category: ToolCategory.notes.rawValue,
                handler: { call in await listAppleNotes(call) }),
            ToolDefinition(name: "read_apple_note", spec: appsToolSpecs[16], category: ToolCategory.notes.rawValue,
                handler: { call in await readAppleNote(call) }),
            ToolDefinition(name: "list_calendar_events", spec: appsToolSpecs[17], category: ToolCategory.calendar.rawValue,
                handler: { call in await listCalendarEventsTool(call) }),
            ToolDefinition(name: "list_numbers_documents", spec: appsToolSpecs[18], category: ToolCategory.numbers.rawValue,
                handler: { _ in await listNumbersDocuments() }),
            ToolDefinition(name: "create_numbers_document", spec: appsToolSpecs[19], category: ToolCategory.numbers.rawValue,
                handler: { _ in await createNumbersDocument() }),
            ToolDefinition(name: "open_numbers_document", spec: appsToolSpecs[20], category: ToolCategory.numbers.rawValue,
                handler: { call in await openNumbersDocument(call) }),
            ToolDefinition(name: "list_numbers_sheets", spec: appsToolSpecs[21], category: ToolCategory.numbers.rawValue,
                handler: { call in await listNumbersSheets(call) }),
            ToolDefinition(name: "list_numbers_tables", spec: appsToolSpecs[22], category: ToolCategory.numbers.rawValue,
                handler: { call in await listNumbersTables(call) }),
            ToolDefinition(name: "read_numbers_table", spec: appsToolSpecs[23], category: ToolCategory.numbers.rawValue,
                handler: { call in await readNumbersTable(call) }),
            ToolDefinition(name: "write_numbers_cell", spec: appsToolSpecs[24], category: ToolCategory.numbers.rawValue,
                handler: { call in await writeNumbersCell(call) }),
            ToolDefinition(name: "export_numbers_document", spec: appsToolSpecs[25], category: ToolCategory.numbers.rawValue,
                handler: { call in await exportNumbersDocument(call) }),
            ToolDefinition(name: "whiteboard_list_elements", spec: appsToolSpecs[26], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await whiteboardListElements(call) }),
            ToolDefinition(name: "whiteboard_add_shape", spec: appsToolSpecs[27], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await whiteboardAddShape(call) }),
            ToolDefinition(name: "whiteboard_add_text", spec: appsToolSpecs[28], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await whiteboardAddText(call) }),
            ToolDefinition(name: "whiteboard_connect", spec: appsToolSpecs[29], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await whiteboardConnect(call) }),
            ToolDefinition(name: "whiteboard_clear", spec: appsToolSpecs[30], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await whiteboardClear(call) }),
        ])
    }



    static var appsToolSpecs: [ToolSpec] {
        [
            // MARK: Notes.md
            rawSpec("list_notes",
                "List folders and notes in the Notes.md vault (a Markdown vault compatible with "
                + "Obsidian/Logseq). Returns relative paths. Omit 'path' to list the whole vault tree.",
                properties: [
                    "path": ["type": "string", "description": "Optional relative folder path to list (omit for the whole vault)."],
                ], required: []),
            rawSpec("read_note",
                "Read a note's Markdown content from the Notes.md vault by its relative path (as returned by list_notes/search_notes).",
                properties: [
                    "path": ["type": "string", "description": "Relative path, e.g. 'Project Ideas/roadmap.md'."],
                ], required: ["path"]),
            rawSpec("write_note",
                "Create or overwrite a note in the Notes.md vault. Creates parent folders automatically. "
                + "Appends '.md' if missing.",
                properties: [
                    "path": ["type": "string", "description": "Relative path, e.g. 'Project Ideas/roadmap.md'."],
                    "content": ["type": "string", "description": "Full Markdown content to write."],
                ], required: ["path", "content"]),
            rawSpec("search_notes",
                "Search note titles and contents in the Notes.md vault.",
                properties: [
                    "query": ["type": "string", "description": "Search text."],
                ], required: ["query"]),

            // MARK: Kanban
            rawSpec("list_kanban_boards",
                "List all Kanban boards with their columns and card counts.",
                properties: [:], required: []),
            rawSpec("create_kanban_board",
                "Create a new Kanban board (starts with Backlog/To Do/In Progress/Done columns).",
                properties: [
                    "name": ["type": "string", "description": "Board name."],
                ], required: ["name"]),
            rawSpec("list_kanban_cards",
                "List all cards on a Kanban board, grouped by column.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id from list_kanban_boards)."],
                ], required: ["board"]),
            rawSpec("create_kanban_card",
                "Add a new card to a column on a Kanban board.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id)."],
                    "column": ["type": "string", "description": "Column name, e.g. 'To Do'."],
                    "title": ["type": "string", "description": "Card title."],
                    "description": ["type": "string", "description": "Optional card description."],
                    "priority": ["type": "string", "description": "Optional: none, low, medium, high, urgent."],
                    "tags": [
                        "type": "array", "description": "Optional tags.",
                        "items": ["type": "string"] as [String: any Sendable],
                    ] as [String: any Sendable],
                ], required: ["board", "column", "title"]),
            rawSpec("move_kanban_card",
                "Move a card to a different column on the same board (e.g. drag it from 'To Do' to 'Done').",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id)."],
                    "card": ["type": "string", "description": "Card title (or id)."],
                    "to_column": ["type": "string", "description": "Destination column name."],
                ], required: ["board", "card", "to_column"]),
            rawSpec("update_kanban_card",
                "Update a card's title, description, priority, or tags. Omit fields you don't want to change. "
                + "Use move_kanban_card to change its column instead.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id)."],
                    "card": ["type": "string", "description": "Current card title (or id)."],
                    "title": ["type": "string", "description": "New title."],
                    "description": ["type": "string", "description": "New description."],
                    "priority": ["type": "string", "description": "none, low, medium, high, urgent."],
                    "tags": [
                        "type": "array", "description": "Replacement tag list.",
                        "items": ["type": "string"] as [String: any Sendable],
                    ] as [String: any Sendable],
                ], required: ["board", "card"]),
            rawSpec("delete_kanban_card",
                "Delete a card from a Kanban board.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id)."],
                    "card": ["type": "string", "description": "Card title (or id)."],
                ], required: ["board", "card"]),

            // MARK: Whiteboard boards (Excalidraw scene files)
            rawSpec("whiteboard_list_boards",
                "List Excalidraw whiteboard boards (name, created/modified dates). Use whiteboard_list_elements "
                + "to see the shapes, text, and workflow arrows on a board.",
                properties: [:], required: []),
            rawSpec("whiteboard_create_board",
                "Create a new empty Excalidraw whiteboard board. Add workflow shapes with whiteboard_add_shape and connect them with whiteboard_connect.",
                properties: [
                    "name": ["type": "string", "description": "Board name."],
                ], required: ["name"]),
            rawSpec("whiteboard_delete_board",
                "Delete an Excalidraw whiteboard board by name (or id).",
                properties: [
                    "name": ["type": "string", "description": "Board name (or id)."],
                ], required: ["name"]),

            // MARK: Apple Notes (richer than the bare create_note in the System category)
            rawSpec("list_apple_note_folders",
                "List the folders in the macOS Notes app. Prompts for access on first use.",
                properties: [:], required: []),
            rawSpec("list_apple_notes",
                "List notes in a folder of the macOS Notes app.",
                properties: [
                    "folder": ["type": "string", "description": "Folder name (or id from list_apple_note_folders)."],
                ], required: ["folder"]),
            rawSpec("read_apple_note",
                "Read the body of a note in the macOS Notes app.",
                properties: [
                    "folder": ["type": "string", "description": "Folder name (or id) the note is in."],
                    "note": ["type": "string", "description": "Note title (or id from list_apple_notes)."],
                ], required: ["folder", "note"]),

            // MARK: Calendar listing (create_calendar_event already existed; this adds reading)
            rawSpec("list_calendar_events",
                "List upcoming events from the macOS Calendar app.",
                properties: [
                    "days": ["type": "integer", "description": "How many days ahead to look (default 7)."],
                    "limit": ["type": "integer", "description": "Max events to return (default 25)."],
                ], required: []),

            // MARK: Apple Numbers (spreadsheets)
            rawSpec("list_numbers_documents",
                "List documents currently open in the macOS Numbers app. Prompts for access on first use. "
                + "Returns each document's id/name/path — use the id (or name) to address it in other numbers tools.",
                properties: [:], required: []),
            rawSpec("create_numbers_document",
                "Create a new blank Numbers document (one default sheet/table) and bring Numbers to the front. "
                + "The document saves wherever Numbers wants by default (usually iCloud Drive); use "
                + "export_numbers_document afterward if a specific file/format is needed.",
                properties: [:], required: []),
            rawSpec("open_numbers_document",
                "Open an existing .numbers file from disk in the macOS Numbers app.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to a .numbers file."],
                ], required: ["path"]),
            rawSpec("list_numbers_sheets",
                "List the sheets in an open Numbers document.",
                properties: [
                    "document": ["type": "string", "description": "Document id or name (from list_numbers_documents)."],
                ], required: ["document"]),
            rawSpec("list_numbers_tables",
                "List the tables on a sheet of an open Numbers document.",
                properties: [
                    "document": ["type": "string", "description": "Document id or name."],
                    "sheet": ["type": "string", "description": "Sheet name (from list_numbers_sheets)."],
                ], required: ["document", "sheet"]),
            rawSpec("read_numbers_table",
                "Read all cell values of a table as a 2-D grid of strings.",
                properties: [
                    "document": ["type": "string", "description": "Document id or name."],
                    "sheet": ["type": "string", "description": "Sheet name."],
                    "table": ["type": "string", "description": "Table name (from list_numbers_tables)."],
                ], required: ["document", "sheet", "table"]),
            rawSpec("write_numbers_cell",
                "Write a single cell's value in a table. Values that look like a plain number "
                + "are written as numbers; everything else is written as text.",
                properties: [
                    "document": ["type": "string", "description": "Document id or name."],
                    "sheet": ["type": "string", "description": "Sheet name."],
                    "table": ["type": "string", "description": "Table name."],
                    "cell": ["type": "string", "description": "A1-style cell reference, e.g. 'B2'."],
                    "value": ["type": "string", "description": "Value to write."],
                ], required: ["document", "sheet", "table", "cell", "value"]),
            rawSpec("export_numbers_document",
                "Export a Numbers document to CSV, PDF, or Excel (.xlsx) at a specific path.",
                properties: [
                    "document": ["type": "string", "description": "Document id or name."],
                    "path": ["type": "string", "description": "Destination file path, including extension."],
                    "format": ["type": "string", "description": "csv, pdf, or xlsx."],
                ], required: ["document", "path", "format"]),

            // MARK: Whiteboard elements (Excalidraw workflow diagrams)
            rawSpec("whiteboard_list_elements",
                "List the elements on an Excalidraw whiteboard board: shapes, text, and arrows, "
                + "with ids, types, positions and sizes. Omit 'board' to use the most recently "
                + "modified board. Use the ids with whiteboard_connect.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board."],
                ], required: []),
            rawSpec("whiteboard_add_shape",
                "Add a shape element to an Excalidraw whiteboard board and return its element id. "
                + "For process workflows, prefer rectangle (steps), diamond (decisions) and "
                + "roundedRectangle (start/end). Positions are Excalidraw canvas coordinates with "
                + "the element's top-left at x/y; omit them to auto-place below existing content. "
                + "Opens the Whiteboard panel so the user sees it.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board (auto-creates one if none exist)."],
                    "shape": ["type": "string", "description": "rectangle, roundedRectangle, circle, ellipse, diamond, star, cloud, or heart (heart = ellipse)."],
                    "text": ["type": "string", "description": "Label text inside the shape."],
                    "color": ["type": "string", "description": "Hex color like #3498DB (default blue)."],
                    "x": ["type": "number", "description": "Canvas x of the element's top-left."],
                    "y": ["type": "number", "description": "Canvas y of the element's top-left."],
                    "width": ["type": "number", "description": "Width in canvas points (default 150)."],
                    "height": ["type": "number", "description": "Height in canvas points (default 150)."],
                ], required: ["shape"]),
            rawSpec("whiteboard_add_text",
                "Add a text element to an Excalidraw whiteboard board and return its element id. "
                + "Use for titles/labels on workflows. Opens the Whiteboard panel so the user sees it.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board (auto-creates one if none exist)."],
                    "text": ["type": "string", "description": "The text content."],
                    "color": ["type": "string", "description": "Text hex color like #3498DB (default)."],
                    "x": ["type": "number", "description": "Canvas x of the element's top-left."],
                    "y": ["type": "number", "description": "Canvas y of the element's top-left."],
                ], required: ["text"]),
            rawSpec("whiteboard_connect",
                "Draw a workflow arrow between two elements on an Excalidraw whiteboard board. "
                + "'from' and 'to' accept element ids (from whiteboard_add_shape/whiteboard_list_elements) "
                + "or exact text labels. The arrow points from the source to the target element. "
                + "Opens the Whiteboard panel so the user sees it.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board."],
                    "from": ["type": "string", "description": "Source element id or its exact text label."],
                    "to": ["type": "string", "description": "Target element id or its exact text label."],
                    "label": ["type": "string", "description": "Optional label on the arrow (e.g. a decision's 'yes'/'no')."],
                ], required: ["from", "to"]),
            rawSpec("whiteboard_clear",
                "Remove ALL elements from an Excalidraw whiteboard board.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board."],
                ], required: []),
        ]
    }

    // MARK: - Shared service instances (mirrors `sharedContactsService` in MaestroTools+System.swift)

    @MainActor
    private static let sharedAppleNotesService = AppleNotesService()

    @MainActor
    private static let sharedKanbanStore = KanbanStore()

    @MainActor
    private static let sharedNumbersService = NumbersService()

    // MARK: - Notes.md vault path resolution
    //
    // Mirrors ChatCompaction's `resolveNotesVaultURL()` so agent tools and the
    // Notes.md UI panel always agree on which vault is currently active.

    @MainActor
    private static func resolveNotesVaultURL() -> URL {
        if let saved = UserDefaults.standard.string(forKey: NotesViewModel.vaultPathKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return NotesiCloudSupport.localVaultURL
    }

    @MainActor
    private static func notesService() -> NotesService {
        NotesService(vaultURL: resolveNotesVaultURL())
    }

    // MARK: - Notes.md argument types

    private struct ListNotesArgs: Codable { let path: String? }
    private struct ReadNoteArgs: Codable { let path: String? }
    private struct WriteNoteArgs: Codable { let path: String?; let content: String? }
    private struct SearchNotesArgs: Codable { let query: String? }

    // MARK: - Notes.md implementations

    static func listNotes(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ListNotesArgs.self)
        let vaultURL = await resolveNotesVaultURL()
        let target = (args?.path).map { vaultURL.appendingPathComponent($0) } ?? vaultURL
        do {
            let service = await notesService()
            try await service.ensureVault()
            let items = try await service.listDirectory(at: target)
            return renderNoteTree(items, vaultURL: vaultURL)
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func renderNoteTree(_ items: [NoteItem], vaultURL: URL, depth: Int = 0) -> String {
        guard !items.isEmpty else { return depth == 0 ? "Vault is empty." : "(empty folder)" }
        var lines: [String] = []
        func relativePath(_ url: URL) -> String {
            let full = url.path
            let base = vaultURL.path
            guard full.hasPrefix(base) else { return url.lastPathComponent }
            return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        func walk(_ items: [NoteItem], indent: String) {
            for item in items.sorted(by: { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name < $1.name }) {
                let path = relativePath(item.url)
                lines.append("\(indent)\(item.isFolder ? "📁" : "📄") \(path)")
                if let children = item.children, !children.isEmpty {
                    walk(children, indent: indent + "  ")
                }
            }
        }
        walk(items, indent: "")
        return "Notes vault (\(lines.count) items):\n" + lines.joined(separator: "\n")
    }

    static func readNote(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadNoteArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return errorJSON("read_note requires 'path'") }
        let vaultURL = await resolveNotesVaultURL()
        let fileURL = vaultURL.appendingPathComponent(path)
        do {
            let content = try await notesService().readFile(at: fileURL)
            return jsonString(["path": path, "content": content])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func writeNote(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WriteNoteArgs.self),
              let rawPath = args.path,
              let content = args.content
        else { return errorJSON("write_note requires 'path' and 'content'") }
        // Normalize the Gemma quote token and any surrounding quotes on the path
        // (paths are never legitimately quote-wrapped), but don't strip brackets,
        // which could be part of a real folder name.
        var path = sanitizeModelInline(rawPath).trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("\"") { path.removeFirst() }
        while path.hasSuffix("\"") { path.removeLast() }
        guard !path.isEmpty else { return errorJSON("write_note requires 'path'") }
        let cleanContent = sanitizeModelInline(content)
        if !path.lowercased().hasSuffix(".md") { path += ".md" }
        let vaultURL = await resolveNotesVaultURL()
        let fileURL = vaultURL.appendingPathComponent(path)
        do {
            try await notesService().writeFile(at: fileURL, content: cleanContent)
            return jsonString(["status": "saved", "path": path])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func searchNotes(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SearchNotesArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty
        else { return errorJSON("search_notes requires 'query'") }
        let vaultURL = await resolveNotesVaultURL()
        do {
            let matches = try await notesService().search(query: query, scope: nil)
            guard !matches.isEmpty else { return "No notes match \"\(query)\"." }
            let lines = matches.map { item -> String in
                let full = item.url.path
                let base = vaultURL.path
                let rel = full.hasPrefix(base)
                    ? String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : item.name
                return "- \(rel)"
            }
            return "Matches for \"\(query)\" (\(matches.count)):\n" + lines.joined(separator: "\n")
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    // MARK: - Kanban argument types

    private struct KanbanBoardArgs: Codable { let name: String? }
    private struct KanbanCardsArgs: Codable { let board: String? }
    private struct KanbanCreateCardArgs: Decodable {
        let board: String?; let column: String?; let title: String?
        let description: String?; let priority: String?; let tags: [String]?
    }
    private struct KanbanMoveCardArgs: Codable { let board: String?; let card: String?; let to_column: String? }
    private struct KanbanUpdateCardArgs: Codable {
        let board: String?; let card: String?; let title: String?
        let description: String?; let priority: String?; let tags: [String]?
    }
    private struct KanbanDeleteCardArgs: Codable { let board: String?; let card: String? }

    /// Fuzzy board lookup: exact id, then case-insensitive exact name, then
    /// case-insensitive substring — small models rarely pass the literal UUID.
    @MainActor
    private static func findBoard(_ store: KanbanStore, _ key: String) -> KanbanBoard? {
        if let byID = store.boards.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) {
            return byID
        }
        if let exact = store.boards.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        return store.boards.first { $0.name.localizedCaseInsensitiveContains(key) }
    }

    @MainActor
    private static func findColumn(_ board: KanbanBoard, _ key: String) -> KanbanColumn? {
        if let exact = board.columns.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        return board.columns.first { $0.title.localizedCaseInsensitiveContains(key) }
    }

    @MainActor
    private static func findCard(_ board: KanbanBoard, _ key: String) -> (column: KanbanColumn, card: KanbanCard)? {
        for column in board.columns {
            if let byID = column.cards.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) {
                return (column, byID)
            }
        }
        for column in board.columns {
            if let byTitle = column.cards.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }) {
                return (column, byTitle)
            }
        }
        for column in board.columns {
            if let fuzzy = column.cards.first(where: { $0.title.localizedCaseInsensitiveContains(key) }) {
                return (column, fuzzy)
            }
        }
        return nil
    }

    private static func renderBoardSummary(_ board: KanbanBoard) -> [String: Any] {
        [
            "id": board.id.uuidString,
            "name": board.name,
            "columns": board.columns.map { column in
                ["name": column.title, "cardCount": column.cards.count] as [String: Any]
            },
        ]
    }

    private static func renderCard(_ card: KanbanCard, column: String) -> [String: Any] {
        [
            "id": card.id.uuidString,
            "title": card.title,
            "column": column,
            "description": card.description,
            "priority": card.priority.rawValue,
            "tags": card.tags,
        ]
    }

    // MARK: - Kanban implementations

    static func listKanbanBoards() async -> String {
        await MainActor.run {
            let boards = sharedKanbanStore.boards
            guard !boards.isEmpty else { return "No Kanban boards yet. Use create_kanban_board to make one." }
            return jsonString(["boards": boards.map(renderBoardSummary)])
        }
    }

    static func createKanbanBoard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: KanbanBoardArgs.self),
              let name = args.name.map({ sanitizeModelText($0) }), !name.isEmpty
        else { return errorJSON("create_kanban_board requires 'name'") }
        return await MainActor.run {
            let board = sharedKanbanStore.createBoard(name: name)
            return jsonString(renderBoardSummary(board))
        }
    }

    static func listKanbanCards(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: KanbanCardsArgs.self),
              let key = args.board?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return errorJSON("list_kanban_cards requires 'board'") }
        return await MainActor.run {
            guard let board = findBoard(sharedKanbanStore, key) else {
                return errorJSON("no board matching \"\(key)\". Use list_kanban_boards to see boards.")
            }
            let columns = board.columns.map { column -> [String: Any] in
                [
                    "name": column.title,
                    "cards": column.cards.map { renderCard($0, column: column.title) },
                ]
            }
            return jsonString(["board": board.name, "columns": columns])
        }
    }

    static func createKanbanCard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: KanbanCreateCardArgs.self),
              let boardKey = args.board.map({ sanitizeModelText($0) }), !boardKey.isEmpty,
              let columnKey = args.column.map({ sanitizeModelText($0) }), !columnKey.isEmpty,
              let title = args.title.map({ sanitizeModelText($0) }), !title.isEmpty
        else { return errorJSON("create_kanban_card requires 'board', 'column', and 'title'") }
        return await MainActor.run {
            guard let board = findBoard(sharedKanbanStore, boardKey) else {
                return errorJSON("no board matching \"\(boardKey)\".")
            }
            guard let column = findColumn(board, columnKey) else {
                let names = board.columns.map(\.title).joined(separator: ", ")
                return errorJSON("no column matching \"\(columnKey)\" on board \"\(board.name)\". Columns: \(names)")
            }
            let priority = args.priority.flatMap { KanbanPriority(rawValue: $0.lowercased()) } ?? .none
            let card = KanbanCard(
                title: title,
                description: sanitizeModelInline(args.description ?? ""),
                priority: priority,
                tags: args.tags ?? []
            )
            sharedKanbanStore.addCard(card, toColumn: column.id, in: board.id)
            return jsonString(renderCard(card, column: column.title))
        }
    }

    static func moveKanbanCard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: KanbanMoveCardArgs.self),
              let boardKey = args.board?.trimmingCharacters(in: .whitespacesAndNewlines), !boardKey.isEmpty,
              let cardKey = args.card?.trimmingCharacters(in: .whitespacesAndNewlines), !cardKey.isEmpty,
              let toColumnKey = args.to_column?.trimmingCharacters(in: .whitespacesAndNewlines), !toColumnKey.isEmpty
        else { return errorJSON("move_kanban_card requires 'board', 'card', and 'to_column'") }
        return await MainActor.run {
            guard let board = findBoard(sharedKanbanStore, boardKey) else {
                return errorJSON("no board matching \"\(boardKey)\".")
            }
            guard let (_, card) = findCard(board, cardKey) else {
                return errorJSON("no card matching \"\(cardKey)\" on board \"\(board.name)\".")
            }
            guard let toColumn = findColumn(board, toColumnKey) else {
                let names = board.columns.map(\.title).joined(separator: ", ")
                return errorJSON("no column matching \"\(toColumnKey)\". Columns: \(names)")
            }
            sharedKanbanStore.moveCard(card.id, toColumn: toColumn.id, toIndex: 0, in: board.id)
            return jsonString(["status": "moved", "card": card.title, "to_column": toColumn.title])
        }
    }

    static func updateKanbanCard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: KanbanUpdateCardArgs.self),
              let boardKey = args.board?.trimmingCharacters(in: .whitespacesAndNewlines), !boardKey.isEmpty,
              let cardKey = args.card?.trimmingCharacters(in: .whitespacesAndNewlines), !cardKey.isEmpty
        else { return errorJSON("update_kanban_card requires 'board' and 'card'") }
        return await MainActor.run {
            guard let board = findBoard(sharedKanbanStore, boardKey) else {
                return errorJSON("no board matching \"\(boardKey)\".")
            }
            guard let (column, existing) = findCard(board, cardKey) else {
                return errorJSON("no card matching \"\(cardKey)\" on board \"\(board.name)\".")
            }
            var updated = existing
            if let title = args.title.map({ sanitizeModelText($0) }), !title.isEmpty {
                updated.title = title
            }
            if let description = args.description { updated.description = sanitizeModelInline(description) }
            if let priority = args.priority.flatMap({ KanbanPriority(rawValue: $0.lowercased()) }) {
                updated.priority = priority
            }
            if let tags = args.tags { updated.tags = tags }
            sharedKanbanStore.updateCard(updated, in: board.id)
            return jsonString(renderCard(updated, column: column.title))
        }
    }

    static func deleteKanbanCard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: KanbanDeleteCardArgs.self),
              let boardKey = args.board?.trimmingCharacters(in: .whitespacesAndNewlines), !boardKey.isEmpty,
              let cardKey = args.card?.trimmingCharacters(in: .whitespacesAndNewlines), !cardKey.isEmpty
        else { return errorJSON("delete_kanban_card requires 'board' and 'card'") }
        return await MainActor.run {
            guard let board = findBoard(sharedKanbanStore, boardKey) else {
                return errorJSON("no board matching \"\(boardKey)\".")
            }
            guard let (_, card) = findCard(board, cardKey) else {
                return errorJSON("no card matching \"\(cardKey)\" on board \"\(board.name)\".")
            }
            sharedKanbanStore.deleteCard(card.id, from: board.id)
            return jsonString(["status": "deleted", "card": card.title])
        }
    }

    // MARK: - Whiteboard (Excalidraw) argument types

    private struct WhiteboardBoardArgs: Codable { let name: String? }

    /// Element-level whiteboard tools take `board` (not `name`) per their
    /// published specs.
    private struct WhiteboardBoardKeyArgs: Codable { let board: String? }

    @MainActor
    private static func findWhiteboardBoard(_ key: String) -> ExcalidrawBoard? {
        let boards = ExcalidrawStore.shared.listBoards()
        if let byID = boards.first(where: { $0.url.lastPathComponent.caseInsensitiveCompare(key) == .orderedSame }) {
            return byID
        }
        if let exact = boards.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        return boards.first { $0.name.localizedCaseInsensitiveContains(key) }
    }

    // MARK: - Whiteboard board implementations

    static func listWhiteboardBoards() async -> String {
        await MainActor.run {
            let boards = ExcalidrawStore.shared.listBoards()
            guard !boards.isEmpty else { return "No whiteboard boards yet. Use whiteboard_create_board to make one." }
            let iso = ISO8601DateFormatter()
            return jsonString(["boards": boards.map { board -> [String: Any] in
                [
                    "id": board.url.lastPathComponent,
                    "name": board.name,
                    "created": iso.string(from: board.created),
                    "modified": iso.string(from: board.modified),
                ]
            }])
        }
    }

    static func createWhiteboardBoard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WhiteboardBoardArgs.self),
              let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return errorJSON("whiteboard_create_board requires 'name'") }
        return await MainActor.run {
            do {
                try ExcalidrawStore.shared.saveBoard(name: name, data: emptyExcalidrawSceneJSON())
                return jsonString(["status": "created", "name": name])
            } catch {
                return errorJSON("failed to create board '\(name)': \(error.localizedDescription)")
            }
        }
    }

    static func deleteWhiteboardBoard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WhiteboardBoardArgs.self),
              let key = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return errorJSON("whiteboard_delete_board requires 'name'") }
        return await MainActor.run {
            guard let board = findWhiteboardBoard(key) else {
                return errorJSON("no whiteboard board matching \"\(key)\".")
            }
            do {
                try ExcalidrawStore.shared.deleteBoard(url: board.url)
                return jsonString(["status": "deleted", "name": board.name])
            } catch {
                return errorJSON("failed to delete board '\(board.name)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Whiteboard element implementations (Excalidraw workflow diagrams)

    private struct WhiteboardAddShapeArgs: Codable {
        let board: String?
        let shape: String?
        let text: String?
        let color: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
    }

    private struct WhiteboardAddTextArgs: Codable {
        let board: String?
        let text: String?
        let color: String?
        let x: Double?
        let y: Double?
    }

    private struct WhiteboardConnectArgs: Codable {
        let board: String?
        let from: String?
        let to: String?
        let label: String?
    }

    /// Resolve a board by explicit key (id/name/substring), else the most
    /// recently modified board. When `createIfNone`, an empty store yields a
    /// fresh "Workflows" board so an agent's first workflow command never
    /// dead-ends on setup.
    @MainActor
    private static func resolveWhiteboard(_ key: String?, createIfNone: Bool) -> ExcalidrawBoard? {
        let boards = ExcalidrawStore.shared.listBoards()
        if let key, !key.isEmpty {
            return findWhiteboardBoard(key)
        }
        if let latest = boards.first { return latest }
        if createIfNone {
            let name = "Workflows"
            do {
                try ExcalidrawStore.shared.saveBoard(name: name, data: emptyExcalidrawSceneJSON())
                return ExcalidrawStore.shared.listBoards().first
            } catch {
                return nil
            }
        }
        return nil
    }

    /// An empty Excalidraw scene, matching what the bundled Excalidraw app emits.
    private static func emptyExcalidrawSceneJSON() -> String {
        "{\"type\":\"excalidraw\",\"version\":2,\"source\":\"swiftmaestro\",\"elements\":[],\"appState\":{}}"
    }

    /// Read a board's decoded scene dictionary (elements survive round-trip).
    @MainActor
    private static func readScene(for board: ExcalidrawBoard) -> [String: Any] {
        guard let data = try? ExcalidrawStore.shared.loadBoard(url: board.url),
              let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Write a scene dictionary back to disk, notify any open panel, and
    /// (for content-creating tools) surface the Whiteboard panel so the user
    /// watches the workflow appear.
    @MainActor
    private static func writeScene(_ scene: [String: Any], for board: ExcalidrawBoard, surface: Bool) {
        do {
            let data = try JSONSerialization.data(withJSONObject: scene, options: [.prettyPrinted, .sortedKeys])
            try ExcalidrawStore.shared.saveBoard(name: board.name, data: String(data: data, encoding: .utf8) ?? emptyExcalidrawSceneJSON())
            NotificationCenter.default.post(
                name: .excalidrawBoardExternallyModified, object: nil,
                userInfo: ["boardURL": board.url])
            if surface {
                _ = WorkspaceLayoutState.shared.open(.canvas)
            }
        } catch {
            // Persist failure is best-effort for the agent tool.
        }
    }

    /// Fully-qualified elements list from a scene (non-deleted only).
    @MainActor
    private static func liveElements(in scene: [String: Any]) -> [[String: Any]] {
        guard let raw = scene["elements"] as? [[String: Any]] else { return [] }
        return raw.filter { ($0["isDeleted"] as? Bool) != true }
    }

    /// A new lowercase Excalidraw element id.
    private static func newElementID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Reasonable text width/height for a bare text element.
    private static func textExtents(_ text: String, fontSize: Double) -> (width: Double, height: Double) {
        let chars = Double(text.count)
        return (max(60, chars * fontSize * 0.6), fontSize * 1.5)
    }

    /// Default placement for agent-added elements: under the lowest existing
    /// content so workflow steps stack downward predictably.
    @MainActor
    private static func nextFreePoint(in elements: [[String: Any]]) -> (x: Double, y: Double) {
        guard let lowest = elements.map({ (($0["y"] as? Double) ?? 0) + (($0["height"] as? Double) ?? 0) }).max() else {
            return (300, 200)
        }
        let left = elements.map { ($0["x"] as? Double) ?? 0 }.min() ?? 250
        return (left, lowest + 80)
    }

    /// Map a requested shape name to an Excalidraw element type.
    private static func excalidrawType(for shape: String) -> String? {
        switch shape.lowercased() {
        case "rectangle", "roundedrectangle", "rounded_rectangle": return "rectangle"
        case "circle", "ellipse", "oval": return "ellipse"
        case "diamond": return "diamond"
        case "star": return "star"
        case "cloud": return "cloud"
        case "heart", "arrow": return "ellipse"
        default: return nil
        }
    }

    /// Build a fully-qualified Excalidraw element dictionary for a shape.
    private static func shapeElement(
        shape: String, text: String?, color: String?,
        x: Double?, y: Double?, width: Double?, height: Double?
    ) -> [String: Any] {
        let strokeColor = color ?? "#3498DB"
        let bg = lighten(strokeColor)
        var el: [String: Any] = [
            "id": newElementID(),
            "type": excalidrawType(for: shape) ?? "rectangle",
            "x": x ?? 300,
            "y": y ?? 200,
            "width": width ?? 150,
            "height": height ?? 150,
            "angle": 0,
            "strokeColor": strokeColor,
            "backgroundColor": bg,
            "fillStyle": "solid",
            "strokeWidth": 2,
            "strokeStyle": "solid",
            "roughness": 1,
            "opacity": 100,
            "groupIds": [],
            "frameId": NSNull(),
            "seed": Int.random(in: 0..<Int.max),
            "versionNonce": Int.random(in: 0..<Int.max),
            "isDeleted": false,
            "boundElements": [],
            "updated": Int(Date().timeIntervalSince1970 * 1000),
            "link": NSNull(),
            "locked": false,
            "version": 1,
            "customData": NSNull(),
        ]
        if let text, !text.isEmpty {
            el["label"] = [
                "text": text,
                "fontSize": 20,
                "fontFamily": 1,
                "textAlign": "center",
                "verticalAlign": "middle",
            ]
        }
        return el
    }

    /// Build a text element.
    private static func textElement(text: String, color: String?, x: Double?, y: Double?) -> [String: Any] {
        let fontSize = 20.0
        let extents = textExtents(text, fontSize: fontSize)
        return [
            "id": newElementID(),
            "type": "text",
            "x": x ?? 300,
            "y": y ?? 200,
            "width": extents.width,
            "height": extents.height,
            "angle": 0,
            "strokeColor": color ?? "#1e1e1e",
            "backgroundColor": "transparent",
            "fillStyle": "solid",
            "strokeWidth": 2,
            "strokeStyle": "solid",
            "roughness": 1,
            "opacity": 100,
            "groupIds": [],
            "frameId": NSNull(),
            "seed": Int.random(in: 0..<Int.max),
            "versionNonce": Int.random(in: 0..<Int.max),
            "isDeleted": false,
            "boundElements": NSNull(),
            "updated": Int(Date().timeIntervalSince1970 * 1000),
            "link": NSNull(),
            "locked": false,
            "version": 1,
            "customData": NSNull(),
            "text": text,
            "fontSize": fontSize,
            "fontFamily": 1,
            "textAlign": "left",
            "verticalAlign": "top",
        ]
    }

    /// Compute a lighter background tone from a hex stroke color.
    private static func lighten(_ hex: String) -> String {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = Int(h, radix: 16) else { return "#ffffff" }
        let r = (val >> 16) & 0xFF
        let g = (val >> 8) & 0xFF
        let b = val & 0xFF
        let mix: (Int) -> Int = { c in c + (255 - c) * 3 / 4 }
        return String(format: "#%02X%02X%02X", mix(r), mix(g), mix(b))
    }

    /// Center (top-left + half extents) of an element.
    private static func elementCenter(_ el: [String: Any]) -> (x: Double, y: Double) {
        let x = (el["x"] as? Double) ?? 0
        let y = (el["y"] as? Double) ?? 0
        let w = (el["width"] as? Double) ?? 0
        let h = (el["height"] as? Double) ?? 0
        return (x + w / 2, y + h / 2)
    }

    private static func elementLabel(_ el: [String: Any]) -> String {
        if let label = el["label"] as? [String: Any], let text = label["text"] as? String { return text }
        return (el["text"] as? String) ?? ""
    }

    static func whiteboardListElements(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: WhiteboardBoardKeyArgs.self)
        return await MainActor.run {
            guard let board = resolveWhiteboard(args?.board ?? nil, createIfNone: false) else {
                return errorJSON("No whiteboard boards yet. Add a shape with whiteboard_add_shape (a board is auto-created) or create one with whiteboard_create_board.")
            }
            let elements = liveElements(in: readScene(for: board))
            return jsonString([
                "board": board.name,
                "elements": elements.compactMap { el -> [String: Any]? in
                    var d: [String: Any] = [
                        "id": el["id"] ?? "",
                        "type": el["type"] ?? "unknown",
                        "x": Int(el["x"] as? Double ?? 0),
                        "y": Int(el["y"] as? Double ?? 0),
                        "width": Int(el["width"] as? Double ?? 0),
                        "height": Int(el["height"] as? Double ?? 0),
                    ]
                    let label = elementLabel(el)
                    if !label.isEmpty { d["text"] = label }
                    return d
                },
            ])
        }
    }

    static func whiteboardAddShape(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WhiteboardAddShapeArgs.self),
              let shapeName = args.shape, !shapeName.isEmpty
        else { return errorJSON("whiteboard_add_shape requires 'shape'") }
        guard excalidrawType(for: shapeName) != nil else {
            return errorJSON("unknown shape '\(shapeName)' — use rectangle, roundedRectangle, circle, ellipse, diamond, star, cloud, or heart.")
        }
        return await MainActor.run {
            guard let board = resolveWhiteboard(args.board, createIfNone: true) else {
                return errorJSON("no board found for '\(args.board ?? "")'.")
            }
            var scene = readScene(for: board)
            var elements = liveElements(in: scene)
            let pos: (x: Double, y: Double)
            if let x = args.x, let y = args.y {
                pos = (x, y)
            } else {
                pos = nextFreePoint(in: elements)
            }
            var el = shapeElement(
                shape: shapeName,
                text: args.text,
                color: args.color,
                x: pos.x, y: pos.y,
                width: args.width, height: args.height
            )
            let id = el["id"] as? String ?? ""
            // If a label was added, record it as a bound element for canonical form.
            if el["label"] != nil {
                el["boundElements"] = [["type": "text", "id": "\(id)-label"]]
            }
            elements.append(el)
            scene["elements"] = elements
            writeScene(scene, for: board, surface: true)
            return jsonString([
                "status": "added", "id": id,
                "type": el["type"] ?? "", "x": el["x"] ?? 0, "y": el["y"] ?? 0,
                "width": el["width"] ?? 0, "height": el["height"] ?? 0,
                "board": board.name,
            ])
        }
    }

    static func whiteboardAddText(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WhiteboardAddTextArgs.self),
              let text = args.text, !text.isEmpty
        else { return errorJSON("whiteboard_add_text requires 'text'") }
        return await MainActor.run {
            guard let board = resolveWhiteboard(args.board, createIfNone: true) else {
                return errorJSON("no board found for '\(args.board ?? "")'.")
            }
            var scene = readScene(for: board)
            var elements = liveElements(in: scene)
            let pos: (x: Double, y: Double)
            if let x = args.x, let y = args.y {
                pos = (x, y)
            } else {
                pos = nextFreePoint(in: elements)
            }
            let el = textElement(text: text, color: args.color, x: pos.x, y: pos.y)
            let id = el["id"] as? String ?? ""
            elements.append(el)
            scene["elements"] = elements
            writeScene(scene, for: board, surface: true)
            return jsonString([
                "status": "added", "id": id,
                "type": "text", "x": el["x"] ?? 0, "y": el["y"] ?? 0,
                "width": el["width"] ?? 0, "height": el["height"] ?? 0,
                "board": board.name,
            ])
        }
    }

    static func whiteboardConnect(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WhiteboardConnectArgs.self),
              let fromKey = args.from, !fromKey.isEmpty,
              let toKey = args.to, !toKey.isEmpty
        else { return errorJSON("whiteboard_connect requires 'from' and 'to'") }
        return await MainActor.run {
            guard let board = resolveWhiteboard(args.board, createIfNone: false) else {
                return errorJSON("No whiteboard boards yet — add shapes first with whiteboard_add_shape.")
            }
            var scene = readScene(for: board)
            let elements = liveElements(in: scene)

            func findElement(_ key: String) -> [String: Any]? {
                let candidates = elements.filter { (($0["type"] as? String) ?? "") != "arrow" }
                if let byID = candidates.first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(key) == .orderedSame }) {
                    return byID
                }
                if let exact = candidates.first(where: { !elementLabel($0).isEmpty && elementLabel($0) == key }) {
                    return exact
                }
                return candidates.first {
                    !elementLabel($0).isEmpty && elementLabel($0).localizedCaseInsensitiveContains(key)
                }
            }

            guard let fromEl = findElement(fromKey) else {
                return errorJSON("no element matching '\(fromKey)' on board '\(board.name)'. Use whiteboard_list_elements to see ids and labels.")
            }
            guard let toEl = findElement(toKey) else {
                return errorJSON("no element matching '\(toKey)' on board '\(board.name)'. Use whiteboard_list_elements to see ids and labels.")
            }
            let fromID = (fromEl["id"] as? String) ?? ""
            let toID = (toEl["id"] as? String) ?? ""
            guard fromID != toID else {
                return errorJSON("can't connect an element to itself.")
            }

            let s = elementCenter(fromEl)
            let e = elementCenter(toEl)
            let dx = e.x - s.x
            let dy = e.y - s.y

            var arrow: [String: Any] = [
                "id": newElementID(),
                "type": "arrow",
                "x": s.x,
                "y": s.y,
                "width": abs(dx),
                "height": abs(dy),
                "angle": 0,
                "strokeColor": "#1e1e1e",
                "backgroundColor": "transparent",
                "fillStyle": "solid",
                "strokeWidth": 2,
                "strokeStyle": "solid",
                "roughness": 1,
                "opacity": 100,
                "groupIds": [],
                "frameId": NSNull(),
                "seed": Int.random(in: 0..<Int.max),
                "versionNonce": Int.random(in: 0..<Int.max),
                "isDeleted": false,
                "boundElements": NSNull(),
                "updated": Int(Date().timeIntervalSince1970 * 1000),
                "link": NSNull(),
                "locked": false,
                "version": 1,
                "customData": NSNull(),
                "points": [[0, 0], [dx, dy]],
                "lastCommittedPoint": NSNull(),
                "startBinding": ["elementId": fromID],
                "endBinding": ["elementId": toID],
                "start": ["id": fromID],
                "end": ["id": toID],
            ]
            if let label = args.label, !label.isEmpty {
                arrow["label"] = [
                    "text": label,
                    "fontSize": 16,
                    "fontFamily": 1,
                    "textAlign": "center",
                    "verticalAlign": "middle",
                ]
            }
            let arrowID = arrow["id"] as? String ?? ""
            var allElements = elements
            allElements.append(arrow)
            scene["elements"] = allElements
            writeScene(scene, for: board, surface: true)
            return jsonString([
                "status": "connected", "id": arrowID,
                "from": fromID, "to": toID,
                "board": board.name,
            ])
        }
    }

    static func whiteboardClear(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: WhiteboardBoardKeyArgs.self)
        return await MainActor.run {
            guard let board = resolveWhiteboard(args?.board ?? nil, createIfNone: false) else {
                return errorJSON("No whiteboard boards yet.")
            }
            var scene = readScene(for: board)
            let removed = liveElements(in: scene).count
            scene["elements"] = []
            writeScene(scene, for: board, surface: true)
            return jsonString(["status": "cleared", "board": board.name, "removed": removed])
        }
    }

    // MARK: - Apple Notes (richer) argument types

    private struct AppleNoteFolderArgs: Codable { let folder: String? }
    private struct AppleNoteReadArgs: Codable { let folder: String?; let note: String? }

    @MainActor
    private static func findAppleNotesFolder(_ key: String) -> AppleNotesFolder? {
        if let byID = sharedAppleNotesService.folders.first(where: { $0.id == key }) { return byID }
        if let exact = sharedAppleNotesService.folders.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        return sharedAppleNotesService.folders.first { $0.name.localizedCaseInsensitiveContains(key) }
    }

    // MARK: - Apple Notes (richer) implementations

    static func listAppleNoteFolders() async -> String {
        await MainActor.run {
            if sharedAppleNotesService.status != .authorized {
                // requestAuthorization is async; kick it off and ask the model
                // to retry once permission is granted (matches how other
                // first-use-permission tools in this file report the state).
            }
        }
        if await MainActor.run(body: { sharedAppleNotesService.status }) != .authorized {
            await sharedAppleNotesService.requestAuthorization()
        }
        await sharedAppleNotesService.loadFolders()
        return await MainActor.run {
            if let error = sharedAppleNotesService.error, sharedAppleNotesService.folders.isEmpty {
                return errorJSON(error)
            }
            let folders = sharedAppleNotesService.folders
            guard !folders.isEmpty else { return "No folders found (or access not yet granted)." }
            return jsonString(["folders": folders.map { ["id": $0.id, "name": $0.name] }])
        }
    }

    static func listAppleNotes(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: AppleNoteFolderArgs.self),
              let key = args.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return errorJSON("list_apple_notes requires 'folder'") }
        if await MainActor.run(body: { sharedAppleNotesService.folders.isEmpty }) {
            await sharedAppleNotesService.loadFolders()
        }
        guard let folder = await MainActor.run(body: { findAppleNotesFolder(key) }) else {
            return errorJSON("no folder matching \"\(key)\". Use list_apple_note_folders first.")
        }
        await sharedAppleNotesService.loadNotes(in: folder.id)
        return await MainActor.run {
            let notes = sharedAppleNotesService.notes
            guard !notes.isEmpty else { return "No notes in folder \"\(folder.name)\"." }
            let iso = ISO8601DateFormatter()
            return jsonString(["folder": folder.name, "notes": notes.map { note -> [String: Any] in
                var dict: [String: Any] = ["id": note.id, "title": note.name]
                if let modified = note.modified { dict["modified"] = iso.string(from: modified) }
                return dict
            }])
        }
    }

    static func readAppleNote(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: AppleNoteReadArgs.self),
              let folderKey = args.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !folderKey.isEmpty,
              let noteKey = args.note?.trimmingCharacters(in: .whitespacesAndNewlines), !noteKey.isEmpty
        else { return errorJSON("read_apple_note requires 'folder' and 'note'") }
        if await MainActor.run(body: { sharedAppleNotesService.folders.isEmpty }) {
            await sharedAppleNotesService.loadFolders()
        }
        guard let folder = await MainActor.run(body: { findAppleNotesFolder(folderKey) }) else {
            return errorJSON("no folder matching \"\(folderKey)\".")
        }
        await sharedAppleNotesService.loadNotes(in: folder.id)
        let match = await MainActor.run { () -> AppleNotesNote? in
            if let byID = sharedAppleNotesService.notes.first(where: { $0.id == noteKey }) { return byID }
            if let exact = sharedAppleNotesService.notes.first(where: { $0.name.caseInsensitiveCompare(noteKey) == .orderedSame }) {
                return exact
            }
            return sharedAppleNotesService.notes.first { $0.name.localizedCaseInsensitiveContains(noteKey) }
        }
        guard let note = match else {
            return errorJSON("no note matching \"\(noteKey)\" in folder \"\(folder.name)\".")
        }
        do {
            let body = try await sharedAppleNotesService.loadBody(for: note.id)
            return jsonString(["title": note.name, "folder": folder.name, "body": body])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    // MARK: - Calendar listing

    private struct ListCalendarEventsArgs: Codable { let days: Int?; let limit: Int? }

    static func listCalendarEventsTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ListCalendarEventsArgs.self)
        let days = args?.days ?? 7
        let limit = args?.limit ?? 25
        do {
            let now = Date()
            let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
            let events = try await MacOSIntegration.fetchCalendarEvents(start: now, end: end, limit: limit)
            guard !events.isEmpty else { return "No events in the next \(days) day(s)." }
            let fmt = DateFormatter()
            fmt.dateStyle = .short; fmt.timeStyle = .short
            let lines = events.map { event -> String in
                let when = event.isAllDay
                    ? "All day"
                    : "\(fmt.string(from: event.startDate)) – \(fmt.string(from: event.endDate))"
                return "- \(event.title) (\(when), \(event.calendarTitle))"
            }
            return "Events (\(events.count)):\n" + lines.joined(separator: "\n")
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    // MARK: - Numbers argument types

    private struct NumbersDocumentArgs: Codable { let document: String? }
    private struct NumbersOpenArgs: Codable { let path: String? }
    private struct NumbersSheetArgs: Codable { let document: String?; let sheet: String? }
    private struct NumbersTableArgs: Codable { let document: String?; let sheet: String?; let table: String? }
    private struct NumbersWriteCellArgs: Codable {
        let document: String?; let sheet: String?; let table: String?
        let cell: String?; let value: String?
    }
    private struct NumbersExportArgs: Codable { let document: String?; let path: String?; let format: String? }

    /// Fuzzy document lookup: exact id, then case-insensitive exact name,
    /// then case-insensitive substring — mirrors `findBoard` for Kanban.
    /// Loads the document list first if it's never been loaded.
    @MainActor
    private static func resolveNumbersDocument(_ key: String) async -> NumbersDocument? {
        if sharedNumbersService.documents.isEmpty {
            await sharedNumbersService.loadDocuments()
        }
        if let byID = sharedNumbersService.documents.first(where: { $0.id == key }) { return byID }
        if let exact = sharedNumbersService.documents.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        return sharedNumbersService.documents.first { $0.name.localizedCaseInsensitiveContains(key) }
    }

    private static func renderNumbersDocument(_ doc: NumbersDocument) -> [String: Any] {
        var dict: [String: Any] = ["id": doc.id, "name": doc.name]
        if let path = doc.path { dict["path"] = path }
        return dict
    }

    // MARK: - Numbers implementations

    static func listNumbersDocuments() async -> String {
        if await MainActor.run(body: { sharedNumbersService.status }) != .authorized {
            await sharedNumbersService.requestAuthorization()
        }
        await sharedNumbersService.loadDocuments()
        return await MainActor.run {
            if let error = sharedNumbersService.error, sharedNumbersService.documents.isEmpty {
                return errorJSON(error)
            }
            let docs = sharedNumbersService.documents
            guard !docs.isEmpty else { return "No documents open in Numbers (or access not yet granted)." }
            return jsonString(["documents": docs.map(renderNumbersDocument)])
        }
    }

    static func createNumbersDocument() async -> String {
        do {
            let doc = try await sharedNumbersService.createDocument()
            return jsonString(renderNumbersDocument(doc))
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func openNumbersDocument(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumbersOpenArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return errorJSON("open_numbers_document requires 'path'") }
        do {
            let doc = try await sharedNumbersService.openDocument(atPath: path)
            return jsonString(renderNumbersDocument(doc))
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func listNumbersSheets(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumbersDocumentArgs.self),
              let key = args.document?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return errorJSON("list_numbers_sheets requires 'document'") }
        guard let doc = await resolveNumbersDocument(key) else {
            return errorJSON("no Numbers document matching \"\(key)\". Use list_numbers_documents first.")
        }
        do {
            let sheets = try await sharedNumbersService.listSheets(documentID: doc.id)
            guard !sheets.isEmpty else { return "No sheets in \"\(doc.name)\"." }
            return jsonString(["document": doc.name, "sheets": sheets.map { ["name": $0.name, "tableCount": $0.tableCount] }])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func listNumbersTables(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumbersSheetArgs.self),
              let docKey = args.document?.trimmingCharacters(in: .whitespacesAndNewlines), !docKey.isEmpty,
              let sheetName = args.sheet?.trimmingCharacters(in: .whitespacesAndNewlines), !sheetName.isEmpty
        else { return errorJSON("list_numbers_tables requires 'document' and 'sheet'") }
        guard let doc = await resolveNumbersDocument(docKey) else {
            return errorJSON("no Numbers document matching \"\(docKey)\".")
        }
        do {
            let tables = try await sharedNumbersService.listTables(documentID: doc.id, sheetName: sheetName)
            guard !tables.isEmpty else { return "No tables on sheet \"\(sheetName)\" of \"\(doc.name)\"." }
            return jsonString(["document": doc.name, "sheet": sheetName, "tables": tables.map {
                ["name": $0.name, "rowCount": $0.rowCount, "columnCount": $0.columnCount]
            }])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func readNumbersTable(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumbersTableArgs.self),
              let docKey = args.document?.trimmingCharacters(in: .whitespacesAndNewlines), !docKey.isEmpty,
              let sheetName = args.sheet?.trimmingCharacters(in: .whitespacesAndNewlines), !sheetName.isEmpty,
              let tableName = args.table?.trimmingCharacters(in: .whitespacesAndNewlines), !tableName.isEmpty
        else { return errorJSON("read_numbers_table requires 'document', 'sheet', and 'table'") }
        guard let doc = await resolveNumbersDocument(docKey) else {
            return errorJSON("no Numbers document matching \"\(docKey)\".")
        }
        do {
            let data = try await sharedNumbersService.readTable(
                documentID: doc.id, sheetName: sheetName, tableName: tableName)
            return jsonString([
                "document": doc.name, "sheet": sheetName, "table": tableName,
                "rowCount": data.rowCount, "columnCount": data.columnCount, "rows": data.rows,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func writeNumbersCell(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumbersWriteCellArgs.self),
              let docKey = args.document?.trimmingCharacters(in: .whitespacesAndNewlines), !docKey.isEmpty,
              let sheetName = args.sheet?.trimmingCharacters(in: .whitespacesAndNewlines), !sheetName.isEmpty,
              let tableName = args.table?.trimmingCharacters(in: .whitespacesAndNewlines), !tableName.isEmpty,
              let cell = args.cell?.trimmingCharacters(in: .whitespacesAndNewlines), !cell.isEmpty,
              let value = args.value
        else { return errorJSON("write_numbers_cell requires 'document', 'sheet', 'table', 'cell', and 'value'") }
        guard let doc = await resolveNumbersDocument(docKey) else {
            return errorJSON("no Numbers document matching \"\(docKey)\".")
        }
        do {
            try await sharedNumbersService.writeCell(
                documentID: doc.id, sheetName: sheetName, tableName: tableName, cell: cell, value: value)
            return jsonString(["status": "written", "document": doc.name, "cell": cell, "value": value])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func exportNumbersDocument(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumbersExportArgs.self),
              let docKey = args.document?.trimmingCharacters(in: .whitespacesAndNewlines), !docKey.isEmpty,
              let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              let formatRaw = args.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !formatRaw.isEmpty
        else { return errorJSON("export_numbers_document requires 'document', 'path', and 'format'") }
        guard let format = NumbersExportFormat(rawValue: formatRaw) else {
            return errorJSON("unsupported format \"\(formatRaw)\". Use csv, pdf, or xlsx.")
        }
        guard let doc = await resolveNumbersDocument(docKey) else {
            return errorJSON("no Numbers document matching \"\(docKey)\".")
        }
        do {
            try await sharedNumbersService.exportDocument(documentID: doc.id, toPath: path, format: format)
            return jsonString(["status": "exported", "document": doc.name, "path": path, "format": formatRaw])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }
}
