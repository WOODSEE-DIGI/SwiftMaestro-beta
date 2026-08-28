import Foundation
import GRDB
import UniformTypeIdentifiers

// MARK: - Direct .lrcat SQLite Reader
//
// Reads a Lightroom Classic catalog (.lrcat) directly without requiring
// a CSV export. The .lrcat is a standard SQLite database — opened read-only
// so the catalog is never modified.
//
// Key tables read:
//   Adobe_images           — image records (rating, pick, captureTime)
//   AgLibraryFile           — physical files (baseName, extension)
//   AgLibraryFolder         — folder hierarchy (pathFromRoot)
//   AgLibraryRootFolder     — root folders (absolutePath)
//   AgLibraryKeyword        — keyword definitions (name)
//   AgLibraryKeywordImage   — keyword ↔ image mapping
//   AgLibraryCollection     — collections (name)
//   AgLibraryCollectionImage — collection ↔ image mapping
//   AgHarvestedExifMetadata — EXIF data (camera, lens, ISO, aperture, shutter)
//
// Keywords become exemplars for the learn-as-you-tag engine.

actor DAMLrcatReader {

    static let shared = DAMLrcatReader()

    /// Brand-prefix table used to split an older Lightroom catalog's packed
    /// camera `value` into make + model ("Apple iPhone 11 Pro Max",
    /// "ILCE-7RM5", "NIKON D850"). First match wins; the full original string
    /// is always kept as the model (display clarity), the brand is only the
    /// filter dimension.
    private static let cameraBrands: [(prefix: String, brand: String)] = [
        ("Apple", "Apple"), ("Canon", "Canon"), ("EOS", "Canon"),
        ("NIKON", "Nikon"), ("SONY", "Sony"), ("ILCE", "Sony"), ("DSC", "Sony"),
        ("SAMSUNG", "Samsung"), ("FUJIFILM", "Fujifilm"), ("OLYMPUS", "Olympus"),
        ("OM System", "OM System"), ("DJI", "DJI"), ("GoPro", "GoPro"),
        ("HERO", "GoPro"), ("Leica", "Leica"), ("Panasonic", "Panasonic"),
        ("LUMIX", "Panasonic"), ("PENTAX", "Pentax"), ("RICOH", "Ricoh"),
        ("Hasselblad", "Hasselblad"), ("Motorola", "Motorola"),
        ("Google", "Google"), ("Pixel", "Google"),
    ]

    /// Splits a packed camera value into (make, model). Camera-only codes
    /// ("6120c", "AC003") return a nil make and the raw value as the model.
    static func splitCameraValue(_ value: String) -> (make: String?, model: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        for (prefix, brand) in cameraBrands where trimmed.hasPrefix(prefix) {
            return (brand, trimmed)
        }
        return (nil, trimmed)
    }

    struct ImportResult: Sendable {
        var scanned = 0
        var inserted = 0
        var updated = 0
        var keywordsApplied = 0
        var collectionsCreated = 0
        var missingOnDisk = 0
    }

    enum ReaderError: Error, LocalizedError {
        case notAFile
        case cannotOpen(String)
        case missingTable(String)

        var errorDescription: String? {
            switch self {
            case .notAFile:
                return "Selected item is not a file."
            case .cannotOpen(let path):
                return "Cannot open Lightroom catalog: \(path)"
            case .missingTable(let name):
                return "Not a valid Lightroom catalog (missing table: \(name))."
            }
        }
    }

    // MARK: - Public entry point

    @discardableResult
    func importLrcat(
        at lrcatURL: URL,
        rootOverride: URL? = nil,
        database: DAMDatabase = .shared,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ImportResult {
        guard lrcatURL.isFileURL else { throw ReaderError.notAFile }

        // Lightroom catalogs use WAL journal mode, which requires companion
        // -wal and -shm files.  If those are missing (catalog was copied/moved,
        // or on a network volume) SQLite refuses to open the file.
        //
        // Fix: copy to a temp directory, then use the sqlite3 CLI to switch
        // journal mode to DELETE (which doesn't need WAL/SHM), then open
        // with GRDB readonly.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lrcat-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempLrcat = tempDir.appendingPathComponent(lrcatURL.lastPathComponent)
        try FileManager.default.copyItem(at: lrcatURL, to: tempLrcat)

        // Switch journal mode via sqlite3 CLI (handles missing WAL/SHM gracefully).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [tempLrcat.path, "PRAGMA journal_mode = DELETE;"]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ReaderError.cannotOpen(lrcatURL.path)
        }

        // Now open with GRDB — journal mode is DELETE, no WAL/SHM needed.
        var config = GRDB.Configuration()
        config.readonly = true
        let db: GRDB.DatabasePool
        do {
            db = try GRDB.DatabasePool(path: tempLrcat.path, configuration: config)
        } catch {
            throw ReaderError.cannotOpen(lrcatURL.path)
        }

        // Verify key tables exist.
        for tableName in ["Adobe_images", "AgLibraryFile", "AgLibraryRootFolder"] {
            let exists = try await db.read { try $0.tableExists(tableName) }
            guard exists else { throw ReaderError.missingTable(tableName) }
        }

        let folderMap = try await buildFolderMap(db: db, rootOverride: rootOverride)
        let images = try await fetchAllImages(db: db)
        let total = images.count
        var result = ImportResult()

        let batchSize = 500
        var index = 0
        while index < images.count {
            try Task.checkCancellation()
            let batch = Array(images[index..<min(index + batchSize, images.count)])
            let batchResult = try await database.dbQueue.write { db in
                Self.importBatch(batch, folderMap: folderMap, db: db)
            }
            result.scanned += batchResult.scanned
            result.inserted += batchResult.inserted
            result.updated += batchResult.updated
            result.keywordsApplied += batchResult.keywordsApplied
            result.collectionsCreated += batchResult.collectionsCreated
            result.missingOnDisk += batchResult.missingOnDisk
            index += batch.count
            progress?(index, total)
        }

        // Cleanup temp copy
        try? db.close()
        try? FileManager.default.removeItem(at: tempDir)

        return result
    }

    // MARK: - Folder map (folderId → absolute path)

    private func buildFolderMap(
        db: GRDB.DatabasePool,
        rootOverride: URL?
    ) async throws -> [Int64: String] {
        try await db.read { db in
            var map: [Int64: String] = [:]

            let roots = try Row.fetchAll(db, sql:
                "SELECT id_local, absolutePath FROM AgLibraryRootFolder")
            for root in roots {
                guard var absPath = root["absolutePath"] as? String else { continue }
                if let override = rootOverride {
                    let rootName = (absPath as NSString).lastPathComponent
                    absPath = override.appendingPathComponent(rootName).path
                }
                if !absPath.hasSuffix("/") { absPath += "/" }
                map[root["id_local"] as! Int64] = absPath
            }

            let folders = try Row.fetchAll(db, sql:
                "SELECT id_local, rootFolder, pathFromRoot FROM AgLibraryFolder")
            for folder in folders {
                let rootId = folder["rootFolder"] as! Int64
                guard let rootPath = map[rootId] else { continue }
                let relPath = folder["pathFromRoot"] as? String ?? ""
                map[folder["id_local"] as! Int64] = rootPath + relPath
            }
            return map
        }
    }

    // MARK: - Fetch all images

    private struct ImageRecord: Sendable {
        var id_local: Int64
        var filename: String
        var absolutePath: String
        var fileFormat: String?
        var rating: Int?
        var pick: Double?
        var captureTime: String?
        var orientation: String?
        var width: Int?
        var height: Int?
        var keywords: [String]
        var cameraMake: String?
        var cameraModel: String?
        var lensModel: String?
        var iso: Int?
        var aperture: Double?
        var shutterSpeed: String?
        var focalLength: Double?
        var gpsLat: Double?
        var gpsLon: Double?
        var collections: [(name: String, isFolder: Bool)]
    }

    private func fetchAllImages(db: GRDB.DatabasePool) async throws -> [ImageRecord] {
        try await db.read { db in
            // Discover columns — schema varies wildly across LR versions.
            let aiCols = try Set(db.columns(in: "Adobe_images").map(\.name))
            let afCols = try Set(db.columns(in: "AgLibraryFile").map(\.name))
            let alfCols = try Set(db.columns(in: "AgLibraryFolder").map(\.name))
            let arfCols = try Set(db.columns(in: "AgLibraryRootFolder").map(\.name))

            // EXIF schema discovery — the single biggest cross-version break
            // (the 2026-08-27 flood of 'no such column' failures per image):
            //   - GPS columns are `latitude`/`longitude` on modern catalogs but
            //     `gpsLatitude`/`gpsLongitude` on older ones.
            //   - AgInternedExifCameraModel has separate `make`/`model` columns
            //     on modern catalogs but only a packed `value` ("ILCE-7RM5",
            //     "Apple iPhone 11 Pro Max") on older ones (same for
            //     AgInternedExifLens: `model` vs `value`).
            // Adaptive selects mean zero failing queries — and far less SQL.
            let exifTableExists = try db.tableExists("AgHarvestedExifMetadata")
            let ehCols: Set<String> = exifTableExists
                ? try Set(db.columns(in: "AgHarvestedExifMetadata").map(\.name)) : []
            let camTableExists = try db.tableExists("AgInternedExifCameraModel")
            let camCols: Set<String> = camTableExists
                ? try Set(db.columns(in: "AgInternedExifCameraModel").map(\.name)) : []
            let lensTableExists = try db.tableExists("AgInternedExifLens")
            let lensCols: Set<String> = lensTableExists
                ? try Set(db.columns(in: "AgInternedExifLens").map(\.name)) : []
            let gpsLatExpr: String? = ehCols.contains("latitude") ? "eh.latitude"
                : ehCols.contains("gpsLatitude") ? "eh.gpsLatitude" : nil
            let gpsLonExpr: String? = ehCols.contains("longitude") ? "eh.longitude"
                : ehCols.contains("gpsLongitude") ? "eh.gpsLongitude" : nil
            let camHasMakeModel = camCols.contains("make") && camCols.contains("model")
            let camHasValue = camCols.contains("value")
            let lensHasModel = lensCols.contains("model")
            let lensHasValue = lensCols.contains("value")

            // --- Path resolution: figure out the join chain from rootFolder → file ---
            //
            // LR6/early:  Adobe_images.rootFile → AgLibraryFile.id_local
            //             AgLibraryFile has no rootFolder; instead there's
            //             AgLibraryFile.folder → AgLibraryFolder.id_local
            //             AgLibraryFolder.rootFolder → AgLibraryRootFolder.id_local
            //
            // LR8+:       Same chain but column names may differ; some builds use
            //             AgLibraryFile.rootFolder directly.
            //
            // We discover the chain dynamically.

            // Step 1: locate the rootFolder FK on the folder table.
            //         alfCols: does AgLibraryFolder have rootFolder?
            let folderHasRootFolder = alfCols.contains("rootFolder")
            //         afCols: does AgLibraryFile have rootFolder directly?
            let fileHasRootFolder = afCols.contains("rootFolder")
            //         afCols: does AgLibraryFile have a 'folder' FK?
            let fileHasFolder = afCols.contains("folder")

            // Step 2: build the JOIN chain and absolutePath resolution.
            //
            // Strategy A (most common): file → folder → rootFolder
            //   af.folder → alf.id_local  AND  alf.rootFolder → arf.id_local
            //
            // Strategy B (some LR8+): file.rootFolder → rootFolder directly
            //   af.rootFolder → arf.id_local  (skip folder table)
            //
            // Strategy C (fallback): just grab whatever path fragments exist.

            var joinClauses: [String] = [
                "JOIN AgLibraryFile af ON af.id_local = ai.rootFile"
            ]
            var pathExpr = "''"  // fallback: empty path

            if fileHasRootFolder {
                // Strategy B: file → rootFolder directly
                joinClauses.append(
                    "LEFT JOIN AgLibraryRootFolder arf ON arf.id_local = af.rootFolder")
                pathExpr = "arf.absolutePath"
            } else if fileHasFolder && folderHasRootFolder {
                // Strategy A: file → folder → rootFolder
                joinClauses.append(
                    "JOIN AgLibraryFolder alf ON alf.id_local = af.folder")
                joinClauses.append(
                    "LEFT JOIN AgLibraryRootFolder arf ON arf.id_local = alf.rootFolder")
                // pathFromRoot lives on AgLibraryFolder
                if alfCols.contains("pathFromRoot") {
                    pathExpr = "arf.absolutePath || alf.pathFromRoot || '/'"
                } else {
                    pathExpr = "arf.absolutePath"
                }
            } else if folderHasRootFolder {
                // ai has a direct folder reference? Unlikely but handle it.
                joinClauses.append(
                    "JOIN AgLibraryFolder alf ON alf.id_local = ai.rootFile")
                joinClauses.append(
                    "LEFT JOIN AgLibraryRootFolder arf ON arf.id_local = alf.rootFolder")
                pathExpr = "arf.absolutePath || alf.pathFromRoot || '/'"
            } else {
                // Last resort: no path chain at all — we'll use the filename only.
                pathExpr = "''"
            }

            // Step 3: build SELECT columns.
            var selectCols: [String] = [
                "ai.id_local AS imageId",
                "af.baseName", "af.extension"
            ]
            // Only select pathFromRoot if AgLibraryFolder has it.
            if alfCols.contains("pathFromRoot") {
                selectCols.append("alf.pathFromRoot")
            }
            // rootPath
            if arfCols.contains("absolutePath") {
                selectCols.append("arf.absolutePath AS rootPath")
            }

            let imageColNames: [(String, String)] = [
                ("fileFormat", "ai.fileFormat"),
                ("rating", "ai.rating"),
                ("pick", "ai.pick"),
                ("captureTime", "ai.captureTime"),
                ("orientation", "ai.orientation"),
                ("width", "ai.width"),
                ("height", "ai.height")
            ]
            for (colName, selectExpr) in imageColNames where aiCols.contains(colName) {
                selectCols.append(selectExpr + " AS " + colName)
            }

            // Step 4: assemble the full query.
            let sql = """
                SELECT \(selectCols.joined(separator: ",\n       "))
                FROM Adobe_images ai
                \(joinClauses.joined(separator: "\n"))
                """

            NSLog("[LrcatImport] Query schema: af.hasRootFolder=%d, af.hasFolder=%d, alf.hasRootFolder=%d, arf.hasPath=%d",
                  fileHasRootFolder ? 1 : 0, fileHasFolder ? 1 : 0,
                  folderHasRootFolder ? 1 : 0, arfCols.contains("absolutePath") ? 1 : 0)

            let rows = try Row.fetchAll(db, sql: sql)

            var images: [ImageRecord] = []
            for row in rows {
                let imageId = row["imageId"] as! Int64
                let baseName = row["baseName"] as? String ?? ""
                let ext = row["extension"] as? String ?? ""
                let filename = ext.isEmpty ? baseName : baseName + "." + ext

                // Build absolute path from whatever columns are available.
                let rootPath = row["rootPath"] as? String ?? ""
                let relPath = row["pathFromRoot"] as? String ?? ""
                let absolutePath: String
                if rootPath.isEmpty {
                    absolutePath = filename  // no path info available
                } else if relPath.isEmpty {
                    absolutePath = rootPath + filename
                } else {
                    absolutePath = rootPath + relPath + "/" + filename
                }

                // Keywords (wrapped in try? — table may not exist in all LR versions).
                var keywords: [String] = []
                if let kwRows = try? Row.fetchAll(db, sql: """
                    SELECT ak.name FROM AgLibraryKeywordImage aki
                    JOIN AgLibraryKeyword ak ON ak.id_local = aki.tag
                    WHERE aki.image = ?
                    """, arguments: [imageId]) {
                    keywords = kwRows.compactMap { $0["name"] as? String }
                }

                // EXIF
                var cameraMake: String?
                var cameraModel: String?
                var lensModel: String?
                var iso: Int?
                var aperture: Double?
                var shutterSpeed: String?
                var focalLength: Double?
                var gpsLat: Double?
                var gpsLon: Double?

                if exifTableExists, !ehCols.isEmpty {
                    // Only select columns that actually exist in this LR build.
                    var exifCols: [String] = []
                    if ehCols.contains("isoSpeedRating") { exifCols.append("eh.isoSpeedRating AS iso") }
                    if ehCols.contains("aperture") { exifCols.append("eh.aperture AS aperture") }
                    if ehCols.contains("shutterSpeed") { exifCols.append("eh.shutterSpeed AS shutterSpeed") }
                    if ehCols.contains("focalLength") { exifCols.append("eh.focalLength AS focalLength") }
                    if let gpsLatExpr { exifCols.append("\(gpsLatExpr) AS gpsLat") }
                    if let gpsLonExpr { exifCols.append("\(gpsLonExpr) AS gpsLon") }
                    if !exifCols.isEmpty,
                       let exifRow = try? Row.fetchOne(db, sql: """
                        SELECT \(exifCols.joined(separator: ",\n       "))
                        FROM AgHarvestedExifMetadata eh
                        WHERE eh.image = ?
                        """, arguments: [imageId]) {
                        iso = exifRow["iso"] as? Int
                        aperture = exifRow["aperture"] as? Double
                        if let rawShutter = exifRow["shutterSpeed"] as? Double {
                            let divisor = pow(2.0, rawShutter)
                            shutterSpeed = "1/\(Int(divisor.rounded()))"
                        } else if let shutterStr = exifRow["shutterSpeed"] as? String,
                                  !shutterStr.isEmpty {
                            shutterSpeed = shutterStr
                        }
                        focalLength = exifRow["focalLength"] as? Double
                        gpsLat = exifRow["gpsLat"] as? Double
                        gpsLon = exifRow["gpsLon"] as? Double
                    }
                }

                // Camera/lens: separate make/model columns on modern catalogs
                // vs a single packed `value` on older ones.
                var camSelects: [String] = []
                var joinClauses: [String] = []
                if camTableExists {
                    if camHasMakeModel {
                        camSelects.append("eap.make AS cameraMake")
                        camSelects.append("eap.model AS cameraModel")
                    } else if camHasValue {
                        camSelects.append("eap.value AS cameraValue")
                    }
                    if camHasMakeModel || camHasValue {
                        joinClauses.append("LEFT JOIN AgInternedExifCameraModel eap ON eap.id_local = eh.cameraModelRef")
                    }
                }
                if lensTableExists {
                    if lensHasModel { camSelects.append("el.model AS lensModel") }
                    else if lensHasValue { camSelects.append("el.value AS lensModel") }
                    if lensHasModel || lensHasValue {
                        joinClauses.append("LEFT JOIN AgInternedExifLens el ON el.id_local = eh.lensRef")
                    }
                }
                if exifTableExists, !camSelects.isEmpty,
                   let camRow = try? Row.fetchOne(db, sql: """
                    SELECT \(camSelects.joined(separator: ",\n       "))
                    FROM AgHarvestedExifMetadata eh
                    \(joinClauses.joined(separator: "\n"))
                    WHERE eh.image = ?
                    """, arguments: [imageId]) {
                    cameraMake = camRow["cameraMake"] as? String
                    cameraModel = camRow["cameraModel"] as? String
                    lensModel = camRow["lensModel"] as? String
                    if cameraModel == nil, let packed = camRow["cameraValue"] as? String {
                        let (make, model) = Self.splitCameraValue(packed)
                        cameraMake = cameraMake ?? make
                        cameraModel = model
                    }
                }

                // Collections
                var collections: [(name: String, isFolder: Bool)] = []
                if let colRows = try? Row.fetchAll(db, sql: """
                    SELECT alc.name, alc.creationId FROM AgLibraryCollectionImage alci
                    JOIN AgLibraryCollection alc ON alc.id_local = alci.collection
                    WHERE alci.image = ?
                    """, arguments: [imageId]) {
                    for colRow in colRows {
                        let name = colRow["name"] as? String ?? ""
                        let creationId = colRow["creationId"] as? String ?? ""
                        let isFolder = creationId.contains("folder")
                        collections.append((name: name, isFolder: isFolder))
                    }
                }

                images.append(ImageRecord(
                    id_local: imageId, filename: filename,
                    absolutePath: absolutePath,
                    fileFormat: row["fileFormat"] as? String,
                    rating: row["rating"] as? Int,
                    pick: row["pick"] as? Double,
                    captureTime: row["captureTime"] as? String,
                    orientation: row["orientation"] as? String,
                    width: row["width"] as? Int,
                    height: row["height"] as? Int,
                    keywords: keywords,
                    cameraMake: cameraMake, cameraModel: cameraModel,
                    lensModel: lensModel, iso: iso,
                    aperture: aperture, shutterSpeed: shutterSpeed,
                    focalLength: focalLength,
                    gpsLat: gpsLat, gpsLon: gpsLon,
                    collections: collections
                ))
            }
            return images
        }
    }

    // MARK: - Batch import (one write transaction)

    private static func importBatch(
        _ images: [ImageRecord],
        folderMap: [Int64: String],
        db: GRDB.Database
    ) -> ImportResult {
        var result = ImportResult()
        var tagCache: [String: Int64] = [:]
        var collectionCache: [String: Int64] = [:]

        for image in images {
            result.scanned += 1
            let absolutePath = image.absolutePath

            var asset = try? DAMAsset
                .filter(DAMAsset.Columns.path == absolutePath)
                .fetchOne(db)
            let isNew = asset == nil
            if asset == nil {
                asset = DAMAsset(
                    id: nil, path: absolutePath, filename: image.filename,
                    folder: (absolutePath as NSString).deletingLastPathComponent,
                    uti: utiFor(filename: image.filename, format: image.fileFormat),
                    fileSize: nil, fileModDate: nil,
                    width: image.width, height: image.height,
                    duration: nil, rating: image.rating ?? 0,
                    colorLabel: .none, flag: flagFor(image.pick),
                    captureDate: parseCaptureTime(image.captureTime),
                    cameraMake: image.cameraMake, cameraModel: image.cameraModel,
                    lensModel: image.lensModel, iso: image.iso,
                    aperture: image.aperture, shutterSpeed: image.shutterSpeed,
                    focalLength: image.focalLength,
                    gpsLat: image.gpsLat, gpsLon: image.gpsLon,
                    orientation: orientationFor(image.orientation),
                    perceptualHash: nil, xattrKeywords: nil, tagColors: nil,
                    aiCaption: nil, aiKeywords: nil, ocrText: nil,
                    userKeywords: nil, indexedAt: Date(), aiIndexedAt: nil)
            }
            guard var working = asset else { continue }

            var changed = false
            let newRating = image.rating ?? 0
            if newRating != working.rating {
                working.rating = newRating; changed = true
            }
            let newFlag = flagFor(image.pick)
            if newFlag != .none && newFlag != working.flag {
                working.flag = newFlag; changed = true
            }
            if working.captureDate == nil,
               let date = parseCaptureTime(image.captureTime) {
                working.captureDate = date; changed = true
            }

            do {
                // inserted() (not insert()) — the plain insert resolves to the
                // non-mutating PersistableRecord overload whose didInsert
                // never fires, leaving working.id nil so the keyword and
                // collection links below are skipped for new assets.
                if isNew { working = try working.inserted(db); result.inserted += 1 }
                else if changed { try working.update(db); result.updated += 1 }
            } catch {
                NSLog("[LrcatImport] asset upsert failed: %@", "\(error)")
                continue
            }
            guard let assetId = working.id else { continue }

            // Keywords → tag tree.
            for name in Set(image.keywords) {
                guard let tagId = tagId(for: name, db: db, cache: &tagCache) else { continue }
                try? db.execute(sql:
                    "INSERT OR IGNORE INTO assetTag (assetId, tagId) VALUES (?, ?)",
                    arguments: [assetId, tagId])
                mirrorKeyword(name, assetId: assetId, db: db)
                result.keywordsApplied += 1
            }

            // Collections.
            for col in image.collections where !col.isFolder && !col.name.isEmpty {
                guard let colId = collectionId(for: col.name, db: db, cache: &collectionCache) else { continue }
                try? db.execute(sql:
                    "INSERT OR IGNORE INTO collectionAsset (collectionId, assetId, position) VALUES (?, ?, NULL)",
                    arguments: [colId, assetId])
                result.collectionsCreated += 1
            }

            if !FileManager.default.fileExists(atPath: absolutePath) {
                result.missingOnDisk += 1
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func flagFor(_ pick: Double?) -> DAMFlag {
        guard let pick else { return .none }
        if pick < 0 { return .reject }
        if pick > 0 { return .pick }
        return .none
    }

    private static func orientationFor(_ lrOrientation: String?) -> Int {
        guard let s = lrOrientation else { return 1 }
        switch s {
        case "AB": return 1
        case "DA": return 8
        case "BC": return 6
        case "CD": return 3
        default: return 1
        }
    }

    private static func utiFor(filename: String, format: String?) -> String? {
        let ext = (format?.isEmpty == false ? format! : (filename as NSString).pathExtension)
            .lowercased()
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.identifier
    }

    private static let captureFormatterFull: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let captureFormatterNoMs: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseCaptureTime(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return captureFormatterFull.date(from: raw)
            ?? captureFormatterNoMs.date(from: raw)
    }

    private static func tagId(for name: String, db: GRDB.Database,
                              cache: inout [String: Int64]) -> Int64? {
        if let cached = cache[name] { return cached }
        do {
            if let existing = try DAMTag
                .filter(DAMTag.Columns.name == name)
                .fetchOne(db), let id = existing.id {
                cache[name] = id
                return id
            }
            let tag = try DAMTag(id: nil, name: name, parentId: nil, source: .user)
                .inserted(db)
            cache[name] = tag.id
            return tag.id
        } catch {
            NSLog("[LrcatImport] tag create failed: %@ %@", name, "\(error)")
            return nil
        }
    }

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

    private static func collectionId(for name: String, db: GRDB.Database,
                                     cache: inout [String: Int64]) -> Int64? {
        if let cached = cache[name] { return cached }
        do {
            if let existing = try DAMCollection
                .filter(DAMCollection.Columns.name == name
                        && DAMCollection.Columns.kind == DAMCollection.Kind.folder.rawValue)
                .fetchOne(db), let id = existing.id {
                cache[name] = id
                return id
            }
            let collection = try DAMCollection(
                id: nil, name: name, kind: .folder,
                predicateJSON: nil, parentId: nil
            ).inserted(db)
            cache[name] = collection.id
            return collection.id
        } catch {
            NSLog("[LrcatImport] collection create failed: %@", name)
            return nil
        }
    }
}
