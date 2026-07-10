import Foundation
import MLXLMCommon
import GRDB

// MARK: - Native SQLite query tool
//
// In-process SQLite access that ENFORCES the same authorized-folders policy
// as file tools. Models can inspect schemas and run read-only queries without
// needing shell access. Write operations (INSERT/UPDATE/DELETE) require
// explicit opt-in via the `write` parameter.
extension MaestroTools {

    static let sqliteToolNames: Set<String> = ["execute_sqlite"]

    static var sqliteToolSpecs: [ToolSpec] {
        [
            rawSpec("execute_sqlite",
                "Query a SQLite database file. Returns table schemas and query results. "
                + "Use schema='true' to list all tables and their columns without running a query. "
                + "For read-only queries (SELECT, PRAGMA), just pass the SQL in 'query'. "
                + "For write operations (INSERT, UPDATE, DELETE, CREATE, DROP), you MUST set "
                + "write='true' to confirm. Results are returned as a markdown table.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the .db or .sqlite file."],
                    "query": ["type": "string", "description": "SQL query to execute (e.g. 'SELECT * FROM messages LIMIT 10')."],
                    "schema": ["type": "string", "description": "Set to 'true' to list all tables and columns instead of running a query."],
                    "limit": ["type": "integer", "description": "Maximum rows to return (default 100, max 1000)."],
                    "write": ["type": "string", "description": "Set to 'true' to allow write operations (INSERT/UPDATE/DELETE/CREATE/DROP)."],
                ],
                required: ["path"]),
        ]
    }

    private struct SQLiteArgs: Codable {
        let path: String?
        let query: String?
        let schema: String?
        let limit: Int?
        let write: String?
    }

    /// SQL keywords that modify data — blocked unless write=true.
    private static let writeKeywords: Set<String> = [
        "insert", "update", "delete", "drop", "alter", "create",
        "replace", "truncate", "attach", "detach",
    ]

    /// Check if a SQL statement contains write operations.
    private static func isWriteQuery(_ sql: String) -> Bool {
        let lowered = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var s = lowered
        while s.hasPrefix("--") || s.hasPrefix("/*") {
            if s.hasPrefix("--") {
                if let nl = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: nl)...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    return false
                }
            } else if s.hasPrefix("/*") {
                if let end = s.range(of: "*/") {
                    s = String(s[end.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    return false
                }
            }
        }
        for keyword in writeKeywords {
            if s.hasPrefix(keyword) {
                let rest = s.dropFirst(keyword.count)
                if rest.isEmpty || !(rest.first?.isLetter ?? true) {
                    return true
                }
            }
        }
        return false
    }

    static func executeSQLite(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SQLiteArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("execute_sqlite requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("execute_sqlite requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file at '\(actualPath)'.\(didYouMean(path: resolved, wantDirectory: false))")
        }

        // Verify it's a SQLite file by checking the header magic
        guard let fh = FileHandle(forReadingAtPath: actualPath) else {
            return errorJSON("could not open '\(actualPath)'")
        }
        let header = fh.readData(ofLength: 16)
        fh.closeFile()
        let magic = String(data: header, encoding: .ascii) ?? ""
        guard magic.hasPrefix("SQLite format 3") else {
            return errorJSON("'\(actualPath)' does not appear to be a SQLite database.")
        }

        let showSchema = args.schema?.lowercased() == "true"
        let maxRows = min(args.limit ?? 100, 1000)

        do {
            let allowWrite = args.write?.lowercased() == "true"
            var config = GRDB.Configuration()
            config.readonly = !allowWrite
            let db = try DatabaseQueue(path: actualPath, configuration: config)

            if showSchema {
                let result = try await db.read { db in
                    try renderSchema(db, path: actualPath)
                }
                return result
            }

            guard let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return errorJSON("pass 'query' (SQL to execute) or set 'schema'='true' to list tables.")
            }

            if isWriteQuery(query) && !allowWrite {
                return errorJSON(
                    "Write operation detected. To run INSERT/UPDATE/DELETE/CREATE/DROP, "
                    + "you MUST set write='true' to confirm.")
            }

            if allowWrite {
                let result = try await db.write { db -> String in
                    try executeQuery(db, query: query, maxRows: maxRows, path: actualPath)
                }
                return result
            } else {
                let result = try await db.read { db -> String in
                    try executeQuery(db, query: query, maxRows: maxRows, path: actualPath)
                }
                return result
            }
        } catch {
            return errorJSON("SQLite error: \(error.localizedDescription)")
        }
    }

    private static func renderSchema(_ db: Database, path: String) throws -> String {
        let tableNames = try String.fetchAll(db,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")

        guard !tableNames.isEmpty else {
            return "Database at \(path) has no tables."
        }

        let dbFileName = URL(fileURLWithPath: path).lastPathComponent
        var lines: [String] = ["**Schema for \(dbFileName):**\n"]
        for table in tableNames {
            let pragma = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
            var colLines: [String] = []
            for col in pragma {
                let name = col["name"] ?? "?"
                let type = col["type"] ?? "?"
                let pk = (col["pk"] as? Int64 ?? 0) != 0 ? " [PK]" : ""
                let notNull = (col["notnull"] as? Int64 ?? 0) != 0 ? " NOT NULL" : ""
                colLines.append("  - \(name) \(type)\(pk)\(notNull)")
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            lines.append("### \(table) (~\(count) rows)")
            lines.append(colLines.joined(separator: "\n"))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func executeQuery(
        _ db: Database, query: String, maxRows: Int, path: String
    ) throws -> String {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isSelect = lowered.hasPrefix("select") || lowered.hasPrefix("pragma")
            || lowered.hasPrefix("explain") || lowered.hasPrefix("with")

        if isSelect {
            let rows = try Row.fetchAll(db, sql: query)
            guard let first = rows.first else {
                return "Query returned 0 rows."
            }

            let columns = Array(first.columnNames)
            let dbFileName = URL(fileURLWithPath: path).lastPathComponent
            let header = "| " + columns.joined(separator: " | ") + " |"
            let separator = "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"

            var dataLines: [String] = []
            for row in rows.prefix(maxRows) {
                // Build a dictionary from the row for safe value access
                var dict: [String: Any] = [:]
                for (key, value) in row {
                    dict[key] = value
                }
                let values = columns.map { col -> String in
                    guard let val = dict[col] else { return "NULL" }
                    if let s = val as? String {
                        return s.replacingOccurrences(of: "|", with: "\\|")
                            .replacingOccurrences(of: "\n", with: " ")
                    }
                    if let i = val as? Int64 { return "\(i)" }
                    if let d = val as? Double { return "\(d)" }
                    if let b = val as? Data { return "[blob \(b.count) bytes]" }
                    return "\(val)"
                }
                dataLines.append("| " + values.joined(separator: " | ") + " |")
            }

            var result = "\(rows.count) row(s) from \(dbFileName):\n\n"
            result += header + "\n" + separator + "\n" + dataLines.joined(separator: "\n")
            if rows.count > maxRows {
                result += "\n\n... (\(rows.count - maxRows) more rows, limit \(maxRows))"
            }
            return result
        } else {
            let changes = try db.execute(sql: query)
            return jsonString([
                "status": "executed",
                "changes": changes,
            ])
        }
    }
}
