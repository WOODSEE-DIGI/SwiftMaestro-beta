import Foundation
import GRDB

// MARK: - MaestroDAM Models
//
// GRDB records backing the MaestroDAM catalog. Schema decisions follow the
// research captured in `docs/26.07.30-MaestroDAM-Architecture.md`:
// ratings/labels/flags mirror Adobe Bridge + darktable so future XMP
// round-tripping is lossless, and the tag tree follows digiKam's hierarchical
// parent-chain model.

/// Finder/Bridge-compatible color label applied to an asset.
enum DAMColorLabel: String, Codable, Sendable, CaseIterable {
    case none, red, orange, yellow, green, blue, purple

    var displayName: String { rawValue.capitalized }
}

/// Culling flag (darktable pick/reject parity).
enum DAMFlag: String, Codable, Sendable {
    case none, pick, reject
}

/// Where a tag came from — user entry, harvested from xattr Finder tags,
/// AI keywording, OCR text, or EXIF/IPTC metadata.
enum DAMTagSource: String, Codable, Sendable {
    case user, xattr, ai, ocr, exif
}

/// A cataloged file. One row per file, keyed by absolute path.
/// `Identifiable` on the database id for SwiftUI lists.
struct DAMAsset: Codable, FetchableRecord, PersistableRecord, TableRecord,
               Identifiable, Hashable, Sendable {
    static let databaseTableName = "asset"

    var id: Int64?
    var path: String
    var filename: String
    /// Containing folder (path minus filename). Indexed — backs the folder
    /// tree and folder-scoped browsing. `nil` only for rows cataloged
    /// before migration v3 (backfill fills them).
    var folder: String?
    var uti: String?
    var fileSize: Int64?
    var fileModDate: Date?

    var width: Int?
    var height: Int?
    var duration: Double?

    var rating: Int                      // 0–5, Bridge-compatible
    var colorLabel: DAMColorLabel
    var flag: DAMFlag

    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var aperture: Double?
    var shutterSpeed: String?
    var focalLength: Double?
    var gpsLat: Double?
    var gpsLon: Double?
    var orientation: Int

    var perceptualHash: String?
    var xattrKeywords: String?
    /// JSON dict mapping tag names to Finder color indices (0=none,
    /// 1=gray, 2=green, 3=purple, 4=blue, 5=yellow, 6=red, 7=orange).
    /// Migration v5.
    var tagColors: String?
    var aiCaption: String?
    var aiKeywords: String?
    var ocrText: String?
    /// User-entered keywords (comma-separated) — migration v4. Written by
    /// the Edit workspace batch keywording; audited like ratings.
    var userKeywords: String?

    var indexedAt: Date?
    var aiIndexedAt: Date?

    enum Columns {
        static let id = Column("id")
        static let path = Column("path")
        static let filename = Column("filename")
        static let folder = Column("folder")
        static let rating = Column("rating")
        static let colorLabel = Column("colorLabel")
        static let flag = Column("flag")
        static let captureDate = Column("captureDate")
        static let indexedAt = Column("indexedAt")
    }

    enum CodingKeys: String, CodingKey {
        case id, path, filename, folder, uti, fileSize, fileModDate, width, height,
             duration, rating, colorLabel, flag, captureDate, cameraMake,
             cameraModel, lensModel, iso, aperture, shutterSpeed, focalLength,
             gpsLat, gpsLon, orientation, perceptualHash, xattrKeywords, tagColors,
             aiCaption, aiKeywords, ocrText, userKeywords, indexedAt, aiIndexedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Byte count formatted for cell subtitles.
    var formattedSize: String {
        guard let fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Pixel dimensions formatted for tooltips/subtitles.
    var formattedDimensions: String {
        guard let width, let height else { return "" }
        return "\(width)×\(height)"
    }

    // MARK: Sort keys (Metadata list view)
    //
    // Non-optional projections used by SwiftUI Table's KeyPathComparator
    // (Optional doesn't conform to Comparable). Computed only — not in
    // CodingKeys, so GRDB ignores them.

    var sortDate: Date { captureDate ?? fileModDate ?? .distantPast }
    var sortSize: Int64 { fileSize ?? -1 }
    var sortType: String { uti ?? "" }
}

/// A node in the hierarchical tag tree (`/People/Family/Celeste`).
struct DAMTag: Codable, FetchableRecord, PersistableRecord, TableRecord,
             Identifiable, Hashable, Sendable {
    static let databaseTableName = "tag"

    var id: Int64?
    var name: String
    var parentId: Int64?
    var source: DAMTagSource

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let parentId = Column("parentId")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One node in the DAM folder tree (sidebar). Built from the catalog's
/// distinct folder paths; `count` is assets directly in this folder.
struct DAMFolderNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let count: Int
    var children: [DAMFolderNode]?
}

/// Join table: asset ↔ tag.
struct DAMAssetTag: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable {
    static let databaseTableName = "assetTag"

    var assetId: Int64
    var tagId: Int64

    enum Columns {
        static let assetId = Column("assetId")
        static let tagId = Column("tagId")
    }
}

/// Folder-backed, smart, or manual grouping of assets.
/// Named `DAMCollection` to avoid ambiguity with `Swift.Collection`.
struct DAMCollection: Codable, FetchableRecord, PersistableRecord, TableRecord,
                      Identifiable, Hashable, Sendable {
    static let databaseTableName = "collection"

    enum Kind: String, Codable, Sendable {
        case folder, smart, manual
    }

    var id: Int64?
    var name: String
    var kind: Kind
    var predicateJSON: String?
    var parentId: Int64?

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let kind = Column("kind")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Join table: collection ↔ asset, with manual ordering.
struct DAMCollectionAsset: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable {
    static let databaseTableName = "collectionAsset"

    var collectionId: Int64
    var assetId: Int64
    var position: Int?

    enum Columns {
        static let collectionId = Column("collectionId")
        static let assetId = Column("assetId")
    }
}
