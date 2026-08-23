import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - MaestroDB tools (in-app dynamic-schema database)
//
// Agent-first access to the same MaestroDBDatabase the MaestroDB panel uses.
// Bases and tables resolve by NAME or id (name is what the user sees; the id
// is what list tools return). Row values are keyed by field NAME and coerced
// through MaestroDBCoercion — the same canonical path as CSV import — so
// "4", 4 and true all mean what the field type says they mean.
extension MaestroTools {

    static func registerDatabaseTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "db_list_bases", spec: databaseToolSpecs[0],
                category: ToolCategory.database.rawValue,
                handler: { _ in await dbListBases() }),
            ToolDefinition(
                name: "db_create_base", spec: databaseToolSpecs[1],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbCreateBase(call) }),
            ToolDefinition(
                name: "db_list_tables", spec: databaseToolSpecs[2],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbListTables(call) }),
            ToolDefinition(
                name: "db_create_table", spec: databaseToolSpecs[3],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbCreateTable(call) }),
            ToolDefinition(
                name: "db_table_schema", spec: databaseToolSpecs[4],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbTableSchema(call) }),
            ToolDefinition(
                name: "db_add_field", spec: databaseToolSpecs[5],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbAddField(call) }),
            ToolDefinition(
                name: "db_list_rows", spec: databaseToolSpecs[6],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbListRows(call) }),
            ToolDefinition(
                name: "db_add_row", spec: databaseToolSpecs[7],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbAddRow(call) }),
            ToolDefinition(
                name: "db_update_row", spec: databaseToolSpecs[8],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbUpdateRow(call) }),
            ToolDefinition(
                name: "db_delete_row", spec: databaseToolSpecs[9],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbDeleteRow(call) }),
            ToolDefinition(
                name: "db_import_csv", spec: databaseToolSpecs[10],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbImportCSV(call) }),
            ToolDefinition(
                name: "db_export_csv", spec: databaseToolSpecs[11],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbExportCSV(call) }),
            ToolDefinition(
                name: "db_delete_table", spec: databaseToolSpecs[12],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbDeleteTable(call) }),
            ToolDefinition(
                name: "db_delete_base", spec: databaseToolSpecs[13],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbDeleteBase(call) }),
            ToolDefinition(
                name: "db_add_rows", spec: databaseToolSpecs[14],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbAddRows(call) }),
            ToolDefinition(
                name: "db_delete_field", spec: databaseToolSpecs[15],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbDeleteField(call) }),
            ToolDefinition(
                name: "db_upsert_rows", spec: databaseToolSpecs[16],
                category: ToolCategory.database.rawValue,
                handler: { call in await dbUpsertRows(call) }),
            ToolDefinition(
                name: "investigation_sync", spec: databaseToolSpecs[17],
                category: ToolCategory.database.rawValue,
                handler: { call in await investigationSync(call) }),
        ])
    }

    private static let baseRefDesc = "Base NAME or id (names are case-insensitive)."
    private static let tableRefDesc = "Table NAME or id (case-insensitive; disambiguate with 'base' when names repeat across bases)."
    private static let valuesDesc =
        "JSON object string mapping FIELD NAME to value, e.g. "
        + "{\"Job\": \"Website redesign\", \"Priority\": 4, \"Delivered\": true}. "
        + "Values are coerced to each field's type (checkbox: true/false/yes/1; "
        + "date: ISO8601 or yyyy-MM-dd; rating: 1-5; multiSelect: JSON array or "
        + "semicolon-separated; relation: the linked row's TITLE or row id; "
        + "attachment: an absolute file path). Unknown field names are reported, not stored."

    static var databaseToolSpecs: [ToolSpec] {
        [
            rawSpec("db_list_bases",
                "List the user's MaestroDB bases (the in-app Airtable-style database) "
                + "with their tables. Start here to discover what databases exist.",
                properties: [:], required: []),
            rawSpec("db_create_base",
                "Create a new MaestroDB base. Returns the base id.",
                properties: [
                    "name": ["type": "string"],
                    "icon": ["type": "string", "description": "SF Symbol name (default 'tablecells')"],
                ],
                required: ["name"]),
            rawSpec("db_list_tables",
                "List tables in a base with field and row counts.",
                properties: ["base": ["type": "string", "description": baseRefDesc]],
                required: ["base"]),
            rawSpec("db_create_table",
                "Create a table in a base. Add fields next with db_add_field, or "
                + "import a spreadsheet directly with db_import_csv (create='true').",
                properties: [
                    "base": ["type": "string", "description": baseRefDesc],
                    "name": ["type": "string"],
                ],
                required: ["base", "name"]),
            rawSpec("db_table_schema",
                "Show a table's fields (name, type, options) and row count. "
                + "Always call this before db_add_row so you use exact field names.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                ],
                required: ["table"]),
            rawSpec("db_add_field",
                "Add a field (column) to a table. Types: text, longText, number, "
                + "checkbox, date, select, multiSelect, url, email, phone, rating, "
                + "relation (single link to a row in another table — pass link_table), "
                + "attachment (file reference). For select/multiSelect pass options too.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                    "name": ["type": "string"],
                    "type": ["type": "string"],
                    "options": ["type": "string", "description": "select/multiSelect options: JSON array or semicolon-separated"],
                    "link_table": ["type": "string", "description": "relation only: target table NAME or id (may be the same table for self-links)"],
                ],
                required: ["table", "name", "type"]),
            rawSpec("db_list_rows",
                "Read rows from a table as a markdown table (first column is row_id "
                + "for db_update_row/db_delete_row). Optional text search across all "
                + "cells. Long values are truncated — read a single row's cells via "
                + "db_list_rows with a unique 'query' if you need the full text.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                    "query": ["type": "string", "description": "Optional search text."],
                    "limit": ["type": "integer", "description": "Max rows (default 50, max 200)."],
                    "offset": ["type": "integer", "description": "Skip this many rows first."],
                ],
                required: ["table"]),
            rawSpec("db_add_row",
                "Add a row to a table. " + valuesDesc,
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                    "values": ["type": "object", "description": "Object of field name → value (native JSON object, not a quoted string)."],
                ],
                required: ["table", "values"]),
            rawSpec("db_update_row",
                "Update cells of an existing row (row_id from db_list_rows). " + valuesDesc,
                properties: [
                    "row_id": ["type": "string"],
                    "values": ["type": "object", "description": "Object of field name → value (native JSON object, not a quoted string)."],
                ],
                required: ["row_id", "values"]),
            rawSpec("db_delete_row",
                "Delete a row by row_id (from db_list_rows).",
                properties: ["row_id": ["type": "string"]],
                required: ["row_id"]),
            rawSpec("db_import_csv",
                "Import a CSV file into MaestroDB. With create='true' a NEW table is "
                + "made in 'base' with column types inferred from the data; otherwise "
                + "rows are appended to the EXISTING 'table' (headers matched to fields "
                + "case-insensitively, unknown columns become new fields). The path "
                + "must be inside an authorized folder.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the .csv file."],
                    "base": ["type": "string", "description": baseRefDesc],
                    "table": ["type": "string", "description": "Target table name — created when create='true', must exist otherwise."],
                    "create": ["type": "string", "description": "'true' = create a new table with inferred field types."],
                ],
                required: ["path", "base", "table"]),
            rawSpec("db_export_csv",
                "Export a table to a CSV file (header row of field names, one line "
                + "per row). The output path must be inside an authorized folder. "
                + "Re-importing the exported file round-trips losslessly.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                    "path": ["type": "string", "description": "Absolute output path, e.g. /Users/x/Documents/jobs.csv"],
                ],
                required: ["table", "path"]),
            rawSpec("db_delete_table",
                "Permanently DELETE a table and all its fields and rows. This cannot "
                + "be undone — confirm with the user before calling, and report the "
                + "counts from the result. For a fresh start, delete then re-create.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                ],
                required: ["table"]),
            rawSpec("db_delete_base",
                "Permanently DELETE an entire base with every table, field and row "
                + "inside it. This cannot be undone — always confirm with the user "
                + "first and report the counts from the result.",
                properties: ["base": ["type": "string", "description": baseRefDesc]],
                required: ["base"]),
            rawSpec("db_add_rows",
                "Add MULTIPLE rows to a table in ONE call — always prefer this over "
                + "repeated db_add_row when seeding several rows. 'rows' is a JSON "
                + "array of value objects (same shape as db_add_row's 'values') — "
                + "send it as a native array, NOT a quoted string. Numbers and "
                + "booleans are fine as raw JSON values. The result reports "
                + "per-row successes/failures AND rows_in_table_after — the "
                + "verified count read back from the database. Quote that number "
                + "when you tell the user it's done; if any row failed, say "
                + "which and why.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                    "rows": ["type": "array", "description": "Array of row objects, e.g. [{\"Name\": \"Ada\", \"Done\": true}, {\"Name\": \"Grace\"}]"],
                ],
                required: ["table", "rows"]),
            rawSpec("db_delete_field",
                "Permanently DELETE a field (column) from a table, with every value "
                + "stored in that column. Use to remove duplicate or mistaken columns "
                + "(e.g. a field you accidentally created twice). This cannot be undone. "
                + "If the name matches MULTIPLE fields (duplicates), you must delete by "
                + "field_id — the error lists the matching ids.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                    "name": ["type": "string", "description": "Field name (case-insensitive)"],
                    "field_id": ["type": "string", "description": "Field UUID — required when the name is duplicated"],
                ],
                required: ["table"]),
            rawSpec("db_upsert_rows",
                "Add OR update rows matched by a KEY field — the monitoring-workflow "
                + "tool. For each row: if a row already exists whose key field value "
                + "matches (case-insensitive), UPDATE that row's cells; otherwise "
                + "INSERT a new row. Use this when re-running research (weekly price "
                + "checks, stock monitoring) so you NEVER duplicate rows. 'rows' is "
                + "a JSON array of objects (same shape as db_add_rows) — 2-3 per "
                + "call is most reliable.",
                properties: [
                    "table": ["type": "string", "description": tableRefDesc],
                    "base": ["type": "string", "description": baseRefDesc],
                    "key": ["type": "string", "description": "Field NAME to match rows on, e.g. 'Equipment Name'"],
                    "rows": ["type": "array", "description": "Array of row objects, each including the key field"],
                ],
                required: ["table", "key", "rows"]),
            rawSpec("investigation_sync",
                "Sync Blocky (blockchain) and/or Stocky (equities) investigation data "
                + "into the MaestroDB 'Investigations' base — cases, watched wallets, "
                + "wallet transactions, tracked stocks, insider transactions, proxy "
                + "filings, and notes. Idempotent: re-running updates existing rows "
                + "instead of duplicating. After syncing you can query everything with "
                + "db_list_rows to do cross-domain analysis (e.g. correlate flagged "
                + "wallets with insider selling).",
                properties: [
                    "domain": ["type": "string", "description": "'blockchain', 'stocks', or 'all' (default 'all')."],
                ],
                required: []),
        ]
    }

    // MARK: - Args

    private struct CreateBaseArgs: Codable { let name, icon: String? }
    private struct BaseRefArgs: Codable { let base: String? }
    private struct CreateTableArgs: Decodable {
        let base, name: String?

        enum CodingKeys: String, CodingKey { case base, name, base_id, table_name, table }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Small models often send base_id (the UUID db_create_base
            // returned), table_name, or plain 'table' — accept the aliases.
            base = try c.decodeIfPresent(String.self, forKey: .base)
                ?? c.decodeIfPresent(String.self, forKey: .base_id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .table_name)
                ?? c.decodeIfPresent(String.self, forKey: .table)
        }
    }
    private struct TableRefArgs: Codable {
        let table, base, query: String?
        let limit, offset: Int?
    }
    struct AddFieldArgs: Decodable {
        let table, base, name, type, options, link_table: String?

        enum CodingKeys: String, CodingKey {
            case table, base, name, type, options, link_table
            case table_name, field_name, field, field_type, base_id
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Small models reliably send field_name/table_name/field_type —
            // the tool is called db_add_FIELD, so "field_name" is the natural
            // key they invent. Accept the aliases.
            table = try c.decodeIfPresent(String.self, forKey: .table)
                ?? c.decodeIfPresent(String.self, forKey: .table_name)
            base = try c.decodeIfPresent(String.self, forKey: .base)
                ?? c.decodeIfPresent(String.self, forKey: .base_id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .field_name)
                ?? c.decodeIfPresent(String.self, forKey: .field)
            type = try c.decodeIfPresent(String.self, forKey: .type)
                ?? c.decodeIfPresent(String.self, forKey: .field_type)
            options = try c.decodeIfPresent(String.self, forKey: .options)
            link_table = try c.decodeIfPresent(String.self, forKey: .link_table)
        }
    }
    struct RowValuesArgs: Decodable {
        let table, base, values, row_id: String?

        enum CodingKeys: String, CodingKey { case table, base, values, row_id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            table = try c.decodeIfPresent(String.self, forKey: .table)
            base = try c.decodeIfPresent(String.self, forKey: .base)
            row_id = try c.decodeIfPresent(String.self, forKey: .row_id)
            // 'values': models may send a JSON object string OR a native object.
            values = MaestroTools.decodeStringOrJSON(c, key: .values)
        }
    }
    private struct ImportCSVArgs: Codable { let path, base, table, create: String? }
    struct AddRowsArgs: Decodable {
        let table, base, base_id, rows: String?

        enum CodingKeys: String, CodingKey { case table, base, base_id, rows }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            table = try c.decodeIfPresent(String.self, forKey: .table)
            base = try c.decodeIfPresent(String.self, forKey: .base)
            base_id = try c.decodeIfPresent(String.self, forKey: .base_id)
            // 'rows': models may send a JSON array string OR a native array
            // of objects. Normalise to a JSON string for the parser below.
            rows = MaestroTools.decodeStringOrJSON(c, key: .rows)
        }
    }
    private struct ExportCSVArgs: Codable { let table, base, path: String? }
    private struct DeleteFieldArgs: Decodable { let table, base, name, field_id: String? }
    struct UpsertRowsArgs: Decodable {
        let table, base, base_id, key, rows: String?

        enum CodingKeys: String, CodingKey { case table, base, base_id, key, rows }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            table = try c.decodeIfPresent(String.self, forKey: .table)
            base = try c.decodeIfPresent(String.self, forKey: .base)
            base_id = try c.decodeIfPresent(String.self, forKey: .base_id)
            key = try c.decodeIfPresent(String.self, forKey: .key)
            rows = MaestroTools.decodeStringOrJSON(c, key: .rows)
        }
    }

    /// Lenient decoder for arguments models send either as a JSON string or
    /// as a native JSON value (array/object). Returns a JSON string either
    /// way, so downstream `JSONSerialization` parsing works unchanged.
    static func decodeStringOrJSON<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>, key: K
    ) -> String? {
        if let s = try? container.decode(String.self, forKey: key) { return s }
        guard let v = try? container.decode(JSONValue.self, forKey: key),
              let data = try? JSONEncoder().encode(v),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    // MARK: - Resolution helpers

    /// Resolve a base by id or case-insensitive name.
    private static func resolveBase(
        _ ref: String, database: MaestroDBDatabase
    ) throws -> MaestroBase? {
        let bases = try database.bases()
        if let byID = bases.first(where: { $0.id == ref }) { return byID }
        return bases.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
    }

    /// Resolve a table by id or case-insensitive name, optionally scoped to a
    /// base. A bare id match always wins; a name match searches the given base
    /// first, then every base (first hit wins).
    private static func resolveTable(
        _ ref: String, baseRef: String?, database: MaestroDBDatabase
    ) throws -> DBTable? {
        if let byID = try database.table(ref) { return byID }
        if let baseRef, let base = try resolveBase(baseRef, database: database) {
            if let match = try database.tables(baseID: base.id)
                .first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) {
                return match
            }
        }
        for base in try database.bases() {
            if let match = try database.tables(baseID: base.id)
                .first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) {
                return match
            }
        }
        return nil
    }

    /// All table names across all bases, for error messages.
    private static func tableNameList(_ database: MaestroDBDatabase) throws -> String {
        var names: [String] = []
        for base in try database.bases() {
            for table in try database.tables(baseID: base.id) {
                names.append("\(base.name)/\(table.name)")
            }
        }
        return names.isEmpty ? "(none — create one first)" : names.joined(separator: ", ")
    }

    /// Parse a 'rows' payload into an array of row objects, salvaging the
    /// Gemma-4 meltdown patterns seen in production:
    /// 1. Escape tokens `<|"|>` / `<|"` / `"|>` glued around values.
    /// 2. Rows wrapped as {"values": "<json-string>"} — native function-call
    ///    syntax leaking into the payload.
    /// 3. Truncated tails (generation cut off mid-row) — drop the incomplete
    ///    final row and keep the complete prefix rather than losing everything.
    /// Internal (not private) so tests can drive it with real meltdown payloads.
    static func parseRowsArray(_ raw: String) -> [[String: Any]]? {
        // Stage 1: DELETE Gemma escape tokens, then quote BARE keys. Replacing
        // tokens with quotes would produce invalid JSON (the outer decode
        // already unescaped the payload's quotes); and the model emits
        // `values:` as an unquoted bare key — invalid JSON until quoted.
        let tokenStripped = raw
            .replacingOccurrences(of: "<|\"|>", with: "")
            .replacingOccurrences(of: "<|\"|", with: "")
            .replacingOccurrences(of: "<|\"", with: "")
            .replacingOccurrences(of: "\"|>", with: "")
        let cleaned = quoteBareKeys(tokenStripped)

        // Stage 2: straightforward parse.
        if let rows = parseRowElements(cleaned) { return rows }

        // Stage 3: truncation salvage — cut at progressively earlier '}' and
        // append BALANCED closers (a values:{…} wrapper needs its own '}'
        // before the array's ']'), until the payload parses. The incomplete
        // tail row is dropped; every complete row before it is kept.
        guard cleaned.hasPrefix("[") else { return nil }
        var searchEnd = cleaned.endIndex
        for _ in 0..<16 {
            guard let lastBrace = cleaned[..<searchEnd].lastIndex(of: "}") else { break }
            let candidate = String(cleaned[...lastBrace])
            if let rows = parseRowElements(candidate + balancedClosers(for: candidate)) { return rows }
            searchEnd = lastBrace
        }
        return nil
    }

    /// Quote bare identifier keys (`{values:` → `{"values":`) outside string
    /// literals — the model emits unquoted keys when its function-call syntax
    /// leaks into JSON payloads. Already-quoted keys and non-key colons
    /// (URLs, times) are untouched: the transform only fires when an
    /// identifier immediately follows '{' or ',' and precedes ':'.
    private static func quoteBareKeys(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var inString = false, escaped = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if escaped { out.append(ch); escaped = false; i += 1; continue }
            if ch == "\\" { out.append(ch); escaped = true; i += 1; continue }
            if ch == "\"" { inString.toggle(); out.append(ch); i += 1; continue }
            if !inString && (ch == "{" || ch == ",") {
                // Lookahead: whitespace, identifier, whitespace, ':' → bare key.
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                var k = j
                while k < chars.count && (chars[k].isLetter || chars[k].isNumber || chars[k] == "_") {
                    k += 1
                }
                var m = k
                while m < chars.count && chars[m].isWhitespace { m += 1 }
                if k > j && m < chars.count && chars[m] == ":" {
                    out.append(ch)
                    out.append(contentsOf: chars[(i + 1)..<j])
                    out.append("\"")
                    out.append(contentsOf: chars[j..<k])
                    out.append("\"")
                    out.append(contentsOf: chars[k..<m])
                    i = m
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// Count unclosed '{' and '[' outside string literals and return the
    /// matching closers in nesting order ('}' first, then ']').
    private static func balancedClosers(for text: String) -> String {
        var braces = 0, brackets = 0, inString = false, escaped = false
        for ch in text {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            switch ch {
            case "{": braces += 1
            case "}": braces -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }
        }
        return String(repeating: "}", count: max(0, braces))
            + String(repeating: "]", count: max(0, brackets))
    }

    /// Parse a JSON array string into row objects, unwrapping the
    /// {"values": …} function-call wrapper when present — whether the wrapper
    /// holds a nested object or a string-wrapped JSON document.
    private static func parseRowElements(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let elements = object as? [Any], !elements.isEmpty else { return nil }
        if let rows = elements as? [[String: Any]] {
            // Wrapped fast path: every element is a single-key {"values": obj}
            // dictionary — the model's function-call syntax. Unwrap to rows.
            if rows.allSatisfy({ $0.count == 1 && $0["values"] != nil }) {
                return rows.compactMap { $0["values"] as? [String: Any] }
            }
            return rows
        }
        // Salvage path: [{"values": "<json-string>"}, ...] — string-wrapped.
        var rows: [[String: Any]] = []
        for element in elements {
            guard let dict = element as? [String: Any], dict.count == 1,
                  let wrapped = dict["values"] as? String,
                  let innerData = wrapped.data(using: .utf8),
                  let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any]
            else { return nil }
            rows.append(inner)
        }
        return rows
    }

    /// Convert a JSON object (already deserialized) into [fieldName: valueText].
    /// JSON scalars (number/bool) are stringified so models can pass natural
    /// JSON instead of string-everything. Shared by parseValues (single row)
    /// and the db_add_rows bulk path.
    static func stringifyJSONDict(_ dict: [String: Any]) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in dict {
            switch value {
            case let string as String: values[key] = stripModelJunk(string)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    values[key] = number.boolValue ? "true" : "false"
                } else {
                    values[key] = number.stringValue
                }
            case let array as [Any]:
                // Tolerate a real JSON array for multiSelect values.
                let strings = array.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
                values[key] = MaestroDBCoercion.canonical(
                    strings.joined(separator: "; "), for: .multiSelect).map { _ in strings.joined(separator: "; ") }
            default: break
            }
        }
        return values
    }

    /// Strip stray escape characters small models glue onto the EDGES of
    /// string values — e.g. `\"Profoto B1` or `2025-05-22\` — while leaving
    /// interior content (URLs, slashes) untouched. A leading/trailing
    /// backslash or unbalanced quote is never legitimate cell data.
    static func stripModelJunk(_ s: String) -> String {
        var cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk: [Character] = ["\\", "\""]
        while let first = cleaned.first, junk.contains(first) { cleaned.removeFirst() }
        while let last = cleaned.last, junk.contains(last) { cleaned.removeLast() }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the `values` JSON-object string into [fieldName: valueText].
    private static func parseValues(_ raw: String) -> [String: String]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return stringifyJSONDict(dict)
    }

    /// Best-guess field for an unknown name: exact case-insensitive first
    /// (handled by the caller), then normalized prefix/contains ("Serial No" →
    /// "Serial Number", "Item" → "Item Name"). Nil when nothing is close.
    /// Internal (not private) so tests can drive it directly.
    static func suggestField(_ name: String, fields: [DBField]) -> String? {
        let norm = { (s: String) in
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let target = norm(name)
        guard !target.isEmpty else { return nil }
        // Prefix in either direction, then containment — shortest match wins
        // (closest in specificity).
        let prefixHits = fields.filter {
            let candidate = norm($0.name)
            return candidate.hasPrefix(target) || target.hasPrefix(candidate)
        }
        let containHits = prefixHits.isEmpty
            ? fields.filter { norm($0.name).contains(target) || target.contains(norm($0.name)) }
            : []
        return (prefixHits.isEmpty ? containHits : prefixHits)
            .min { norm($0.name).count < norm($1.name).count }?.name
    }

    /// Apply parsed name→value pairs to canonical field-id→stored-value
    /// pairs. Unknown field names and uncoercible values are reported.
    /// Select/multiSelect options auto-add (matches UI behaviour).
    private static func coerceValues(
        _ values: [String: String], fields: [DBField], database: MaestroDBDatabase
    ) throws -> (cells: [String: String], errors: [String], optionsAdded: [String]) {
        var cells: [String: String] = [:]
        var errors: [String] = []
        var optionsAdded: [String] = []
        var mutableFields = fields
        for (name, raw) in values {
            // Resolve the target field: exact case-insensitive match first,
            // then a confident AUTO-MAP for near-miss names ("rental_house" →
            // "Rental House", "Daily Rate" → "Daily Rate (AUD)"). The old
            // behaviour only SUGGESTED the right name in an error — the model
            // kept retrying with the same wrong key and the value never landed.
            // Every auto-map is noted so the user can see what happened.
            var resolvedIndex = mutableFields.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            })
            if resolvedIndex == nil, let suggestion = suggestField(name, fields: fields) {
                resolvedIndex = mutableFields.firstIndex(where: { $0.name == suggestion })
                if resolvedIndex != nil {
                    errors.append("note: auto-mapped unknown field '\(name)' → '\(suggestion)'")
                }
            }
            guard let index = resolvedIndex else {
                errors.append("unknown field '\(name)' (fields: \(fields.map(\.name).joined(separator: ", ")))")
                continue
            }
            var field = mutableFields[index]

            // Relations resolve against the target table (row id OR title),
            // not through the string coercion used by every other type.
            if field.type == .relation {
                guard let resolved = try MaestroDBRelations.resolveRowID(
                    raw, field: field, database: database) else {
                    let targetName = (try? database.table(field.config["table"] ?? ""))?.name ?? "?"
                    errors.append("'\(raw)' matches no row in '\(targetName)' (use a row title or id)")
                    continue
                }
                cells[field.id] = resolved
                continue
            }

            guard let canonical = MaestroDBCoercion.canonical(raw, for: field.type) else {
                errors.append("'\(raw)' is not a valid \(field.type.rawValue) value for '\(field.name)'")
                continue
            }
            if !canonical.isEmpty {
                if field.type == .select, !field.options.contains(canonical) {
                    try database.addFieldOption(field.id, option: canonical)
                    field.options.append(canonical)
                    optionsAdded.append(canonical)
                }
                if field.type == .multiSelect {
                    for option in MaestroDBCoercion.coerceMulti(canonical) ?? []
                    where !field.options.contains(option) {
                        try database.addFieldOption(field.id, option: option)
                        field.options.append(option)
                        optionsAdded.append(option)
                    }
                }
                mutableFields[index] = field
            }
            cells[field.id] = canonical
        }

        // Auto-stamp "when was this recorded" date fields (Date Monitored,
        // Date Found, …) the model left empty. Monitoring data is meaningless
        // without an accurate collection date, and small models either skip
        // these or hallucinate them (Gemma 4 stamped rows "2025-05-22" in
        // August 2026). A date the model DID provide is left alone — but if
        // it's implausibly far from today, flag it as a warning so the user
        // (and the model) can see the likely hallucination.
        // CRITICAL: never stamp an otherwise-EMPTY row — a date-only cell
        // would make `cells` non-empty, masking total coercion failure and
        // inserting a worthless husk (eleven such rows landed in one session).
        for field in fields where field.type == .date && isRecordDateField(field.name) {
            if let existing = cells[field.id], !existing.isEmpty {
                if let provided = MaestroDBCoercion.parseDate(existing),
                   abs(provided.timeIntervalSinceNow) > 14 * 86_400 {
                    errors.append(
                        "'\(field.name)' is \(existing) but today is \(todayISO) — "
                        + "the model may have hallucinated this date; verify it")
                }
            } else if !cells.isEmpty {
                cells[field.id] = DBRow.store(Date())
                errors.append("auto-stamped '\(field.name)' with today's date (\(todayISO))")
            }
            // else: every value failed coercion — leave the row cell-empty so
            // the caller's failure path rejects it loudly instead of inserting
            // a date-only husk.
        }
        return (cells, errors, optionsAdded)
    }

    /// Field names that mean "when this row was recorded" — safe to
    /// auto-stamp and date-sanity-check. Due/Expiry/Published-style fields
    /// are deliberately NOT matched: their dates are legitimately not today.
    static func isRecordDateField(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["date monitored", "date found", "date added", "date created",
                "date recorded", "date logged", "monitored", "recorded", "logged"]
            .contains { n.contains($0) }
    }

    /// Today's date as yyyy-MM-dd, for prompts and warnings.
    static var todayISO: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Detect STRUCTURAL ARGUMENT COLLAPSE: the model splattered row data
    /// across the TOP-LEVEL argument object as giant alternating key/value
    /// strings instead of nesting it under 'rows'. Lenient salvage of that
    /// shape inserted corrupt rows in production (a "-5" price, fragmented
    /// URLs, empty names) and — worse — returned "partial" success, so the
    /// failure breaker never saw the identical failure and the model retried
    /// the same collapse 12 times. Detect it and fail LOUDLY.
    ///
    /// A legitimate extra key is a field name: short, free of JSON
    /// punctuation. Meltdown keys embed whole row fragments. Returns the
    /// offending key (truncated) when collapse is detected, nil otherwise.
    static func collapsedArgumentKey(
        _ args: [String: JSONValue], knownKeys: Set<String>
    ) -> String? {
        for (key, _) in args where !knownKeys.contains(key) {
            if key.count > 60 || key.contains("\",") || key.contains(",\"") {
                return String(key.prefix(40))
            }
        }
        return nil
    }

    /// The loud error for a collapsed call, with the correct shape spelled
    /// out so the model's next attempt can actually succeed.
    static func collapsedArgumentsError(tool: String, garbageKey: String) -> String {
        errorJSON(
            "arguments are STRUCTURALLY CORRUPT — key '\(garbageKey)…' is a JSON "
            + "meltdown artifact, not a field name. Do NOT retry this shape. Send "
            + "ONE row per call as a proper JSON object under 'rows', e.g. "
            + "\(tool) {\"table\": \"Equipment Prices\", \"rows\": "
            + "[{\"Equipment Name\": \"Canon EOS R5 Mark II\", \"Daily Rate (AUD\": 250}]}")
    }

    /// Map the model's natural type vocabulary onto the API's enum. Small
    /// models reliably send 'single_select' (Airtable-style), 'integer',
    /// 'boolean', 'string'… — the identical "unknown type" error 4-6 times in
    /// a row got db_add_field disabled by the failure breaker in production.
    /// Case-insensitive; returns the canonical rawValue or nil.
    static func canonicalFieldType(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespaces)
            .lowercased().replacingOccurrences(of: " ", with: "_")
        let aliases: [String: String] = [
            // select family
            "single_select": "select", "singleselect": "select", "dropdown": "select",
            "multi_select": "multiSelect", "multiselect": "multiSelect", "multi": "multiSelect",
            "tags": "multiSelect",
            // numbers
            "integer": "number", "int": "number", "float": "number", "double": "number",
            "decimal": "number", "currency": "number", "price": "number", "amount": "number",
            // checkbox
            "boolean": "checkbox", "bool": "checkbox", "check": "checkbox",
            // date
            "datetime": "date", "timestamp": "date", "day": "date",
            // text
            "string": "text", "varchar": "text", "name": "text",
            "long_text": "longText", "longtext": "longText", "note": "longText", "notes": "longText",
            // misc
            "link": "relation", "linked": "relation",
            "image": "attachment", "file": "attachment",
            "email_address": "email", "phone_number": "phone", "telephone": "phone",
            "stars": "rating",
        ]
        if let mapped = aliases[key] { return mapped }
        // Already canonical?
        if DBFieldType(rawValue: key) != nil { return key }
        if DBFieldType(rawValue: raw.trimmingCharacters(in: .whitespaces)) != nil {
            return raw.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Infer a field type from the field NAME when the model omits 'type'.
    /// The 13:48 run: six parallel db_add_field calls all missing 'type' (the
    /// user's prompt wrote "Daily Rate AUD (number)" — the model stripped the
    /// parenthetical for the name arg but never moved it to 'type'). Six
    /// identical failures → breaker → dead workflow. Name inference gets all
    /// six right: "Daily Rate AUD"→number, "Source URL"→url, "Last Checked"→date.
    static func inferFieldType(fromName name: String) -> String {
        let n = name.lowercased()
        if n.contains("url") || n.contains("link") || n.contains("website") { return "url" }
        if n.contains("date") || n.contains("checked") || n.contains("monitored")
            || n.contains("found") { return "date" }
        if n.contains("email") { return "email" }
        if n.contains("phone") { return "phone" }
        if n.contains("rate") || n.contains("price") || n.contains("cost")
            || n.contains("amount") || n.contains("count") || n.contains("quantity")
            || n.contains("qty") || n.contains("aud") || n.contains("$") { return "number" }
        if n.contains("done") || n.contains("complete") || n.contains("active") { return "checkbox" }
        if n.contains("note") || n.contains("description") || n.contains("comment") { return "longText" }
        return "text"
    }

    // MARK: - Handlers

    private static func dbListBases() async -> String {
        do {
            let database = MaestroDBDatabase.shared
            var result: [[String: Any]] = []
            for base in try database.bases() {
                result.append([
                    "id": base.id, "name": base.name, "icon": base.icon,
                    "tables": try database.tables(baseID: base.id).map(\.name),
                    "demo_mode": MaestroDBDatabase.isDemoMode,
                ])
            }
            if result.isEmpty {
                return jsonString([
                    "bases": [],
                    "note": "No bases yet — create one with db_create_base or import a CSV with db_import_csv.",
                ])
            }
            return jsonString(["bases": result])
        } catch { return errorJSON("db_list_bases failed: \(error.localizedDescription)") }
    }

    private static func dbCreateBase(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CreateBaseArgs.self),
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return errorJSON("db_create_base requires 'name'")
        }
        do {
            let base = try MaestroDBDatabase.shared.createBase(
                name: name, icon: args.icon?.isEmpty == false ? args.icon! : "tablecells")
            return jsonString([
                "status": "created", "base_id": base.id, "name": base.name,
                "next": "create a table with db_create_table, then add fields with db_add_field",
            ])
        } catch { return errorJSON("could not create base: \(error.localizedDescription)") }
    }

    private static func dbListTables(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: BaseRefArgs.self),
              let ref = args.base?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            return errorJSON("db_list_tables requires 'base'")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let base = try resolveBase(ref, database: database) else {
                let names = try database.bases().map(\.name).joined(separator: ", ")
                return errorJSON("no base named '\(ref)'. Bases: \(names.isEmpty ? "(none)" : names)")
            }
            var result: [[String: Any]] = []
            for table in try database.tables(baseID: base.id) {
                result.append([
                    "id": table.id, "name": table.name,
                    "fields": try database.fields(tableID: table.id).count,
                    "rows": try database.rows(tableID: table.id).count,
                ])
            }
            return jsonString(["base": base.name, "tables": result])
        } catch { return errorJSON("db_list_tables failed: \(error.localizedDescription)") }
    }

    private static func dbCreateTable(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CreateTableArgs.self),
              let baseRef = args.base?.trimmingCharacters(in: .whitespaces), !baseRef.isEmpty,
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return errorJSON("db_create_table requires 'base' and 'name'")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let base = try resolveBase(baseRef, database: database) else {
                return errorJSON("no base named '\(baseRef)'")
            }
            let table = try database.createTable(baseID: base.id, name: name)
            return jsonString([
                "status": "created", "table_id": table.id, "name": table.name, "base": base.name,
                "next": "add fields with db_add_field, or db_import_csv with create='true' to build "
                    + "from a spreadsheet. Then research with browser_open — and call db_add_rows "
                    + "after EVERY page you read, BEFORE opening the next one.",
            ])
        } catch { return errorJSON("could not create table: \(error.localizedDescription)") }
    }

    private static func dbTableSchema(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TableRefArgs.self),
              let ref = args.table?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            return errorJSON("db_table_schema requires 'table'")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(ref, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(ref)'. Tables: \(try tableNameList(database))")
            }
            let fields = try database.fields(tableID: table.id)
            return jsonString([
                "table": table.name, "table_id": table.id,
                "row_count": try database.rows(tableID: table.id).count,
                "fields": fields.map { field -> [String: Any] in
                    var dict: [String: Any] = ["name": field.name, "type": field.type.rawValue]
                    if !field.options.isEmpty { dict["options"] = field.options }
                    return dict
                },
            ])
        } catch { return errorJSON("db_table_schema failed: \(error.localizedDescription)") }
    }

    private static func dbAddField(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: AddFieldArgs.self),
              let tableRef = args.table?.trimmingCharacters(in: .whitespaces), !tableRef.isEmpty,
              let rawName = args.name?.trimmingCharacters(in: .whitespaces), !rawName.isEmpty else {
            return errorJSON(
                "db_add_field requires 'table' and 'name'. Valid types: "
                + DBFieldType.uiSupported.map(\.rawValue).joined(separator: ", ")
                + ". Example: {\"table\": \"Rental Prices\", \"name\": \"Daily Rate\", \"type\": \"number\"}")
        }
        // Type resolution, three-tier fallback:
        // 1. Explicit 'type' argument (canonical or alias).
        // 2. Parenthetical in the name: "Daily Rate AUD (number)" → number,
        //    name stripped. This is EXACTLY how users write field specs in prompts.
        // 3. Name inference: "Daily Rate AUD" → number, "Source URL" → url.
        // Every fallback is reported in the result so nothing is silent.
        var name = rawName
        var typeRaw = args.type?.trimmingCharacters(in: .whitespaces)
        var typeSource = "provided"
        if typeRaw == nil || typeRaw!.isEmpty,
           let open = rawName.lastIndex(of: "("), rawName.hasSuffix(")") {
            let inner = String(rawName[rawName.index(after: open)..<rawName.index(before: rawName.endIndex)])
            if canonicalFieldType(inner) != nil {
                typeRaw = inner
                name = String(rawName[..<open]).trimmingCharacters(in: .whitespaces)
                typeSource = "extracted_from_name"
            }
        }
        if typeRaw == nil || typeRaw!.isEmpty {
            typeRaw = inferFieldType(fromName: name)
            typeSource = "inferred_from_name"
        }
        guard let canonicalType = canonicalFieldType(typeRaw!),
              let type = DBFieldType(rawValue: canonicalType) else {
            return errorJSON(
                "unknown type '\(typeRaw!)'. Types: "
                + DBFieldType.uiSupported.map(\.rawValue).joined(separator: ", ")
                + " (aliases work too: single_select → select, boolean → checkbox, integer → number)")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(tableRef, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(tableRef)'. Tables: \(try tableNameList(database))")
            }
            // Duplicate guard: small models react to a VALUE-level coercion
            // error by re-adding the SAME field ("maybe the column is broken")
            // — which silently stacked five identical "Price (AUD)" columns in
            // one session. A case-insensitive name match returns the EXISTING
            // field with a clear note instead of creating a duplicate column.
            if let existing = try database.fields(tableID: table.id).first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                let note: String
                if existing.type == type {
                    note = "field '\(existing.name)' already exists in '\(table.name)' with the same "
                        + "type — use it as-is; do NOT create duplicate columns. If a row VALUE "
                        + "failed to save, fix the value (e.g. send 250 not \"$250/day\"), not the field."
                } else {
                    note = "field '\(existing.name)' already exists but with type "
                        + "'\(existing.type.rawValue)' (you asked for '\(type.rawValue)'). "
                        + "Use the existing field, or choose a different name."
                }
                return jsonString([
                    "status": "exists", "field_id": existing.id, "name": existing.name,
                    "type": existing.type.rawValue, "table": table.name, "note": note,
                    // Loop-breaker: re-adding existing fields burned 9 rounds in
                    // production (varied args dodged the repeated-args guard).
                    // Point at the NEXT phase so the model stops re-adding.
                    "next": "your fields already exist — do NOT add them again. If all fields "
                        + "are created: research with browser_open, and after EVERY page you "
                        + "read, save rows with db_add_rows (2-3 per call) BEFORE the next page.",
                ])
            }
            var options: [String] = []
            if let optionsRaw = args.options, !optionsRaw.isEmpty {
                options = MaestroDBCoercion.coerceMulti(optionsRaw) ?? []
            }
            var config: [String: String] = [:]
            if type == .relation {
                guard let linkRef = args.link_table?.trimmingCharacters(in: .whitespaces),
                      !linkRef.isEmpty else {
                    return errorJSON("relation fields require 'link_table' (target table NAME or id)")
                }
                guard let target = try resolveTable(linkRef, baseRef: args.base, database: database) else {
                    return errorJSON("no table named '\(linkRef)' to link to. Tables: \(try tableNameList(database))")
                }
                config["table"] = target.id
            }
            let field = try database.addField(
                tableID: table.id, name: name, type: type, options: options, config: config)
            var result: [String: Any] = [
                "status": "created", "field_id": field.id, "name": field.name,
                "type": field.type.rawValue, "table": table.name,
            ]
            if canonicalType != typeRaw! {
                result["type_alias_used"] = "'\(typeRaw!)' → '\(canonicalType)'"
            }
            if typeSource != "provided" {
                result["type_source"] = typeSource
                let how = typeSource == "extracted_from_name"
                    ? "extracted '\(canonicalType)' from the name's parenthetical"
                    : "inferred '\(canonicalType)' from the field name"
                result["note"] = "no 'type' was provided — \(how). "
                    + "If that's wrong, delete with db_delete_field and re-create with an explicit 'type'."
            }
            // Breadcrumb chain: the production gap was agents creating the schema
            // then browsing 30+ pages WITHOUT ever calling db_add_rows. Every
            // schema tool's result must point at the write rhythm.
            result["next"] = "when all fields are created: research with browser_open, and after "
                + "EVERY page you read, save what you found with db_add_rows (2-3 rows per call) "
                + "BEFORE opening the next page. Never browse more than 2 pages without saving rows."
            return jsonString(result)
        } catch { return errorJSON("could not add field: \(error.localizedDescription)") }
    }

    private static func dbDeleteField(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DeleteFieldArgs.self) else {
            return errorJSON("db_delete_field: could not decode arguments")
        }
        guard let tableRef = args.table?.trimmingCharacters(in: .whitespaces), !tableRef.isEmpty else {
            return errorJSON("db_delete_field requires 'table' (name or id)")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(tableRef, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(tableRef)'. Tables: \(try tableNameList(database))")
            }
            let fields = try database.fields(tableID: table.id)
            let target: DBField?
            if let fid = args.field_id?.trimmingCharacters(in: .whitespaces), !fid.isEmpty {
                target = fields.first { $0.id == fid }
                guard target != nil else {
                    return errorJSON("no field with id '\(fid)' in '\(table.name)'")
                }
            } else if let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                let matches = fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if matches.isEmpty {
                    return errorJSON(
                        "no field named '\(name)' in '\(table.name)'. "
                        + "Fields: \(fields.map(\.name).joined(separator: ", "))")
                }
                if matches.count > 1 {
                    return errorJSON(
                        "'\(name)' matches \(matches.count) duplicate fields — delete by "
                        + "field_id instead. Matching ids: \(matches.map(\.id).joined(separator: ", "))")
                }
                target = matches[0]
            } else {
                return errorJSON("db_delete_field requires 'name' or 'field_id'")
            }
            guard let field = target else { return errorJSON("field not found") }
            try database.deleteField(field.id)
            return jsonString([
                "status": "deleted", "field_id": field.id, "name": field.name,
                "table": table.name,
                "fields_remaining": try database.fields(tableID: table.id).map(\.name),
            ])
        } catch { return errorJSON("could not delete field: \(error.localizedDescription)") }
    }

    private static func dbListRows(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TableRefArgs.self),
              let ref = args.table?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            return errorJSON("db_list_rows requires 'table'")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(ref, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(ref)'. Tables: \(try tableNameList(database))")
            }
            let fields = try database.fields(tableID: table.id)
            let query = args.query?.trimmingCharacters(in: .whitespaces) ?? ""
            let allRows = try database.searchRows(tableID: table.id, query: query)
            let limit = min(args.limit ?? 50, 200)
            let offset = max(args.offset ?? 0, 0)
            let page = Array(allRows.dropFirst(offset).prefix(limit))
            // Relation cells display as the linked row's TITLE, not its raw id.
            let relationContexts = MaestroDBRelations.contexts(forFields: fields, database: database)

            if page.isEmpty {
                return "0 rows in '\(table.name)'\(query.isEmpty ? "" : " matching '\(query)'")"
                    + " (total: \(allRows.count))."
            }

            let columns = ["row_id"] + fields.map(\.name)
            var lines = [
                "| " + columns.joined(separator: " | ") + " |",
                "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |",
            ]
            for row in page {
                var cells = [row.id]
                for field in fields {
                    var value: String
                    if field.type == .relation, let ctx = relationContexts[field.id] {
                        let linked = row.value(for: field.id)
                        value = linked.isEmpty ? "" : (ctx.title(for: linked) ?? "⚠︎ missing row")
                    } else {
                        value = row.display(for: field)
                    }
                    if value.count > 80 { value = String(value.prefix(77)) + "…" }
                    cells.append(
                        value.replacingOccurrences(of: "|", with: "\\|")
                            .replacingOccurrences(of: "\n", with: " "))
                }
                lines.append("| " + cells.joined(separator: " | ") + " |")
            }
            var header = "\(page.count) row(s) from '\(table.name)'"
            if offset > 0 { header += " (offset \(offset))" }
            if allRows.count > offset + page.count {
                header += " — \(allRows.count - offset - page.count) more; page with offset/limit"
            }
            return header + ":\n\n" + lines.joined(separator: "\n")
        } catch { return errorJSON("db_list_rows failed: \(error.localizedDescription)") }
    }

    private static func dbAddRow(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: RowValuesArgs.self),
              let tableRef = args.table?.trimmingCharacters(in: .whitespaces), !tableRef.isEmpty,
              let valuesRaw = args.values?.trimmingCharacters(in: .whitespaces), !valuesRaw.isEmpty else {
            return errorJSON("db_add_row requires 'table' and 'values'")
        }
        guard let values = parseValues(valuesRaw) else {
            return errorJSON("'values' must be a JSON object string, e.g. {\"Name\": \"Ada\", \"Done\": true}")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(tableRef, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(tableRef)'. Tables: \(try tableNameList(database))")
            }
            let fields = try database.fields(tableID: table.id)
            let (cells, errors, optionsAdded) = try coerceValues(
                values, fields: fields, database: database)
            // Truthful statuses: NOTHING valid → hard error, no empty row;
            // SOME rejected → 'partial', never a silent 'created' (the model
            // was reading 'created' as full success and moving on).
            guard !cells.isEmpty else {
                return errorJSON(
                    "row NOT created — every value was rejected: \(errors.joined(separator: "; "))")
            }
            let row = try database.addRow(tableID: table.id, values: cells)
            var result: [String: Any] = [
                "status": errors.isEmpty ? "created" : "partial",
                "row_id": row.id, "table": table.name,
                "fields_set": cells.count,
                "rows_in_table_after": try database.rows(tableID: table.id).count,
            ]
            if !optionsAdded.isEmpty { result["options_added"] = optionsAdded }
            if !errors.isEmpty {
                result["warnings"] = errors
                result["note"] = "PARTIAL: \(errors.count) value(s) were NOT stored — tell the user exactly what was skipped."
            }
            return jsonString(result)
        } catch { return errorJSON("could not add row: \(error.localizedDescription)") }
    }

    private static func dbAddRows(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: AddRowsArgs.self) else {
            return errorJSON("db_add_rows: could not decode arguments")
        }
        var tableRef = args.table?.trimmingCharacters(in: .whitespaces) ?? ""
        let baseRef = args.base ?? args.base_id

        // rows: native array / string-wrapped / Gemma-token-wrapped / truncated —
        // parseRowsArray salvages all of them. Field-spread salvage as last resort.
        var array = args.rows.flatMap { parseRowsArray($0) }
        if array == nil {
            // COLLAPSE DETECTION before salvage: giant alternating key/value
            // strings at the top level are a meltdown, not salvageable fields.
            // Failing loudly here lets the failure breaker see the identical
            // error and stop the retry loop — silent salvage inserted corrupt
            // rows (-5 prices, fragmented URLs) for 12 consecutive rounds.
            if let garbage = Self.collapsedArgumentKey(
                call.function.arguments, knownKeys: ["table", "base", "base_id", "rows"]) {
                return Self.collapsedArgumentsError(tool: "db_add_rows", garbageKey: garbage)
            }
            let knownKeys: Set<String> = ["table", "base", "base_id", "rows"]
            let extras = call.function.arguments.filter { !knownKeys.contains($0.key) }
            if !extras.isEmpty,
               let data = try? JSONEncoder().encode(extras),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                array = [obj]
            }
        }
        guard let array, !array.isEmpty else {
            return errorJSON(
                "db_add_rows requires 'rows' — a JSON array of objects, e.g. "
                + "[{\"Name\": \"Ada\"}, {\"Name\": \"Grace\"}]. Keep calls SMALL: "
                + "2-3 rows per call; make multiple calls for more rows.")
        }
        do {
            let database = MaestroDBDatabase.shared
            // Table inference: 'table' omitted but the base has exactly ONE
            // table — the model frequently forgets 'table' right after creating
            // the base's only table. Infer rather than error.
            var inferredTableNote: String? = nil
            if tableRef.isEmpty, let baseRef,
               let base = try resolveBase(baseRef, database: database) {
                let tables = try database.tables(baseID: base.id)
                if tables.count == 1 {
                    tableRef = tables[0].name
                    inferredTableNote = "inferred table '\(tables[0].name)' (the base's only table)"
                }
            }
            guard !tableRef.isEmpty else {
                return errorJSON("db_add_rows requires 'table' (name or id)")
            }
            guard let table = try resolveTable(tableRef, baseRef: baseRef, database: database) else {
                return errorJSON("no table named '\(tableRef)'. Tables: \(try tableNameList(database))")
            }
            let fields = try database.fields(tableID: table.id)
            var createdIDs: [String] = []
            var failures: [String] = []
            var allWarnings: [String] = []
            var optionsAdded: [String] = []
            for (index, dict) in array.enumerated() {
                let values = stringifyJSONDict(dict)
                let (cells, errors, newOptions) = try coerceValues(
                    values, fields: fields, database: database)
                if cells.isEmpty, !errors.isEmpty {
                    failures.append("row \(index + 1): \(errors.joined(separator: "; "))")
                    continue
                }
                do {
                    let row = try database.addRow(tableID: table.id, values: cells)
                    createdIDs.append(row.id)
                    optionsAdded.append(contentsOf: newOptions)
                } catch {
                    failures.append("row \(index + 1): insert failed — \(error.localizedDescription)")
                }
                for error in errors {
                    allWarnings.append("row \(index + 1): \(error)")
                }
            }
            var result: [String: Any] = [
                "status": (failures.isEmpty && allWarnings.isEmpty) ? "created" : "partial",
                "table": table.name,
                "rows_requested": array.count,
                "rows_created": createdIDs.count,
                "rows_failed": failures.count,
                "rows_in_table_after": try database.rows(tableID: table.id).count,
            ]
            if !createdIDs.isEmpty { result["row_ids"] = createdIDs }
            if !failures.isEmpty { result["failures"] = failures }
            if !allWarnings.isEmpty { result["warnings"] = allWarnings }
            if !optionsAdded.isEmpty { result["options_added"] = optionsAdded }
            if let inferredTableNote { result["table_inferred"] = inferredTableNote }
            if !failures.isEmpty || !allWarnings.isEmpty {
                result["note"] = "Report rows_created/rows_failed truthfully — NEVER claim all rows were added unless rows_failed is 0 with no warnings."
            }
            return jsonString(result)
        } catch { return errorJSON("could not add rows: \(error.localizedDescription)") }
    }

    private static func dbUpsertRows(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UpsertRowsArgs.self) else {
            return errorJSON("db_upsert_rows: could not decode arguments")
        }
        var tableRef = args.table?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let keyName = args.key?.trimmingCharacters(in: .whitespaces), !keyName.isEmpty else {
            return errorJSON("db_upsert_rows requires 'key' — the field NAME to match rows on")
        }
        let baseRef = args.base ?? args.base_id

        // rows: native array / string-wrapped / Gemma-token-wrapped / truncated —
        // parseRowsArray salvages all of them. Field-spread salvage as last resort.
        var array = args.rows.flatMap { parseRowsArray($0) }
        if array == nil {
            if let garbage = Self.collapsedArgumentKey(
                call.function.arguments, knownKeys: ["table", "base", "base_id", "key", "rows"]) {
                return Self.collapsedArgumentsError(tool: "db_upsert_rows", garbageKey: garbage)
            }
            let knownKeys: Set<String> = ["table", "base", "base_id", "key", "rows"]
            let extras = call.function.arguments.filter { !knownKeys.contains($0.key) }
            if !extras.isEmpty,
               let data = try? JSONEncoder().encode(extras),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                array = [obj]
            }
        }
        guard let array, !array.isEmpty else {
            return errorJSON(
                "'rows' must be a JSON array of objects, each including the key field. "
                + "Keep calls SMALL: 2-3 rows per call.")
        }
        do {
            let database = MaestroDBDatabase.shared
            // Table inference (same as db_add_rows): single-table base.
            if tableRef.isEmpty, let baseRef,
               let base = try resolveBase(baseRef, database: database) {
                let tables = try database.tables(baseID: base.id)
                if tables.count == 1 { tableRef = tables[0].name }
            }
            guard !tableRef.isEmpty else {
                return errorJSON("db_upsert_rows requires 'table' (name or id)")
            }
            guard let table = try resolveTable(tableRef, baseRef: baseRef, database: database) else {
                return errorJSON("no table named '\(tableRef)'. Tables: \(try tableNameList(database))")
            }
            let fields = try database.fields(tableID: table.id)
            // Resolve the key field by name (exact case-insensitive, then auto-map).
            var keyField = fields.first { $0.name.caseInsensitiveCompare(keyName) == .orderedSame }
            if keyField == nil, let suggestion = suggestField(keyName, fields: fields) {
                keyField = fields.first { $0.name == suggestion }
            }
            guard let keyField else {
                return errorJSON(
                    "no key field named '\(keyName)' in '\(table.name)'. "
                    + "Fields: \(fields.map(\.name).joined(separator: ", "))")
            }
            let existingRows = try database.rows(tableID: table.id)

            var inserted = 0, updated = 0
            var failures: [String] = []
            var allWarnings: [String] = []
            var optionsAdded: [String] = []
            for (index, dict) in array.enumerated() {
                let values = stringifyJSONDict(dict)
                let (cells, errors, newOptions) = try coerceValues(
                    values, fields: fields, database: database)
                optionsAdded.append(contentsOf: newOptions)
                for error in errors { allWarnings.append("row \(index + 1): \(error)") }
                guard let keyValue = cells[keyField.id], !keyValue.isEmpty else {
                    failures.append("row \(index + 1): no value for key field '\(keyField.name)' — cannot match")
                    continue
                }
                let needle = keyValue.trimmingCharacters(in: .whitespaces).lowercased()
                let match = existingRows.first {
                    $0.value(for: keyField.id).trimmingCharacters(in: .whitespaces).lowercased() == needle
                }
                guard !cells.isEmpty else {
                    failures.append("row \(index + 1): every value was rejected: \(errors.joined(separator: "; "))")
                    continue
                }
                if let match {
                    for (fieldID, value) in cells {
                        try database.setCell(rowID: match.id, fieldID: fieldID, value: value)
                    }
                    updated += 1
                } else {
                    _ = try database.addRow(tableID: table.id, values: cells)
                    inserted += 1
                }
            }
            // __UPSERT_RESULT__
            var result: [String: Any] = [
                "status": failures.isEmpty ? "upserted" : "partial",
                "table": table.name,
                "key_field": keyField.name,
                "rows_requested": array.count,
                "rows_inserted": inserted,
                "rows_updated": updated,
                "rows_failed": failures.count,
                "rows_in_table_after": try database.rows(tableID: table.id).count,
            ]
            if !failures.isEmpty { result["failures"] = failures }
            if !allWarnings.isEmpty { result["warnings"] = allWarnings }
            if !optionsAdded.isEmpty { result["options_added"] = optionsAdded }
            result["note"] = "Report inserted/updated/failed truthfully. "
                + "To match on a different field, pass a different 'key'."
            return jsonString(result)
        } catch { return errorJSON("could not upsert rows: \(error.localizedDescription)") }
    }

    // MARK: - Investigation sync

    private struct InvestigationSyncArgs: Codable { let domain: String? }

    @MainActor
    static func investigationSync(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: InvestigationSyncArgs.self)
        let domain = args?.domain?.lowercased() ?? "all"
        let bridge = InvestigationBridge.shared
        do {
            switch domain {
            case "blockchain", "blocky":
                let counts = try bridge.syncBlocky()
                return jsonString(["status": "synced", "domain": "blockchain",
                                   "counts": counts, "base": "Investigations"])
            case "stocks", "equities":
                let counts = try bridge.syncStocks()
                return jsonString(["status": "synced", "domain": "stocks",
                                   "counts": counts, "base": "Investigations"])
            case "all":
                let result = try bridge.syncAll()
                return jsonString(["status": "synced", "domain": "all",
                                   "counts": result, "base": "Investigations",
                                   "note": "Query with db_list_rows on the Investigations base tables: Cases, Watched Wallets, Wallet Transactions, Tracked Stocks, Insider Transactions, Proxy Filings, Investigation Notes."])
            default:
                return errorJSON("unknown domain '\(domain)' — use 'blockchain', 'stocks', or 'all'")
            }
        } catch {
            return errorJSON("investigation sync failed: \(error.localizedDescription)")
        }
    }

    private static func dbUpdateRow(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: RowValuesArgs.self),
              let rowID = args.row_id?.trimmingCharacters(in: .whitespaces), !rowID.isEmpty,
              let valuesRaw = args.values?.trimmingCharacters(in: .whitespaces), !valuesRaw.isEmpty else {
            return errorJSON("db_update_row requires 'row_id' and 'values'")
        }
        guard let values = parseValues(valuesRaw) else {
            return errorJSON("'values' must be a JSON object string, e.g. {\"Status\": \"Delivered\"}")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let row = try database.row(rowID) else {
                return errorJSON("no row with id '\(rowID)' — get row ids from db_list_rows")
            }
            let fields = try database.fields(tableID: row.tableID)
            let (cells, errors, optionsAdded) = try coerceValues(
                values, fields: fields, database: database)
            guard !cells.isEmpty else {
                return errorJSON(
                    "row NOT updated — every value was rejected: \(errors.joined(separator: "; "))")
            }
            for (fieldID, value) in cells {
                try database.setCell(rowID: rowID, fieldID: fieldID, value: value)
            }
            var result: [String: Any] = [
                "status": errors.isEmpty ? "updated" : "partial",
                "row_id": rowID, "fields_set": cells.count,
            ]
            if !optionsAdded.isEmpty { result["options_added"] = optionsAdded }
            if !errors.isEmpty {
                result["warnings"] = errors
                result["note"] = "PARTIAL: \(errors.count) value(s) were NOT stored — tell the user exactly what was skipped."
            }
            return jsonString(result)
        } catch { return errorJSON("could not update row: \(error.localizedDescription)") }
    }

    private static func dbDeleteRow(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: RowValuesArgs.self),
              let rowID = args.row_id?.trimmingCharacters(in: .whitespaces), !rowID.isEmpty else {
            return errorJSON("db_delete_row requires 'row_id'")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard try database.row(rowID) != nil else {
                return errorJSON("no row with id '\(rowID)' — get row ids from db_list_rows")
            }
            try database.deleteRow(rowID)
            return jsonString(["status": "deleted", "row_id": rowID])
        } catch { return errorJSON("could not delete row: \(error.localizedDescription)") }
    }

    private static func dbDeleteTable(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TableRefArgs.self),
              let ref = args.table?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            return errorJSON("db_delete_table requires 'table'")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(ref, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(ref)'. Tables: \(try tableNameList(database))")
            }
            let fieldCount = try database.fields(tableID: table.id).count
            let rowCount = try database.rows(tableID: table.id).count
            try database.deleteTable(table.id)
            return jsonString([
                "status": "deleted", "table": table.name,
                "fields_deleted": fieldCount, "rows_deleted": rowCount,
            ])
        } catch { return errorJSON("could not delete table: \(error.localizedDescription)") }
    }

    private static func dbDeleteBase(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: BaseRefArgs.self),
              let ref = args.base?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            return errorJSON("db_delete_base requires 'base'")
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let base = try resolveBase(ref, database: database) else {
                let names = try database.bases().map(\.name).joined(separator: ", ")
                return errorJSON("no base named '\(ref)'. Bases: \(names.isEmpty ? "(none)" : names)")
            }
            let tables = try database.tables(baseID: base.id)
            var rowCount = 0
            for table in tables {
                rowCount += try database.rows(tableID: table.id).count
            }
            try database.deleteBase(base.id)
            return jsonString([
                "status": "deleted", "base": base.name,
                "tables_deleted": tables.count, "rows_deleted": rowCount,
            ])
        } catch { return errorJSON("could not delete base: \(error.localizedDescription)") }
    }

    // MARK: - CSV handlers

    private static func dbImportCSV(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ImportCSVArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let baseRef = args.base?.trimmingCharacters(in: .whitespaces), !baseRef.isEmpty,
              let tableRef = args.table?.trimmingCharacters(in: .whitespaces), !tableRef.isEmpty else {
            return errorJSON("db_import_csv requires 'path', 'base' and 'table'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("db_import_csv requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath),
              let text = try? String(contentsOfFile: actualPath, encoding: .utf8) else {
            return errorJSON("could not read '\(actualPath)'.\(didYouMean(path: resolved, wantDirectory: false))")
        }

        do {
            let parsed = try MaestroDBCSV.parse(text)
            let database = MaestroDBDatabase.shared
            guard let base = try resolveBase(baseRef, database: database) else {
                return errorJSON("no base named '\(baseRef)'")
            }
            if args.create?.lowercased() == "true" {
                let (table, report) = try MaestroDBCSV.createTable(
                    from: parsed, baseID: base.id, name: tableRef, database: database)
                return jsonString([
                    "status": "created", "table": table.name, "table_id": table.id,
                    "rows_imported": report.rowsAdded,
                    "fields_created": report.fieldsCreated,
                    "options_added": report.optionsAdded,
                    "cells_skipped": report.cellsSkipped,
                    "rows_in_table_after": try database.rows(tableID: table.id).count,
                ])
            }
            guard let table = try resolveTable(tableRef, baseRef: baseRef, database: database) else {
                return errorJSON(
                    "no table named '\(tableRef)' in base '\(base.name)' — "
                    + "pass create='true' to create it with inferred field types.")
            }
            let report = try MaestroDBCSV.importRows(parsed, into: table.id, database: database)
            return jsonString([
                "status": "imported", "table": table.name,
                "rows_imported": report.rowsAdded,
                "fields_created": report.fieldsCreated,
                "options_added": report.optionsAdded,
                "cells_skipped": report.cellsSkipped,
                "rows_in_table_after": try database.rows(tableID: table.id).count,
            ])
        } catch { return errorJSON("CSV import failed: \(error.localizedDescription)") }
    }

    private static func dbExportCSV(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ExportCSVArgs.self),
              let tableRef = args.table?.trimmingCharacters(in: .whitespaces), !tableRef.isEmpty,
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("db_export_csv requires 'table' and 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("db_export_csv requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }

        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(tableRef, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(tableRef)'. Tables: \(try tableNameList(database))")
            }
            let csv = MaestroDBCSV.exportCSV(
                fields: try database.fields(tableID: table.id),
                rows: try database.rows(tableID: table.id))
            let url = URL(fileURLWithPath: resolved)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return jsonString([
                "status": "exported", "table": table.name,
                "rows": try database.rows(tableID: table.id).count,
                "path": resolved,
            ])
        } catch { return errorJSON("CSV export failed: \(error.localizedDescription)") }
    }
}
