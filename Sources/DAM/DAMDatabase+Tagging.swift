import Foundation
import GRDB

// MARK: - AI Tagging queries (learn-as-you-tag)
//
// Query layer behind `DAMTaggingService`: feature-print/OCR-token storage,
// the exemplar pool (tagged assets), propagation candidates (untagged
// assets), tag-tree writes with the `userKeywords` mirror, and the
// suggestion queue. Everything here is synchronous GRDB — callers hop off
// the main actor themselves (the service is an actor).

extension DAMDatabase {

    // MARK: Feature storage

    /// Store (insert-or-replace) the computed AI features for one asset.
    func saveFeature(assetId: Int64, featurePrint: Data?, ocrTokens: [String],
                     classificationTags: [String]) throws {
        let tokensJSON = String(data: try JSONEncoder().encode(ocrTokens), encoding: .utf8)
        let tagsJSON = classificationTags.isEmpty ? nil :
            String(data: try JSONEncoder().encode(classificationTags), encoding: .utf8)
        try dbQueue.write { db in
            try DAMAssetFeature(
                assetId: assetId, featurePrint: featurePrint,
                ocrTokens: tokensJSON, classificationTags: tagsJSON,
                computedAt: Date()
            ).save(db)
        }
    }

    /// Fetch the feature row for one asset (nil = not yet indexed).
    func feature(forAssetId assetId: Int64) throws -> DAMAssetFeature? {
        try dbQueue.read { db in
            try DAMAssetFeature.fetchOne(db, key: assetId)
        }
    }

    /// Image-like UTIs the AI indexer works on. Mirrors the import filter's
    /// idea of "visually taggable": raster images, RAW, HEIC, TIFF, WebP.
    static let aiIndexableUTIFilter = """
        (a.uti LIKE 'public.image%' OR a.uti LIKE 'public.jpeg%'
         OR a.uti LIKE 'public.png%' OR a.uti LIKE 'public.heic%'
         OR a.uti LIKE 'public.tiff%' OR a.uti LIKE 'public.raw-image%'
         OR a.uti LIKE 'public.camera-raw-image%' OR a.uti LIKE 'com.apple.%'
         OR a.uti LIKE 'org.webmproject.webp%'
         OR a.uti LIKE 'com.adobe.raw-image%' OR a.uti LIKE 'com.canon.%'
         OR a.uti LIKE 'com.nikon.%' OR a.uti LIKE 'com.sony.%'
         OR a.uti LIKE 'com.fujifilm.%' OR a.uti LIKE 'com.olympus.%'
         OR a.uti LIKE 'com.pentax.%' OR a.uti LIKE 'com.panasonic.%')
        """

    /// Page of assets missing AI features (feature print, OCR tokens, or
    /// classification tags) — the indexing backlog. Ordered by id for a stable
    /// scan cursor.
    func featureBacklog(limit: Int, offset: Int) throws -> [DAMAsset] {
        try dbQueue.read { db in
            try DAMAsset.fetchAll(db, sql: """
                SELECT a.* FROM asset a
                LEFT JOIN assetFeature f ON f.assetId = a.id
                WHERE (f.assetId IS NULL OR f.featurePrint IS NULL
                       OR f.ocrTokens IS NULL OR f.classificationTags IS NULL)
                  AND \(Self.aiIndexableUTIFilter)
                ORDER BY a.id LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
        }
    }

    /// Backlog size — drives the Tagging workspace progress label.
    func featureBacklogCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset a
                LEFT JOIN assetFeature f ON f.assetId = a.id
                WHERE (f.assetId IS NULL OR f.featurePrint IS NULL
                       OR f.ocrTokens IS NULL OR f.classificationTags IS NULL)
                  AND \(Self.aiIndexableUTIFilter)
                """) ?? 0
        }
    }

    // MARK: Exemplars & candidates

