import AppKit
import Foundation
import PDFKit

// MARK: - MaestroDAM Document Thumbnail Renderers
//
// Native, offline document renderers for the thumbnail pipeline — the
// MaestroDocs engine's visual half. NO QuickLook anywhere here: every path
// is deterministic, in-process, and immune to QL's zombie failure mode on
// slow volumes. Package/XML extraction lives in `DocEngine`; this file is
// painters only.
//
//   PDF               → PDFKit CG render at exact size (vector-crisp)
//   iWork             → embedded preview.pdf → same PDFKit path (any size!)
//   ODF/OOXML/EPUB    → embedded thumbnail/cover raster via `unzip`
//   DOC/DOCX/RTF/ODT  → TextKit page paint
//   TXT/MD/HTML/etc.  → bounded plain-text page paint (offline rule:
//                        we never let TextKit's HTML importer fetch)
//   XLSX/CSV/TSV      → first-sheet table grid paint
enum DocumentThumbService {

    // MARK: - PDF (PDFKit)

    /// Renders page 1 of a PDF at the requested size (2x for retina).
    static func pdfRender(url: URL, pixelSize: CGFloat, key: String) throws -> NSImage {
        guard let doc = PDFDocument(url: url) else {
            throw ThumbnailService.ThumbnailError.generationFailed
        }
        return try pdfImage(doc: doc, pixelSize: pixelSize, key: key)
    }

    /// Shared PDF painter (file-backed or in-memory — iWork preview.pdf).
    private static func pdfImage(doc: PDFDocument, pixelSize: CGFloat, key: String) throws -> NSImage {
        guard let page = doc.page(at: 0) else {
            throw ThumbnailService.ThumbnailError.noRepresentation
        }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw ThumbnailService.ThumbnailError.noRepresentation
        }
        let maxPixel = max(64, pixelSize * 2)
        let scale = maxPixel / max(bounds.width, bounds.height)
        let target = NSSize(
            width: max(1, (bounds.width * scale).rounded()),
            height: max(1, (bounds.height * scale).rounded()))

