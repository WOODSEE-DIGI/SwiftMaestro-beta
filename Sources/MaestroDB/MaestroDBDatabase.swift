import Foundation
import GRDB

// MARK: - MaestroDB Database (core: open/migrate/bases/tables/fields)
//
// GRDB/WAL with the live ↔ demo swap pattern proven in BooksDatabase.
// Dynamic schema: bases → tables → fields → rows → cells (EAV). Covers all
// field types from day one so relation/attachment need no migration.
// Row/cell CRUD lives in MaestroDBDatabase+Rows.swift.

extension Notification.Name {
    /// Posted (from any thread) after every MaestroDB write — base, table,
    /// field, row, or cell — so open MaestroDB panels reload changes they
    /// didn't make themselves (agent db_* tools, the kanban write-through
    /// bridge, another panel's edits).
    static let maestroDBDidChange = Notification.Name(
        "com.woodseedigi.swiftmaestro.maestroDBDidChange")
}

final class MaestroDBDatabase: Sendable {

    nonisolated(unsafe) private(set) static var isDemoMode = false
    nonisolated(unsafe) private static var instance: MaestroDBDatabase?
    private static let instanceLock = NSLock()

    static var shared: MaestroDBDatabase {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        if let instance { return instance }
        let opened = open(currentURL())
        instance = opened
        return opened
    }

