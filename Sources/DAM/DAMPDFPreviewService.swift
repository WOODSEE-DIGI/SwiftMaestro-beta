import AppKit
import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers

// MARK: - MaestroDAM Redacted PDF Preview Service
//
// Generates a temporary, redacted PDF suitable for Quick Look and the home
// preview pane. For PDFs with visible redactions, each page is re-rendered
// with the redaction boxes burned in; the result is a multi-page PDF that
// preserves page count and shows the protected content. Assets without edits,
// or with no visible redactions, return the original file URL so the caller
// can display it directly.

enum DAMPDFPreviewService {

    enum PreviewError: Error {
        case notAPDF
        case cannotOpenPDF
        case cannotCreateDestination
        case finalizeFailed
        case renderFailed
    }

    /// Returns a URL that can be displayed by PDFKit or QLPreviewView.
    /// For PDFs with visible redactions, this is a freshly-rendered redacted
    /// copy in the temporary directory. For everything else it is the
    /// original asset URL.
    static func redactedPreviewURL(for asset: DAMAsset) throws -> URL {
        let originalURL = URL(fileURLWithPath: asset.path)
        guard DAMFileKind.isPDF(originalURL) else {
            return originalURL
        }
        guard let assetId = asset.id else {
            return originalURL
        }
        guard DAMDatabase.shared.hasEdits(assetId: assetId),
              let recipe = DAMDatabase.shared.loadEdits(assetId: assetId),
              !recipe.visibleRedactions().isEmpty else {
            return originalURL
        }
        guard let doc = PDFDocument(url: originalURL), doc.pageCount > 0 else {
            throw PreviewError.cannotOpenPDF
        }

        // Only burn in redactions — geometry/light/color edits are previewed
        // in the Edit workspace; Quick Look and the home pane should show the
        // original pages with redactions applied.
        let redactionRecipe = redactionOnlyRecipe(from: recipe)

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DAMRedactedPreviews", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)

        let outputURL = cacheDir.appendingPathComponent("asset-\(assetId).pdf")

        let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.pdf.identifier as CFString,
            doc.pageCount,
            nil)
        guard let destination else {
            throw PreviewError.cannotCreateDestination
        }

        for pageIndex in 0..<doc.pageCount {
            let cgImage = try DAMEditRenderer.renderCGImage(
                asset: asset,
                edit: redactionRecipe,
                maxPixelSize: 2400,
                pageIndex: pageIndex)
            CGImageDestinationAddImage(destination, cgImage, nil)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw PreviewError.finalizeFailed
        }
        return outputURL
    }

    /// Strip a recipe down to just visible redaction layers/boxes. This avoids
    /// applying crop/rotate/tone/color adjustments to a Quick Look preview of
    /// a PDF while still protecting sensitive regions.
    private static func redactionOnlyRecipe(from recipe: DAMEditState) -> DAMEditState {
        var reduced = DAMEditState()
        reduced.redactionLayers = recipe.redactionLayers.filter(\.isVisible)
        let visibleLayerIDs = Set(reduced.redactionLayers.map(\.id))
        reduced.redactions = recipe.redactions.filter { box in
            guard let layerID = box.layerID else { return true }
            return visibleLayerIDs.contains(layerID)
        }
        return reduced
    }
}
