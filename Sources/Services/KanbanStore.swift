import Foundation

// MARK: - Kanban store

/// Loads and saves kanban boards to the shared memory store
/// (`~/.ai-context/memory/knowledge/kanban/boards.json`) so boards survive app
/// reinstalls and are readable by other AI tools.
@Observable
@MainActor
final class KanbanStore {

    /// Merged display array: regular JSON boards + MaestroDB-linked
    /// projections (see KanbanStore+MaestroDB.swift). Read-only to views.
    private(set) var boards: [KanbanBoard] = []
    private(set) var error: String?

    /// JSON-persisted boards only — never includes MaestroDB projections.
    private var regularBoards: [KanbanBoard] = []

    private let memoryStore = SimpleMemoryStore()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let boardsURI = MaestroURI(kind: .knowledge, path: ["kanban", "boards.json"])

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        loadBoards()
    }

    // MARK: - Persistence

    func loadBoards() {
        do {
            if let json = try memoryStore.load(boardsURI),
               let data = json.data(using: .utf8) {
                regularBoards = (try? decoder.decode([KanbanBoard].self, from: data)) ?? []
            } else {
                regularBoards = []
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            NSLog("[KANBAN] load failed: \(error)")
        }
        rebuildBoards()
    }

    private func persist() {
        do {
            let data = try encoder.encode(regularBoards)
            guard let json = String(data: data, encoding: .utf8) else { return }
            try memoryStore.save(json, at: boardsURI)
            error = nil
        } catch {
            self.error = error.localizedDescription
            NSLog("[KANBAN] persist failed: \(error)")
        }
    }

    /// Rebuild the merged display array: regular boards followed by fresh
    /// MaestroDB projections. Called after every mutation (regular or bridge).
    func rebuildBoards() {
        let projections = loadMaestroLinks().compactMap { maestroProject($0) }
        boards = regularBoards + projections
    }

    // MARK: - Board CRUD

    @discardableResult
    func createBoard(name: String) -> KanbanBoard {
        let now = Date()
        let board = KanbanBoard(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            columns: Self.defaultColumns(),
            created: now,
            modified: now
        )
        regularBoards.insert(board, at: 0)
        persist()
        rebuildBoards()
        return board
    }

    func saveBoard(_ board: KanbanBoard) {
        // MaestroDB-linked boards are projections — nothing to persist here.
        guard maestroLink(for: board.id) == nil else { return }
        guard let index = regularBoards.firstIndex(where: { $0.id == board.id }) else {
            var updated = board
            updated.modified = Date()
            regularBoards.insert(updated, at: 0)
            persist()
            rebuildBoards()
            return
        }
        var updated = board
        updated.modified = Date()
        regularBoards[index] = updated
        regularBoards.sort { $0.modified > $1.modified }
        persist()
        rebuildBoards()
    }

    func delete(_ id: UUID) {
        // Deleting a linked board unlinks it — the table data stays in MaestroDB.
        if maestroLink(for: id) != nil {
            unlinkMaestroBoard(id)
            return
        }
        regularBoards.removeAll { $0.id == id }
        persist()
        rebuildBoards()
    }

    @discardableResult
    func duplicate(_ board: KanbanBoard) -> KanbanBoard {
        let now = Date()
        var copy = board
        copy.id = UUID()
        copy.name = "\(board.name) Copy"
        copy.created = now
        copy.modified = now
        copy.columns = board.columns.map { column in
            var c = column
            c.id = UUID()
            c.cards = column.cards.map { card in
                var copyCard = card
                copyCard.id = UUID()
                copyCard.created = now
                copyCard.modified = now
                return copyCard
            }
            return c
        }
        regularBoards.insert(copy, at: 0)
        persist()
        rebuildBoards()
        return copy
    }

    // MARK: - Column helpers

    func addColumn(to boardId: UUID, title: String, color: KanbanColumnColor? = nil) {
        if let link = maestroLink(for: boardId) {
            maestroAddColumn(title: title.trimmingCharacters(in: .whitespacesAndNewlines), link: link)
            return
        }
        guard let index = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        var board = regularBoards[index]
        board.columns.append(KanbanColumn(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color
        ))
        saveBoard(board)
    }

    func updateColumn(_ column: KanbanColumn, in boardId: UUID) {
        if let link = maestroLink(for: boardId) {
            let oldTitle = boards.first(where: { $0.id == boardId })?
                .columns.first(where: { $0.id == column.id })?.title ?? column.title
            if oldTitle != column.title {
                maestroRenameColumn(from: oldTitle, to: column.title, link: link)
            }
            return
        }
        guard let boardIndex = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        var board = regularBoards[boardIndex]
        guard let columnIndex = board.columns.firstIndex(where: { $0.id == column.id }) else { return }
        board.columns[columnIndex] = column
        saveBoard(board)
    }

    func deleteColumn(_ columnId: UUID, from boardId: UUID) {
        if let link = maestroLink(for: boardId) {
            guard let title = boards.first(where: { $0.id == boardId })?
                .columns.first(where: { $0.id == columnId })?.title else { return }
            maestroDeleteColumn(title: title, link: link)
            return
        }
        guard let boardIndex = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        var board = regularBoards[boardIndex]
        board.columns.removeAll { $0.id == columnId }
        saveBoard(board)
    }

    // MARK: - Card helpers

    func addCard(_ card: KanbanCard, toColumn columnId: UUID, in boardId: UUID) {
        if let link = maestroLink(for: boardId) {
            let title = boards.first(where: { $0.id == boardId })?
                .columns.first(where: { $0.id == columnId })?.title ?? ""
            maestroAddCard(card, columnTitle: title, link: link)
            return
        }
        guard let boardIndex = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        var board = regularBoards[boardIndex]
        guard let columnIndex = board.columns.firstIndex(where: { $0.id == columnId }) else { return }
        board.columns[columnIndex].cards.append(card)
        saveBoard(board)
    }

    func updateCard(_ card: KanbanCard, in boardId: UUID) {
        if let link = maestroLink(for: boardId) {
            maestroUpdateCard(card, link: link)
            return
        }
        guard let boardIndex = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        var board = regularBoards[boardIndex]
        for columnIndex in board.columns.indices {
            if let cardIndex = board.columns[columnIndex].cards.firstIndex(where: { $0.id == card.id }) {
                var updated = card
                updated.modified = Date()
                board.columns[columnIndex].cards[cardIndex] = updated
                saveBoard(board)
                return
            }
        }
    }

    func deleteCard(_ cardId: UUID, from boardId: UUID) {
        if let link = maestroLink(for: boardId) {
            maestroDeleteCard(cardId, link: link)
            return
        }
        guard let boardIndex = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        var board = regularBoards[boardIndex]
        for columnIndex in board.columns.indices {
            let before = board.columns[columnIndex].cards.count
            board.columns[columnIndex].cards.removeAll { $0.id == cardId }
            if board.columns[columnIndex].cards.count != before {
                saveBoard(board)
                return
            }
        }
    }

    func moveCard(
        _ cardId: UUID,
        fromColumn sourceColumnId: UUID,
        toColumn targetColumnId: UUID,
        toIndex targetIndex: Int,
        in boardId: UUID
    ) {
        if let link = maestroLink(for: boardId) {
            guard let title = boards.first(where: { $0.id == boardId })?
                .columns.first(where: { $0.id == targetColumnId })?.title else { return }
            maestroMoveCard(cardId, toColumnTitle: title, link: link)
            return
        }
        guard let boardIndex = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        var board = regularBoards[boardIndex]

        guard let sourceColumnIndex = board.columns.firstIndex(where: { $0.id == sourceColumnId }),
              let cardIndex = board.columns[sourceColumnIndex].cards.firstIndex(where: { $0.id == cardId })
        else { return }

        var card = board.columns[sourceColumnIndex].cards.remove(at: cardIndex)
        card.modified = Date()

        guard let targetColumnIndex = board.columns.firstIndex(where: { $0.id == targetColumnId }) else { return }
        let insertIndex = max(0, min(targetIndex, board.columns[targetColumnIndex].cards.count))
        board.columns[targetColumnIndex].cards.insert(card, at: insertIndex)

        saveBoard(board)
    }

    /// Move a card to a target column, discovering its current column automatically.
    func moveCard(
        _ cardId: UUID,
        toColumn targetColumnId: UUID,
        toIndex targetIndex: Int,
        in boardId: UUID
    ) {
        if let link = maestroLink(for: boardId) {
            guard let title = boards.first(where: { $0.id == boardId })?
                .columns.first(where: { $0.id == targetColumnId })?.title else { return }
            maestroMoveCard(cardId, toColumnTitle: title, link: link)
            return
        }
        guard let boardIndex = regularBoards.firstIndex(where: { $0.id == boardId }) else { return }
        let board = regularBoards[boardIndex]

        guard let sourceColumnId = board.columns.first(where: { $0.cards.contains(where: { $0.id == cardId }) })?.id
        else { return }

        moveCard(cardId, fromColumn: sourceColumnId, toColumn: targetColumnId, toIndex: targetIndex, in: boardId)
    }

    // MARK: - Defaults

    private nonisolated static func defaultColumns() -> [KanbanColumn] {
        [
            KanbanColumn(title: "Backlog", color: .gray),
            KanbanColumn(title: "To Do", color: .blue),
            KanbanColumn(title: "In Progress", color: .yellow),
            KanbanColumn(title: "Done", color: .green)
        ]
    }
}
