import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - MaestroDAM Share Preparation Service
//
// Prepares selected assets for the macOS share sheet. Image assets with
// visible edits (crop, rotation, redactions, tone/color adjustments) are
// flattened to a temporary JPEG with metadata scrubbed of GPS/PII. Assets
// without edits, or non-image assets, are shared from their original path.
// This guarantees redaction boxes are baked in and cannot be removed by the
// recipient.

enum DAMShareService {

    enum ShareError: Error {
        case missingAssetID
        case renderFailure(String)
    }

    /// Prepare shareable file URLs for `assets`.
    /// - Parameters:
    ///   - assets: catalog assets to share.
    ///   - progress: called on MainActor with `(completed, total)` after each
    ///     asset is processed.
    /// - Returns: URLs to share. These may be original file URLs or temporary
    ///   rendered files. Temporary files are scheduled for cleanup.
    static func prepareShareURLs(
        for assets: [DAMAsset],
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> [URL] {
        let total = assets.count
        var results: [URL] = []
        results.reserveCapacity(total)

        for (index, asset) in assets.enumerated() {
            let url = try await shareURL(for: asset)
            results.append(url)
            await progress(index + 1, total)
        }
        return results
    }

    /// Prepare a single shareable URL for `asset`.
    private static func shareURL(for asset: DAMAsset) async throws -> URL {
        let sourceURL = URL(fileURLWithPath: asset.path)
        guard let assetId = asset.id else {
            throw ShareError.missingAssetID
        }

        let recipe = DAMDatabase.shared.loadEdits(assetId: assetId) ?? DAMEditState()
        let exportRecipe = recipe.forExport()
        let isImage = asset.kind == "image" || asset.kind == "raw"

        // No visible edits: share the original file. Hidden redactions were
        // already stripped by forExport(); if the exported recipe is identity
        // there is nothing to flatten.
        guard isImage, !exportRecipe.isIdentity else {
            return sourceURL
        }

        // Render the image with visible edits/redactions baked in.
        let cgImage = try DAMEditRenderer.renderCGImage(
            asset: asset,
            edit: exportRecipe,
            maxPixelSize: 0   // full resolution
        )

        let data = try DAMEditRenderer.encode(
            cgImage,
            format: .jpeg,
            quality: 0.95,
            sourceURL: sourceURL,
            metadataPolicy: .some  // scrub GPS / IPTC / serials
        )

        let tempDir = try tempShareDirectory()
        let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: tempURL, options: .atomic)

        // Schedule cleanup so temp files don't accumulate. Most share services
        // copy the file immediately, but keep it around for a few minutes in
        // case the user is composing a large email or slow upload.
        scheduleCleanup(of: tempURL, after: 300)

        return tempURL
    }

    /// Dedicated temp subdirectory for share exports.
    private static func tempShareDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.woodseedigi.swiftmaestro.share-exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    /// Remove a temp file after `delay` seconds, ignoring errors.
    private static func scheduleCleanup(of url: URL, after delay: TimeInterval) {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
