import SwiftUI
import PDFKit

// MARK: - MaestroDAM PDF Preview View
//
// A SwiftUI wrapper around PDFKit's PDFView for the home preview pane and
// any other place that needs a scrollable, multi-page PDF. It automatically
// uses DAMPDFPreviewService so PDFs with visible redactions are shown with
// sensitive content hidden.

struct DAMPDFPreviewView: View {
    let asset: DAMAsset
    /// Optional zoom multiplier. When nil the PDF view fits to the available
    /// space (legacy behaviour). When provided the page is scaled by
    /// `fitScale * zoom` so the user can magnify the page.
    var zoom: Double? = nil
    /// The size of the SwiftUI container. Required for reliable zoom math
    /// because `PDFView.scaleFactorForSizeToFit` may report 0 before layout.
    var containerSize: CGSize? = nil

    var body: some View {
        DAMPDFPreviewRepresentable(asset: asset, zoom: zoom, containerSize: containerSize)
            .id(asset.id)
            .onReceive(NotificationCenter.default.publisher(for: .damEditsDidChange)) { notification in
                // The underlying representable will pick up the change when
                // updateNSView is called because the asset identity is used as
                // the .id above; SwiftUI treats a new id as a new view.
                _ = notification
            }
    }
}

private struct DAMPDFPreviewRepresentable: NSViewRepresentable {
    let asset: DAMAsset
    let zoom: Double?
    let containerSize: CGSize?

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        do {
            let url = try DAMPDFPreviewService.redactedPreviewURL(for: asset)
            // Always reload so redaction edits are reflected.
            pdfView.document = PDFDocument(url: url)
        } catch {
            pdfView.document = nil
        }

        if let zoom, let containerSize, let page = pdfView.document?.page(at: 0) {
            // Compute a true fit-to-view scale from the first page’s media box
            // and the SwiftUI container size.
            let pageRect = page.bounds(for: .mediaBox)
            guard pageRect.width > 0, pageRect.height > 0,
                  containerSize.width > 0, containerSize.height > 0 else {
                pdfView.autoScales = true
                return
            }
            let fitScale = min(
                containerSize.width / pageRect.width,
                containerSize.height / pageRect.height
            )
            pdfView.autoScales = false
            pdfView.scaleFactor = fitScale * zoom
        } else {
            pdfView.autoScales = true
        }
    }
}
