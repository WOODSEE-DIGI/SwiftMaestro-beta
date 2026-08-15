import Foundation
import GRDB

// MARK: - MaestroDAM Database
//
// Owns the catalog's GRDB queue and migrations. The catalog lives in the
// app's Application Support directory (already a default-authorized folder)
// and runs in WAL mode so the browser can read while an import batch writes.

enum DAMDatabaseError: Error, Sendable {
    case migrationFailed(String)
}

final class DAMDatabase: Sendable {

    /// Shared catalog. Falls back to an in-memory database (with a logged
    /// error) if the on-disk catalog cannot be opened — the DAM browser then
    /// shows an empty catalog instead of crashing the app.
    static let shared: DAMDatabase = {
        do {
            return try DAMDatabase(makeURL: DAMDatabase.defaultCatalogURL)
        } catch {
            NSLog("[DAM] Failed to open catalog at %@: %@ — using in-memory fallback.",
                  DAMDatabase.defaultCatalogURL().path, String(describing: error))
            // swiftlint:disable:next force_try
            return try! DAMDatabase(inMemory: ())
        }
    }()

    let dbQueue: DatabaseQueue

    private static func defaultCatalogURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro/DAM", isDirectory: true)
            .appendingPathComponent("catalog.sqlite")
    }

    private init(makeURL: () throws -> URL) throws {
        let url = try makeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    private init(inMemory: ()) throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Migrations

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        // v1 — initial catalog schema (see docs/26.07.30-MaestroDAM-Architecture.md)
        migrator.registerMigration("v1-catalog") { db in
            try db.create(table: "asset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("filename", .text).notNull()
                t.column("uti", .text)
                t.column("fileSize", .integer)
                t.column("fileModDate", .datetime)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("duration", .double)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("colorLabel", .text).notNull().defaults(to: DAMColorLabel.none.rawValue)
                t.column("flag", .text).notNull().defaults(to: DAMFlag.none.rawValue)
                t.column("captureDate", .datetime)
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("lensModel", .text)
                t.column("iso", .integer)
                t.column("aperture", .double)
                t.column("shutterSpeed", .text)
                t.column("focalLength", .double)
                t.column("gpsLat", .double)
                t.column("gpsLon", .double)
                t.column("orientation", .integer).notNull().defaults(to: 1)
                t.column("perceptualHash", .text)
                t.column("xattrKeywords", .text)
                t.column("aiCaption", .text)
                t.column("aiKeywords", .text)
                t.column("ocrText", .text)
                t.column("indexedAt", .datetime)
                t.column("aiIndexedAt", .datetime)
            }
            try db.create(index: "idx_asset_rating", on: "asset", columns: ["rating"])
            try db.create(index: "idx_asset_captureDate", on: "asset", columns: ["captureDate"])

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("parentId", .integer).references("tag", onDelete: .cascade)
                t.column("source", .text).notNull().defaults(to: DAMTagSource.user.rawValue)
                t.uniqueKey(["name", "parentId"])
            }

            try db.create(table: "assetTag") { t in
                t.column("assetId", .integer).notNull()
                    .references("asset", onDelete: .cascade)
                t.column("tagId", .integer).notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["assetId", "tagId"])
            }

            try db.create(table: "collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("predicateJSON", .text)
                t.column("parentId", .integer).references("collection", onDelete: .cascade)
            }

            try db.create(table: "collectionAsset") { t in
                t.column("collectionId", .integer).notNull()
                    .references("collection", onDelete: .cascade)
                t.column("assetId", .integer).notNull()
                    .references("asset", onDelete: .cascade)
                t.column("position", .integer)
                t.primaryKey(["collectionId", "assetId"])
            }

            // Full-text search over all human-readable asset text, kept in
            // sync with the asset table via triggers (external-content FTS5).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE assetSearch USING fts5(
                    filename, aiCaption, aiKeywords, ocrText, xattrKeywords,
                    content='asset', content_rowid='id'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER assetSearch_insert AFTER INSERT ON asset BEGIN
                    INSERT INTO assetSearch(rowid, filename, aiCaption, aiKeywords, ocrText, xattrKeywords)
                    VALUES (new.id, new.filename, new.aiCaption, new.aiKeywords, new.ocrText, new.xattrKeywords);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER assetSearch_delete AFTER DELETE ON asset BEGIN
                    INSERT INTO assetSearch(assetSearch, rowid, filename, aiCaption, aiKeywords, ocrText, xattrKeywords)
                    VALUES ('delete', old.id, old.filename, old.aiCaption, old.aiKeywords, old.ocrText, old.xattrKeywords);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER assetSearch_update AFTER UPDATE ON asset BEGIN
                    INSERT INTO assetSearch(assetSearch, rowid, filename, aiCaption, aiKeywords, ocrText, xattrKeywords)
                    VALUES ('delete', old.id, old.filename, old.aiCaption, old.aiKeywords, old.ocrText, old.xattrKeywords);
                    INSERT INTO assetSearch(rowid, filename, aiCaption, aiKeywords, ocrText, xattrKeywords)
                    VALUES (new.id, new.filename, new.aiCaption, new.aiKeywords, new.ocrText, new.xattrKeywords);
                END
                """)
        }

        // v2 — audit trail: every DAM metadata mutation (rating, label,
        // flag, tag) with old/new values, so any change can be rolled back.
        migrator.registerMigration("v2-audit") { db in
            try db.create(table: "damAudit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetId", .integer).notNull()
                    .references("asset", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("oldValue", .text)
                t.column("newValue", .text)
                t.column("source", .text).notNull()
                t.column("changedAt", .datetime).notNull()
            }
            try db.create(index: "idx_damAudit_asset", on: "damAudit", columns: ["assetId"])
        }

        // v3 — folder column for the folder tree + folder-scoped browsing.
        // Backfilled from path minus filename.
        migrator.registerMigration("v3-folder") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "folder", .text)
            }
            try db.execute(sql: """
                UPDATE asset SET folder = substr(path, 1, length(path) - length(filename) - 1)
                """)
            try db.create(index: "idx_asset_folder", on: "asset", columns: ["folder"])
        }

        // v4 — user-entered keywords (Edit workspace batch keywording).
        // Deliberately NOT in the FTS5 external-content table yet: adding a
        // column there requires a table rebuild — deferred to the metadata-
        // write phase. xattr/AI keywords remain full-text searchable.
        migrator.registerMigration("v4-user-keywords") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "userKeywords", .text)
            }
        }

        migrator.registerMigration("v5-tag-colors") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "tagColors", .text)
            }
        }

        return migrator
    }()

    /// Records one metadata mutation in the audit trail. Called inside the
    /// same write transaction as the mutation itself so both land atomically.
    func recordAudit(
        _ db: GRDB.Database,
        assetId: Int64,
        field: String,
        oldValue: String?,
        newValue: String?,
        source: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO damAudit (assetId, field, oldValue, newValue, source, changedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [assetId, field, oldValue, newValue, source, Date()])
    }

    // MARK: - Queries

    /// Sort orders for the browser grid (Bridge's Sort menu parity).
    enum DAMSortOrder: String, Sendable, CaseIterable {
        case captureDateDesc, captureDateAsc, filenameAsc, sizeDesc, ratingDesc

        var displayName: String {
            switch self {
            case .captureDateDesc: return "Date (newest)"
            case .captureDateAsc: return "Date (oldest)"
            case .filenameAsc: return "Filename"
            case .sizeDesc: return "Size (largest)"
            case .ratingDesc: return "Rating"
            }
        }
    }

    /// Assets for the browser grid, optional folder scope (recursive —
    /// includes subfolders) and minimum rating filter, paged. Kept
    /// deliberately simple for the scaffold — GRDB ValueObservation-driven
    /// live updates come with Phase 1.
    func assets(folder: String?, minRating: Int, sort: DAMSortOrder,
                 limit: Int, offset: Int,
                 tagColor: Int? = nil, fileType: String? = nil,
                 tagged: Bool? = nil, flag: DAMFlag? = nil) throws -> [DAMAsset] {
        try dbQueue.read { db in
            var request = DAMAsset.filter(DAMAsset.Columns.rating >= minRating)
            if let tagColor {
                let pattern = "%\":\(tagColor),%"
                let patternEnd = "%\":\(tagColor)}"
                request = request.filter(
                    Column("tagColors").like(pattern)
                    || Column("tagColors").like(patternEnd)
                )
            }
            if let fileType {
                request = request.filter(Column("uti").like("%\(fileType)%"))
            }
            if let tagged {
                if tagged {
                    request = request.filter(Column("xattrKeywords") != nil && Column("xattrKeywords") != "")
                } else {
                    request = request.filter(Column("xattrKeywords") == nil || Column("xattrKeywords") == "")
                }
            }
            if let flag {
                request = request.filter(Column("flag") == flag.rawValue)
            }
            if let folder {
                // Recursive folder scope without LIKE/GLOB escaping hazards:
                // exact match, or range scan [folder+"/", folder+"0") which
                // covers all descendants ('/'=47 < any path char, and '0' is
                // '/' + 1 so the range tight-bounds the subtree). Indexed.
                request = request.filter(
                    DAMAsset.Columns.folder == folder
                    || (DAMAsset.Columns.folder >= folder + "/"
                        && DAMAsset.Columns.folder < folder + "0")
                )
            }
            switch sort {
            case .captureDateDesc: request = request.order(DAMAsset.Columns.captureDate.desc)
            case .captureDateAsc: request = request.order(DAMAsset.Columns.captureDate.asc)
            case .filenameAsc: request = request.order(DAMAsset.Columns.filename.asc)
            case .sizeDesc: request = request.order(Column("fileSize").desc)
            case .ratingDesc:
                request = request.order(DAMAsset.Columns.rating.desc, DAMAsset.Columns.captureDate.desc)
            }
            return try request.limit(limit, offset: offset).fetchAll(db)
        }
    }

    /// Total assets matching the current filters — the "N items" figure in
    /// the Bridge-style status bar.
    func assetCount(folder: String?, minRating: Int,
                     tagColor: Int? = nil, fileType: String? = nil,
                     tagged: Bool? = nil, flag: DAMFlag? = nil) throws -> Int {
        try dbQueue.read { db in
            var request = DAMAsset.filter(DAMAsset.Columns.rating >= minRating)
            if let tagColor {
                // Match any tag in the JSON dict with this color index
                // e.g. {"2024":7,"Work":1} matches tagColor=7
                let pattern = "%\":\(tagColor),%"  // mid-dict: "tag":7,
                let patternEnd = "%\":\(tagColor)}" // end-dict: "tag":7}
                request = request.filter(
                    Column("tagColors").like(pattern)
                    || Column("tagColors").like(patternEnd)
                )
            }
            if let fileType {
                request = request.filter(Column("uti").like("%\(fileType)%"))
            }
            if let tagged {
                if tagged {
                    request = request.filter(Column("xattrKeywords") != nil && Column("xattrKeywords") != "")
                } else {
                    request = request.filter(Column("xattrKeywords") == nil || Column("xattrKeywords") == "")
                }
            }
            if let flag {
                request = request.filter(Column("flag") == flag.rawValue)
            }
            if let folder {
                request = request.filter(
                    DAMAsset.Columns.folder == folder
                    || (DAMAsset.Columns.folder >= folder + "/"
                        && DAMAsset.Columns.folder < folder + "0")
                )
            }
            return try request.fetchCount(db)
        }
    }

    /// Convenience: total assets in a folder (any rating).
    func assetCount(folder: String?) throws -> Int {
        try assetCount(folder: folder, minRating: 0)
    }

    /// Distinct folders with their direct asset counts — the data behind
    /// the folder tree sidebar.
    func folderCounts() throws -> [(folder: String, count: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT folder, COUNT(*) AS n FROM asset
                WHERE folder IS NOT NULL GROUP BY folder ORDER BY folder
                """)
            return rows.compactMap { row in
                guard let folder: String = row["folder"] else { return nil }
                let count: Int = row["n"] ?? 0
                return (folder: folder, count: count)
            }
        }
    }

    /// Fetch specific assets by id (export / batch operations where the
    /// selection may span beyond the loaded grid page).
    func fetchAssets(ids: [Int64]) throws -> [DAMAsset] {
        try dbQueue.read { db in
            try DAMAsset.fetchAll(db, keys: ids)
        }
    }

    /// Fetch a single asset by its absolute file path. Returns nil if not found.
    func asset(withPath path: String) throws -> DAMAsset? {
        try dbQueue.read { db in
            try DAMAsset
                .filter(DAMAsset.Columns.path == path)
                .fetchOne(db)
        }
    }

    /// FTS5 search across filename/caption/keywords/OCR text, optionally
    /// scoped to a folder subtree. Returns matching asset rowids in rank order.
    func searchAssetIDs(matching query: String, folder: String?, limit: Int) throws -> [Int64] {
        // Quote the raw query as an FTS5 phrase to keep special characters
        // (e.g. hyphens, colons) from being parsed as FTS5 operators.
        let phrase = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try dbQueue.read { db in
            if let folder {
                return try Int64.fetchAll(db, sql: """
                    SELECT assetSearch.rowid
                    FROM assetSearch JOIN asset a ON a.id = assetSearch.rowid
                    WHERE assetSearch MATCH ?
                      AND (a.folder = ? OR (a.folder >= ? AND a.folder < ?))
                    ORDER BY rank LIMIT ?
                    """, arguments: [phrase, folder, folder + "/", folder + "0", limit])
            }
            return try Int64.fetchAll(db, sql: """
                SELECT rowid FROM assetSearch
                WHERE assetSearch MATCH ?
                ORDER BY rank LIMIT ?
                """, arguments: [phrase, limit])
        }
    }

    // MARK: - Search + Filters

    /// Shared WHERE clause for the toolbar filters, for both the plain browse
    /// path and FTS search. Columns are referenced with the `a.` alias (the
    /// asset table). Keeping this in one place is what guarantees the results
    /// list and the "N items" count can never disagree.
    private static func assetFilterSQL(
        minRating: Int, tagColor: Int?, fileType: String?,
        tagged: Bool?, flag: DAMFlag?, folder: String?
    ) -> (sql: String, args: [any DatabaseValueConvertible]) {
        var clauses = ["a.rating >= ?"]
        var args: [any DatabaseValueConvertible] = [minRating]
        if let tagColor {
            // Match any tag in the JSON dict with this color index
            clauses.append(#"(a.tagColors LIKE ? OR a.tagColors LIKE ?)"#)
            args.append("%\":\(tagColor),%")   // mid-dict: "tag":7,
            args.append("%\":\(tagColor)}")    // end-dict: "tag":7}
        }
        if let fileType {
            clauses.append("a.uti LIKE ?")
            args.append("%\(fileType)%")
        }
        if let tagged {
            clauses.append(tagged
                ? "(a.xattrKeywords IS NOT NULL AND a.xattrKeywords != '')"
                : "(a.xattrKeywords IS NULL OR a.xattrKeywords = '')")
        }
        if let flag {
            clauses.append("a.flag = ?")
            args.append(flag.rawValue)
        }
        if let folder {
            // Range scan [folder+"/", folder+"0") covers the subtree, indexed.
            clauses.append("(a.folder = ? OR (a.folder >= ? AND a.folder < ?))")
            args.append(folder)
            args.append(folder + "/")
            args.append(folder + "0")
        }
        return (clauses.joined(separator: " AND "), args)
    }

    /// Quote a raw search string as an FTS5 phrase so special characters
    /// (hyphens, colons) aren't parsed as FTS5 operators.
    private static func ftsPhrase(for query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// FTS search WITH the toolbar filters applied, rank-ordered and paginated.
    /// (The old searchAssetIDs path ignored filters and offset, so filtered
    /// counts disagreed and "load more" repeated page 1.)
    func searchAssets(
        matching query: String, folder: String?, minRating: Int,
        tagColor: Int? = nil, fileType: String? = nil,
        tagged: Bool? = nil, flag: DAMFlag? = nil,
        limit: Int, offset: Int
    ) throws -> [DAMAsset] {
        let phrase = Self.ftsPhrase(for: query)
        let (filterSQL, filterArgs) = Self.assetFilterSQL(
            minRating: minRating, tagColor: tagColor, fileType: fileType,
            tagged: tagged, flag: flag, folder: folder)
        return try dbQueue.read { db in
            var args: [any DatabaseValueConvertible] = [phrase]
            args.append(contentsOf: filterArgs)
            args.append(limit)
            args.append(offset)
            return try DAMAsset.fetchAll(db, sql: """
                SELECT a.* FROM asset a
                JOIN assetSearch ON assetSearch.rowid = a.id
                WHERE assetSearch MATCH ? AND \(filterSQL)
                ORDER BY assetSearch.rank
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(args))
        }
    }

    /// Count of FTS search results with the same filters — keeps the
    /// "N items" label consistent with what's actually shown.
    func searchAssetCount(
        matching query: String, folder: String?, minRating: Int,
        tagColor: Int? = nil, fileType: String? = nil,
        tagged: Bool? = nil, flag: DAMFlag? = nil
    ) throws -> Int {
        let phrase = Self.ftsPhrase(for: query)
        let (filterSQL, filterArgs) = Self.assetFilterSQL(
            minRating: minRating, tagColor: tagColor, fileType: fileType,
            tagged: tagged, flag: flag, folder: folder)
        return try dbQueue.read { db in
            var args: [any DatabaseValueConvertible] = [phrase]
            args.append(contentsOf: filterArgs)
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset a
                JOIN assetSearch ON assetSearch.rowid = a.id
                WHERE assetSearch MATCH ? AND \(filterSQL)
                """, arguments: StatementArguments(args)) ?? 0
        }
    }
}
