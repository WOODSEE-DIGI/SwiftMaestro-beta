import Foundation

// MARK: - MaestroDB Relations
//
// Shared helpers for .relation fields (value = linked row id, config:
// ["table": targetTableID]). One title-derivation and one resolution path
// used by the grid cell editor, the agent db_* tools, and CSV import/export
// so a link means the same thing on every surface.

enum MaestroDBRelations {

    /// Everything a surface needs to display/resolve one relation field:
    /// the target table's fields and rows, plus a rowID→title lookup.
    struct Context: Sendable {
        let tableID: String
        let fields: [DBField]
        let rows: [DBRow]
        let titles: [String: String]   // rowID → display title

        func title(for rowID: String) -> String? { titles[rowID] }
    }

    // MARK: - Title derivation

    /// The short display title for a row: first text-ish field's value,
    /// else "Row N". Single source of truth — was MaestroDBViewModel's.
    static func title(for row: DBRow, fields: [DBField]) -> String {
        if let titleField = fields.first(where: { [.text, .url, .email, .phone].contains($0.type) }) {
            let value = row.value(for: titleField.id)
            if !value.isEmpty { return value }
        }
        return "Row \(row.position + 1)"
    }

    // MARK: - Context loading

    /// Load the resolution context for a relation field. Returns nil when
    /// the field isn't a relation or its target table is gone (deleted
    /// tables leave dangling configs — callers fall back to raw ids).
    static func context(for field: DBField, database: MaestroDBDatabase) -> Context? {
        guard field.type == .relation,
              let targetTableID = field.config["table"],
              !targetTableID.isEmpty,
              (try? database.table(targetTableID)) != nil else { return nil }
        guard let fields = try? database.fields(tableID: targetTableID),
              let rows = try? database.rows(tableID: targetTableID) else { return nil }
        var titles: [String: String] = [:]
        for row in rows { titles[row.id] = title(for: row, fields: fields) }
        return Context(tableID: targetTableID, fields: fields, rows: rows, titles: titles)
    }

    /// Contexts for every relation field in a table, keyed by FIELD id.
    static func contexts(forFields fields: [DBField], database: MaestroDBDatabase) -> [String: Context] {
        var result: [String: Context] = [:]
        for field in fields where field.type == .relation {
            if let ctx = context(for: field, database: database) {
                result[field.id] = ctx
            }
        }
        return result
    }

    // MARK: - Resolution (raw input → row id)

    /// Resolve a user/agent/CSV-supplied value to a target row id:
    /// exact row id first, then case-insensitive title match (first wins).
    /// Empty input resolves to "" (clears the link). Nil = no match.
    static func resolveRowID(
        _ raw: String, field: DBField, database: MaestroDBDatabase
    ) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let ctx = context(for: field, database: database) else { return nil }
        // Exact row id?
        if ctx.rows.contains(where: { $0.id == trimmed }) { return trimmed }
        // Title match (case-insensitive, first wins).
        if let match = ctx.rows.first(where: {
            (ctx.titles[$0.id] ?? "").caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return match.id
        }
        return nil
    }
}
