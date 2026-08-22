import Foundation
import Testing
@testable import SwiftMaestro

/// Lightroom CSV importer coverage: RFC4180 edge cases plus a full import
/// into an in-memory catalog via a temp CSV (keywords→tags→exemplars,
/// custom labels→tags, folder tree→collections, idempotent re-import).
struct DAMLightroomImportTests {

    // MARK: - Parser edge cases

    @Test func parserHandlesQuotesCommasAndEscapedQuotes() {
        let csv = "id,notes\n1,\"hello, world\"\n2,\"say \"\"hi\"\" now\"\n3,plain\n"
        let rows = LightroomCSVParser.parse(csv)
        #expect(rows.count == 4)
        #expect(rows[1] == ["1", "hello, world"])
        #expect(rows[2] == ["2", "say \"hi\" now"])
        #expect(rows[3] == ["3", "plain"])
    }

    @Test func parserHandlesCRLFAndMissingTrailingNewline() {
        let csv = "a,b\r\n1,2\r\n3,4"
        let rows = LightroomCSVParser.parse(csv)
        #expect(rows == [["a", "b"], ["1", "2"], ["3", "4"]])
    }

    @Test func headerIndexIsCaseInsensitiveAndTrimmed() {
        let map = LightroomCSVParser.headerIndex([" Filename ", "FULL_PATH", "keywords"])
        #expect(map["filename"] == 0)
        #expect(map["full_path"] == 1)
        #expect(map["keywords"] == 2)
    }

    // MARK: - Full import

    private func makeCSV() throws -> URL {
        let csv = """
        id,filename,full_path,captureTime,rating,pick,fileFormat,width,height,colorLabels,copyName,keywords
        1,photo one.jpg,Photos/Trip/photo one.jpg,2024-03-01T10:00:00.000,5.0,0.0,JPG,100.0,200.0,Red,,Alex; Alex; Kids
        2,photo2.jpg,Photos/Trip/photo2.jpg,2024-03-02T11:00:00,1.0,0.0,JPG,300.0,400.0,Alex Stone,,"Say ""cheese"", please"
        3,plain.jpg,plain.jpg,,0.0,0.0,JPG,50.0,60.0,,,

        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-test-\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importBuildsAssetsTagsAndCollections() async throws {
        let csvURL = try makeCSV()
        defer { try? FileManager.default.removeItem(at: csvURL) }
        let root = URL(fileURLWithPath: "/tmp/lr-root")
        let db = try DAMDatabase.makeForTesting()

        let result = try await DAMLightroomImporter.shared.importCSV(
            at: csvURL, root: root, database: db)

        #expect(result.scanned == 3)
        #expect(result.inserted == 3)
        #expect(result.missingOnDisk == 3)  // /tmp/lr-root doesn't exist

        // Asset 1: rating + known color label + deduped keywords as tags.
        let one = try #require(try db.asset(withPath: "/tmp/lr-root/Photos/Trip/photo one.jpg"))
        #expect(one.rating == 5)
        #expect(one.colorLabel == .red)
        #expect(one.width == 100 && one.height == 200)
        #expect(one.captureDate != nil)
        let oneId = try #require(one.id)
        #expect(try db.tagNames(forAssetId: oneId).sorted() == ["Alex", "Kids"])
        #expect(one.userKeywords?.contains("Alex") == true)
        #expect(one.userKeywords?.contains("Kids") == true)

        // Asset 2: CUSTOM label "Alex Stone" becomes a tag (not a color),
        // and the quoted comma keyword survives intact.
        let two = try #require(try db.asset(withPath: "/tmp/lr-root/Photos/Trip/photo2.jpg"))
        #expect(two.colorLabel == .none)
        let twoId = try #require(two.id)
        let twoTags = try db.tagNames(forAssetId: twoId)
        #expect(twoTags.contains("Alex Stone"))
        #expect(twoTags.contains("Say \"cheese\", please"))

        // Folder hierarchy → collection chain: Photos (root) → Trip (child),
        // both assets linked to the leaf.
        let collections = try await db.dbQueue.read { conn in
            try DAMCollection.fetchAll(conn)
        }
        let photos = try #require(collections.first { $0.name == "Photos" })
        let trip = try #require(collections.first { $0.name == "Trip" })
        #expect(photos.parentId == nil)
        #expect(trip.parentId == photos.id)
        let linkCount = try await db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM collectionAsset WHERE collectionId = ?
                """, arguments: [trip.id]) ?? 0
        }
        #expect(linkCount == 2)

        // Tagged assets are now AI exemplars; the untagged one is a candidate.
        let exemplars = try db.taggedExemplars()
        #expect(exemplars.count == 2)
        let untagged = try db.untaggedAssets(requireFeatures: false, limit: 10, offset: 0)
        #expect(untagged.count == 1)
        #expect(untagged[0].filename == "plain.jpg")
    }

    @Test func reimportIsIdempotent() async throws {
        let csvURL = try makeCSV()
        defer { try? FileManager.default.removeItem(at: csvURL) }
        let root = URL(fileURLWithPath: "/tmp/lr-root")
        let db = try DAMDatabase.makeForTesting()

        _ = try await DAMLightroomImporter.shared.importCSV(
            at: csvURL, root: root, database: db)
        let second = try await DAMLightroomImporter.shared.importCSV(
            at: csvURL, root: root, database: db)

        #expect(second.inserted == 0)
        let tagCount = try await db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM tag") ?? 0
        }
        // 3 keyword tags + 1 custom-label tag, exactly once each.
        #expect(tagCount == 4)
        let collectionCount = try await db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM collection") ?? 0
        }
        #expect(collectionCount == 2)
    }
}
