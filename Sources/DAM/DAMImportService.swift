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

    enum ImportError: Error, Sendable {
        case notAFolder
        case cancelled
    }

    /// File kinds the DAM catalogs in the scaffold. Extended later
    /// (sidecars, project files, fonts…).
    private static let catalogedTypes: [UTType] = [
        .image, .rawImage, .movie, .audio, .pdf
    ]

    /// Imports every catalogable file under `url` (recursive), upserting by
    /// path. Returns the number of rows written.
    /// - Parameter progress: called on progress milestones with
    ///   `(filesScanned, rowsWritten)` — safe to call from any context.
    @discardableResult
    func importFolder(
        at url: URL,
        database: DAMDatabase = .shared,
        progress: (@Sendable (_ scanned: Int, _ written: Int) -> Void)? = nil
    ) async throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImportError.notAFolder
        }

        // Enumeration runs in a synchronous helper: `NSEnumerator`'s
        // `makeIterator` is unavailable from asynchronous contexts, so the
        // scan+batch-write loop must live in a non-async function even though
        // it's only ever invoked from here.
        return try Self.scanAndImport(at: url, database: database, progress: progress)
    }

    // MARK: - Synchronous scan loop

    /// Enumerates the folder, builds assets, and writes 500-row batches.
    /// Cancellation is polled between files via `Task.checkCancellation()`
    /// (a synchronous API).
    private nonisolated static func scanAndImport(
        at url: URL,
        database: DAMDatabase,
        progress: (@Sendable (_ scanned: Int, _ written: Int) -> Void)?
    ) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey,
                                         .typeIdentifierKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ImportError.notAFolder
        }

        var scanned = 0
        var written = 0
        var pending: [(url: URL, uti: UTType, values: URLResourceValues)] = []
        pending.reserveCapacity(500)

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            guard let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .typeIdentifierKey, .isRegularFileKey
            ]), values.isRegularFile == true else { continue }

            let uti = values.typeIdentifier.flatMap { UTType($0) }
            guard let uti, catalogedTypes.contains(where: { uti.conforms(to: $0) }) else { continue }

            scanned += 1
            pending.append((fileURL, uti, values))

            if pending.count >= 500 {
                written += try processBatch(pending, to: database)
                pending.removeAll(keepingCapacity: true)
                progress?(scanned, written)
            }
        }

        written += try processBatch(pending, to: database)
        progress?(scanned, written)
        return written
    }

    /// Processes one batch of candidates: skips files whose catalog row is
    /// already up to date (same size + modification date — the delta-import
    /// fast path that makes re-running an interrupted import cheap), then
    /// extracts metadata and upserts only the new/changed remainder.
    private nonisolated static func processBatch(
        _ pending: [(url: URL, uti: UTType, values: URLResourceValues)],
        to database: DAMDatabase
    ) throws -> Int {
        guard !pending.isEmpty else { return 0 }

        let states = try existingFileStates(for: pending.map(\.url.path), in: database)
        var batch: [DAMAsset] = []
        batch.reserveCapacity(pending.count)

        for item in pending {
            if let existing = states[item.url.path],
               let newSize = item.values.fileSize.map({ Int64($0) }),
               existing.size == newSize,
               let newMod = item.values.contentModificationDate,
               abs(existing.modDate.timeIntervalSince(newMod)) < 1.0 {
                continue // unchanged — skip the ImageIO re-read entirely
            }
            batch.append(makeAsset(from: item.url, uti: item.uti, values: item.values))
        }

        guard !batch.isEmpty else { return 0 }
        try writeBatch(batch, to: database)
        return batch.count
    }

    /// One indexed lookup of existing catalog rows (path → size/modDate) for
    /// a batch of candidate paths, used by the delta-import fast path.
    private nonisolated static func existingFileStates(
        for paths: [String], in database: DAMDatabase
    ) throws -> [String: (size: Int64, modDate: Date)] {
        try database.dbQueue.read { db in
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT path, fileSize, fileModDate
                FROM asset WHERE path IN (\(placeholders))
                """, arguments: StatementArguments(paths))
            var result: [String: (size: Int64, modDate: Date)] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                guard let path: String = row["path"] else { continue }
                let size: Int64 = row["fileSize"] ?? -1
                let modDate: Date = row["fileModDate"] ?? .distantPast
                result[path] = (size, modDate)
            }
            return result
        }
    }

    // MARK: - Per-file extraction

    private nonisolated static func makeAsset(
        from url: URL, uti: UTType, values: URLResourceValues
    ) -> DAMAsset {
        var asset = DAMAsset(
            id: nil,
            path: url.path,
            filename: url.lastPathComponent,
            folder: url.deletingLastPathComponent().path,
            uti: uti.identifier,
            fileSize: values.fileSize.map { Int64($0) },
            fileModDate: values.contentModificationDate,
            width: nil, height: nil, duration: nil,
            rating: 0, colorLabel: .none, flag: .none,
            captureDate: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
            iso: nil, aperture: nil, shutterSpeed: nil, focalLength: nil,
            gpsLat: nil, gpsLon: nil, orientation: 1,
            perceptualHash: nil,
            xattrKeywords: Self.readXattrKeywords(at: url),
            aiCaption: nil, aiKeywords: nil, ocrText: nil,
            indexedAt: Date(), aiIndexedAt: nil
        )

        // ImageIO property reads invoke Apple's RAW reader on RAW files —
        // which fails (loudly) on Phase One IIQ and Capture One EIP
        // (`RA30 initImage err=-50` per file). Skip them here; LibRaw
        // supplies their thumbnails, and LibRaw-based metadata enrichment
        // for IIQ is a Phase-2 follow-up.
        let needsMetadataDecode = (uti.conforms(to: .image) || uti.conforms(to: .rawImage))
            && !DAMFileKind.shouldSkipImageIO(url)
        if needsMetadataDecode {
            Self.applyImageIOMetadata(from: url, to: &asset)
        }
        return asset
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
               let dateString = tiff[kCGImagePropertyTIFFDateTime] as? String {
                asset.captureDate = Self.parseEXIFDate(dateString)
            }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                asset.captureDate = Self.parseEXIFDate(dateString)
            }
            asset.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            asset.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                asset.iso = isoArray.first
            }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
                asset.shutterSpeed = exposure >= 1
                    ? "\(Int(exposure))s"
                    : "1/\(Int((1.0 / exposure).rounded()))s"
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

    /// EXIF dates are fixed-format `"yyyy:MM:dd HH:mm:ss"` in the camera's
    /// local zone. Parsed manually (rather than via DateFormatter) so this
    /// stays `Sendable` under strict concurrency — and it's faster per file.
    private nonisolated static func parseEXIFDate(_ string: String) -> Date? {
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

    /// Reads Finder tag names from `com.apple.metadata:_kMDItemUserTags`
    /// (a binary plist of `[name, color]` pairs) without any external
    /// dependency — same technique as the swift-xattr reference repo.
    private nonisolated static func readXattrKeywords(at url: URL) -> String? {
        let attribute = "com.apple.metadata:_kMDItemUserTags"
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
        ) as? [[Any]] else { return nil }

        let names = raw.compactMap { $0.first as? String }
        return names.isEmpty ? nil : names.joined(separator: ", ")
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
                    existing.indexedAt = asset.indexedAt
                    try existing.update(db)
                } else {
                    try asset.insert(db)
                }
            }
        }
    }
}
