import Foundation
import MLXLMCommon

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
            ToolDefinition(name: "list_canvas_boards", spec: appsToolSpecs[11], category: ToolCategory.canvas.rawValue,
                handler: { _ in await listCanvasBoards() }),
            ToolDefinition(name: "create_canvas_board", spec: appsToolSpecs[12], category: ToolCategory.canvas.rawValue,
                handler: { call in await createCanvasBoard(call) }),
            ToolDefinition(name: "delete_canvas_board", spec: appsToolSpecs[13], category: ToolCategory.canvas.rawValue,
                handler: { call in await deleteCanvasBoard(call) }),
            ToolDefinition(name: "list_apple_note_folders", spec: appsToolSpecs[14], category: ToolCategory.notes.rawValue,
                handler: { _ in await listAppleNoteFolders() }),
            ToolDefinition(name: "list_apple_notes", spec: appsToolSpecs[15], category: ToolCategory.notes.rawValue,
                handler: { call in await listAppleNotes(call) }),
            ToolDefinition(name: "read_apple_note", spec: appsToolSpecs[16], category: ToolCategory.notes.rawValue,
                handler: { call in await readAppleNote(call) }),
            ToolDefinition(name: "list_calendar_events", spec: appsToolSpecs[17], category: ToolCategory.system.rawValue,
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
            rawSpec("list_canvas_boards",
                "List Canvas sketch boards (name, created/modified dates). The drawing content "
                + "itself isn't readable — this only exposes board metadata.",
                properties: [:], required: []),
            rawSpec("create_canvas_board",
                "Create a new empty Canvas sketch board.",
                properties: [
                    "name": ["type": "string", "description": "Board name."],
                ], required: ["name"]),
            rawSpec("delete_canvas_board",
                "Delete a Canvas sketch board by name (or id).",
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
        ]
    }

    // MARK: - Shared service instances (mirrors `sharedContactsService` in MaestroTools+System.swift)

    @MainActor
    private static let sharedAppleNotesService = AppleNotesService()

    @MainActor
    private static let sharedKanbanStore = KanbanStore()

    @MainActor
    private static let sharedCanvasStore = CanvasStore()

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
              var path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              let content = args.content
        else { return errorJSON("write_note requires 'path' and 'content'") }
        if !path.lowercased().hasSuffix(".md") { path += ".md" }
        let vaultURL = await resolveNotesVaultURL()
        let fileURL = vaultURL.appendingPathComponent(path)
        do {
            try await notesService().writeFile(at: fileURL, content: content)
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
              let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
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
              let boardKey = args.board?.trimmingCharacters(in: .whitespacesAndNewlines), !boardKey.isEmpty,
              let columnKey = args.column?.trimmingCharacters(in: .whitespacesAndNewlines), !columnKey.isEmpty,
              let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
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
                description: args.description ?? "",
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
            if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                updated.title = title
            }
            if let description = args.description { updated.description = description }
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

    private struct CanvasBoardArgs: Codable { let name: String? }

    @MainActor
    private static func findCanvasBoard(_ key: String) -> CanvasBoard? {
        if let byID = sharedCanvasStore.boards.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) {
            return byID
        }
        if let exact = sharedCanvasStore.boards.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return exact
        }
        return sharedCanvasStore.boards.first { $0.name.localizedCaseInsensitiveContains(key) }
    }

    // MARK: - Canvas implementations

    static func listCanvasBoards() async -> String {
        await MainActor.run {
            sharedCanvasStore.loadBoards()
            let boards = sharedCanvasStore.boards
            guard !boards.isEmpty else { return "No Canvas boards yet. Use create_canvas_board to make one." }
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

    static func createCanvasBoard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CanvasBoardArgs.self),
              let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return errorJSON("create_canvas_board requires 'name'") }
        return await MainActor.run {
            let board = sharedCanvasStore.createBoard(name: name)
            return jsonString(["status": "created", "id": board.id.uuidString, "name": board.name])
        }
    }

    static func deleteCanvasBoard(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CanvasBoardArgs.self),
              let key = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return errorJSON("delete_canvas_board requires 'name'") }
        return await MainActor.run {
            guard let board = findCanvasBoard(key) else {
                return errorJSON("no canvas board matching \"\(key)\".")
            }
            sharedCanvasStore.delete(board.id)
            return jsonString(["status": "deleted", "name": board.name])
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
