import Foundation

// MARK: - Investigation Bridge
//
// Mirrors Blocky (blockchain) and Stocks (equities) investigation data into a
// dedicated MaestroDB base called "Investigations". The per-domain SQLite
// stores remain the operational source of truth; this bridge pushes
// write-through copies so the Maestro agent can query across domains with the
// existing MaestroDB tools, build correlations, and the user can view/edit
// everything in the MaestroDB panel.
//
// Sync is idempotent: a sync map (source record id -> MaestroDB row id) is
// persisted to the shared memory store, so re-syncs update instead of dupe.

@MainActor
final class InvestigationBridge {

    static let shared = InvestigationBridge()

    private let db = MaestroDBDatabase.shared
    private static let baseName = "Investigations"

    // MARK: - Schema descriptor (persisted so re-runs reuse the same tables)

    struct Schema: Codable {
        var baseID: String
        var tables: [String: String]            // table key -> table id
        var fields: [String: [String: String]]  // table key -> (field name -> field id)
    }

    private(set) var schema: Schema?
    /// source key (e.g. "blocky:investigation:<uuid>") -> MaestroDB row id
    private var rowMap: [String: String] = [:]

    private static let schemaURI = MaestroURI(kind: .knowledge, path: ["investigations", "maestrodb-schema.json"])
    private static let rowMapURI = MaestroURI(kind: .knowledge, path: ["investigations", "maestrodb-rows.json"])

    private init() {
        schema = Self.loadJSON(Schema.self, at: Self.schemaURI)
        rowMap = Self.loadJSON([String: String].self, at: Self.rowMapURI) ?? [:]
    }

    // MARK: - Persistence helpers

    private static func loadJSON<T: Decodable>(_ type: T.Type, at uri: MaestroURI) -> T? {
        guard let json = try? SimpleMemoryStore().load(uri),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func saveJSON<T: Encodable>(_ value: T, at uri: MaestroURI) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        try? SimpleMemoryStore().save(json, at: uri)
    }

    // MARK: - Schema bootstrap

    /// Ensure the Investigations base + all tables + fields exist.
    @discardableResult
    func ensureSchema() throws -> Schema {
        if let schema, (try? db.table(schema.tables["cases"] ?? "")) != nil {
            return schema
        }

        let base: MaestroBase
        if let existing = try db.bases().first(where: { $0.name == Self.baseName }) {
            base = existing
        } else {
            base = try db.createBase(name: Self.baseName, icon: "magnifyingglass.circle")
        }

        var newSchema = Schema(baseID: base.id, tables: [:], fields: [:])

        let tableSpecs: [(String, String, [(String, DBFieldType, [String])])] = [
            ("cases", "Cases", [
                ("Name", .text, []),
                ("Domain", .select, ["Blockchain", "Stocks"]),
                ("Status", .select, ["Open", "Monitoring", "Closed"]),
                ("Source", .text, []),
                ("Source ID", .text, []),
                ("Created", .date, []),
                ("Notes", .longText, []),
            ]),
            ("wallets", "Watched Wallets", [
                ("Case", .text, []),
                ("Address", .text, []),
                ("Chain", .select, ["BTC", "ETH"]),
                ("Label", .text, []),
                ("Entity", .text, []),
                ("Balance", .number, []),
                ("Flagged", .checkbox, []),
                ("Flag Reason", .text, []),
                ("Source ID", .text, []),
            ]),
            ("transactions", "Wallet Transactions", [
                ("Hash", .text, []),
                ("Chain", .select, ["BTC", "ETH"]),
                ("From", .text, []),
                ("To", .text, []),
                ("Value", .number, []),
                ("Fee", .number, []),
                ("Timestamp", .text, []),
                ("Source ID", .text, []),
            ]),
            ("stocks", "Tracked Stocks", [
                ("Case", .text, []),
                ("Symbol", .text, []),
                ("Name", .text, []),
                ("Flagged", .checkbox, []),
                ("Flag Reason", .text, []),
                ("Source ID", .text, []),
            ]),
            ("insider", "Insider Transactions", [
                ("Symbol", .text, []),
                ("Insider", .text, []),
                ("Title", .text, []),
                ("Type", .select, ["Purchase", "Sale", "Option Exercise", "Gift", "Other"]),
                ("Shares", .number, []),
                ("Price Per Share", .number, []),
                ("Total Value", .number, []),
                ("Date", .text, []),
                ("Source ID", .text, []),
            ]),
            ("proxy", "Proxy Filings", [
                ("Symbol", .text, []),
                ("Company", .text, []),
                ("Filing Date", .text, []),
                ("Meeting Date", .text, []),
                ("Proposals", .longText, []),
                ("URL", .url, []),
                ("Source ID", .text, []),
            ]),
            ("notes", "Investigation Notes", [
                ("Subject", .text, []),
                ("Content", .longText, []),
                ("Author", .text, []),
                ("Created", .date, []),
                ("Source ID", .text, []),
            ]),
        ]

        let existingTables = (try? db.tables(baseID: base.id)) ?? []
        for (key, name, fieldSpecs) in tableSpecs {
            let table: DBTable
            if let found = existingTables.first(where: { $0.name == name }) {
                table = found
            } else {
                table = try db.createTable(baseID: base.id, name: name)
            }
            newSchema.tables[key] = table.id

            let existingFields = (try? db.fields(tableID: table.id)) ?? []
            var fieldMap: [String: String] = [:]
            for (fieldName, type, options) in fieldSpecs {
                if let found = existingFields.first(where: { $0.name == fieldName }) {
                    fieldMap[fieldName] = found.id
                } else {
                    let field = try db.addField(tableID: table.id, name: fieldName, type: type, options: options)
                    fieldMap[fieldName] = field.id
                }
            }
            newSchema.fields[key] = fieldMap
        }

        schema = newSchema
        Self.saveJSON(newSchema, at: Self.schemaURI)
        return newSchema
    }

    // MARK: - Row upsert

    /// Upsert a row in a synced table. `values` is field NAME -> string value;
    /// names resolve to IDs via the schema. Empty values are skipped.
    func upsertRow(tableKey: String, sourceKey: String, values: [String: String]) throws {
        guard let schema else { throw BridgeError.schemaNotInitialized }
        guard let tableID = schema.tables[tableKey],
              let fieldIDs = schema.fields[tableKey] else {
            throw BridgeError.tableMissing(tableKey)
        }

        var byFieldID: [String: String] = [:]
        for (name, value) in values {
            if let fid = fieldIDs[name], !value.isEmpty {
                byFieldID[fid] = value
            }
        }

        if let rowID = rowMap[sourceKey] {
            for (fieldID, value) in byFieldID {
                try db.setCell(rowID: rowID, fieldID: fieldID, value: value)
            }
        } else {
            let row = try db.addRow(tableID: tableID, values: byFieldID)
            rowMap[sourceKey] = row.id
            Self.saveJSON(rowMap, at: Self.rowMapURI)
        }
    }

    static func dateOnly(_ isoString: String) -> String {
        String(isoString.prefix(10))
    }

    static func num(_ v: Double?) -> String {
        v.map { String($0) } ?? ""
    }

    enum BridgeError: LocalizedError {
        case schemaNotInitialized
        case tableMissing(String)

        var errorDescription: String? {
            switch self {
            case .schemaNotInitialized: return "Investigation schema not initialized in MaestroDB"
            case .tableMissing(let key): return "Synced table '\(key)' missing from MaestroDB schema"
            }
        }
    }
}
