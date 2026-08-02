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
                    "values": ["type": "string", "description": "JSON object string of field name → value."],
                ],
                required: ["table", "values"]),
            rawSpec("db_update_row",
                "Update cells of an existing row (row_id from db_list_rows). " + valuesDesc,
                properties: [
                    "row_id": ["type": "string"],
                    "values": ["type": "string", "description": "JSON object string of field name → value."],
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
        ]
    }

    // MARK: - Args

    private struct CreateBaseArgs: Codable { let name, icon: String? }
    private struct BaseRefArgs: Codable { let base: String? }
    private struct CreateTableArgs: Codable { let base, name: String? }
    private struct TableRefArgs: Codable {
        let table, base, query: String?
        let limit, offset: Int?
    }
    private struct AddFieldArgs: Codable { let table, base, name, type, options, link_table: String? }
    private struct RowValuesArgs: Codable { let table, base, values, row_id: String? }
    private struct ImportCSVArgs: Codable { let path, base, table, create: String? }
    private struct ExportCSVArgs: Codable { let table, base, path: String? }

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

    /// Parse the `values` JSON-object string into [fieldName: valueText].
    /// JSON scalars (number/bool) are stringified so models can pass natural
    /// JSON instead of string-everything.
    private static func parseValues(_ raw: String) -> [String: String]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        var values: [String: String] = [:]
        for (key, value) in dict {
            switch value {
            case let string as String: values[key] = string
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
            guard let index = mutableFields.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
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
        return (cells, errors, optionsAdded)
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
            return jsonString(["status": "created", "base_id": base.id, "name": base.name])
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
                "next": "add fields with db_add_field, or db_import_csv with create='true' to build from a spreadsheet",
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
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let typeRaw = args.type?.trimmingCharacters(in: .whitespaces) else {
            return errorJSON("db_add_field requires 'table', 'name' and 'type'")
        }
        guard let type = DBFieldType(rawValue: typeRaw) else {
            return errorJSON(
                "unknown type '\(typeRaw)'. Types: "
                + DBFieldType.uiSupported.map(\.rawValue).joined(separator: ", "))
        }
        do {
            let database = MaestroDBDatabase.shared
            guard let table = try resolveTable(tableRef, baseRef: args.base, database: database) else {
                return errorJSON("no table named '\(tableRef)'. Tables: \(try tableNameList(database))")
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
            return jsonString([
                "status": "created", "field_id": field.id, "name": field.name,
                "type": field.type.rawValue, "table": table.name,
            ])
        } catch { return errorJSON("could not add field: \(error.localizedDescription)") }
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
            let row = try database.addRow(tableID: table.id, values: cells)
            var result: [String: Any] = [
                "status": "created", "row_id": row.id, "table": table.name,
                "fields_set": cells.count,
            ]
            if !optionsAdded.isEmpty { result["options_added"] = optionsAdded }
            if !errors.isEmpty { result["warnings"] = errors }
            return jsonString(result)
        } catch { return errorJSON("could not add row: \(error.localizedDescription)") }
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
            for (fieldID, value) in cells {
                try database.setCell(rowID: rowID, fieldID: fieldID, value: value)
            }
            var result: [String: Any] = [
                "status": "updated", "row_id": rowID, "fields_set": cells.count,
            ]
            if !optionsAdded.isEmpty { result["options_added"] = optionsAdded }
            if !errors.isEmpty { result["warnings"] = errors }
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