    /// Swap between the live and demo databases. Seeds demo content on
    /// first entry. View models must reload after this.
    static func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoMode else { return }
        instanceLock.lock()
        isDemoMode = enabled
        instance = nil
        instanceLock.unlock()
        if enabled {
            do { try MaestroDBDemoData.seedIfEmpty(shared) }
            catch { NSLog("[MaestroDB] Demo seed failed: %@", String(describing: error)) }
        }
    }

    private static func currentURL() -> URL { isDemoMode ? demoURL() : defaultURL() }

    private static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
            .appendingPathComponent("maestrodb.sqlite")
    }

    private static func demoURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
            .appendingPathComponent("maestrodb-demo.sqlite")
    }

    // MARK: - Open / migrate

    let dbQueue: DatabaseQueue

    /// Internal (not private) so @testable suites can open throwaway
    /// databases in temp directories without touching the shared singleton.
    static func open(_ url: URL) -> MaestroDBDatabase {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.journalMode = .wal
            configuration.foreignKeysEnabled = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            let database = MaestroDBDatabase(dbQueue: queue)
            try database.migrate()
            return database
        } catch {
            fatalError("[MaestroDB] Cannot open database at \(url.path): \(error)")
        }
    }

    private init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-schema") { db in
            try db.create(table: "db_base") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "tablecells")
                t.column("created_at", .double).notNull()
            }
            try db.create(table: "db_table") { t in
                t.column("id", .text).primaryKey()
                t.column("base_id", .text).notNull()
                    .references("db_base", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "db_field") { t in
                t.column("id", .text).primaryKey()
                t.column("table_id", .text).notNull()
                    .references("db_table", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("options", .text).notNull().defaults(to: "[]")
                t.column("config", .text).notNull().defaults(to: "{}")
            }
            try db.create(table: "db_row") { t in
                t.column("id", .text).primaryKey()
                t.column("table_id", .text).notNull()
                    .references("db_table", onDelete: .cascade)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(table: "db_cell") { t in
                t.column("row_id", .text).notNull()
                    .references("db_row", onDelete: .cascade)
                t.column("field_id", .text).notNull()
                    .references("db_field", onDelete: .cascade)
                t.column("value", .text).notNull().defaults(to: "")
                t.primaryKey(["row_id", "field_id"])
            }
            try db.create(index: "idx_table_base", on: "db_table", columns: ["base_id", "position"])
            try db.create(index: "idx_field_table", on: "db_field", columns: ["table_id", "position"])
            try db.create(index: "idx_row_table", on: "db_row", columns: ["table_id", "position"])
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Bases

    func bases() throws -> [MaestroBase] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM db_base ORDER BY created_at").map(Self.baseFromRow)
        }
    }

    @discardableResult
    func createBase(name: String, icon: String = "tablecells") throws -> MaestroBase {
        let base = MaestroBase(id: UUID().uuidString, name: name, icon: icon, createdAt: Date())
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO db_base (id, name, icon, created_at) VALUES (?, ?, ?, ?)",
                arguments: [base.id, base.name, base.icon, base.createdAt.timeIntervalSince1970])
        }
        Self.postDidChange()
        return base
    }

    func renameBase(_ baseID: String, name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE db_base SET name = ? WHERE id = ?", arguments: [name, baseID])
        }
        Self.postDidChange()
    }

    func deleteBase(_ baseID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM db_base WHERE id = ?", arguments: [baseID])
        }
        Self.postDidChange()
    }

    // MARK: - Tables

    func tables(baseID: String) throws -> [DBTable] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM db_table WHERE base_id = ? ORDER BY position",
                arguments: [baseID]
            ).map(Self.tableFromRow)
        }
    }

    func table(_ tableID: String) throws -> DBTable? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM db_table WHERE id = ?", arguments: [tableID])
                .map(Self.tableFromRow)
        }
    }

    @discardableResult
    func createTable(baseID: String, name: String) throws -> DBTable {
        let table = DBTable(
            id: UUID().uuidString, baseID: baseID, name: name,
            position: try nextPosition("db_table", "base_id", baseID))
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO db_table (id, base_id, name, position) VALUES (?, ?, ?, ?)",
                arguments: [table.id, table.baseID, table.name, table.position])
        }
        Self.postDidChange()
        return table
    }

    func renameTable(_ tableID: String, name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE db_table SET name = ? WHERE id = ?", arguments: [name, tableID])
        }
        Self.postDidChange()
    }

    func deleteTable(_ tableID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM db_table WHERE id = ?", arguments: [tableID])
        }
        Self.postDidChange()
    }

    // MARK: - Fields

    func fields(tableID: String) throws -> [DBField] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM db_field WHERE table_id = ? ORDER BY position",
                arguments: [tableID]
            ).map(Self.fieldFromRow)
        }
    }

    func field(_ fieldID: String) throws -> DBField? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM db_field WHERE id = ?", arguments: [fieldID])
                .map(Self.fieldFromRow)
        }
    }

    @discardableResult
    func addField(tableID: String, name: String, type: DBFieldType,
                  options: [String] = [], config: [String: String] = [:]) throws -> DBField {
        let field = DBField(
            id: UUID().uuidString, tableID: tableID, name: name, type: type,
            position: try nextPosition("db_field", "table_id", tableID),
            options: options, config: config)
        try insertField(field)
        Self.postDidChange()
        return field
    }

    func updateField(_ field: DBField) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE db_field SET name = ?, type = ?, options = ?, config = ? WHERE id = ?",
                arguments: [
                    field.name, field.type.rawValue,
                    Self.encodeJSON(field.options), Self.encodeJSON(field.config),
                    field.id,
                ])
        }
        Self.postDidChange()
    }

    func deleteField(_ fieldID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM db_field WHERE id = ?", arguments: [fieldID])
        }
        Self.postDidChange()
    }

    /// Add an option to a select/multiSelect field (deduped, appended).
    func addFieldOption(_ fieldID: String, option: String) throws {
        guard var field = try self.field(fieldID) else { return }
        guard !option.isEmpty, !field.options.contains(option) else { return }
        field.options.append(option)
        try updateField(field)
    }

    // MARK: - Helpers (internal for the Rows extension)

    /// Notify observers (open MaestroDB panels) that data changed. Safe from
    /// any thread; the view model debounces bursts into one reload.
    static func postDidChange() {
        NotificationCenter.default.post(name: .maestroDBDidChange, object: nil)
    }

    func insertField(_ field: DBField) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO db_field (id, table_id, name, type, position, options, config) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    field.id, field.tableID, field.name, field.type.rawValue,
                    field.position, Self.encodeJSON(field.options), Self.encodeJSON(field.config),
                ])
        }
    }

    func nextPosition(_ table: String, _ parentColumn: String, _ parentID: String) throws -> Int {
        try dbQueue.read { db in
            let maxPosition = try Int.fetchOne(
                db, sql: "SELECT MAX(position) FROM \(table) WHERE \(parentColumn) = ?",
                arguments: [parentID]) ?? -1
            return maxPosition + 1
        }
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from string: String, fallback: T) -> T {
        guard let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return decoded
    }

    static func baseFromRow(_ row: Row) -> MaestroBase {
        MaestroBase(
            id: row["id"], name: row["name"], icon: row["icon"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }

    static func tableFromRow(_ row: Row) -> DBTable {
        DBTable(id: row["id"], baseID: row["base_id"], name: row["name"], position: row["position"])
    }

    static func fieldFromRow(_ row: Row) -> DBField {
        DBField(
            id: row["id"], tableID: row["table_id"], name: row["name"],
            type: DBFieldType(rawValue: row["type"]) ?? .text,
            position: row["position"],
            options: decodeJSON([String].self, from: row["options"], fallback: []),
            config: decodeJSON([String: String].self, from: row["config"], fallback: [:]))
    }
}
