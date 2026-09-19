import Foundation
import Testing
@testable import SwiftMaestro

/// Coverage for the learn-as-you-tag tagging engine's data layer and the
/// Lightroom CSV importer. Uses in-memory catalogs (`DAMDatabase.makeForTesting`)
/// and temp files — the user's real catalog is never touched.
struct DAMTaggingTests {

    // MARK: - Helpers

    private func insertAsset(_ db: DAMDatabase, path: String) throws -> Int64 {
        try db.dbQueue.write { conn in
            let asset = try DAMAsset(
                id: nil, path: path, filename: (path as NSString).lastPathComponent,
                folder: (path as NSString).deletingLastPathComponent,
                uti: "public.jpeg", fileSize: 1000, fileModDate: Date(),
                volumeId: nil, relativePath: nil, isAvailable: true, lastVerifiedAt: Date(),
                width: 100, height: 100, duration: nil,
                rating: 0, colorLabel: .none, flag: .none,
                captureDate: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
                iso: nil, aperture: nil, shutterSpeed: nil, focalLength: nil,
                gpsLat: nil, gpsLon: nil, orientation: 1,
                perceptualHash: nil, xattrKeywords: nil, tagColors: nil,
                aiCaption: nil, aiKeywords: nil, ocrText: nil, userKeywords: nil,
                indexedAt: Date(), aiIndexedAt: nil
            ).inserted(conn)
            return try #require(asset.id)
        }
    }

    // MARK: - Tag tree + mirror + audit

