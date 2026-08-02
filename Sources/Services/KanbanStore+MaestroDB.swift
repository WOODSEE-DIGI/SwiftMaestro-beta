import Foundation

// MARK: - KanbanStore + MaestroDB Bridge
//
// Write-through bridge: a MaestroDB table + single-select field registers as
// a linked kanban board. Projections render via the EXISTING KanbanBoardView;
// every mutation routes here instead of boards.json and writes straight into
// the MaestroDB database. One kanban implementation, two data backends.

/// Link descriptor: which MaestroDB table + fields back a kanban board.
struct MaestroBoardLink: Codable, Identifiable, Sendable {
    var id: UUID { boardID }
    let boardID: UUID
    let tableID: String
    /// Single-select field that defines the columns.
    let groupFieldID: String
    /// Field-role mapping (auto-derived at link time, editable later).
    let titleFieldID: String
    let descriptionFieldID: String?
    let dueFieldID: String?
    let tagsFieldID: String?
    let priorityFieldID: String?
}

extension KanbanStore {

    private static let linksURI = MaestroURI(kind: .knowledge, path: ["kanban", "maestro-links.json"])

    // MARK: - Link persistence

    func loadMaestroLinks() -> [MaestroBoardLink] {
        do {
            if let json = try SimpleMemoryStore().load(Self.linksURI),
               let data = json.data(using: .utf8) {
                let decoder = JSONDecoder()
                return try decoder.decode([MaestroBoardLink].self, from: data)
            }
        } catch {
            NSLog("[KANBAN] maestro links load failed: \(error)")
        }
        return []
    }

    func persistMaestroLinks(_ links: [MaestroBoardLink]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(links)
            guard let json = String(data: data, encoding: .utf8) else { return }
            try SimpleMemoryStore().save(json, at: Self.linksURI)
        } catch {
            NSLog("[KANBAN] maestro links persist failed: \(error)")
        }
    }

    // MARK: - Link management

    /// Create a link for a table, auto-mapping field roles:
    /// first text-ish field → title, first longText → description,
    /// first date → due, first multiSelect → tags, first rating → priority.
    @discardableResult
    func linkMaestroTable(tableID: String, groupFieldID: String) throws -> KanbanBoard {
        let database = MaestroDBDatabase.shared
        let fields = try database.fields(tableID: tableID)
        guard let groupField = fields.first(where: { $0.id == groupFieldID }),
              groupField.type == .select else {
            throw MaestroBridgeError.groupFieldNotSelect
        }
        let link = MaestroBoardLink(
            boardID: UUID(),
            tableID: tableID,
            groupFieldID: groupFieldID,
            titleFieldID: fields.first(where: { [.text, .url, .email, .phone].contains($0.type) })?.id
                ?? groupFieldID,
            descriptionFieldID: fields.first(where: { $0.type == .longText })?.id,
            dueFieldID: fields.first(where: { $0.type == .date })?.id,
            tagsFieldID: fields.first(where: { $0.type == .multiSelect })?.id,
            priorityFieldID: fields.first(where: { $0.type == .rating })?.id)
        var links = loadMaestroLinks()
        links.append(link)
        persistMaestroLinks(links)
        guard let board = maestroProject(link) else { throw MaestroBridgeError.projectionFailed }
        rebuildBoards()
        return board
    }

    /// Remove the link. Never deletes the table — the data stays in MaestroDB.
    func unlinkMaestroBoard(_ boardID: UUID) {
        var links = loadMaestroLinks()
        links.removeAll { $0.boardID == boardID }
        persistMaestroLinks(links)
        rebuildBoards()
    }

    func maestroLink(for boardID: UUID) -> MaestroBoardLink? {
        loadMaestroLinks().first { $0.boardID == boardID }
    }

    func maestroLink(forTable tableID: String) -> MaestroBoardLink? {
        loadMaestroLinks().first { $0.tableID == tableID }
    }

    // MARK: - Projection (DB → KanbanBoard)

    /// Project a linked MaestroDB table into the shared KanbanBoard model.
    /// Columns = select options + a "No value" column; cards = rows.
    func maestroProject(_ link: MaestroBoardLink) -> KanbanBoard? {
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try database.table(link.tableID) else { return nil }
            let fields = try database.fields(tableID: link.tableID)
            guard let groupField = fields.first(where: { $0.id == link.groupFieldID }) else { return nil }
            let rows = try database.rows(tableID: link.tableID)

            var columns: [KanbanColumn] = groupField.options.map { option in
                KanbanColumn(
                    title: option,
                    cards: rows
                        .filter { $0.value(for: link.groupFieldID) == option }
                        .map { Self.card(from: $0, link: link) })
            }
            let ungrouped = rows.filter { $0.value(for: link.groupFieldID).isEmpty }
            if !ungrouped.isEmpty {
                columns.append(KanbanColumn(title: "No value", cards: ungrouped.map { Self.card(from: $0, link: link) }, color: .gray))
            }
            return KanbanBoard(id: link.boardID, name: table.name, columns: columns)
        } catch {
            NSLog("[KANBAN] maestro projection failed: \(error)")
            return nil
        }
    }

    static func card(from row: DBRow, link: MaestroBoardLink) -> KanbanCard {
        let title = row.value(for: link.titleFieldID)
        let description = link.descriptionFieldID.map { row.value(for: $0) } ?? ""
        let due = link.dueFieldID.flatMap { row.date(for: $0) }
        let tags = link.tagsFieldID.map { row.multiValues(for: $0) } ?? []
        let rating = link.priorityFieldID.map { row.rating(for: $0) } ?? 0
        return KanbanCard(
            id: UUID(uuidString: row.id) ?? UUID(),
            title: title.isEmpty ? "Untitled" : title,
            description: description,
            priority: priority(from: rating),
            dueDate: due,
            tags: tags,
            created: row.createdAt,
            modified: row.updatedAt)
    }

    static func priority(from rating: Int) -> KanbanPriority {
        switch rating {
        case 1, 2: return .low
        case 3: return .medium
        case 4: return .high
        case 5: return .urgent
        default: return .none
        }
    }

    static func rating(from priority: KanbanPriority) -> String {
        switch priority {
        case .low: return "2"
        case .medium: return "3"
        case .high: return "4"
        case .urgent: return "5"
        case .none: return ""
        }
    }

    enum MaestroBridgeError: Error {
        case groupFieldNotSelect
        case projectionFailed
    }
}
