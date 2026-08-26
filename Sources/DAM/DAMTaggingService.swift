import Foundation
import Vision
import ImageIO
import AppKit

// MARK: - AI Tagging Service (learn-as-you-tag)
//
// The engine behind the Tagging workspace. Three jobs:
//
// 1. **Index** — for every image asset, compute (a) an Apple Vision feature
//    print (`VNGenerateImageFeaturePrintRequest` — a visual similarity
//    fingerprint) and (b) OCR text (`VNRecognizeTextRequest`, accurate) whose
//    normalized tokens feed text similarity. Both are stored once per asset
//    (migration v6 `assetFeature`); OCR text also lands in `asset.ocrText`
//    so FTS5 search picks it up automatically.
//
// 2. **Learn** — whenever the user applies a tag, that asset becomes an
//    *exemplar*: the service scores every untagged indexed asset against it
//    (visual distance + OCR Jaccard overlap) and enqueues `tagSuggestion`
//    rows at/above the review threshold. No model training — the exemplar
//    pool IS the learned state, so the system improves with every tag.
//
// 3. **Propagate** — suggestions above the auto-apply threshold (optional,
//    off by default) apply immediately with source `ai`; the rest wait for
//    review in the Tagging workspace. Rejections are kept as negative
//    feedback so the same (asset, tag) pair is never re-suggested.
//
// Everything runs on-device via Apple Vision — no model downloads, matching
// the project's 100%-local policy. Follows the `DAMImportService` actor +
// progress-callback pattern. Learning/propagation live in
// `DAMTaggingService+Learning.swift`.