        let image = NSImage(size: target)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: target).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        image.unlockFocus()

        ThumbnailService.writeDiskCache(image, key: key)
        return image
    }

    // MARK: - Text page (TextKit / plain text)

    /// Renders the document's first page of text at the requested size.
    static func textKitRender(url: URL, pixelSize: CGFloat, key: String) throws -> NSImage {
        let ext = url.pathExtension.lowercased()
        let fontSize = max(9, pixelSize * 2 / 44)
        let attributed: NSAttributedString

        if ["txt", "md", "markdown", "html", "htm", "json", "xml", "yaml", "yml", "log"]
            .contains(ext) {
            // Plain-source render — bounded read, monospace. HTML stays
            // source-form: offline rule, we never let an importer fetch.
            let text = (try? DocEngine.read(url).text) ?? ""
            guard !text.isEmpty else {
                throw ThumbnailService.ThumbnailError.noRepresentation
            }
            attributed = NSAttributedString(
                string: String(text.prefix(20_000)),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: NSColor.black,
                ])
        } else {
            // Word/RTF/ODT via TextKit — re-set fonts to a size proportional
            // to the canvas so 256px thumbs and 1600px previews read alike.
            // richAttributedContent also restores DOCX page headers/footers
            // (letterheads, logos) that TextKit drops.
            guard let loaded = try? DocEngine.richAttributedContent(url),
                  loaded.length > 0 else {
                throw ThumbnailService.ThumbnailError.generationFailed
            }
            let mutable = NSMutableAttributedString(
                attributedString: loaded.attributedSubstring(
                    from: NSRange(location: 0, length: min(loaded.length, 12_000))))
            mutable.addAttributes(
                [.font: NSFont.systemFont(ofSize: fontSize),
                 .foregroundColor: NSColor.black],
                range: NSRange(location: 0, length: mutable.length))
            attributed = mutable
        }

        let image = paintTextPage(attributed, pixelSize: pixelSize)
        ThumbnailService.writeDiskCache(image, key: key)
        return image
    }

    /// A4-ish white page with the text drawn top-down inside margins.
    private static func paintTextPage(_ text: NSAttributedString, pixelSize: CGFloat) -> NSImage {
        let width = max(64, pixelSize * 2)
        let height = (width * 1.294).rounded()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let margin = width * 0.08
        // NSAttributedString.draw(in:) lays the first line at the TOP of the
        // rect (AppKit text drawing is upright in a lockFocus context).
        text.draw(in: NSRect(
            x: margin, y: margin,
            width: width - margin * 2, height: height - margin * 2))
        image.unlockFocus()
        return image
    }

    // MARK: - Table grid (XLSX / CSV / TSV)

    /// Renders the document's first rows as a spreadsheet grid.
    static func tableRender(url: URL, pixelSize: CGFloat, key: String) throws -> NSImage {
        let ext = url.pathExtension.lowercased()
        let rows: [[String]]
        if ext == "csv" || ext == "tsv" {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.read(upToCount: 256 * 1024),
                  let text = String(data: data, encoding: .utf8) else {
                throw ThumbnailService.ThumbnailError.generationFailed
            }
            try? handle.close()
            rows = Array(DocEngine.parseDelimited(
                text, separator: ext == "csv" ? "," : "\t").prefix(40))
        } else {
            rows = try DocEngine.xlsxRows(url, sheetIndex: 0, maxRows: 40, maxCols: 12)
        }
        guard !rows.isEmpty else {
            throw ThumbnailService.ThumbnailError.noRepresentation
        }

        let image = paintGrid(rows, pixelSize: pixelSize)
        ThumbnailService.writeDiskCache(image, key: key)
        return image
    }

    /// Spreadsheet-style grid painter: header row tinted + bold, zebra rows,
    /// hairline separators, per-cell truncation.
    private static func paintGrid(_ rows: [[String]], pixelSize: CGFloat) -> NSImage {
        let canvasW = max(64, pixelSize * 2)
        let visibleRows = min(rows.count, 40)
        let cols = max(1, rows.prefix(visibleRows).map(\.count).max() ?? 1)
        let colW = canvasW / CGFloat(cols)
        let rowH = max(18, canvasW / 30)
        let canvasH = rowH * CGFloat(visibleRows)
        let fontSize = rowH * 0.52
        let headerFont = NSFont.boldSystemFont(ofSize: fontSize)
        let cellFont = NSFont.systemFont(ofSize: fontSize)

        let image = NSImage(size: NSSize(width: canvasW, height: canvasH))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()

        // y grows upward in a lockFocus context — row 0 paints at the top.
        for (rowIndex, row) in rows.prefix(visibleRows).enumerated() {
            let y = canvasH - rowH * CGFloat(rowIndex + 1)
            if rowIndex == 0 {
                NSColor(white: 0.92, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: canvasW, height: rowH).fill()
            } else if rowIndex % 2 == 0 {
                NSColor(white: 0.98, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: canvasW, height: rowH).fill()
            }
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: canvasW, height: 1).fill()

            for (colIndex, value) in row.enumerated() where !value.isEmpty {
                let maxChars = max(1, Int((colW - 8) / (fontSize * 0.56)))
                let text = value.count > maxChars
                    ? String(value.prefix(maxChars - 1)) + "…" : value
                let cell = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: rowIndex == 0 ? headerFont : cellFont,
                        .foregroundColor: NSColor.black,
                    ])
                cell.draw(at: NSPoint(
                    x: CGFloat(colIndex) * colW + 4,
                    y: y + (rowH - fontSize) / 2 - fontSize * 0.2))
            }
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Embedded package previews (ODF / OOXML / iWork / EPUB)

    /// Extracts the package's own embedded preview via `unzip`:
    ///   iWork  → preview.pdf (vector — rendered at ANY size via PDFKit)
    ///   ODF    → Thumbnails/thumbnail.png (spec-mandated)
    ///   OOXML  → docProps/thumbnail.(jpeg|png) (written by real Office)
    ///   EPUB   → cover image heuristic
    /// Small rasters are accepted for grid sizes (≤384pt); larger previews
    /// require the raster to be at least the requested size, else throw so
    /// the caller can fall back.
    static func embeddedPreview(url: URL, pixelSize: CGFloat, key: String) throws -> NSImage {
        let ext = url.pathExtension.lowercased()
        let listing = (try? DocEngine.unzipList(url)) ?? []

        // iWork vector preview — the crown jewel (full-fidelity, any size).
        if ["pages", "numbers", "key"].contains(ext),
           let entry = listing.first(where: { $0.hasSuffix("preview.pdf") }),
           let data = try? DocEngine.unzipData(url, entry: entry),
           let doc = PDFDocument(data: data) {
            return try pdfImage(doc: doc, pixelSize: pixelSize, key: key)
        }

        let rasterCandidates: [String]
        switch ext {
        case "odt", "ods", "odp", "odg":
            rasterCandidates = ["Thumbnails/thumbnail.png"]
        case "docx", "xlsx", "xlsm", "pptx", "pptm":
            rasterCandidates = [
                "docProps/thumbnail.jpeg", "docProps/thumbnail.png",
                "docProps/thumbnail.jpg",
            ]
        case "pages", "numbers", "key":
            rasterCandidates = ["preview.jpg", "preview.png", "preview-micro.jpg"]
        case "epub":
            rasterCandidates = listing.filter { entry in
                let last = (entry as NSString).lastPathComponent.lowercased()
                let suffix = (last as NSString).pathExtension
                return last.hasPrefix("cover") && ["jpg", "jpeg", "png"].contains(suffix)
            }
        default:
            rasterCandidates = []
        }

        for candidate in rasterCandidates where listing.contains(candidate) {
            guard let data = try? DocEngine.unzipData(url, entry: candidate),
                  let image = NSImage(data: data) else { continue }
            let edge = max(image.size.width, image.size.height)
            // Grid: any sane raster wins over a decoder round-trip.
            // Previews: refuse stamps smaller than the requested size.
            let floor: CGFloat = pixelSize > 384 ? pixelSize : 128
            guard edge >= floor else { continue }
            ThumbnailService.writeDiskCache(image, key: key)
            return image
        }

        throw ThumbnailService.ThumbnailError.noRepresentation
    }
}
