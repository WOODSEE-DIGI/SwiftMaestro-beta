import AppKit
import AVFoundation
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

// MARK: - MaestroDAM Import Service
//
// Scans folders and upserts files into the catalog. Metadata is read with
// ImageIO (fast — no full pixel decode) and xattr Finder tags are harvested
// directly from `com.apple.metadata:_kMDItemUserTags` (the same store the
// MyStory keyword system uses). Writes happen in 500-row transactions so a
// huge import never blocks the browser for long.

actor DAMImportService {

    static let shared = DAMImportService()

    /// Cached tag→color consensus map, populated after the disk-wide
    /// consensus pass. Used by `enrichSingleFile` to prevent stale
    /// per-file xattr colors from overwriting consensus-corrected values.
    private static let consensusLock = NSLock()
    nonisolated(unsafe) private static var _cachedConsensus: [String: Int]?

    nonisolated static var cachedConsensus: [String: Int]? {
        consensusLock.lock()
        defer { consensusLock.unlock() }
        return _cachedConsensus
    }

    nonisolated static func setCachedConsensus(_ map: [String: Int]?) {
        consensusLock.lock()
        defer { consensusLock.unlock() }
        _cachedConsensus = map
    }

    enum ImportError: Error, Sendable {
        case notAFolder
        case cancelled
    }

    /// Imports every catalogable file under `url` (recursive), upserting by
    /// path. Returns the number of rows written.
    /// - Parameter progress: called on progress milestones with
    ///   `(filesScanned, rowsWritten)` — safe to call from any context.
    @discardableResult
    nonisolated func importFolder(
        at url: URL,
        database: DAMDatabase = .shared,
        progress: (@Sendable (_ scanned: Int, _ written: Int) -> Void)? = nil
    ) async throws -> Int {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        NSLog("[DAMImport] fileExists for %@: exists=%@ isDirectory=%@", url.path, exists ? "true" : "false", isDirectory.boolValue ? "true" : "false")
        guard exists, isDirectory.boolValue else {
            throw ImportError.notAFolder
        }

        // Security-scoped resource access: NSOpenPanel returns URLs that
        // require explicit access calls before the app can read their
        // contents. This is critical for iCloud Drive folders where files
        // may be cloud-only and the enumerator hangs without authorization.
        let accessed = url.startAccessingSecurityScopedResource()
        NSLog("[DAMImport] startAccessingSecurityScopedResource for %@ returned %@", url.path, accessed ? "true" : "false")
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        // Quick sanity check: can we even list the top-level directory?
        let topLevel = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        NSLog("[DAMImport] top-level contents of %@: %d items", url.path, topLevel.count)

        // Phase 1: Fast scan — enumerate by extension, minimal I/O.
        let count = try await Self.scanAndImport(at: url, database: database, progress: progress)
        NSLog("[DAMImport] importFolder finished for %@ — %d rows written", url.path, count)

        return count
    }

    // MARK: - Synchronous scan loop

    /// Whether a file extension belongs to a cataloged type. Used as a fast
    /// fallback when `resourceValues` can't read the UTI (e.g. iCloud
    /// cloud-only stubs whose metadata hasn't been downloaded yet).
    /// Built manually because `preferredFilenameExtension` only returns ONE
    /// extension per UTType (e.g. .image → "jpeg"), not the full set.
    nonisolated static let extensionCache: [String: String] = {
        var cache: [String: String] = [:]
        let mapping: [(extensions: [String], uti: UTType)] = [
            (["jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "heic",
              "heif", "webp", "svg", "ico", "jp2", "j2k", "jpf", "jpm",
              "mj2", "avci", "apng"], .image),
            (["arw", "cr2", "cr3", "nef", "nrw", "orf", "raf", "raw",
              "rw2", "rwl", "srw", "pef", "iiq", "3fr", "fff", "dng",
              "erf", "mef", "mos", "mrw", "sr2", "srf", "x3f"], .rawImage),
            (["mp4", "mov", "avi", "mkv", "m4v", "mpg", "mpeg", "wmv",
              "flv", "webm", "3gp", "mts", "m2ts"], .movie),
            (["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg",
              "wma", "opus", "caf"], .audio),
            (["pdf"], .pdf),
        ]
        for (extensions, uti) in mapping {
            for ext in extensions {
                cache[ext] = uti.identifier
            }
        }
        return cache
    }()

    /// Enumerates the folder, builds assets, and writes 500-row batches.
    /// Uses extension-based type detection only (no resourceValues) to
    /// avoid blocking on iCloud cloud-only files whose metadata requires
    /// a download before it can be read.
    private nonisolated static func scanAndImport(
        at url: URL,
        database: DAMDatabase,
        progress: (@Sendable (_ scanned: Int, _ written: Int) -> Void)?
    ) async throws -> Int {
        // No includingPropertiesForKeys — avoids blocking on iCloud files.
        // Extension-based detection is fast and sufficient for cataloging.
        // Descend into package directories (e.g. .dsbundle sample libraries)
        // so their audio files are cataloged. The extension whitelist below
        // still filters out non-catalogable files inside those bundles.
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.notAFolder
        }

        // Collect URLs synchronously first; `FileManager.enumerator` is not
        // available in async contexts, but batch processing needs to await
        // the volume store.
        var collectedURLs = enumerator.allObjects.compactMap { $0 as? URL }

        // Fallback: some security-scoped / external-volume URLs return an
        // empty URL enumerator even though the directory is readable. The
        // path-based enumerator often works in that case.
        if collectedURLs.isEmpty {
            NSLog("[DAMImport] URL enumerator found 0 files; trying path-based fallback for %@", url.path)
            if let pathEnumerator = FileManager.default.enumerator(atPath: url.path) {
                collectedURLs = pathEnumerator.allObjects.compactMap { item in
                    guard let relativePath = item as? String else { return nil }
                    return url.appendingPathComponent(relativePath)
                }
            } else {
                NSLog("[DAMImport] path-based enumerator is also nil for %@", url.path)
            }
        }

        var scanned = 0
        var skipped = 0
        var written = 0
        var pending: [(url: URL, uti: UTType)] = []
        pending.reserveCapacity(500)

        for fileURL in collectedURLs {
            try Task.checkCancellation()

            let ext = fileURL.pathExtension.lowercased()
            let uti: UTType
            if !ext.isEmpty,
               let utiID = extensionCache[ext],
               let cached = UTType(utiID) {
                uti = cached
            } else if !ext.isEmpty,
                      let dynamic = UTType(filenameExtension: ext) {
                // Fallback for extensions not in the static cache (e.g.
                // niche audio formats or new RAW variants). Guard against
                // ambiguous extensions like `.ts` (TypeScript vs MPEG-TS)
                // by using the content-aware DAMFileKind classifier.
                uti = dynamic
            } else {
                skipped += 1
                continue
            }

            guard DAMFileKind.kind(for: fileURL) != "unknown" else {
                skipped += 1
                continue
            }

            scanned += 1
            pending.append((fileURL, uti))

            // Fire progress every 100 files so the UI updates during
            // large scans (not just at 500-file batch boundaries).
            if scanned % 100 == 0 {
                progress?(scanned, written)
            }

            if pending.count >= 500 {
                written += try await processBatch(pending, to: database)
                pending.removeAll(keepingCapacity: true)
                progress?(scanned, written)
            }
        }

        // Process remaining batch
        if !pending.isEmpty {
            written += try await processBatch(pending, to: database)
        }

        // Final progress callback
        progress?(scanned, written)
        NSLog("[DAMImport] scanAndImport finished for %@ — scanned=%ld skipped=%ld written=%ld", url.path, scanned, skipped, written)
        return written
    }

    /// Creates a catalog entry from a URL and UTI, reading metadata
    /// inline. `attributesOfItem` is fast even on cloud stubs (5ms).
    /// `readXattrKeywords` reads Finder tags. ImageIO reads EXIF for
    /// locally-available images. Cloud-only files that fail any step
    /// get nil for that field.
    private nonisolated static func makeAsset(
        from url: URL, uti: UTType
    ) async -> DAMAsset {
        // Minimal catalog entry — zero file I/O. The background enrichAll
        // pass fills in size, tags, EXIF after the fast scan completes.
        let volume = await DAMVolumeStore.shared.volumeInfo(for: url)
        let relativePath = await DAMVolumeStore.shared.relativePath(for: url)
        return DAMAsset(
            id: nil,
            path: url.path,
            filename: url.lastPathComponent,
            folder: url.deletingLastPathComponent().path,
            uti: uti.identifier,
            kind: DAMFileKind.kind(for: url),
            fileSize: nil, fileModDate: nil,
            volumeId: volume?.id,
            relativePath: relativePath,
            isAvailable: true,
            lastVerifiedAt: Date(),
            width: nil, height: nil, duration: nil,
            rating: 0, colorLabel: .none, flag: .none,
            captureDate: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
            iso: nil, aperture: nil, shutterSpeed: nil, focalLength: nil,
            gpsLat: nil, gpsLon: nil, orientation: 1,
            perceptualHash: nil, xattrKeywords: nil,
            aiCaption: nil, aiKeywords: nil, ocrText: nil,
            indexedAt: Date(), aiIndexedAt: nil
        )
    }

    /// ImageIO `CGImageSource` properties — dimensions, EXIF, TIFF, GPS.
    /// Uses `CGImageSourceCreateWithURL` without decoding pixels.
    private nonisolated static func applyImageIOMetadata(from url: URL, to asset: inout DAMAsset) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }

        asset.width = props[kCGImagePropertyPixelWidth] as? Int
        asset.height = props[kCGImagePropertyPixelHeight] as? Int
        asset.orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            asset.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            asset.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            if asset.captureDate == nil,
               let ds = tiff[kCGImagePropertyTIFFDateTime] as? String {
                asset.captureDate = parseEXIFDate(ds)
            }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let ds = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                asset.captureDate = parseEXIFDate(ds) ?? asset.captureDate
            }
            asset.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            asset.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                asset.iso = isoArr.first
            }
            if let exp = exif[kCGImagePropertyExifExposureTime] as? Double, exp > 0 {
                asset.shutterSpeed = exp >= 1
                    ? "\(Int(exp))s"
                    : "1/\(Int((1.0 / exp).rounded()))s"
            }
            asset.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String
                asset.gpsLat = (ref == "S") ? -lat : lat
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String
                asset.gpsLon = (ref == "W") ? -lon : lon
            }
        }
    }

    /// Enriches a single file: reads size, xattr tags, and ImageIO EXIF,
    /// then updates the catalog row. Returns the updated asset or nil.
    nonisolated static func enrichSingleFile(
        path: String, database: DAMDatabase
    ) async -> DAMAsset? {
        let url = URL(fileURLWithPath: path)

        var fileSize: Int64?
        var modDate: Date?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            fileSize = (attrs[.size] as? Int).map(Int64.init)
            modDate = attrs[.modificationDate] as? Date
        }

        let tags = readXattrTags(at: url)
        let starRating = readXattrStarRating(at: url)

        // Apply consensus to override stale per-file xattr colors.
        // Uses the cached consensus from enrichAll's Phase 2 if available;
        // otherwise does a quick inline Spotlight vote for just this file's
        // tags so the first click before enrichment completes still gets
        // the correct colors.
        let correctedColors: String? = {
            guard let json = tags.colors,
                  let data = json.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
            else { return tags.colors }

            // Use cached consensus if available, otherwise build a mini
            // consensus from Spotlight for just the tags on this file.
            let consensus: [String: Int]
            if let cached = cachedConsensus, !cached.isEmpty {
                consensus = cached
            } else {
                var inline: [String: Int] = [:]
                for tag in map.keys {
                    if let winner = diskWideColorVote(forTag: tag) {
                        inline[tag] = winner
                    }
                }
                guard !inline.isEmpty else { return tags.colors }
                consensus = inline
            }

            var corrected = map
            var changed = false
            for (tag, color) in map {
                if let winner = consensus[tag], winner != color {
                    corrected[tag] = winner
                    changed = true
                }
            }
            guard changed else { return tags.colors }
            return (try? JSONSerialization.data(withJSONObject: corrected))
                .flatMap { String(data: $0, encoding: .utf8) }
        }()

        var w: Int?
        var h: Int?
        var capDate: Date?
        var camMake: String?
        var camModel: String?
        var lens: String?
        var isoVal: Int?
        var aper: Double?
        var shut: String?
        var focal: Double?
        var lat: Double?
        var lon: Double?
        var orient = 1
        var duration: Double?

        let ext = (path as NSString).pathExtension.lowercased()
        if let utiID = extensionCache[ext],
           let uti = UTType(utiID),
           (uti.conforms(to: .image) || uti.conforms(to: .rawImage)),
           !DAMFileKind.shouldSkipImageIO(url),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {

            w = props[kCGImagePropertyPixelWidth] as? Int
            h = props[kCGImagePropertyPixelHeight] as? Int
            orient = props[kCGImagePropertyOrientation] as? Int ?? 1

            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                camMake = tiff[kCGImagePropertyTIFFMake] as? String
                camModel = tiff[kCGImagePropertyTIFFModel] as? String
                if let ds = tiff[kCGImagePropertyTIFFDateTime] as? String {
                    capDate = parseEXIFDate(ds)
                }
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let ds = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    capDate = parseEXIFDate(ds) ?? capDate
                }
                lens = exif[kCGImagePropertyExifLensModel] as? String
                aper = exif[kCGImagePropertyExifFNumber] as? Double
                if let arr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                    isoVal = arr.first
                }
                if let exp = exif[kCGImagePropertyExifExposureTime] as? Double, exp > 0 {
                    shut = exp >= 1 ? "\(Int(exp))s" : "1/\(Int((1.0/exp).rounded()))s"
                }
                focal = exif[kCGImagePropertyExifFocalLength] as? Double
            }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                if let v = gps[kCGImagePropertyGPSLatitude] as? Double {
                    let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String
                    lat = (ref == "S") ? -v : v
                }
                if let v = gps[kCGImagePropertyGPSLongitude] as? Double {
                    let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String
                    lon = (ref == "W") ? -v : v
                }
            }
        }

        // Audio/video duration from AVFoundation. The list view's Duration
        // column relies on this for both movie and audio rows.
        let kind = DAMFileKind.kind(for: url)
        let mediaUTI = UTType(filenameExtension: ext)
        if kind == "audio" || kind == "movie" ||
           mediaUTI?.conforms(to: .audio) == true ||
           mediaUTI?.conforms(to: .movie) == true {
            let mediaAsset = AVURLAsset(url: url)
            if let cmTime = try? await mediaAsset.load(.duration), CMTimeGetSeconds(cmTime).isFinite {
                duration = CMTimeGetSeconds(cmTime)
            }
        }

        // Capture into Sendable tuple before DB closure
        let update = (
            fileSize: fileSize, modDate: modDate, xattr: tags.names,
            tagColors: correctedColors,
            w: w, h: h, orient: orient,
            capDate: capDate, camMake: camMake, camModel: camModel,
            lens: lens, isoVal: isoVal, aper: aper, shut: shut,
            focal: focal, lat: lat, lon: lon, duration: duration,
            rating: starRating
        )

        // Update DB
        try? await database.dbQueue.write { db in
            guard var a = try DAMAsset
                .filter(DAMAsset.Columns.path == path)
                .fetchOne(db) else { return }
            if let v = update.fileSize { a.fileSize = v }
            if let v = update.modDate { a.fileModDate = v }
            if let v = update.xattr { a.xattrKeywords = v }
            if let v = update.tagColors { a.tagColors = v }
            if let v = update.w { a.width = v }
            if let v = update.h { a.height = v }
            a.orientation = update.orient
            if let v = update.capDate { a.captureDate = v }
            if let v = update.camMake { a.cameraMake = v }
            if let v = update.camModel { a.cameraModel = v }
            if let v = update.lens { a.lensModel = v }
            if let v = update.isoVal { a.iso = v }
            if let v = update.aper { a.aperture = v }
            if let v = update.shut { a.shutterSpeed = v }
            if let v = update.focal { a.focalLength = v }
            if let v = update.lat { a.gpsLat = v }
            if let v = update.lon { a.gpsLon = v }
            if let v = update.duration { a.duration = v }
            if let v = update.rating, v > 0 { a.rating = v }
            try a.update(db)
        }

        // Return the updated asset from DB
        return try? await database.dbQueue.read { db in
            try DAMAsset.filter(DAMAsset.Columns.path == path).fetchOne(db)
        }
    }

    /// Enriches metadata for all cataloged assets that are missing
    /// xattr tags. Runs in the background after import with progress
    /// reporting. Reads file size, xattr Finder tags, and ImageIO EXIF
    /// in batches of 500 for database safety.
    ///
    /// After the per-file pass, a consensus pass corrects stale per-file
    /// xattr color indices. macOS Finder resolves tag colors from the
    /// system tag definition store (not readable by third-party apps),
    /// so the per-file xattr color index is only a snapshot from when the
    /// tag was applied. When the same tag name appears with different
    /// color indices across files, the majority wins — that matches the
    /// system definition.
    nonisolated func enrichAll(
        database: DAMDatabase = .shared,
        progress: (@Sendable (_ enriched: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        // Run the quick, high-value Spotlight backfills FIRST so duration and
        // rating KPIs populate quickly. The heavier per-file xattr/EXIF pass
        // can take a long time on large catalogs; if it runs first, these
        // backfills may never be reached before a crash or quit.

        // Phase A: Duration backfill from Spotlight — catches video/audio
        // files whose kind was mis-classified or where the previous per-file
        // AVFoundation fallback never finished.
        try await Self.backfillDurations(database: database)

        // Phase B: Star-rating backfill — Finder/Photos ratings that were
        // never imported because the catalog predates rating extraction.
        try await Self.backfillRatings(database: database)

        // Phase C: Finder xattr star-rating backfill — catches ratings from
        // Finder, Photos export, Lightroom export, Capture One export, etc.
        try await Self.backfillFinderRatings(database: database)

        // Phase 1: Fast pass — file size + xattr tags only. Sub-ms per
        // file, processes all 473K in ~1-2 minutes. No ImageIO.
        // Enriches files missing EITHER xattrKeywords OR tagColors so that
        // a previous partial pass (or a writeBatch that set xattrKeywords
        // without colors) gets completed.
        let paths: [String] = try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT path FROM asset
                WHERE xattrKeywords IS NULL
                   OR (tagColors IS NULL AND xattrKeywords IS NOT NULL AND xattrKeywords != '')
                ORDER BY
                  CASE WHEN path LIKE '/Users/%' THEN 0
                       WHEN path LIKE '/Volumes/%' THEN 1
                       ELSE 2 END,
                  path
                """)
        }
        if !paths.isEmpty {
            try Self.enrichBatch(paths: paths, database: database, progress: progress)
        }

        // Phase 1b: Media duration pass — fills the Duration column for audio
        // and movie rows that were imported before duration extraction existed
        // or where the initial read failed.
        let mediaPaths: [String] = try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT path FROM asset
                WHERE duration IS NULL
                  AND (kind = 'audio' OR kind = 'movie')
                ORDER BY path
                """)
        }
        if !mediaPaths.isEmpty {
            try await Self.enrichDurationBatch(paths: mediaPaths, database: database, progress: progress)
        }

        // Phase 2: Tag color consensus — fix stale per-file xattr colors.
        try await Self.applyTagColorConsensus(database: database)
    }

    /// Resolves each tag name's true Finder color by majority vote across
    /// the whole disk (via Spotlight), then rewrites catalog rows whose
    /// stored color disagrees. The per-file xattr color index is only a
    /// snapshot from tag-apply time; the system definition lives in a
    /// private store. Disk-wide consensus reproduces it accurately.
    private nonisolated static func applyTagColorConsensus(
        database: DAMDatabase
    ) async throws {
        // Read all tagColors blobs
        let rows: [(id: Int64, tagColors: String)] = try await database.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, tagColors FROM asset
                WHERE tagColors IS NOT NULL AND tagColors != ''
                """).map { row in
                    (id: row["id"] as Int64, tagColors: row["tagColors"] as String)
                }
        }
        guard !rows.isEmpty else { return }

        var parsed: [(id: Int64, map: [String: Int])] = []
        parsed.reserveCapacity(rows.count)
        var allTags = Set<String>()
        for row in rows {
            guard let data = row.tagColors.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
            else { continue }
            parsed.append((id: row.id, map: map))
            allTags.formUnion(map.keys)
        }
        guard !allTags.isEmpty else { return }

        // For each tag name, query Spotlight for disk-wide files and
        // majority-vote the xattr color index. This matches what Finder
        // displays, since Finder resolves colors from the system tag
        // definition (which the majority of xattrs reflect).
        var consensus: [String: Int] = [:]
        for tag in allTags.sorted() {
            if let winner = diskWideColorVote(forTag: tag) {
                consensus[tag] = winner
            }
        }
        guard !consensus.isEmpty else { return }

        // Cache for use by enrichSingleFile (prevents stale xattr colors
        // from overwriting consensus-corrected values on click).
        setCachedConsensus(consensus)

        // Compute corrections outside the write closure (strict concurrency)
        let corrections: [(id: Int64, json: String)] = parsed.compactMap { entry in
            var corrected = entry.map
            var changed = false
            for (tag, color) in entry.map {
                if let winner = consensus[tag], winner != color {
                    corrected[tag] = winner
                    changed = true
                }
            }
            guard changed,
                  let data = try? JSONSerialization.data(withJSONObject: corrected),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return (id: entry.id, json: json)
        }

        guard !corrections.isEmpty else { return }
        try await database.dbQueue.write { [corrections] db in
            for c in corrections {
                try db.execute(
                    sql: "UPDATE asset SET tagColors = ? WHERE id = ?",
                    arguments: [c.json, c.id]
                )
            }
        }
    }

    /// Queries Spotlight for files carrying `tagName`, reads each file's
    /// xattr color index for that tag, and returns the majority winner.
    /// Caps at 500 samples for speed — plenty for a stable vote.
    /// Internal (not private) so DAMViewModel can use it for folder tags.
    nonisolated static func diskWideColorVote(forTag tagName: String) -> Int? {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == %@", "kMDItemUserTags", tagName)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.start()
        defer { query.stop() }

        // Wait briefly for results (Spotlight is fast for tag queries)
        let deadline = Date().addingTimeInterval(10)
        while query.isGathering, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard query.resultCount > 0 else { return nil }

        var votes: [Int: Int] = [:]
        let sampleCount = min(query.resultCount, 500)
        for i in 0..<sampleCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            let (_, colorsJSON) = readXattrTags(at: url)
            guard let json = colorsJSON,
                  let data = json.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                  let color = map[tagName] else { continue }
            votes[color, default: 0] += 1
        }
        return votes.max(by: { $0.value < $1.value })?.key
    }

    private nonisolated static func enrichBatch(
        paths: [String],
        database: DAMDatabase,
        progress: (@Sendable (_ enriched: Int, _ total: Int) -> Void)?
    ) throws {
        var enriched = 0
        let total = paths.count
        var batch: [(path: String, fileSize: Int64, modDate: Date?, xattr: String?, tagColors: String?, rating: Int?)] = []
        batch.reserveCapacity(1000)

        for path in paths {
            let url = URL(fileURLWithPath: path)

            // attributesOfItem is fast (~0.1ms) even on cloud stubs.
            var fileSize: Int64?
            var modDate: Date?
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                fileSize = (attrs[.size] as? Int).map(Int64.init)
                modDate = attrs[.modificationDate] as? Date
            }

            // Skip cloud-only stubs (no local data yet).
            guard (fileSize ?? 0) > 0 else {
                enriched += 1
                continue
            }

            let tags = readXattrTags(at: url)
            let rating = readXattrStarRating(at: url)
            batch.append((path, fileSize!, modDate, tags.names, tags.colors, rating))

            if batch.count >= 1000 {
                try writeSizeAndXattrBatch(batch, to: database)
                enriched += batch.count
                batch.removeAll(keepingCapacity: true)
                progress?(enriched, total)
            }
        }

        if !batch.isEmpty {
            try writeSizeAndXattrBatch(batch, to: database)
            enriched += batch.count
        }
        progress?(enriched, total)
    }

    /// Fast write: file size, mod date, xattr tags, tag colors, and star rating.
    private nonisolated static func writeSizeAndXattrBatch(
        _ batch: [(path: String, fileSize: Int64, modDate: Date?, xattr: String?, tagColors: String?, rating: Int?)],
        to database: DAMDatabase
    ) throws {
        try database.dbQueue.write { db in
            for item in batch {
                guard var asset = try DAMAsset
                    .filter(DAMAsset.Columns.path == item.path)
                    .fetchOne(db) else { continue }
                asset.fileSize = item.fileSize
                asset.fileModDate = item.modDate
                asset.xattrKeywords = item.xattr ?? asset.xattrKeywords
                asset.tagColors = item.tagColors ?? asset.tagColors
                if let rating = item.rating, rating > 0 {
                    asset.rating = rating
                }
                try asset.update(db)
            }
        }
    }

    /// Reads audio/video duration for media rows missing it and writes the
    /// value back to the catalog. Uses `mdls` for a fast Spotlight-based batch
    /// read, then falls back to AVFoundation for files Spotlight hasn't indexed.
    private nonisolated static func enrichDurationBatch(
        paths: [String],
        database: DAMDatabase,
        progress: (@Sendable (_ enriched: Int, _ total: Int) -> Void)?
    ) async throws {
        let total = paths.count
        var enriched = 0
        let batchSize = 500

        var index = 0
        while index < paths.count {
            try Task.checkCancellation()
            let chunk = Array(paths[index..<min(index + batchSize, paths.count)])
            index += chunk.count

            var updates: [(path: String, duration: Double)] = []
            updates.reserveCapacity(chunk.count)

            // Fast path: batch-read kMDItemDurationSeconds via mdls.
            // mdls omits path lines when every requested file has the attribute,
            // so fall back to pairing results with the input chunk order.
            let args = ["-name", "kMDItemDurationSeconds"] + chunk
            let (_, stdout, _) = await run("/usr/bin/mdls", arguments: args)
            let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let hasPathLines = lines.contains { $0.hasPrefix("/") }
            var currentPath: String?
            var chunkIndex = 0
            for line in lines {
                if line.hasPrefix("/") {
                    currentPath = line
                    continue
                }
                guard line.contains("kMDItemDurationSeconds"),
                      let eqIndex = line.firstIndex(of: "=") else { continue }
                let valueStart = line.index(after: eqIndex)
                let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
                let path: String
                if hasPathLines {
                    guard let cp = currentPath else { continue }
                    path = cp
                } else {
                    guard chunkIndex < chunk.count else { continue }
                    path = chunk[chunkIndex]
                    chunkIndex += 1
                }
                if value != "(null)", let duration = Double(value), duration > 0 {
                    updates.append((path, duration))
                }
            }

            // Fallback for files mdls couldn't index.
            let foundPaths = Set(updates.map(\.path))
            for path in chunk where !foundPaths.contains(path) {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path)
                let mediaAsset = AVURLAsset(url: url)
                guard let cmTime = try? await mediaAsset.load(.duration),
                      CMTimeGetSeconds(cmTime).isFinite,
                      CMTimeGetSeconds(cmTime) > 0 else { continue }
                updates.append((path, CMTimeGetSeconds(cmTime)))
            }

            if !updates.isEmpty {
                try writeDurationBatch(updates, to: database)
                enriched += updates.count
            }
            progress?(enriched, total)
        }
        progress?(enriched, total)
    }

    private nonisolated static func writeDurationBatch(
        _ batch: [(path: String, duration: Double)],
        to database: DAMDatabase
    ) throws {
        try database.dbQueue.write { db in
            for item in batch {
                guard var asset = try DAMAsset
                    .filter(DAMAsset.Columns.path == item.path)
                    .fetchOne(db) else { continue }
                asset.duration = item.duration
                try asset.update(db)
            }
        }
    }

    /// One-time backfill of Finder/Photos star ratings for already-cataloged
    /// assets. Uses `mdfind` to locate only files with a Spotlight rating,
    /// then `mdls` to read the value and writes it to the DB. Skipped once it
    /// has completed successfully.
    private nonisolated static func backfillRatings(
        database: DAMDatabase = .shared
    ) async throws {
        let doneKey = "dam.ratingBackfill.completed"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let (_, stdout, _) = await run("/usr/bin/mdfind", arguments: ["kMDItemStarRating > 0"])
        let paths = stdout.split(separator: "\n").map(String.init)
        guard !paths.isEmpty else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }

        let batchSize = 500
        var index = 0
        while index < paths.count {
            try Task.checkCancellation()
            let chunk = Array(paths[index..<min(index + batchSize, paths.count)])
            index += chunk.count

            var updates: [(path: String, rating: Int)] = []
            updates.reserveCapacity(chunk.count)

            let args = ["-name", "kMDItemStarRating"] + chunk
            let (_, mdlsOut, _) = await run("/usr/bin/mdls", arguments: args)
            let lines = mdlsOut.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let hasPathLines = lines.contains { $0.hasPrefix("/") }
            var currentPath: String?
            var chunkIndex = 0
            for line in lines {
                if line.hasPrefix("/") {
                    currentPath = line
                    continue
                }
                guard line.contains("kMDItemStarRating"),
                      let eqIndex = line.firstIndex(of: "=") else { continue }
                let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                let path: String
                if hasPathLines {
                    guard let cp = currentPath else { continue }
                    path = cp
                } else {
                    guard chunkIndex < chunk.count else { continue }
                    path = chunk[chunkIndex]
                    chunkIndex += 1
                }
                if value != "(null)", let rating = Int(value), rating > 0 {
                    updates.append((path, rating))
                }
            }

            if !updates.isEmpty {
                let batchUpdates = updates
                try await database.dbQueue.write { db in
                    for item in batchUpdates {
                        guard var asset = try DAMAsset
                            .filter(DAMAsset.Columns.path == item.path)
                            .fetchOne(db) else { continue }
                        asset.rating = item.rating
                        try asset.update(db)
                    }
                }
            }
        }

        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// One-time backfill of audio/video durations from Spotlight. Uses
    /// `mdfind` to locate only files with a `kMDItemDurationSeconds` value,
    /// then writes that value to the matching catalog rows.
    private nonisolated static func backfillDurations(
        database: DAMDatabase = .shared
    ) async throws {
        let doneKey = "dam.durationBackfill.completed"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let (_, stdout, _) = await run("/usr/bin/mdfind", arguments: ["kMDItemDurationSeconds > 0"])
        let paths = stdout.split(separator: "\n").map(String.init)
        guard !paths.isEmpty else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }

        let batchSize = 500
        var index = 0
        while index < paths.count {
            try Task.checkCancellation()
            let chunk = Array(paths[index..<min(index + batchSize, paths.count)])
            index += chunk.count

            var updates: [(path: String, duration: Double)] = []
            updates.reserveCapacity(chunk.count)

            let args = ["-name", "kMDItemDurationSeconds"] + chunk
            let (_, mdlsOut, _) = await run("/usr/bin/mdls", arguments: args)
            let lines = mdlsOut.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let hasPathLines = lines.contains { $0.hasPrefix("/") }
            var currentPath: String?
            var chunkIndex = 0
            for line in lines {
                if line.hasPrefix("/") {
                    currentPath = line
                    continue
                }
                guard line.contains("kMDItemDurationSeconds"),
                      let eqIndex = line.firstIndex(of: "=") else { continue }
                let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                let path: String
                if hasPathLines {
                    guard let cp = currentPath else { continue }
                    path = cp
                } else {
                    guard chunkIndex < chunk.count else { continue }
                    path = chunk[chunkIndex]
                    chunkIndex += 1
                }
                if value != "(null)", let duration = Double(value), duration > 0 {
                    updates.append((path, duration))
                }
            }

            if !updates.isEmpty {
                let batchUpdates = updates
                try await database.dbQueue.write { db in
                    for item in batchUpdates {
                        guard var asset = try DAMAsset
                            .filter(DAMAsset.Columns.path == item.path)
                            .fetchOne(db) else { continue }
                        asset.duration = item.duration
                        try asset.update(db)
                    }
                }
            }
        }

        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// One-time backfill of Finder star ratings from the
    /// `com.apple.metadata:kMDItemStarRating` extended attribute. This catches
    /// ratings applied in Finder or written by apps like Photos, Lightroom, or
    /// Capture One on export, which Spotlight does not always index.
    private nonisolated static func backfillFinderRatings(
        database: DAMDatabase = .shared
    ) async throws {
        let doneKey = "dam.finderRatingBackfill.completed"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let rows: [(id: Int64, path: String)] = try await database.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path FROM asset
                WHERE rating = 0
                ORDER BY path
                """).map { row in
                (id: row["id"] as Int64, path: row["path"] as String)
            }
        }
        guard !rows.isEmpty else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }

        let batchSize = 1000
        var index = 0
        var updated = 0
        while index < rows.count {
            try Task.checkCancellation()
            let chunk = Array(rows[index..<min(index + batchSize, rows.count)])
            index += chunk.count

            var updates: [(id: Int64, rating: Int)] = []
            for item in chunk {
                let url = URL(fileURLWithPath: item.path)
                guard let rating = readXattrStarRating(at: url), rating > 0 else { continue }
                updates.append((item.id, rating))
            }

            if !updates.isEmpty {
                let batchUpdates = updates
                try await database.dbQueue.write { db in
                    for item in batchUpdates {
                        guard var asset = try DAMAsset.fetchOne(db, key: item.id) else { continue }
                        asset.rating = item.rating
                        try asset.update(db)
                    }
                }
                updated += updates.count
            }
        }

        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Runs an external executable and returns its exit code and outputs.
    private nonisolated static func run(
        _ executable: String,
        arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let stdout = String(data: stdoutPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (255, "", String(describing: error)))
            }
        }
    }

    private nonisolated static func processBatch(
        _ pending: [(url: URL, uti: UTType)],
        to database: DAMDatabase
    ) async throws -> Int {
        guard !pending.isEmpty else { return 0 }
        var batch: [DAMAsset] = []
        batch.reserveCapacity(pending.count)
        for item in pending {
            batch.append(await makeAsset(from: item.url, uti: item.uti))
        }
        guard !batch.isEmpty else { return 0 }
        try writeBatch(batch, to: database)
        return batch.count
    }

    // MARK: - EXIF parsing and xattr reading
    nonisolated static func parseEXIFDate(_ string: String) -> Date? {
        // "2024:01:17 10:30:45" → date components
        let parts = string.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: ":").compactMap { Int($0) }
        let timeParts = parts[1].split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3, timeParts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        components.hour = timeParts[0]
        components.minute = timeParts[1]
        components.second = timeParts[2]
        return components.date
    }

    /// Reads Finder tags with color indices from `com.apple.metadata:_kMDItemUserTags`.
    /// Returns (tagNames, tagColorsJSON) where tagColorsJSON is a JSON dict
    /// mapping tag name to Finder color index:
    ///   0=none, 1=gray, 2=green, 3=purple, 4=blue, 5=yellow, 6=red, 7=orange
    nonisolated static func readXattrTags(
        at url: URL
    ) -> (names: String?, colors: String?) {
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let length = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        if length <= 0 {
            // ENODATA (aka ENOATTR on Darwin) = attribute definitively absent
            // → the file has NO Finder tags. Report "" (empty = "read, none")
            // so enrichment never retries this file. Any other error (EPERM,
            // EIO, …) = couldn't read → nil, retried on a later pass.
            return errno == ENODATA ? ("", nil) : (nil, nil)
        }

        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return getxattr(url.path, attribute, base, length, 0, XATTR_NOFOLLOW)
        }
        guard read > 0 else { return (nil, nil) }

        guard let raw = try? PropertyListSerialization.propertyList(
            from: data, options: 0, format: nil
        ) else { return (nil, nil) }

        var names: [String] = []
        var colorMap: [String: Int] = [:]

        // Current format: ["Tag Name\n7", "Another Tag\n0"]
        if let stringArray = raw as? [String] {
            for entry in stringArray {
                let parts = entry.components(separatedBy: "\n")
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                names.append(name)
                if parts.count > 1, let colorIdx = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    colorMap[name] = colorIdx
                }
            }
        }
        // Legacy format: [["Name", 7], ["Name", 0]]
        else if let nestedArray = raw as? [[Any]] {
            for pair in nestedArray {
                guard let name = pair.first as? String, !name.isEmpty else { continue }
                names.append(name)
                if pair.count > 1, let colorIdx = pair[1] as? Int {
                    colorMap[name] = colorIdx
                }
            }
        }

        // "" (not nil) = "read, no tags" — lets enrichment permanently skip
        // untagged files, and clears the catalog when a tag is removed in Finder.
        let namesStr = names.isEmpty ? "" : names.joined(separator: ", ")
        let colorsStr: String? = colorMap.isEmpty ? nil : (
            try? JSONSerialization.data(withJSONObject: colorMap)
        ).flatMap { String(data: $0, encoding: .utf8) }

        return (namesStr, colorsStr)
    }

    /// Reads Finder tag names from `com.apple.metadata:_kMDItemUserTags`.
    /// Convenience wrapper — drops color info. Use `readXattrTags` for full data.
    nonisolated static func readXattrKeywords(at url: URL) -> String? {
        readXattrTags(at: url).names
    }

    /// Reads a Finder/Photos star rating from `com.apple.metadata:kMDItemStarRating`
    /// if one exists. Returns `nil` when the attribute is absent or unreadable.
    nonisolated static func readXattrStarRating(at url: URL) -> Int? {
        let attribute = "com.apple.metadata:kMDItemStarRating"
        let length = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return getxattr(url.path, attribute, base, length, 0, XATTR_NOFOLLOW)
        }
        guard read > 0 else { return nil }
        guard let raw = try? PropertyListSerialization.propertyList(
            from: data, options: 0, format: nil
        ) else { return nil }
        return raw as? Int
    }

    // MARK: - Writes

    /// Upserts a batch by path. Existing rows keep their ratings/labels/AI
    /// fields — a rescan only refreshes file + EXIF metadata.
    private nonisolated static func writeBatch(_ batch: [DAMAsset], to database: DAMDatabase) throws {
        try database.dbQueue.write { db in
            for asset in batch {
                let existing = try DAMAsset
                    .filter(DAMAsset.Columns.path == asset.path)
                    .fetchOne(db)
                if var existing {
                    existing.fileSize = asset.fileSize
                    existing.fileModDate = asset.fileModDate
                    existing.folder = asset.folder ?? existing.folder
                    // A rescan from a currently-mounted volume refreshes volume
                    // identity and relative path; if the file moved volumes this
                    // keeps the catalog accurate.
                    existing.volumeId = asset.volumeId ?? existing.volumeId
                    existing.relativePath = asset.relativePath ?? existing.relativePath
                    existing.isAvailable = asset.isAvailable
                    existing.lastVerifiedAt = asset.lastVerifiedAt
                    // Nil-coalescing: a rescan that skipped metadata decode
                    // (IIQ/EIP) must not erase previously extracted values.
                    existing.width = asset.width ?? existing.width
                    existing.height = asset.height ?? existing.height
                    existing.captureDate = asset.captureDate ?? existing.captureDate
                    existing.cameraMake = asset.cameraMake ?? existing.cameraMake
                    existing.cameraModel = asset.cameraModel ?? existing.cameraModel
                    existing.lensModel = asset.lensModel ?? existing.lensModel
                    existing.iso = asset.iso ?? existing.iso
                    existing.aperture = asset.aperture ?? existing.aperture
                    existing.shutterSpeed = asset.shutterSpeed ?? existing.shutterSpeed
                    existing.focalLength = asset.focalLength ?? existing.focalLength
                    existing.gpsLat = asset.gpsLat ?? existing.gpsLat
                    existing.gpsLon = asset.gpsLon ?? existing.gpsLon
                    existing.xattrKeywords = asset.xattrKeywords ?? existing.xattrKeywords
                    existing.tagColors = asset.tagColors ?? existing.tagColors
                    existing.kind = asset.kind ?? existing.kind
                    existing.indexedAt = asset.indexedAt
                    try existing.update(db)
                } else {
                    try asset.insert(db)
                }
            }
        }
    }
}