actor DAMTaggingService {

    static let shared = DAMTaggingService()

    // MARK: - Configuration (UserDefaults-backed, tuned in the Tagging UI)

    struct Thresholds: Sendable, Equatable {
        /// Minimum combined confidence for a suggestion to enter the queue.
        var suggest: Double
        /// Confidence at/above which tags apply without review (opt-in).
        var autoApply: Double
        /// Master switch for auto-apply.
        var autoApplyEnabled: Bool

        static let `default` = Thresholds(
            suggest: 0.62, autoApply: 0.93, autoApplyEnabled: false)

        static func load() -> Thresholds {
            let defaults = UserDefaults.standard
            var t = Thresholds.default
            if defaults.object(forKey: "dam.tagging.suggestThreshold") != nil {
                t.suggest = defaults.double(forKey: "dam.tagging.suggestThreshold")
            }
            if defaults.object(forKey: "dam.tagging.autoApplyThreshold") != nil {
                t.autoApply = defaults.double(forKey: "dam.tagging.autoApplyThreshold")
            }
            t.autoApplyEnabled = defaults.bool(forKey: "dam.tagging.autoApplyEnabled")
            return t
        }

        func save() {
            let defaults = UserDefaults.standard
            defaults.set(suggest, forKey: "dam.tagging.suggestThreshold")
            defaults.set(autoApply, forKey: "dam.tagging.autoApplyThreshold")
            defaults.set(autoApplyEnabled, forKey: "dam.tagging.autoApplyEnabled")
        }
    }

    // MARK: - Scoring

    /// What evidence produced a candidate score.
    enum MatchBasis: Sendable {
        case visual(Double)   // feature-print distance-derived score
        case ocr(Double)      // Jaccard token overlap
        case both(visual: Double, ocr: Double)

        var confidence: Double {
            switch self {
            case .visual(let visual): return visual
            case .ocr(let ocr): return ocr
            case .both(let visual, let ocr):
                return min(1.0, max(visual, ocr) + 0.12 * min(visual, ocr))
            }
        }

        var dbBasis: DAMSuggestionBasis {
            switch self {
            case .visual: return .visual
            case .ocr: return .ocr
            case .both: return .both
            }
        }
    }

    /// Combined similarity of a candidate against one exemplar.
    /// Visual dominates for photos, OCR dominates for documents/screenshots —
    /// taking the stronger (with a corroboration bonus when both fire) lets
    /// one engine serve both without mode switching.
    static func score(exemplarPrint: VNFeaturePrintObservation?,
                      exemplarTokens: Set<String>,
                      candidatePrint: VNFeaturePrintObservation?,
                      candidateTokens: Set<String>) -> MatchBasis? {
        var visualScore: Double?
        if let exemplarPrint, let candidatePrint {
            var distance: Float = -1
            do {
                try exemplarPrint.computeDistance(&distance, to: candidatePrint)
            } catch {
                distance = -1
            }
            if distance >= 0 {
                // Empirical map: identical ≈ 0, same scene/burst ≈ 3–8,
                // same subject ≈ 8–15, unrelated ≈ 20+. 22 = "nothing alike".
                visualScore = clamp01(1.0 - Double(distance) / 22.0)
            }
        }
        var ocrScore: Double?
        if !exemplarTokens.isEmpty, !candidateTokens.isEmpty {
            let intersection = exemplarTokens.intersection(candidateTokens).count
            let union = exemplarTokens.union(candidateTokens).count
            if union > 0 {
                ocrScore = Double(intersection) / Double(union)
            }
        }
        switch (visualScore, ocrScore) {
        case let (visual?, ocr?): return .both(visual: visual, ocr: ocr)
        case let (visual?, nil): return .visual(visual)
        case let (nil, ocr?): return .ocr(ocr)
        case (nil, nil): return nil
        }
    }

    static func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }

    // MARK: - OCR token normalization

    /// English stop words + OCR noise tokens that match everything and so
    /// carry no discriminative value for Jaccard similarity.
    private static let stopTokens: Set<String> = [
        "the", "and", "for", "are", "was", "were", "with", "this", "that",
        "from", "have", "has", "had", "not", "but", "all", "can", "her",
        "his", "its", "our", "out", "who", "you", "your", "their", "they",
        "them", "then", "than", "when", "what", "will", "would", "could",
        "should", "into", "over", "under", "about", "page", "untitled",
    ]

    /// Normalize raw OCR text into a discriminative token set: lowercased,
    /// punctuation-stripped, stop words removed, min length 3, capped at 400
    /// unique tokens so long documents don't blow up the Jaccard math.
    static func ocrTokens(from text: String) -> Set<String> {
        // Collapse thousands separators inside numbers so amounts survive as
        // whole tokens ("$1,234.00" → "1234", not "1" + "234"). One pass of
        // the lookahead pattern handles chained groups ("1,234,567").
        let normalized = text.replacingOccurrences(
            of: #"(?<=\d)[,.](?=\d{3}\b)"#, with: "", options: .regularExpression)
        var tokens = Set<String>()
        for raw in normalized.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted) {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard token.count >= 3, !stopTokens.contains(token) else { continue }
            tokens.insert(token)
        }
        return tokens.count > 400 ? Set(tokens.prefix(400)) : tokens
    }

    /// Decode the stored JSON token array (nil/empty → empty set).
    static func tokens(fromJSON json: String?) -> Set<String> {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array)
    }

    // MARK: - Feature print archival

    /// VNFeaturePrintObservation is NSSecureCoding-compliant; archive for the
    /// BLOB column.
    static func archive(_ print: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true)
    }

    /// Defensive decode: strict ofClass first, then an explicit class set —
    /// some Vision versions archive NSArray/NSData internals that the strict
    /// single-class decode rejects.
    static func unarchive(_ data: Data) -> VNFeaturePrintObservation? {
        if let print = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: data) {
            return print
        }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [VNFeaturePrintObservation.self, NSArray.self, NSData.self,
                        NSNumber.self, NSDictionary.self, NSString.self],
            from: data) as? VNFeaturePrintObservation
    }

    // MARK: - Image decoding

    /// Decode an image for AI work at a bounded pixel size. Camera RAW and
    /// exotic formats go straight to ThumbnailService (LibRaw-backed) to
    /// avoid Apple's decoder error spam (`-50` per file). Standard images
    /// (JPEG/HEIC/PNG/TIFF/WebP) use ImageIO directly — fast, in-process,
    /// no XPC overhead. Falls back to ThumbnailService for anything else.
    static func loadCGImage(path: String, maxPixel: Int) async -> CGImage? {
        let url = URL(fileURLWithPath: path)

        // Camera RAW + LibRaw-only formats: skip ImageIO entirely.
        // Apple's decoder spams CGImageSourceCreateThumbnailAtIndex [-50]
        // errors on many RAW variants (NEF/RA30/RA02/RA04/IIQ/PEF).
        // ThumbnailService routes these through LibRaw which handles them
        // uniformly and quietly.
        if DAMFileKind.isCameraRAW(url) || DAMFileKind.isLibRAWOnly(url) {
            if let nsImage = try? await ThumbnailService.shared.thumbnail(
                for: url, pixelSize: CGFloat(maxPixel)) {
                var rect = CGRect(origin: .zero, size: nsImage.size)
                return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
            return nil
        }

        // Standard images (JPEG/HEIC/PNG/TIFF/WebP/GIF): ImageIO direct.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        // ThumbnailService fallback (QuickLook-backed for documents, etc.).
        if let nsImage = try? await ThumbnailService.shared.thumbnail(
            for: url, pixelSize: CGFloat(maxPixel)) {
            var rect = CGRect(origin: .zero, size: nsImage.size)
            return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }
}
