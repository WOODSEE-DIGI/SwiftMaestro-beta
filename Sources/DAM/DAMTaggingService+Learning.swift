import Foundation
import Vision

// MARK: - DAMTaggingService: indexing, learning, and suggestion resolution
//
// The actor's stateful operations. All DB access goes through
// `DAMDatabase+Tagging`; all heavy lifting (Vision requests) runs on the
// actor's executor so the main thread never blocks.

extension DAMTaggingService {

    // MARK: - Indexing (OCR + feature prints)

    struct IndexProgress: Sendable {
        var scanned: Int
        var updated: Int
        var total: Int
        var currentFile: String
    }

    /// Batch-compute OCR text + feature prints for every backlog asset.
    /// Cancellable; safe to re-run (skips already-indexed assets by design of
    /// the backlog query). Writes `asset.ocrText` (audited, source `ocr`) so
    /// the existing FTS5 triggers make OCR text searchable immediately.
    @discardableResult
    func indexFeatures(
        batchSize: Int = 200,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> (scanned: Int, updated: Int) {
        let database = DAMDatabase.shared
        let total = (try? database.featureBacklogCount()) ?? 0
        var scanned = 0
        var updated = 0

        while true {
            try Task.checkCancellation()
            // offset: 0 is intentional — indexed assets leave the backlog, so
            // the next page is always the new front of the queue.
            let batch = try database.featureBacklog(limit: batchSize, offset: 0)
            if batch.isEmpty { break }

            for asset in batch {
                try Task.checkCancellation()
                scanned += 1
                progress?(IndexProgress(
                    scanned: scanned, updated: updated,
                    total: total, currentFile: asset.filename))
                guard let assetId = asset.id else { continue }
                if try await indexAsset(asset) { updated += 1 }
                _ = assetId
            }
        }
        progress?(IndexProgress(
            scanned: scanned, updated: updated, total: total, currentFile: ""))
        return (scanned, updated)
    }

    /// Compute + store features for one asset. Idempotent-ish: skips work
    /// only when BOTH a feature print and an OCR-token row already exist.
    /// Returns true when anything was written.
    @discardableResult
    func indexAsset(_ asset: DAMAsset) async throws -> Bool {
        guard let assetId = asset.id else { return false }
        let database = DAMDatabase.shared

        // Skip only fully-indexed assets; missing feature print OR tokens
        // (e.g. an earlier crashed pass) recomputes both — cheap enough.
        if let existing = try database.feature(forAssetId: assetId),
           existing.featurePrint != nil, existing.ocrTokens != nil {
            return false
        }

        // OCR at 2048px keeps document text legible; feature prints use the
        // same decode (Vision rescales internally) to avoid two decodes.
        guard let image = await Self.loadCGImage(path: asset.path, maxPixel: 2048) else {
            // Undecodable right now (offline volume, corrupt file): DON'T
            // write a feature row — leave the asset in the backlog so it is
            // retried on a later pass (e.g. when the volume is back online).
            // Decode failures are cheap (ImageIO fails fast), so retrying
            // is safe.
            return false
        }

        // 1. OCR — accurate, language-corrected (same recipe VisionProxy uses).
        var ocrText = ""
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([textRequest])
            let lines = (textRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            ocrText = lines.joined(separator: "\n")
        } catch {
            NSLog("[DAMTagging] OCR failed for %@: %@", asset.path, "\(error)")
        }

        // 2. Feature print.
        var printData: Data?
        let printRequest = VNGenerateImageFeaturePrintRequest()
        do {
            try handler.perform([printRequest])
            if let observation = printRequest.results?.first {
                printData = Self.archive(observation)
            }
        } catch {
            NSLog("[DAMTagging] Feature print failed for %@: %@", asset.path, "\(error)")
        }

        let tokens = Self.ocrTokens(from: ocrText)

        // 3. Persist: feature row + (changed) ocrText on the asset, audited.
        try database.saveFeature(
            assetId: assetId, featurePrint: printData, ocrTokens: Array(tokens))
        let finalOCRText = ocrText  // immutable copy for the @Sendable closure
        if !finalOCRText.isEmpty, finalOCRText != asset.ocrText {
            try await database.dbQueue.write { db in
                guard var row = try DAMAsset.fetchOne(db, key: assetId) else { return }
                let old = row.ocrText
                row.ocrText = finalOCRText
                try row.update(db)
                try database.recordAudit(
                    db, assetId: assetId, field: "ocrText",
                    oldValue: old?.isEmpty == false ? "(previous OCR text)" : nil,
                    newValue: "(\(finalOCRText.count) chars)", source: "ocr")
            }
        }
        return true
    }

    // MARK: - Learning (user tag → propagation)

    /// The Tagging workspace's manual-tag entry point: apply the tags for
    /// real (source `user`), index the asset if needed, then propagate —
    /// every user tag instantly becomes a new exemplar.
    /// Returns the number of NEW suggestions created by propagation.
    @discardableResult
    func applyTagAndLearn(assetId: Int64, names: [String]) async throws -> Int {
        let database = DAMDatabase.shared
        var appliedAny = false
        for name in names {
            if try database.applyTag(name: name, to: assetId, source: .user) {
                appliedAny = true
            }
        }
        guard appliedAny else { return 0 }

        if let asset = try database.fetchAssets(ids: [assetId]).first {
            _ = try await indexAsset(asset)   // exemplars must be indexed
        }
        return try await propagateFromExemplar(assetId: assetId)
    }

    /// Score every untagged, indexed asset against ONE exemplar and enqueue
    /// suggestions for its tags. Auto-apply (when enabled) writes the tag
    /// immediately with source `ai`. Returns the count of new suggestions.
    @discardableResult
    func propagateFromExemplar(assetId: Int64) async throws -> Int {
        let database = DAMDatabase.shared
        guard let feature = try database.feature(forAssetId: assetId) else { return 0 }
        let exemplarPrint = feature.featurePrint.flatMap(Self.unarchive)
        let exemplarTokens = Self.tokens(fromJSON: feature.ocrTokens)
        guard exemplarPrint != nil || !exemplarTokens.isEmpty else { return 0 }

        let tags = try database.tagNames(forAssetId: assetId)
        guard !tags.isEmpty else { return 0 }
        let thresholds = Thresholds.load()

        // Snapshot candidate ids FIRST: auto-applied tags mutate the untagged
        // set mid-pass, which would corrupt OFFSET pagination.
        var candidateIds: [Int64] = []
        var offset = 0
        while true {
            let page = try database.untaggedAssets(
                requireFeatures: true, limit: 500, offset: offset)
            if page.isEmpty { break }
            candidateIds.append(contentsOf: page.compactMap(\.id))
            offset += page.count
            if page.count < 500 { break }
        }

        var created = 0
        for candidateId in candidateIds {
            try Task.checkCancellation()
            guard let candidateFeature = try database.feature(forAssetId: candidateId)
            else { continue }
            let candidatePrint = candidateFeature.featurePrint.flatMap(Self.unarchive)
            let candidateTokens = Self.tokens(fromJSON: candidateFeature.ocrTokens)

            guard let basis = Self.score(
                exemplarPrint: exemplarPrint, exemplarTokens: exemplarTokens,
                candidatePrint: candidatePrint, candidateTokens: candidateTokens)
            else { continue }
            let confidence = basis.confidence
            guard confidence >= thresholds.suggest else { continue }

            for tag in tags {
                // Never re-offer a pair the user already resolved.
                if let prior = try database.suggestion(assetId: candidateId, tagName: tag),
                   prior.state == .rejected || prior.state == .accepted
                       || prior.state == .autoApplied {
                    continue
                }
                if thresholds.autoApplyEnabled && confidence >= thresholds.autoApply {
                    try database.applyTag(name: tag, to: candidateId, source: .ai)
                    try await database.dbQueue.write { db in
                        try DAMTagSuggestion(
                            id: nil, assetId: candidateId, tagName: tag,
                            confidence: confidence, state: .autoApplied,
                            exemplarAssetId: assetId, basis: basis.dbBasis,
                            createdAt: Date(), resolvedAt: Date()
                        ).insert(db)
                    }
                } else {
                    let isNew = try database.suggestion(
                        assetId: candidateId, tagName: tag) == nil
                    try database.upsertSuggestion(
                        assetId: candidateId, tagName: tag, confidence: confidence,
                        exemplarAssetId: assetId, basis: basis.dbBasis)
                    if isNew { created += 1 }
                }
            }
        }
        return created
    }

    /// Full-catalog relearn: propagate from EVERY tagged exemplar (manual
    /// tags AND Lightroom-imported keywords). Exemplars are indexed on the
    /// fly if needed. O(exemplars × untagged) — a cancellable background
    /// operation the user kicks off after a big metadata import; incremental
    /// per-tag learning handles everything after that.
    @discardableResult
    func propagateFromAllExemplars(
        progress: (@Sendable (Int, Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let database = DAMDatabase.shared
        let exemplars = try database.taggedExemplars()
        var totalCreated = 0
        for (index, exemplar) in exemplars.enumerated() {
            try Task.checkCancellation()
            guard let assetId = exemplar.asset.id else { continue }
            _ = try await indexAsset(exemplar.asset)
            totalCreated += try await propagateFromExemplar(assetId: assetId)
            progress?(index + 1, exemplars.count, totalCreated)
        }
        return totalCreated
    }

    // MARK: - Suggestion resolution

    /// Accept: apply the tag (source `ai` — the audit trail records the human
    /// confirmation), mark the row, then learn from the freshly tagged asset
    /// (accepted suggestions become exemplars too — that's the loop).
    /// Tag application happens BEFORE the state flip: a crash between them
    /// leaves a still-pending row that is safely re-acceptable (applyTag is
    /// idempotent), instead of an accepted row whose tag was never written.
    func acceptSuggestion(id suggestionId: Int64) async throws {
        let database = DAMDatabase.shared
        // 1. Read the pending row.
        guard let row = try await database.dbQueue.read({ db in
            try DAMTagSuggestion.fetchOne(db, key: suggestionId)
        }), row.state == .pending else { return }
        // 2. Apply the tag.
        try database.applyTag(name: row.tagName, to: row.assetId, source: .ai)
        // 3. Mark accepted.
        _ = try database.acceptSuggestion(id: suggestionId)
        // 4. Learn: the newly tagged asset becomes an exemplar.
        if let asset = try database.fetchAssets(ids: [row.assetId]).first {
            _ = try await indexAsset(asset)
        }
        _ = try await propagateFromExemplar(assetId: row.assetId)
    }

    /// Reject: negative feedback. The (asset, tag) pair is never re-offered.
    func rejectSuggestion(id suggestionId: Int64) async throws {
        try DAMDatabase.shared.rejectSuggestion(id: suggestionId)
    }

    /// Batch-accept every pending suggestion at/above a confidence.
    /// Returns the number accepted.
    @discardableResult
    func acceptAll(minConfidence: Double) async throws -> Int {
        let database = DAMDatabase.shared
        let page = try database.pendingSuggestions(
            minConfidence: minConfidence, limit: 500)
        var accepted = 0
        for (suggestion, _) in page {
            guard let id = suggestion.id else { continue }
            try await acceptSuggestion(id: id)
            accepted += 1
        }
        return accepted
    }

    // MARK: - Similarity search (agent tool + future UI)

    /// One similar-asset hit.
    struct SimilarHit: Sendable {
        var asset: DAMAsset
        var confidence: Double
        var basis: DAMSuggestionBasis
    }

    /// Find the assets most similar to the asset at `path` across the whole
    /// indexed catalog (not just untagged ones — this is a search, not a
    /// propagation pass). Indexes the query asset on the fly if needed.
    func findSimilar(path: String, limit: Int, minConfidence: Double) async throws
        -> [SimilarHit] {
        let database = DAMDatabase.shared
        guard let asset = try database.asset(withPath: path) else {
            throw DAMTaggingError.assetNotFound(path)
        }
        _ = try await indexAsset(asset)
        guard let queryFeature = try database.feature(forAssetId: asset.id ?? -1) else {
            return []
        }
        let queryPrint = queryFeature.featurePrint.flatMap(Self.unarchive)
        let queryTokens = Self.tokens(fromJSON: queryFeature.ocrTokens)
        guard queryPrint != nil || !queryTokens.isEmpty else { return [] }

        var hits: [SimilarHit] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try database.featurePage(limit: 500, offset: offset)
            if page.isEmpty { break }
            for (candidate, feature) in page where candidate.id != asset.id {
                let candidatePrint = feature.featurePrint.flatMap(Self.unarchive)
                let candidateTokens = Self.tokens(fromJSON: feature.ocrTokens)
                guard let basis = Self.score(
                    exemplarPrint: queryPrint, exemplarTokens: queryTokens,
                    candidatePrint: candidatePrint, candidateTokens: candidateTokens)
                else { continue }
                let confidence = basis.confidence
                if confidence >= minConfidence {
                    hits.append(SimilarHit(
                        asset: candidate, confidence: confidence,
                        basis: basis.dbBasis))
                }
            }
            offset += page.count
            if page.count < 500 { break }
        }
        return hits
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { $0 }
    }
}

enum DAMTaggingError: Error, LocalizedError {
    case assetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .assetNotFound(let path):
            return "Asset not in the MaestroDAM catalog: \(path)"
        }
    }
}
