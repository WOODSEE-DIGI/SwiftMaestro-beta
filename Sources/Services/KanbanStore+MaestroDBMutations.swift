import Foundation

// MARK: - KanbanStore + MaestroDB Bridge (write-back mutations)
//
// Every kanban mutation on a linked board lands here (routed from
// KanbanStore's mutation methods) and writes straight into MaestroDB.

extension KanbanStore {

    // MARK: Cards

    func maestroMoveCard(_ cardID: UUID, toColumnTitle title: String, link: MaestroBoardLink) {
        do {
            try MaestroDBDatabase.shared.setCell(
                rowID: cardID.uuidString, fieldID: link.groupFieldID,
                value: title == "No value" ? "" : title)
            rebuildBoards()
        } catch { NSLog("[KANBAN] maestro moveCard failed: \(error)") }
    }

    func maestroAddCard(_ card: KanbanCard, columnTitle: String, link: MaestroBoardLink) {
        do {
            var values: [String: String] = [:]
            values[link.titleFieldID] = card.title
            if !columnTitle.isEmpty, columnTitle != "No value" {
                values[link.groupFieldID] = columnTitle
            }
            if let field = link.descriptionFieldID, !card.description.isEmpty {
                values[field] = card.description
            }
            if let field = link.dueFieldID, let due = card.dueDate {
                values[field] = DBRow.store(due)
            }
            if let field = link.tagsFieldID, !card.tags.isEmpty {
                values[field] = DBRow.store(multi: card.tags)
            }
            if let field = link.priorityFieldID {
                let rating = Self.rating(from: card.priority)
                if !rating.isEmpty { values[field] = rating }
            }
            _ = try MaestroDBDatabase.shared.addRow(tableID: link.tableID, values: values)
            rebuildBoards()
        } catch { NSLog("[KANBAN] maestro addCard failed: \(error)") }
    }

    func maestroUpdateCard(_ card: KanbanCard, link: MaestroBoardLink) {
        do {
            let database = MaestroDBDatabase.shared
            let rowID = card.id.uuidString
            try database.setCell(rowID: rowID, fieldID: link.titleFieldID, value: card.title)
            if let field = link.descriptionFieldID {
                try database.setCell(rowID: rowID, fieldID: field, value: card.description)
            }
            if let field = link.dueFieldID {
                try database.setCell(
                    rowID: rowID, fieldID: field,
                    value: card.dueDate.map { DBRow.store($0) } ?? "")
            }
            if let field = link.tagsFieldID {
                try database.setCell(
                    rowID: rowID, fieldID: field,
                    value: card.tags.isEmpty ? "" : DBRow.store(multi: card.tags))
            }
            if let field = link.priorityFieldID {
                try database.setCell(
                    rowID: rowID, fieldID: field,
                    value: Self.rating(from: card.priority))
            }
            rebuildBoards()
        } catch { NSLog("[KANBAN] maestro updateCard failed: \(error)") }
    }

    func maestroDeleteCard(_ cardID: UUID, link: MaestroBoardLink) {
        do {
            try MaestroDBDatabase.shared.deleteRow(cardID.uuidString)
            rebuildBoards()
        } catch { NSLog("[KANBAN] maestro deleteCard failed: \(error)") }
    }

    // MARK: Columns (select options)

    func maestroAddColumn(title: String, link: MaestroBoardLink) {
        do {
            try MaestroDBDatabase.shared.addFieldOption(link.groupFieldID, option: title)
            rebuildBoards()
        } catch { NSLog("[KANBAN] maestro addColumn failed: \(error)") }
    }

    /// Rename a column = rename the option AND migrate every cell holding it.
    func maestroRenameColumn(from oldTitle: String, to newTitle: String, link: MaestroBoardLink) {
        do {
            let database = MaestroDBDatabase.shared
            guard var field = try database.field(link.groupFieldID) else { return }
            guard let index = field.options.firstIndex(of: oldTitle) else { return }
            field.options[index] = newTitle
            try database.updateField(field)
            let affected = try database.rows(tableID: link.tableID, whereSelect: link.groupFieldID, equals: oldTitle)
            for row in affected {
                try database.setCell(rowID: row.id, fieldID: link.groupFieldID, value: newTitle)
            }
            rebuildBoards()
        } catch { NSLog("[KANBAN] maestro renameColumn failed: \(error)") }
    }

    /// Delete a column = remove the option AND clear cells holding it.
    func maestroDeleteColumn(title: String, link: MaestroBoardLink) {
        do {
            let database = MaestroDBDatabase.shared
            guard var field = try database.field(link.groupFieldID) else { return }
            field.options.removeAll { $0 == title }
            try database.updateField(field)
            let affected = try database.rows(tableID: link.tableID, whereSelect: link.groupFieldID, equals: title)
            for row in affected {
                try database.setCell(rowID: row.id, fieldID: link.groupFieldID, value: "")
            }
            rebuildBoards()
        } catch { NSLog("[KANBAN] maestro deleteColumn failed: \(error)") }
    }

    /// Changing the group-by field: unlink and re-link with the new field.
    @discardableResult
    func relinkMaestroTable(tableID: String, newGroupFieldID: String) throws -> KanbanBoard {
        if let existing = maestroLink(forTable: tableID) {
            unlinkMaestroBoard(existing.boardID)
        }
        return try linkMaestroTable(tableID: tableID, groupFieldID: newGroupFieldID)
    }
}
