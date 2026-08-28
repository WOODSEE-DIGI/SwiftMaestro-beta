import XCTest
import Foundation
@testable import SwiftMaestro

/// Verification for the Lightroom-catalog schema adaptation (2026-08-27):
/// the user's real catalog uses the older EXIF layout (`gpsLatitude`/
/// `gpsLongitude` + packed camera/lens `value` instead of `latitude`/
/// `longitude` + separate `make`/`model`), and every import previously
/// flooded 'no such column: eh.latitude' / 'eap.make' per image.
///
/// The import writes into a THROWAWAY in-memory DAM database — the user's
/// real DAM catalog is never touched. Presence-gated: skips when the catalog
/// is not on disk. Import may take minutes on a ~50K-image catalog.
final class DAMLrcatRealCatalogImportTests: XCTestCase {

    private static let catalogPath =
        "/Volumes/16TB Striped/Lightroom/Lightroom Catalog.lrcat"

    func testRealCatalogImportsWithoutColumnErrors() async throws {
        let url = URL(fileURLWithPath: Self.catalogPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("catalog not present at \(Self.catalogPath)")
        }
        let testDB = try DAMDatabase.makeForTesting()
        let result = try await DAMLrcatReader.shared.importLrcat(
            at: url, database: testDB, progress: { done, total in
                if done % 2000 == 0 { NSLog("[LRCAT-TEST] progress %d/%d", done, total) }
            })
        NSLog("[LRCAT-TEST] import result: scanned=%d inserted=%d updated=%d keywordsApplied=%d collectionsCreated=%d missingOnDisk=%d",
              result.scanned, result.inserted, result.updated,
              result.keywordsApplied, result.collectionsCreated, result.missingOnDisk)

        XCTAssertGreaterThan(result.scanned, 0, "no images read from the catalog")

        // The catalog must yield real EXIF for at least some assets —
        // the old schema's failure mode silently produced none.
        let exifCount = try await testDB.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset
                WHERE cameraModel IS NOT NULL OR iso IS NOT NULL
                   OR aperture IS NOT NULL OR focalLength IS NOT NULL
                """) ?? 0
        }
        NSLog("[LRCAT-TEST] assets with EXIF metadata: %d of %d", exifCount, result.scanned)
        XCTAssertGreaterThan(exifCount, 0,
            "no EXIF data extracted — the schema adaptation didn't take")
    }

    /// Exercises splitCameraValue on the exact packed strings found in the
    /// user's real catalog.
    func testSplitCameraValueOnRealPackedValues() {
        let (m1, mod1) = DAMLrcatReader.splitCameraValue("Apple iPhone 11 Pro Max")
        XCTAssertEqual(m1, "Apple")
        XCTAssertEqual(mod1, "Apple iPhone 11 Pro Max")

        let (m2, mod2) = DAMLrcatReader.splitCameraValue("ILCE-7RM5")
        XCTAssertEqual(m2, "Sony")
        XCTAssertEqual(mod2, "ILCE-7RM5")

        let (m3, mod3) = DAMLrcatReader.splitCameraValue("6120c")
        XCTAssertNil(m3)
        XCTAssertEqual(mod3, "6120c")

        let (m4, mod4) = DAMLrcatReader.splitCameraValue("")
        XCTAssertNil(m4)
        XCTAssertNil(mod4)
    }
}