    /// All assets carrying at least one tag-tree tag, with their tag names —
    /// the exemplar pool the k-NN propagation learns from.
    /// Tag names are joined with U+001F (unit separator — cannot appear in a
    /// tag name typed by a human) and split by the caller.
    func taggedExemplars() throws -> [(asset: DAMAsset, tags: [String])] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.*, GROUP_CONCAT(t.name, char(31)) AS maestroTagNames
                FROM asset a
                JOIN assetTag at ON at.assetId = a.id
                JOIN tag t ON t.id = at.tagId
                GROUP BY a.id
                """)
            return rows.compactMap { row in
                guard let asset = try? DAMAsset(row: row) else { return nil }
                let joined: String = row["maestroTagNames"] ?? ""
                let tags = joined.split(separator: "\u{1F}").map(String.init)
                return tags.isEmpty ? nil : (asset, tags)
            }
        }
    }

    /// Tag-tree tag names currently attached to one asset.
    func tagNames(forAssetId assetId: Int64) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT t.name FROM tag t
                JOIN assetTag at ON at.tagId = t.id
                WHERE at.assetId = ? ORDER BY t.name
                """, arguments: [assetId])
        }
    }

    /// Tag names and their sources for one asset, ordered by source then name.
    func tagNamesWithSource(forAssetId assetId: Int64) throws -> [(name: String, source: DAMTagSource)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.name, t.source FROM tag t
                JOIN assetTag at ON at.tagId = t.id
                WHERE at.assetId = ? ORDER BY t.source, t.name
                """, arguments: [assetId]).map { row in
                let source = DAMTagSource(rawValue: row["source"] as? String ?? "") ?? .user
                return (name: row["name"] as! String, source: source)
            }
        }
    }

    /// Assets with no tag-tree tags — the propagation candidates. When
    /// `requireFeatures` is true, only assets whose feature print has been
    /// computed are returned (they're the only ones the visual k-NN can score).
    func untaggedAssets(requireFeatures: Bool, limit: Int, offset: Int) throws -> [DAMAsset] {
        try dbQueue.read { db in
            if requireFeatures {
                return try DAMAsset.fetchAll(db, sql: """
                    SELECT a.* FROM asset a
                    JOIN assetFeature f ON f.assetId = a.id
                    WHERE NOT EXISTS (SELECT 1 FROM assetTag at WHERE at.assetId = a.id)
                      AND (f.featurePrint IS NOT NULL OR (f.ocrTokens IS NOT NULL AND f.ocrTokens != '[]'))
                    ORDER BY a.id LIMIT ? OFFSET ?
                    """, arguments: [limit, offset])
            }
            return try DAMAsset.fetchAll(db, sql: """
                SELECT a.* FROM asset a
                WHERE NOT EXISTS (SELECT 1 FROM assetTag at WHERE at.assetId = a.id)
                ORDER BY a.id LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
        }
    }

    // MARK: Tag writes (tree + userKeywords mirror + audit)

    /// Find-or-create a flat tag by name and attach it to the asset.
    /// Idempotent: re-applying an existing tag is a no-op returning false.
    /// Mirrors the name into `userKeywords` so the Metadata list column and
    /// FTS search stay useful, and audits both mutations in one transaction.
    @discardableResult
    func applyTag(name rawName: String, to assetId: Int64,
                  source: DAMTagSource) throws -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return try dbQueue.write { db in
            // Find-or-create the tag (flat: no parent for AI/user quick tags;
            // hierarchy arrives with the tag-tree UI phase).
            var tag = try DAMTag
                .filter(DAMTag.Columns.name == name)
                .fetchOne(db)
            if tag == nil {
                // NB: inserted() routes through the mutating insert so
                // didInsert fires and the row id is written back. A plain
                // insert(db) on a concrete PersistableRecord resolves to the
                // non-mutating overload whose didInsert never fires, leaving
                // id nil — and the guard below would silently bail without
                // linking the tag (this was the failing-DAMTaggingTests bug).
                tag = try DAMTag(id: nil, name: name, parentId: nil, source: source).inserted(db)
            }
            guard let tagId = tag?.id else { return false }

            // Attach (explicit existence check — portable idempotent insert).
            let alreadyLinked = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM assetTag WHERE assetId = ? AND tagId = ?
                """, arguments: [assetId, tagId]) ?? 0 > 0
            if !alreadyLinked {
                try DAMAssetTag(assetId: assetId, tagId: tagId).insert(db)
                try recordAudit(db, assetId: assetId, field: "tag",
                                oldValue: nil, newValue: name,
                                source: source.rawValue)
            }

            // Mirror to userKeywords for the legacy list/search UI.
            if var asset = try DAMAsset.fetchOne(db, key: assetId) {
                let existing = (asset.userKeywords ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !existing.contains(name) {
                    let old = asset.userKeywords
                    asset.userKeywords = (existing + [name]).joined(separator: ", ")
                    try asset.update(db)
                    try recordAudit(db, assetId: assetId, field: "userKeywords",
                                    oldValue: old, newValue: asset.userKeywords,
                                    source: source.rawValue)
                }
            }
            return !alreadyLinked
        }
    }

    /// Detach a tag from an asset (tag tree + userKeywords mirror). Audited.
    func removeTag(name: String, from assetId: Int64) throws {
        try dbQueue.write { db in
            if let tag = try DAMTag
                .filter(DAMTag.Columns.name == name)
                .fetchOne(db), let tagId = tag.id {
                try db.execute(sql:
                    "DELETE FROM assetTag WHERE assetId = ? AND tagId = ?",
                    arguments: [assetId, tagId])
                try recordAudit(db, assetId: assetId, field: "tag",
                                oldValue: name, newValue: nil, source: "user")
            }
            if var asset = try DAMAsset.fetchOne(db, key: assetId) {
                let old = asset.userKeywords
                let remaining = (old ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0 != name }
                let new = remaining.isEmpty ? nil : remaining.joined(separator: ", ")
                if new != old {
                    asset.userKeywords = new
                    try asset.update(db)
                    try recordAudit(db, assetId: assetId, field: "userKeywords",
                                    oldValue: old, newValue: new, source: "user")
                }
            }
        }
    }

    // MARK: Suggestion queue

    /// Insert a suggestion, or raise the confidence of an existing pending
    /// one when re-derived from a closer exemplar. Rejected/accepted rows are
    /// never resurrected — that history is the negative feedback that stops
    /// the engine re-offering the same tag for the same asset.
    func upsertSuggestion(assetId: Int64, tagName: String, confidence: Double,
                          exemplarAssetId: Int64?, basis: DAMSuggestionBasis) throws {
        try dbQueue.write { db in
            let existing = try DAMTagSuggestion
                .filter(Column("assetId") == assetId && Column("tagName") == tagName)
                .fetchOne(db)
            if var row = existing {
                if row.state == .pending && confidence > row.confidence {
                    row.confidence = confidence
                    row.exemplarAssetId = exemplarAssetId
                    row.basis = basis
                    try row.update(db)
                }
                return
            }
            try DAMTagSuggestion(
                id: nil, assetId: assetId, tagName: tagName,
                confidence: confidence, state: .pending,
                exemplarAssetId: exemplarAssetId, basis: basis,
                createdAt: Date(), resolvedAt: nil
            ).insert(db)
        }
    }

    /// Pending suggestions, highest confidence first, with their assets
    /// resolved for display. `minConfidence` implements the user's review
    /// threshold. Two-step fetch (suggestions, then assets by key) — a flat
    /// `s.*, a.*` join has ambiguous duplicate column names under GRDB Rows.
    func pendingSuggestions(minConfidence: Double, limit: Int, offset: Int = 0) throws
        -> [(suggestion: DAMTagSuggestion, asset: DAMAsset)] {
        try dbQueue.read { db in
            let suggestions = try DAMTagSuggestion
                .filter(Column("state") == DAMSuggestionState.pending.rawValue
                        && Column("confidence") >= minConfidence)
                .order(Column("confidence").desc, Column("id").asc)
                .limit(limit, offset: offset)
                .fetchAll(db)
            let assets = try DAMAsset.fetchAll(db, keys: suggestions.map(\.assetId))
            let byId = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
                asset.id.map { ($0, asset) }
            })
            return suggestions.compactMap { suggestion in
                byId[suggestion.assetId].map { (suggestion, $0) }
            }
        }
    }

    /// Count of pending suggestions at/above a confidence — the queue badge.
    func pendingSuggestionCount(minConfidence: Double) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tagSuggestion WHERE state = ? AND confidence >= ?
                """, arguments: [DAMSuggestionState.pending.rawValue, minConfidence]) ?? 0
        }
    }

    /// Pending suggestions for ONE asset, highest confidence first — the
    /// Metadata panel's AI Tagging section shows per-selection suggestions
    /// rather than the global review queue.
    func pendingSuggestions(forAssetId assetId: Int64, minConfidence: Double = 0) throws
        -> [DAMTagSuggestion] {
        try dbQueue.read { db in
            try DAMTagSuggestion
                .filter(Column("assetId") == assetId
                        && Column("state") == DAMSuggestionState.pending.rawValue
                        && Column("confidence") >= minConfidence)
                .order(Column("confidence").desc, Column("id").asc)
                .fetchAll(db)
        }
    }

    /// Mark a pending suggestion accepted and return its (assetId, tagName).
    /// The CALLER applies the tag first (see DAMTaggingService.acceptSuggestion)
    /// — this helper only flips state, and only from pending.
    func acceptSuggestion(id suggestionId: Int64) throws -> (assetId: Int64, tagName: String)? {
        try dbQueue.write { db in
            guard var row = try DAMTagSuggestion.fetchOne(db, key: suggestionId),
                  row.state == .pending else { return nil }
            row.state = .accepted
            row.resolvedAt = Date()
            try row.update(db)
            return (row.assetId, row.tagName)
        }
    }

    /// Reject a suggestion — the negative-feedback record that prevents the
    /// same (asset, tag) pair being suggested again.
    func rejectSuggestion(id suggestionId: Int64) throws {
        try dbQueue.write { db in
            guard var row = try DAMTagSuggestion.fetchOne(db, key: suggestionId),
                  row.state == .pending else { return }
            row.state = .rejected
            row.resolvedAt = Date()
            try row.update(db)
        }
    }

    /// Suggestion row for a specific (asset, tag) pair, if any.
    func suggestion(assetId: Int64, tagName: String) throws -> DAMTagSuggestion? {
        try dbQueue.read { db in
            try DAMTagSuggestion
                .filter(Column("assetId") == assetId && Column("tagName") == tagName)
                .fetchOne(db)
        }
    }

    /// Delete all suggestions for an asset (e.g. before re-scoring it).
    func clearSuggestions(forAssetId assetId: Int64, state: DAMSuggestionState = .pending) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM tagSuggestion WHERE assetId = ? AND state = ?
                """, arguments: [assetId, state.rawValue])
        }
    }

    /// Distinct tag names across the whole tag table — vocabulary for the
    /// tagging UI's autocomplete.
    func allTagNames() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM tag ORDER BY name")
        }
    }

    /// Page of assets WITH their feature rows — the scan source for
    /// `dam_find_similar`. Assets missing both feature print and OCR tokens
    /// are excluded (nothing to score against).
    func featurePage(limit: Int, offset: Int) throws
        -> [(asset: DAMAsset, feature: DAMAssetFeature)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.*, f.featurePrint AS f_featurePrint,
                       f.ocrTokens AS f_ocrTokens, f.computedAt AS f_computedAt
                FROM asset a
                JOIN assetFeature f ON f.assetId = a.id
                WHERE f.featurePrint IS NOT NULL
                   OR (f.ocrTokens IS NOT NULL AND f.ocrTokens != '[]')
                ORDER BY a.id LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
            return rows.compactMap { row in
                guard let asset = try? DAMAsset(row: row),
                      let assetId = asset.id else { return nil }
                let feature = DAMAssetFeature(
                    assetId: assetId,
                    featurePrint: row["f_featurePrint"],
                    ocrTokens: row["f_ocrTokens"],
                    computedAt: row["f_computedAt"])
                return (asset, feature)
            }
        }
    }
}
