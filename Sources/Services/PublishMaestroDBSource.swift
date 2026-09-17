import Foundation
import GRDB

/// Discovers publishable drafts inside MaestroDB rows whose cell values contain
/// any of the monitored Publish tags.
enum PublishMaestroDBSource {

    static func scan(monitoredTags: Set<String>) async -> [PublishDraft] {
        guard !monitoredTags.isEmpty else { return [] }

        let database = MaestroDBDatabase.shared
        let tags = Array(monitoredTags)

        do {
            return try await Task.detached(priority: .userInitiated) {
                try database.dbQueue.read { db in
                    let conditions = tags.map { _ in "LOWER(c.value) LIKE ?" }.joined(separator: " OR ")
                    let patterns = tags.map { "%\($0.lowercased())%" }

                    let sql = """
                        SELECT
                            c.row_id,
                            r.table_id,
                            r.updated_at,
                            t.name AS table_name,
                            f.name AS field_name,
                            c.value
                        FROM db_cell c
                        JOIN db_row r ON r.id = c.row_id
                        JOIN db_table t ON t.id = r.table_id
                        JOIN db_field f ON f.id = c.field_id
                        WHERE \(conditions)
                        """

                    let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(patterns))

                    var groups: [String: RowGroup] = [:]
                    for row in rows {
                        let rowID: String = row["row_id"]
                        let tableID: String = row["table_id"]
                        let tableName: String = row["table_name"]
                        let updatedAt = Date(timeIntervalSince1970: row["updated_at"])
                        let fieldName: String = row["field_name"]
                        let value: String = row["value"]

                        if groups[rowID] == nil {
                            groups[rowID] = RowGroup(
                                tableID: tableID,
                                tableName: tableName,
                                updatedAt: updatedAt,
                                cells: []
                            )
                        }
                        groups[rowID]?.cells.append((fieldName, value))
                    }

                    return groups.map { rowID, group in
                        let title = Self.title(for: group)
                        let bodyMarkdown = Self.markdown(for: group)
                        let summary = Self.summary(for: group)
                        let matchedTags = tags.filter { tag in
                            group.cells.contains { $0.value.lowercased().contains(tag) }
                        }

                        return PublishDraft(
                            sourceKind: .maestroDB,
                            sourcePath: "maestrodb://row/\(rowID)",
                            title: String(title.prefix(120)),
                            summary: String(summary.prefix(240)),
                            bodyMarkdown: bodyMarkdown,
                            bodyHTML: PublishMarkdownToHTML.convert(bodyMarkdown),
                            tags: matchedTags,
                            modifiedAt: group.updatedAt
                        )
                    }
                }
            }.value
        } catch {
            NSLog("[PUBLISH] MaestroDB scan failed: \(error)")
            return []
        }
    }

    // MARK: - Helpers

    private struct RowGroup {
        let tableID: String
        let tableName: String
        let updatedAt: Date
        var cells: [(field: String, value: String)]
    }

    private static let titleFieldNames: Set<String> = ["title", "name", "heading", "subject", "topic"]

    private static func title(for group: RowGroup) -> String {
        if let titleCell = group.cells.first(where: { titleFieldNames.contains($0.field.lowercased()) }) {
            let trimmed = titleCell.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.components(separatedBy: .newlines).first ?? trimmed
        }
        if let first = group.cells.first {
            let trimmed = first.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.components(separatedBy: .newlines).first ?? "Row in \(group.tableName)"
        }
        return "Row in \(group.tableName)"
    }

    private static func summary(for group: RowGroup) -> String {
        let combined = group.cells.map(\.value).joined(separator: " ")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdown(for group: RowGroup) -> String {
        group.cells.map { cell in
            let field = cell.field.trimmingCharacters(in: .whitespaces)
            let value = cell.value.trimmingCharacters(in: .whitespaces)
            return "### \(field)\n\(value)"
        }.joined(separator: "\n\n")
    }
}
