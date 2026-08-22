import Foundation
import GRDB
import UniformTypeIdentifiers

// MARK: - Lightroom Catalog CSV Importer
//
// Imports a Lightroom catalog CSV export into the MaestroDAM catalog:
//   • Assets upserted by absolute path (root folder + CSV relative path) —
//     rating, pick flag, color label, capture time, dimensions.
//   • Keywords → DAM tag tree (source `user`) + userKeywords mirror, which
//     makes Lightroom-keyworded assets instant EXEMPLARS for the AI
//     learn-as-you-tag engine.
//   • Custom (non-color) Lightroom labels — e.g. a label set of people
//     names — are imported as tags too, since they carry semantics.
//   • The folder hierarchy in `full_path` becomes a DAMCollection tree
//     (kind `folder`, parent chains) and assets link to their leaf
//     collection — Lightroom's organizational structure survives the move.
//
// Assets are upserted even when the file is missing on disk (offline-volume
// friendly: the catalog records what Lightroom knew; thumbnails/enrichment
// catch up when the volume mounts). Follows the DAMImportService actor +
// progress-callback pattern. Batches of 1,000 rows per transaction.

actor DAMLightroomImporter {

    static let shared = DAMLightroomImporter()

    /// Reference box so @Sendable batch closures can mutate the per-run
    /// find-or-create caches (inout vars can't cross that boundary).
    /// Safe under @unchecked Sendable: batches are serialized by the actor.
    private final class ImportCaches: @unchecked Sendable {
        var tags: [String: Int64] = [:]
        var collections: [String: Int64] = [:]
    }

    struct ImportResult: Sendable {
        var scanned = 0
        var inserted = 0
        var updated = 0
        var keywordsApplied = 0
        var labelsTagged = 0
        var collectionsCreated = 0
        var missingOnDisk = 0
    }

    enum ImporterError: Error, LocalizedError {
        case unreadableFile
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "Could not read the CSV file (UTF-8 expected)."
            case .missingColumns(let names):
                return "CSV is missing required column(s): \(names.joined(separator: ", "))"
            }
        }
    }

    /// Import the Lightroom CSV at `csvURL`, resolving each row's
    /// `full_path` against `root` (the folder that CONTAINS the Lightroom
    /// top-level folders, e.g. the parent of "Photos").
    @discardableResult
    func importCSV(
        at csvURL: URL,
        root: URL,
        database: DAMDatabase = .shared,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ImportResult {
        guard let text = try? String(contentsOf: csvURL, encoding: .utf8) else {
            throw ImporterError.unreadableFile
        }
        let rows = LightroomCSVParser.parse(text)
        guard let header = rows.first else { return ImportResult() }
        let columns = LightroomCSVParser.headerIndex(header)

        let required = ["filename", "full_path"]
        let missing = required.filter { columns[$0] == nil }
        guard missing.isEmpty else { throw ImporterError.missingColumns(missing) }

        let dataRows = Array(rows.dropFirst())
        let total = dataRows.count
        var result = ImportResult()

        // Per-run caches (tag name → id, collection path → id) keep the
        // 160K-row import from re-querying for every keyword/folder.
        let caches = ImportCaches()

        let batchSize = 1000
        var index = 0
        while index < dataRows.count {
            try Task.checkCancellation()
            let batch = Array(dataRows[index..<min(index + batchSize, dataRows.count)])
            let batchResult = try await database.dbQueue.write { db in
                Self.importBatch(
                    batch, columns: columns, root: root, db: db, caches: caches)
            }
            result.scanned += batchResult.scanned
            result.inserted += batchResult.inserted
            result.updated += batchResult.updated
            result.keywordsApplied += batchResult.keywordsApplied
            result.labelsTagged += batchResult.labelsTagged
            result.collectionsCreated += batchResult.collectionsCreated
            result.missingOnDisk += batchResult.missingOnDisk
            index += batch.count
            progress?(index, total)
        }
        return result
    }

    // MARK: - Batch import (runs inside one write transaction)

    private static func importBatch(
        _ rows: [[String]],
        columns: [String: Int],
        root: URL,
        db: GRDB.Database,
        caches: ImportCaches
    ) -> ImportResult {
        var result = ImportResult()
        for row in rows {
            result.scanned += 1
            guard let fullPath = value("full_path", in: row, columns: columns),
                  !fullPath.isEmpty else { continue }
            let filename = value("filename", in: row, columns: columns)
                ?? (fullPath as NSString).lastPathComponent
            let absolutePath = root.appendingPathComponent(fullPath).path

            // Upsert the asset by absolute path.
            var asset = try? DAMAsset
                .filter(DAMAsset.Columns.path == absolutePath)
                .fetchOne(db)
            let isNew = asset == nil
            if asset == nil {
                asset = DAMAsset(
                    id: nil, path: absolutePath, filename: filename,
                    folder: (absolutePath as NSString).deletingLastPathComponent,
                    uti: utiFor(filename: filename,
                                format: value("fileformat", in: row, columns: columns)),
                    fileSize: nil, fileModDate: nil,
                    width: intValue("width", in: row, columns: columns),
                    height: intValue("height", in: row, columns: columns),
                    duration: nil, rating: 0, colorLabel: .none, flag: .none,
                    captureDate: nil, cameraMake: nil, cameraModel: nil,
                    lensModel: nil, iso: nil, aperture: nil, shutterSpeed: nil,
                    focalLength: nil, gpsLat: nil, gpsLon: nil, orientation: 1,
                    perceptualHash: nil, xattrKeywords: nil, tagColors: nil,
                    aiCaption: nil, aiKeywords: nil, ocrText: nil,
                    userKeywords: nil, indexedAt: Date(), aiIndexedAt: nil)
            }
            guard var working = asset else { continue }

            // Metadata: CSV wins only where it carries a value; existing DAM
            // edits are otherwise preserved.
            var changed = false
            if let ratingRaw = value("rating", in: row, columns: columns) {
                let rating = Int(Double(ratingRaw) ?? 0)
                if rating != working.rating {
                    working.rating = rating
                    changed = true
                }
            }
            if let pickRaw = value("pick", in: row, columns: columns),
               let pick = Double(pickRaw) {
                let flag: DAMFlag = pick < 0 ? .reject : (pick > 0 ? .pick : .none)
                if flag != .none, flag != working.flag {
                    working.flag = flag
                    changed = true
                }
            }
            var labelAsTag: String?
            if let label = value("colorlabels", in: row, columns: columns)?
                .trimmingCharacters(in: .whitespaces), !label.isEmpty {
                if let mapped = Self.knownLabels[label.lowercased()], mapped != .none {
                    if mapped != working.colorLabel {
                        working.colorLabel = mapped
                        changed = true
                    }
                } else if Self.knownLabels[label.lowercased()] == nil {
                    // Custom Lightroom label set entry (e.g. a person's name)
                    // → semantic tag instead of a color.
                    labelAsTag = label
                }
            }
            if working.captureDate == nil,
               let captureRaw = value("capturetime", in: row, columns: columns),
               let date = Self.parseCaptureTime(captureRaw) {
                working.captureDate = date
                changed = true
            }

            do {
                if isNew {
                    try working.insert(db)
                    result.inserted += 1
                } else if changed {
                    try working.update(db)
                    result.updated += 1
                }
            } catch {
                NSLog("[LightroomImport] asset upsert failed for %@: %@",
                      absolutePath, "\(error)")
                continue
            }
            guard let assetId = working.id else { continue }

            // Keywords (semicolon-separated; Lightroom repeats hierarchy
            // leaves, so dedupe) → tag tree + userKeywords mirror.
            var tagNames = parseKeywords(value("keywords", in: row, columns: columns))
            if let labelAsTag { tagNames.append(labelAsTag) }
            for name in Set(tagNames) {  // dedupe within the row
                guard let tagId = tagId(for: name, db: db, caches: caches) else { continue }
                try? db.execute(sql: """
                    INSERT OR IGNORE INTO assetTag (assetId, tagId) VALUES (?, ?)
                    """, arguments: [assetId, tagId])
                mirrorKeyword(name, assetId: assetId, db: db)
                result.keywordsApplied += 1
                if name == labelAsTag { result.labelsTagged += 1 }
            }

            // Folder hierarchy → DAMCollection chain; asset links the leaf.
            let folderPath = (fullPath as NSString).deletingLastPathComponent
            if !folderPath.isEmpty {
                if let leafId = collectionId(
                    forFolderPath: folderPath, db: db,
                    caches: caches, created: &result.collectionsCreated) {
                    try? db.execute(sql: """
                        INSERT OR IGNORE INTO collectionAsset (collectionId, assetId, position)
                        VALUES (?, ?, NULL)
                        """, arguments: [leafId, assetId])
                }
            }

            if !FileManager.default.fileExists(atPath: absolutePath) {
                result.missingOnDisk += 1
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Lightroom's built-in label names (case-insensitive). Anything else —
    /// custom label sets like a person's name — is treated as a semantic tag.
    private static let knownLabels: [String: DAMColorLabel] = [
        "red": .red, "orange": .orange, "yellow": .yellow,
        "green": .green, "blue": .blue, "purple": .purple,
        "none": .none,
    ]

    private static func value(_ column: String, in row: [String],
                              columns: [String: Int]) -> String? {
        guard let index = columns[column], index < row.count else { return nil }
        let value = row[index].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func intValue(_ column: String, in row: [String],
                                 columns: [String: Int]) -> Int? {
        guard let raw = value(column, in: row, columns: columns) else { return nil }
        return Int(Double(raw) ?? 0)
    }

    private static func utiFor(filename: String, format: String?) -> String? {
        let ext = (format?.isEmpty == false ? format! : (filename as NSString).pathExtension)
            .lowercased()
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.identifier
    }

    /// "2026-06-25T12:26:58.000" (no timezone — Lightroom local time) → Date.
    private static let captureFormatterMillis: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    private static let captureFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func parseCaptureTime(_ raw: String) -> Date? {
        captureFormatterMillis.date(from: raw) ?? captureFormatter.date(from: raw)
    }

    /// Semicolon-separated keywords: trim, drop empties, dedupe (Lightroom
    /// repeats hierarchy leaves — "Alex; Alex" → one "Alex").
    private static func parseKeywords(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        return raw.split(separator: ";").compactMap { part in
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !seen.contains(name) else { return nil }
            seen.insert(name)
            return name
        }
    }

    /// Find-or-create a flat tag, cached for the whole import run.
    private static func tagId(for name: String, db: GRDB.Database,
                              caches: ImportCaches) -> Int64? {
        if let cached = caches.tags[name] { return cached }
        do {
            if let existing = try DAMTag
                .filter(DAMTag.Columns.name == name)
                .fetchOne(db), let id = existing.id {
                caches.tags[name] = id
                return id
            }
            // `inserted` returns the record with didInsert applied (id set).
            let tag = try DAMTag(id: nil, name: name, parentId: nil, source: .user)
                .inserted(db)
            caches.tags[name] = tag.id
            return tag.id
        } catch {
            NSLog("[LightroomImport] tag create failed for %@: %@", name, "\(error)")
            return nil
        }
    }

    /// Mirror a tag into the asset's `userKeywords` (legacy list/search UI)
    /// with an audit row — same convention as DAMDatabase.applyTag.
    private static func mirrorKeyword(_ name: String, assetId: Int64, db: GRDB.Database) {
        guard var asset = try? DAMAsset.fetchOne(db, key: assetId) else { return }
        let existing = (asset.userKeywords ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !existing.contains(name) else { return }
        let old = asset.userKeywords
        asset.userKeywords = (existing + [name]).joined(separator: ", ")
        try? asset.update(db)
        try? DAMDatabase.shared.recordAudit(
            db, assetId: assetId, field: "userKeywords",
            oldValue: old, newValue: asset.userKeywords,
            source: "lightroom-import")
    }

    /// Walk a folder path ("A/B/C") creating one DAMCollection per component
    /// (kind `folder`, parent chain). Returns the LEAF collection id.
    /// Cached per full path so 160K rows don't re-walk the tree.
    private static func collectionId(
        forFolderPath folderPath: String,
        db: GRDB.Database,
        caches: ImportCaches,
        created: inout Int
    ) -> Int64? {
        if let cached = caches.collections[folderPath] { return cached }
        var parentId: Int64?
        var walked = ""
        for component in folderPath.split(separator: "/").map(String.init) {
            walked = walked.isEmpty ? component : walked + "/" + component
            if let cached = caches.collections[walked] {
                parentId = cached
                continue
            }
            do {
                // Reuse an existing collection with the same name+parent
                // (previous import run), else create.
                var query = DAMCollection
                    .filter(DAMCollection.Columns.name == component
                            && DAMCollection.Columns.kind == DAMCollection.Kind.folder.rawValue)
                if let parentId {
                    query = query.filter(Column("parentId") == parentId)
                } else {
                    query = query.filter(Column("parentId") == nil)
                }
                if let existing = try query.fetchOne(db), let id = existing.id {
                    caches.collections[walked] = id
                    parentId = id
                    continue
                }
                let collection = try DAMCollection(
                    id: nil, name: component, kind: .folder,
                    predicateJSON: nil, parentId: parentId
                ).inserted(db)
                caches.collections[walked] = collection.id
                parentId = collection.id
                created += 1
            } catch {
                NSLog("[LightroomImport] collection create failed for %@: %@", walked, "\(error)")
                return nil
            }
        }
        return parentId
    }
}