    @Test func applyTagCreatesLinksAndMirrors() throws {
        let db = try DAMDatabase.makeForTesting()
        let assetId = try insertAsset(db, path: "/tmp/a.jpg")

        let inserted = try db.applyTag(name: "Invoice", to: assetId, source: .user)
        #expect(inserted)

        let tags = try db.tagNames(forAssetId: assetId)
        #expect(tags == ["Invoice"])

        let asset = try db.asset(withPath: "/tmp/a.jpg")
        #expect(asset?.userKeywords == "Invoice")

        // Idempotent: re-applying is a no-op.
        let again = try db.applyTag(name: "Invoice", to: assetId, source: .user)
        #expect(!again)
        #expect(try db.tagNames(forAssetId: assetId) == ["Invoice"])

        // Audit trail captured the tag.
        let auditCount = try db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM damAudit WHERE assetId = ? AND field = 'tag'
                """, arguments: [assetId]) ?? 0
        }
        #expect(auditCount == 1)
    }

    @Test func removeTagDetachesAndUnmirrors() throws {
        let db = try DAMDatabase.makeForTesting()
        let assetId = try insertAsset(db, path: "/tmp/b.jpg")
        try db.applyTag(name: "Receipt", to: assetId, source: .user)
        try db.removeTag(name: "Receipt", from: assetId)
        #expect(try db.tagNames(forAssetId: assetId).isEmpty)
        #expect(try db.asset(withPath: "/tmp/b.jpg")?.userKeywords == nil)
    }

    // MARK: - Suggestion queue lifecycle

    @Test func suggestionAcceptAppliesTag() throws {
        let db = try DAMDatabase.makeForTesting()
        let assetId = try insertAsset(db, path: "/tmp/c.jpg")
        try db.upsertSuggestion(assetId: assetId, tagName: "Legal",
                                confidence: 0.81, exemplarAssetId: nil, basis: .visual)

        let pending = try db.pendingSuggestions(minConfidence: 0.6, limit: 10)
        #expect(pending.count == 1)
        #expect(pending[0].suggestion.tagName == "Legal")
        #expect(pending[0].asset.path == "/tmp/c.jpg")

        let resolved = try db.acceptSuggestion(id: pending[0].suggestion.id!)
        #expect(resolved?.tagName == "Legal")
        #expect(try db.pendingSuggestions(minConfidence: 0.6, limit: 10).isEmpty)
    }

    @Test func rejectedSuggestionsNeverResurrect() throws {
        let db = try DAMDatabase.makeForTesting()
        let assetId = try insertAsset(db, path: "/tmp/d.jpg")
        try db.upsertSuggestion(assetId: assetId, tagName: "Work",
                                confidence: 0.7, exemplarAssetId: nil, basis: .ocr)
        let pending = try db.pendingSuggestions(minConfidence: 0, limit: 10)
        try db.rejectSuggestion(id: pending[0].suggestion.id!)

        // Same pair suggested again at HIGHER confidence must not reappear.
        try db.upsertSuggestion(assetId: assetId, tagName: "Work",
                                confidence: 0.95, exemplarAssetId: nil, basis: .both)
        #expect(try db.pendingSuggestions(minConfidence: 0, limit: 10).isEmpty)
    }

    @Test func pendingUpsertRaisesConfidenceOnly() throws {
        let db = try DAMDatabase.makeForTesting()
        let assetId = try insertAsset(db, path: "/tmp/e.jpg")
        try db.upsertSuggestion(assetId: assetId, tagName: "Family",
                                confidence: 0.8, exemplarAssetId: nil, basis: .visual)
        try db.upsertSuggestion(assetId: assetId, tagName: "Family",
                                confidence: 0.65, exemplarAssetId: nil, basis: .visual)
        let pending = try db.pendingSuggestions(minConfidence: 0, limit: 10)
        #expect(pending.count == 1)
        #expect(pending[0].suggestion.confidence == 0.8)
    }

    // MARK: - Exemplars & candidates

    @Test func exemplarAndUntaggedPartitioning() throws {
        let db = try DAMDatabase.makeForTesting()
        let taggedId = try insertAsset(db, path: "/tmp/tagged.jpg")
        let untaggedId = try insertAsset(db, path: "/tmp/untagged.jpg")
        try db.applyTag(name: "Kids", to: taggedId, source: .user)

        let exemplars = try db.taggedExemplars()
        // #require (not #expect) so a data-layer regression fails the test
        // gracefully — a bare subscript on an empty array crashes the whole
        // test host process and aborts every remaining suite.
        try #require(exemplars.count == 1)
        #expect(exemplars[0].tags == ["Kids"])

        let untagged = try db.untaggedAssets(requireFeatures: false, limit: 100, offset: 0)
        #expect(untagged.map(\.id) == [untaggedId])
    }

    // MARK: - Generative tag parsing

    @Test func tagListParsing() {
        let raw = """
            1. Golden Retriever
            2. Beach, Sunset
            - Sand; ocean
            """
        let tags = DAMTaggingService.parseTagList(from: raw)
        #expect(tags == ["golden retriever", "beach", "sunset", "sand", "ocean"])
    }

    @Test func tagListParsingFiltersStopWords() {
        let raw = "Image, photo, the, a, dog, of, and"
        let tags = DAMTaggingService.parseTagList(from: raw)
        #expect(tags == ["dog"])
    }

    // MARK: - Folder & collection enumeration

    @Test func assetsInFolderRecursive() throws {
        let db = try DAMDatabase.makeForTesting()
        _ = try insertAsset(db, path: "/photos/2024/cat.jpg")
        _ = try insertAsset(db, path: "/photos/2024/january/dog.jpg")
        _ = try insertAsset(db, path: "/photos/2023/old.jpg")

        let recursive = try db.assets(inFolder: "/photos/2024", recursive: true)
        #expect(recursive.count == 2)

        let direct = try db.assets(inFolder: "/photos/2024", recursive: false)
        #expect(direct.count == 1)
    }

    @Test func assetsInCollection() throws {
        let db = try DAMDatabase.makeForTesting()
        let assetA = try insertAsset(db, path: "/tmp/coll-a.jpg")
        let assetB = try insertAsset(db, path: "/tmp/coll-b.jpg")
        _ = try insertAsset(db, path: "/tmp/other.jpg")

        let collectionId = try db.dbQueue.write { conn -> Int64 in
            var collection = DAMCollection(
                id: nil, name: "Favorites", kind: .manual, predicateJSON: nil, parentId: nil)
            try collection.insert(conn)
            let id = try #require(collection.id)
            try DAMCollectionAsset(collectionId: id, assetId: assetA, position: 0).insert(conn)
            try DAMCollectionAsset(collectionId: id, assetId: assetB, position: 1).insert(conn)
            return id
        }

        let members = try db.assets(inCollectionId: collectionId)
        #expect(members.count == 2)
        #expect(Set(members.map(\.id)) == Set([assetA, assetB]))
    }

    // MARK: - OCR token normalization (pure functions)

    @Test func ocrTokenNormalization() {
        let tokens = DAMTaggingService.ocrTokens(
            from: "TAX INVOICE\nAcme Corp, the total is $1,234.00\nTax Invoice #4582")
        #expect(tokens.contains("invoice"))
        #expect(tokens.contains("acme"))
        #expect(tokens.contains("1234"))
        #expect(!tokens.contains("the"))   // stop word
        #expect(!tokens.contains("is"))    // too short
    }

    @Test func ocrJaccardScoring() {
        let exemplar: Set<String> = ["invoice", "acme", "total"]
        let candidate: Set<String> = ["invoice", "acme", "date"]
        let basis = DAMTaggingService.score(
            exemplarPrint: nil, exemplarTokens: exemplar,
            candidatePrint: nil, candidateTokens: candidate)
        guard case .ocr(let score) = basis else {
            Issue.record("Expected OCR-basis score")
            return
        }
        // |∩|=2, |∪|=4 → 0.5
        #expect(abs(score - 0.5) < 0.0001)
    }

    // MARK: - Audio AI tagging helpers

    @Test func audioTagExtractionFromTranscript() {
        let text = "Meeting with Sarah about the Q3 budget in Sydney. We discussed marketing plans."
        let tags = DAMTaggingService.extractTags(from: text)
        #expect(tags.contains("sarah"))
        #expect(tags.contains("sydney"))
        #expect(tags.contains("budget"))
        #expect(tags.contains("marketing"))
        #expect(tags.contains("plans"))
        #expect(!tags.contains("the"))
        #expect(!tags.contains("with"))
        #expect(!tags.contains("we"))
    }
}
