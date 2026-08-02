import Foundation
import GRDB

// MARK: - MaestroDB Database (rows + cells)

extension MaestroDBDatabase {

    // MARK: - Read rows

    /// All rows for a table with their cell values hydrated.
    func rows(tableID: String) throws -> [DBRow] {
        try dbQueue.read { db in
            let rowRecords = try Row.fetchAll(
                db,
                sql: "SELECT * FROM db_row WHERE table_id = ? ORDER BY position",
                arguments: [tableID])
            var cellMap: [String: [String: String]] = [:]
            let cells = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.row_id, c.field_id, c.value FROM db_cell c
                    JOIN db_row r ON r.id = c.row_id
                    WHERE r.table_id = ?
                    """,
                arguments: [tableID])
            for cell in cells {
                let rowID: String = cell["row_id"]
                cellMap[rowID, default: [:]][cell["field_id"]] = cell["value"]
            }
            return rowRecords.map { record in
                let id: String = record["id"]
                return DBRow(
                    id: id,
                    tableID: tableID,
                    position: record["position"],
                    createdAt: Date(timeIntervalSince1970: record["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: record["updated_at"]),
                    values: cellMap[id] ?? [:])
            }
        }
    }

    func row(_ rowID: String) throws -> DBRow? {
        try dbQueue.read { db in
            guard let record = try Row.fetchOne(
                db, sql: "SELECT * FROM db_row WHERE id = ?", arguments: [rowID]) else { return nil }
            let cells = try Row.fetchAll(
                db, sql: "SELECT field_id, value FROM db_cell WHERE row_id = ?",
                arguments: [rowID])
            var values: [String: String] = [:]
            for cell in cells { values[cell["field_id"]] = cell["value"] }
            return DBRow(
                id: rowID,
                tableID: record["table_id"],
                position: record["position"],
                createdAt: Date(timeIntervalSince1970: record["created_at"]),
                updatedAt: Date(timeIntervalSince1970: record["updated_at"]),
                values: values)
        }
    }

    // MARK: - Create / update / delete

    @discardableResult
    func addRow(tableID: String, values: [String: String] = [:]) throws -> DBRow {
        let now = Date()
        let row = DBRow(
            id: UUID().uuidString, tableID: tableID,
            position: try nextPosition("db_row", "table_id", tableID),
            createdAt: now, updatedAt: now, values: values)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO db_row (id, table_id, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [row.id, tableID, row.position, now.timeIntervalSince1970, now.timeIntervalSince1970])
            for (fieldID, value) in values where !value.isEmpty {
                try db.execute(
                    sql: "INSERT INTO db_cell (row_id, field_id, value) VALUES (?, ?, ?)",
                    arguments: [row.id, fieldID, value])
            }
        }
        Self.postDidChange()
        return row
    }

    /// Set a single cell value (empty string deletes the cell row).
    func setCell(rowID: String, fieldID: String, value: String) throws {
        try dbQueue.write { db in
            if value.isEmpty {
                try db.execute(
                    sql: "DELETE FROM db_cell WHERE row_id = ? AND field_id = ?",
                    arguments: [rowID, fieldID])
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO db_cell (row_id, field_id, value) VALUES (?, ?, ?)
                        ON CONFLICT(row_id, field_id) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [rowID, fieldID, value])
            }
            try db.execute(
                sql: "UPDATE db_row SET updated_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, rowID])
        }
        Self.postDidChange()
    }

    func deleteRow(_ rowID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM db_row WHERE id = ?", arguments: [rowID])
        }
        Self.postDidChange()
    }

    /// Persist a full-row order after a drag/reorder or kanban card move.
    func setRowPositions(_ orderedIDs: [String]) throws {
        try dbQueue.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE db_row SET position = ? WHERE id = ?",
                    arguments: [index, id])
            }
        }
        Self.postDidChange()
    }

    // MARK: - Query helpers (agent tools + kanban bridge)

    /// Lightweight text search across all cell values in a table.
    func searchRows(tableID: String, query: String) throws -> [DBRow] {
        guard !query.isEmpty else { return try rows(tableID: tableID) }
        let lowered = query.lowercased()
        return try rows(tableID: tableID).filter { row in
            row.values.values.contains { $0.lowercased().contains(lowered) }
        }
    }

    /// All rows sharing one select value — the kanban bridge's column fill.
    func rows(tableID: String, whereSelect fieldID: String, equals value: String) throws -> [DBRow] {
        try rows(tableID: tableID).filter { $0.value(for: fieldID) == value }
    }
}
