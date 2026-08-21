import Foundation

// MARK: - Clip Library Bridge
//
// Saves web clips into a dedicated MaestroDB base ("Web Clips") so the agent
// can query the clip library with the db_* tools — "what have I clipped from
// youtube.com this month", "all research clips mentioning MLX", etc.
//
// Idempotent: clips upsert by URL+title key stored in a persisted row map.

@MainActor
final class ClipLibraryBridge {

    static let shared = ClipLibraryBridge()

    private let db = MaestroDBDatabase.shared
    static let defaultBaseName = "Web Clips"
    static let defaultTableName = "Clips"

    struct Schema: Codable {
        var baseID: String
        var tableID: String
        var fields: [String: String]  // field name -> field id
    }

    /// Schema cache: "baseName|tableName" -> schema. Persisted so relaunches
    /// reuse the same tables/fields instead of re-creating.
    private var schemas: [String: Schema] = [:]
    /// clip key ("<tableID>|<url>") -> MaestroDB row id. Keyed by table so the
    /// same URL clipped via two templates lands one row per destination table.
    private var rowMap: [String: String] = [:]

    private static let schemasURI = MaestroURI(kind: .knowledge, path: ["clips", "maestrodb-schemas.json"])
    private static let rowMapURI = MaestroURI(kind: .knowledge, path: ["clips", "maestrodb-rows.json"])

    private init() {
        schemas = Self.loadJSON([String: Schema].self, at: Self.schemasURI) ?? [:]
        rowMap = Self.loadJSON([String: String].self, at: Self.rowMapURI) ?? [:]
        migrateLegacySchema()
    }

    /// One-time migration: the original single-schema files (maestrodb-schema.json
    /// with {baseID, tableID, fields}) become the "Web Clips|Clips" cache entry,
    /// and URL-keyed rows become "Web Clips|Clips|url" keyed... we don't know the
    /// tableID on this side of the migration cheaply, so legacy row entries are
    /// left as-is (still valid: they keyed by URL into the default table — the
    /// legacy key format was just the URL, which now would collide across tables,
    /// so we re-key them under the default schema's tableID when available).
    private func migrateLegacySchema() {
        guard schemas.isEmpty else { return }
        let legacyURI = MaestroURI(kind: .knowledge, path: ["clips", "maestrodb-schema.json"])
        if let legacy = Self.loadJSON(Schema.self, at: legacyURI) {
            let key = Self.schemaKey(base: Self.defaultBaseName, table: Self.defaultTableName)
            schemas[key] = legacy
            // Re-key the row map: "<url>" -> "<tableID>|<url>"
            var migrated: [String: String] = [:]
            for (url, rowID) in rowMap {
                if !url.contains("|") {
                    migrated["\(legacy.tableID)|\(url)"] = rowID
                } else {
                    migrated[url] = rowID
                }
            }
            rowMap = migrated
            Self.saveJSON(schemas, at: Self.schemasURI)
            Self.saveJSON(rowMap, at: Self.rowMapURI)
        }
    }

    private static func schemaKey(base: String, table: String) -> String {
        "\(base)|\(table)"
    }

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

    /// Ensure the base + table + fields exist for the given destination.
    @discardableResult
    func ensureSchema(baseName: String = ClipLibraryBridge.defaultBaseName,
                      tableName: String = ClipLibraryBridge.defaultTableName) throws -> Schema {
        let key = Self.schemaKey(base: baseName, table: tableName)
        if let cached = schemas[key], (try? db.table(cached.tableID)) != nil {
            return cached
        }

        let base: MaestroBase
        if let existing = try db.bases().first(where: { $0.name == baseName }) {
            base = existing
        } else {
            base = try db.createBase(name: baseName, icon: "doc.richtext")
        }

        let existingTables = (try? db.tables(baseID: base.id)) ?? []
        let table: DBTable
        if let found = existingTables.first(where: { $0.name == tableName }) {
            table = found
        } else {
            table = try db.createTable(baseID: base.id, name: tableName)
        }

        let fieldSpecs: [(String, DBFieldType, [String])] = [
            ("Title", .text, []),
            ("URL", .url, []),
            ("Domain", .text, []),
            ("Author", .text, []),
            ("Site", .text, []),
            ("Published", .date, []),
            ("Clipped", .date, []),
            ("Words", .number, []),
            ("Template", .text, []),
            ("Tags", .multiSelect, []),
            ("Excerpt", .longText, []),
            ("Image", .url, []),
            ("Note Path", .text, []),
        ]

        let existingFields = (try? db.fields(tableID: table.id)) ?? []
        var fieldMap: [String: String] = [:]
        for (name, type, options) in fieldSpecs {
            if let found = existingFields.first(where: { $0.name == name }) {
                fieldMap[name] = found.id
            } else {
                let field = try db.addField(tableID: table.id, name: name, type: type, options: options)
                fieldMap[name] = field.id
            }
        }

        let newSchema = Schema(baseID: base.id, tableID: table.id, fields: fieldMap)
        schemas[key] = newSchema
        Self.saveJSON(schemas, at: Self.schemasURI)
        return newSchema
    }

    // MARK: - Save a clip

    /// Upsert a clip row into the template's MaestroDB base/table, keyed by
    /// URL within that table. Returns the MaestroDB row id.
    @discardableResult
    func saveClip(_ clip: WebClipResult, template: ClipTemplate, notePath: String?) throws -> String {
        let schema = try ensureSchema(baseName: template.maestroBase, tableName: template.maestroTable)
        let key = "\(schema.tableID)|\(clip.url)"

        let tags = template.properties
            .first(where: { $0.name == "tags" && $0.type == .multitext })
            .map { ClipTemplateEngine.render($0.valueTemplate, variables: ClipTemplateEngine.buildVariables(from: clip)) } ?? ""

        let values: [String: String] = [
            "Title": clip.title,
            "URL": clip.url,
            "Domain": clip.domain,
            "Author": clip.author,
            "Site": clip.site,
            "Published": clip.published.isEmpty ? "" : String(clip.published.prefix(10)),
            "Clipped": ISO8601DateFormatter().string(from: Date()).prefix(10).description,
            "Words": clip.wordCount > 0 ? String(clip.wordCount) : "",
            "Template": template.name,
            "Tags": tags,
            "Excerpt": String(clip.excerpt.prefix(500)),
            "Image": clip.image,
            "Note Path": notePath ?? "",
        ]

        var byFieldID: [String: String] = [:]
        for (name, value) in values where !value.isEmpty {
            if let fid = schema.fields[name] {
                byFieldID[fid] = value
            }
        }

        // Add any multiSelect tag options that don't exist yet
        if let tagsFieldID = schema.fields["Tags"], !tags.isEmpty {
            for tag in tags.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
                try? db.addFieldOption(tagsFieldID, option: tag)
            }
        }

        if let rowID = rowMap[key] {
            for (fieldID, value) in byFieldID {
                try db.setCell(rowID: rowID, fieldID: fieldID, value: value)
            }
            return rowID
        } else {
            let row = try db.addRow(tableID: schema.tableID, values: byFieldID)
            rowMap[key] = row.id
            Self.saveJSON(rowMap, at: Self.rowMapURI)
            return row.id
        }
    }

    /// Count of tracked clips (for UI/status).
    var clipCount: Int { rowMap.count }
}
