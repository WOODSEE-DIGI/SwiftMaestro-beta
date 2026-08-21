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
            ToolDefinition(name: "whiteboard_list_objects", spec: appsToolSpecs[26], category: ToolCategory.whiteboard.rawValue,
                handler: { call in await whiteboardListObjects(call) }),
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

            // MARK: Canvas (metadata only — the drawing itself is opaque PaperKit
            // binary data, not something a text model can meaningfully read/write).
            // MARK: Whiteboard boards (object content is readable via whiteboard_list_objects)
            rawSpec("whiteboard_list_boards",
                "List whiteboard boards (name, created/modified dates). Use whiteboard_list_objects "
                + "to see the shapes, notes, and workflow arrows on a board.",
                properties: [:], required: []),
            rawSpec("whiteboard_create_board",
                "Create a new empty whiteboard board. Add workflow shapes with whiteboard_add_shape and connect them with whiteboard_connect.",
                properties: [
                    "name": ["type": "string", "description": "Board name."],
                ], required: ["name"]),
            rawSpec("whiteboard_delete_board",
                "Delete a whiteboard board by name (or id).",
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

            // MARK: Whiteboard objects (workflow diagrams)
            rawSpec("whiteboard_list_objects",
                "List the objects on a whiteboard board: shapes, sticky notes, text boxes, images, and "
                + "connectors (workflow arrows), with ids, text, positions and sizes. Omit 'board' to "
                + "use the most recently modified board. Use the ids with whiteboard_connect.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board."],
                ], required: []),
            rawSpec("whiteboard_add_shape",
                "Add a shape to a whiteboard board and return its object id. For process workflows, "
                + "prefer rectangle (steps), diamond (decisions) and roundedRectangle (start/end). "
                + "Positions are canvas coordinates with the object centred at x/y; omit them to "
                + "auto-place below existing content. Opens the Whiteboard panel so the user sees it.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board (auto-creates one if none exist)."],
                    "shape": ["type": "string", "description": "rectangle, roundedRectangle, circle, ellipse, diamond, arrow, star, cloud, or heart."],
                    "text": ["type": "string", "description": "Label text inside the shape."],
                    "color": ["type": "string", "description": "Hex color like #3498DB (default blue)."],
                    "x": ["type": "number", "description": "Canvas x of the shape's centre."],
                    "y": ["type": "number", "description": "Canvas y of the shape's centre."],
                    "width": ["type": "number", "description": "Width in canvas points (default 150)."],
                    "height": ["type": "number", "description": "Height in canvas points (default 150)."],
                ], required: ["shape"]),
            rawSpec("whiteboard_add_text",
                "Add a sticky note or text box to a whiteboard board and return its object id. "
                + "Use sticky notes for annotations and text boxes for titles/labels on workflows. "
                + "Opens the Whiteboard panel so the user sees it.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board (auto-creates one if none exist)."],
                    "text": ["type": "string", "description": "The text content."],
                    "kind": ["type": "string", "description": "note (sticky note, default) or textbox (plain text)."],
                    "color": ["type": "string", "description": "Sticky note hex color like #FFE066 (notes only)."],
                    "x": ["type": "number", "description": "Canvas x of the object's centre."],
                    "y": ["type": "number", "description": "Canvas y of the object's centre."],
                ], required: ["text"]),
            rawSpec("whiteboard_connect",
                "Draw a workflow arrow between two objects on a whiteboard board. 'from' and 'to' "
                + "accept object ids (from whiteboard_add_shape/whiteboard_list_objects) or exact "
                + "object text. The arrow snaps to the best edge anchors based on the objects' "
                + "relative positions and stays glued when the objects move. "
                + "Opens the Whiteboard panel so the user sees it.",
                properties: [
                    "board": ["type": "string", "description": "Board name (or id). Omit for the most recently modified board."],
                    "from": ["type": "string", "description": "Source object id or its exact text label."],
                    "to": ["type": "string", "description": "Target object id or its exact text label."],
                    "label": ["type": "string", "description": "Optional label on the arrow (e.g. a decision's 'yes'/'no')."],
                ], required: ["from", "to"]),
            rawSpec("whiteboard_clear",
                "Remove ALL objects and pen strokes from a whiteboard board.",
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
    private static let sharedWhiteboardStore = WhiteboardStore()

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

    // MARK: - Canvas argument types

    private struct WhiteboardBoardArgs: Codable { let name: String? }

    /// Object-level whiteboard tools take `board` (not `name`) per their
    /// published specs.
    private struct WhiteboardBoardKeyArgs: Codable { let board: String? }

    @MainActor
    private static func findWhiteboardBoard(_ key: String) -> WhiteboardBoard? {
        if let byID = sharedWhiteboardStore.boards.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) {
            return byID
        }
        if let exact = sharedWhiteboardStore.boards.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        return sharedWhiteboardStore.boards.first { $0.name.localizedCaseInsensitiveContains(key) }
    }

    // MARK: - Canvas implementations

    static func listWhiteboardBoards() async -> String {
        await MainActor.run {
            sharedWhiteboardStore.loadBoards()
            let boards = sharedWhiteboardStore.boards
            guard !boards.isEmpty else { return "No Canvas boards yet. Use whiteboard_create_board to make one." }
            let iso = ISO8601DateFormatter()
            return jsonString(["boards": boards.map { board -> [String: Any] in
                [
                    "id": board.id.uuidString,
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
            let board = sharedWhiteboardStore.createBoard(name: name)
            return jsonString(["status": "created", "id": board.id.uuidString, "name": board.name])
        }
    }

    static func deleteWhiteboardBoard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WhiteboardBoardArgs.self),
              let key = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return errorJSON("whiteboard_delete_board requires 'name'") }
        return await MainActor.run {
            guard let board = findWhiteboardBoard(key) else {
                return errorJSON("no canvas board matching \"\(key)\".")
            }
            sharedWhiteboardStore.delete(board.id)
            return jsonString(["status": "deleted", "name": board.name])
        }
    }

    // MARK: - Whiteboard object implementations (workflow diagrams)

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
        let kind: String?
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
    private static func resolveWhiteboard(_ key: String?, createIfNone: Bool) -> WhiteboardBoard? {
        sharedWhiteboardStore.loadBoards()
        if let key, !key.isEmpty {
            return findWhiteboardBoard(key)
        }
        if let latest = sharedWhiteboardStore.boards.first { return latest }
        return createIfNone ? sharedWhiteboardStore.createBoard(name: "Workflows") : nil
    }

    @MainActor
    private static func whiteboardData(for board: WhiteboardBoard) -> WhiteboardBoardData {
        guard let data = board.markupData,
              let decoded = try? JSONDecoder().decode(WhiteboardBoardData.self, from: data)
        else { return WhiteboardBoardData() }
        return decoded
    }

    /// Persist board object data, reload any open panel showing this board,
    /// and (for content-creating tools) surface the Whiteboard panel so the
    /// user watches the workflow appear.
    @MainActor
    private static func saveWhiteboardData(
        _ data: WhiteboardBoardData, for board: WhiteboardBoard, surface: Bool
    ) {
        var updated = board
        updated.markupData = try? JSONEncoder().encode(data)
        try? sharedWhiteboardStore.save(updated)
        NotificationCenter.default.post(
            name: .whiteboardBoardExternallyModified, object: nil,
            userInfo: ["boardID": updated.id.uuidString])
        if surface {
            _ = WorkspaceLayoutState.shared.open(.canvas)
        }
    }

    /// Default placement for agent-added objects: under the lowest existing
    /// content so workflow steps stack downward predictably.
    private static func nextFreePoint(in data: WhiteboardBoardData) -> CGPoint {
        guard let lowest = data.objects.map({ $0.position.y + $0.size.height / 2 }).max() else {
            return CGPoint(x: 400, y: 200)
        }
        let left = data.objects.map { $0.position.x - $0.size.width / 2 }.min() ?? 250
        return CGPoint(x: left + 75, y: lowest + 100)
    }

    static func whiteboardListObjects(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: WhiteboardBoardKeyArgs.self)
        return await MainActor.run {
            guard let board = resolveWhiteboard(args?.board ?? nil, createIfNone: false) else {
                return errorJSON("No whiteboard boards yet. Add a shape with whiteboard_add_shape (a board is auto-created) or create one with whiteboard_create_board.")
            }
            let data = whiteboardData(for: board)
            return jsonString([
                "board": board.name,
                "board_id": board.id.uuidString,
                "objects": data.objects.map { obj -> [String: Any] in
                    var d: [String: Any] = [
                        "id": obj.id.uuidString,
                        "x": Int(obj.position.x), "y": Int(obj.position.y),
                        "width": Int(obj.size.width), "height": Int(obj.size.height),
                    ]
                    switch obj.type {
                    case .stickyNote: d["type"] = "sticky_note"
                    case .textBox: d["type"] = "text_box"
                    case .shape(let kind):
                        d["type"] = "shape"
                        d["shape"] = kind.rawValue
                    case .image: d["type"] = "image"
                    case .connector(let conn):
                        d["type"] = "connector"
                        d["from"] = conn.fromObjectID?.uuidString ?? "free"
                        d["to"] = conn.toObjectID?.uuidString ?? "free"
                    }
                    if !obj.text.isEmpty { d["text"] = obj.text }
                    return d
                },
            ])
        }
    }

    static func whiteboardAddShape(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WhiteboardAddShapeArgs.self),
              let shapeName = args.shape, !shapeName.isEmpty
        else { return errorJSON("whiteboard_add_shape requires 'shape'") }
        guard let kind = WhiteboardObject.ShapeKind(rawValue: shapeName) else {
            return errorJSON("unknown shape '\(shapeName)' — use rectangle, roundedRectangle, circle, ellipse, diamond, arrow, star, cloud, or heart.")
        }
        return await MainActor.run {
            guard let board = resolveWhiteboard(args.board, createIfNone: true) else {
                return errorJSON("no board found for '\(args.board ?? "")'.")
            }
            var data = whiteboardData(for: board)
            let position = (args.x != nil && args.y != nil)
                ? CGPoint(x: args.x!, y: args.y!)
                : nextFreePoint(in: data)
            let obj = WhiteboardObject(
                type: .shape(kind),
                text: args.text ?? "",
                position: position,
                size: CGSize(width: args.width ?? 150, height: args.height ?? 150),
                shapeColor: args.color ?? "#3498DB")
            data.objects.append(obj)
            saveWhiteboardData(data, for: board, surface: true)
            return jsonString([
                "status": "added", "id": obj.id.uuidString,
                "board": board.name, "board_id": board.id.uuidString,
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
            var data = whiteboardData(for: board)
            let isTextBox = args.kind?.lowercased() == "textbox"
            let position = (args.x != nil && args.y != nil)
                ? CGPoint(x: args.x!, y: args.y!)
                : nextFreePoint(in: data)
            let obj = WhiteboardObject(
                type: isTextBox
                    ? .textBox
                    : .stickyNote(color: args.color ?? "#FFE066"),
                text: text,
                position: position,
                size: isTextBox ? CGSize(width: 250, height: 60) : CGSize(width: 200, height: 200))
            data.objects.append(obj)
            saveWhiteboardData(data, for: board, surface: true)
            return jsonString([
                "status": "added", "id": obj.id.uuidString,
                "board": board.name, "board_id": board.id.uuidString,
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
            var data = whiteboardData(for: board)

            // Resolve an endpoint key: object id, else exact text match, else
            // case-insensitive text containment (shapes only — never another
            // connector).
            func findObject(_ key: String) -> WhiteboardObject? {
                let candidates = data.objects.filter { !$0.isConnector }
                if let byID = candidates.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) {
                    return byID
                }
                if let exact = candidates.first(where: { !$0.text.isEmpty && $0.text == key }) {
                    return exact
                }
                return candidates.first {
                    !$0.text.isEmpty && $0.text.localizedCaseInsensitiveContains(key)
                }
            }

            guard let fromObj = findObject(fromKey) else {
                return errorJSON("no object matching '\(fromKey)' on board '\(board.name)'. Use whiteboard_list_objects to see ids and labels.")
            }
            guard let toObj = findObject(toKey) else {
                return errorJSON("no object matching '\(toKey)' on board '\(board.name)'. Use whiteboard_list_objects to see ids and labels.")
            }
            guard fromObj.id != toObj.id else {
                return errorJSON("can't connect an object to itself.")
            }

            // Pick edge anchors from relative geometry: if the target sits to
            // the right, leave the source's right edge and arrive at its left;
            // same for vertical. Diagonal ties break toward horizontal.
            let dx = toObj.position.x - fromObj.position.x
            let dy = toObj.position.y - fromObj.position.y
            let fromAnchor: Connector.Anchor
            let toAnchor: Connector.Anchor
            if abs(dx) >= abs(dy) {
                fromAnchor = dx >= 0 ? .right : .left
                toAnchor = dx >= 0 ? .left : .right
            } else {
                fromAnchor = dy >= 0 ? .bottom : .top
                toAnchor = dy >= 0 ? .top : .bottom
            }

            let conn = Connector(
                fromObjectID: fromObj.id, fromAnchor: fromAnchor,
                toObjectID: toObj.id, toAnchor: toAnchor,
                startPoint: fromObj.anchorPoint(fromAnchor),
                endPoint: toObj.anchorPoint(toAnchor))
            var obj = WhiteboardObject(
                type: .connector(conn),
                text: args.label ?? "",
                position: .zero, size: .zero,
                shapeColor: "#FFFFFF", textColor: "#FFFFFF")
            obj.syncConnectorFrame(in: data.objects)
            data.objects.append(obj)
            saveWhiteboardData(data, for: board, surface: true)
            return jsonString([
                "status": "connected", "id": obj.id.uuidString,
                "from": fromObj.id.uuidString, "to": toObj.id.uuidString,
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
            var data = whiteboardData(for: board)
            let removed = data.objects.count + data.strokes.count
            data.objects.removeAll()
            data.strokes.removeAll()
            saveWhiteboardData(data, for: board, surface: true)
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
