import AppKit
import Foundation
import PDFKit

// MARK: - MaestroDocs Engine
//
// SwiftMaestro's native document engine — LibreOffice-class read/create
// functionality with ZERO external dependencies, designed agent-first:
// every capability here is exposed to agents via the ToolRegistry
// (see MaestroTools+Documents.swift) and reused by MaestroDAM for
// thumbnails/previews (see DocumentThumbService.swift).
//
// READ (text extraction for agent context):
//   PDF              → PDFKit (full text + page count)
//   DOC/DOCX/RTF/ODT → TextKit (TextEdit's engine)
//   TXT/MD/HTML      → bounded plain-text read
//   CSV/TSV          → bounded plain-text read + row parser
//   XLSX             → ZIP+XML parser (shared strings + sheet rows)
//   PPTX             → ZIP+XML per-slide text extraction
//   iWork            → embedded preview.pdf → PDFKit text
//   EPUB             → OPF spine → chapter text
//
// CREATE (agent document authoring):
//   TXT/MD, CSV/TSV  → direct write (CSV properly quoted by row helpers)
//   RTF              → NSAttributedString native writer
//   PDF              → CoreText framesetter paged rendering
//   DOCX / XLSX      → minimal valid OOXML packages (via /usr/bin/zip)
//   ODT              → minimal valid ODF package (mimetype stored first)
//
// Legacy binary Office (.xls/.ppt) is intentionally not parsed — the
// readers report a clear "convert to XLSX" error instead of crashing
// (never feed unknown binary to a parser — see the LibRaw rule).

/// Extracted document content for agent consumption.
struct DocContent: Sendable {
    let format: String
    let text: String
    /// PDF page count, when known.
    let pageCount: Int?
    /// XLSX sheet names, when known.
    let sheetNames: [String]?
    /// True when the text was capped (agent context budget).
    let truncated: Bool
}

enum DocEngineError: Error, Sendable {
    case unsupportedFormat(String)
    case unreadable(String)
    case createFailed(String)
}

enum DocEngine {

    /// Hard cap on extracted text so a huge document can't blow up an
    /// agent's context window.
    static let maxExtractedCharacters = 200_000
    /// Cap for plain-text source reads (TXT/MD/CSV/HTML).
    private static let maxPlainReadBytes = 1024 * 1024

    // MARK: - Format detection

    static func formatName(for url: URL) -> String {
        url.pathExtension.lowercased()
    }

    // MARK: - READ

    /// Extracts text from any supported document for agent context.
    static func read(_ url: URL) throws -> DocContent {
        let ext = formatName(for: url)
        switch ext {
        case "pdf":
            return try readPDF(url)
        case "doc", "docx", "rtf", "rtfd", "odt":
            return try readTextKit(url, format: ext)
        case "txt", "md", "markdown", "log", "json", "xml", "yaml", "yml":
            return try readPlain(url, format: ext)
        case "html", "htm":
            return try readHTML(url)
        case "csv", "tsv":
            return try readPlain(url, format: ext)
        case "xlsx", "xlsm":
            return try readXLSX(url)
        case "pptx", "pptm":
            return try readPPTX(url)
        case "pages", "numbers", "key":
            return try readIWorkPreview(url, format: ext)
        case "epub":
            return try readEPUB(url)
        case "xls", "ppt":
            throw DocEngineError.unsupportedFormat(
                "Legacy binary Office (.\(ext)) isn't parsed natively — convert to .\(ext)x first.")
        case "ods", "odp", "odg":
            throw DocEngineError.unsupportedFormat(
                ".\(ext) text extraction is Phase 2 — thumbnails via embedded preview still work.")
        default:
            throw DocEngineError.unsupportedFormat(".\(ext) is not a supported document format")
        }
    }

    /// Basic document facts for the `document_info` tool.
    static func info(_ url: URL) throws -> [String: String] {
        let ext = formatName(for: url)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var out: [String: String] = ["format": ext, "bytes": "\(bytes)"]
        if let content = try? read(url) {
            out["words"] = "\(content.text.split(separator: " ").count)"
            if let pages = content.pageCount { out["pages"] = "\(pages)" }
            if let sheets = content.sheetNames { out["sheets"] = sheets.joined(separator: ", ") }
            out["truncated"] = content.truncated ? "true" : "false"
        }
        return out
    }

    private static func cap(_ text: String, format: String,
                            pages: Int? = nil, sheets: [String]? = nil) -> DocContent {
        if text.count > maxExtractedCharacters {
            return DocContent(
                format: format, text: String(text.prefix(maxExtractedCharacters)),
                pageCount: pages, sheetNames: sheets, truncated: true)
        }
        return DocContent(format: format, text: text,
                          pageCount: pages, sheetNames: sheets, truncated: false)
    }

    // MARK: PDF

    private static func readPDF(_ url: URL) throws -> DocContent {
        guard let doc = PDFDocument(url: url) else {
            throw DocEngineError.unreadable("PDFKit could not open '\(url.lastPathComponent)'")
        }
        return cap(doc.string ?? "", format: "pdf", pages: doc.pageCount)
    }

    // MARK: TextKit (Word / RTF / ODT)

    private static func readTextKit(_ url: URL, format: String) throws -> DocContent {
        do {
            let attr = try NSAttributedString(
                url: url, options: [:], documentAttributes: nil)
            return cap(attr.string, format: format)
        } catch {
            throw DocEngineError.unreadable(
                "TextKit could not read '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
    }

    // MARK: Plain text

    private static func readPlain(_ url: URL, format: String) throws -> DocContent {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DocEngineError.unreadable("cannot open '\(url.lastPathComponent)'")
        }
        let data = (try? handle.read(upToCount: maxPlainReadBytes)) ?? Data()
        try? handle.close()
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return cap(text, format: format)
    }

    private static func readHTML(_ url: URL) throws -> DocContent {
        // TextKit's HTML importer converts tags to text offline (remote
        // subresources are deferred attachments, never fetched here).
        do {
            let attr = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil)
            return cap(attr.string, format: "html")
        } catch {
            return try readPlain(url, format: "html")
        }
    }

    // MARK: XLSX (ZIP + XML)

    private static func readXLSX(_ url: URL) throws -> DocContent {
        let names = (try? xlsxSheetNames(url)) ?? ["Sheet1"]
        var out = ""
        for (index, name) in names.prefix(8).enumerated() {
            let rows = (try? xlsxRows(url, sheetIndex: index, maxRows: 200, maxCols: 26)) ?? []
            guard !rows.isEmpty else { continue }
            out += "## Sheet: \(name)\n"
            for row in rows {
                out += "| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |\n"
            }
            out += "\n"
        }
        guard !out.isEmpty else {
            throw DocEngineError.unreadable("no sheet data found in '\(url.lastPathComponent)'")
        }
        return cap(out, format: "xlsx", sheets: names)
    }

    /// Sheet display names from xl/workbook.xml.
    static func xlsxSheetNames(_ url: URL) throws -> [String] {
        let data = try unzipData(url, entry: "xl/workbook.xml")
        let delegate = WorkbookNameDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.names.isEmpty ? ["Sheet1"] : delegate.names
    }

    /// Rows of display strings from one worksheet (0-based sheet index →
    /// sheetN.xml naming, matching our writer and Excel's default).
    static func xlsxRows(_ url: URL, sheetIndex: Int = 0,
                         maxRows: Int, maxCols: Int) throws -> [[String]] {
        let shared = (try? unzipData(url, entry: "xl/sharedStrings.xml"))
            .map { data -> [String] in
                let delegate = SharedStringsDelegate()
                let parser = XMLParser(data: data)
                parser.delegate = delegate
                parser.parse()
                return delegate.strings
            } ?? []

        // Prefer the conventional sheetN.xml; fall back to any worksheet entry.
        var entry = "xl/worksheets/sheet\(sheetIndex + 1).xml"
        if (try? unzipData(url, entry: entry)) == nil {
            let listing = try unzipList(url)
            guard let found = listing
                .first(where: { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") })
            else { throw DocEngineError.unreadable("no worksheets in XLSX package") }
            entry = found
        }
        let data = try unzipData(url, entry: entry)
        let delegate = SheetDelegate(sharedStrings: shared, maxRows: maxRows, maxCols: maxCols)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    // MARK: PPTX (ZIP + XML, per-slide text)

    private static func readPPTX(_ url: URL) throws -> DocContent {
        let listing = try unzipList(url)
        let slides = listing
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { lhs, rhs in
                slideNumber(lhs) < slideNumber(rhs)
            }
        guard !slides.isEmpty else {
            throw DocEngineError.unreadable("no slides in PPTX package")
        }
        var out = ""
        for (index, entry) in slides.prefix(40).enumerated() {
            guard let data = try? unzipData(url, entry: entry) else { continue }
            let delegate = SlideTextDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            let text = delegate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out += "## Slide \(index + 1)\n\(text)\n\n"
            }
        }
        guard !out.isEmpty else {
            throw DocEngineError.unreadable("no slide text found in '\(url.lastPathComponent)'")
        }
        return cap(out, format: "pptx", pages: slides.count)
    }

    private static func slideNumber(_ entry: String) -> Int {
        let name = (entry as NSString).lastPathComponent   // "slide12.xml"
        let digits = name.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

    // MARK: iWork (embedded preview.pdf)

    /// Pages/Numbers/Keynote packages carry a full-fidelity vector
    /// `preview.pdf` — agents get real document text from it without any
    /// iWork parser at all.
    private static func readIWorkPreview(_ url: URL, format: String) throws -> DocContent {
        let listing = (try? unzipList(url)) ?? []
        guard let entry = listing.first(where: { $0.hasSuffix("preview.pdf") }),
              let data = try? unzipData(url, entry: entry),
              let doc = PDFDocument(data: data) else {
            throw DocEngineError.unreadable(
                "no embedded preview.pdf in this .\(format) package (very old iWork format?)")
        }
        return cap(doc.string ?? "", format: format, pages: doc.pageCount)
    }

    // MARK: EPUB (OPF spine → chapter text)

    private static func readEPUB(_ url: URL) throws -> DocContent {
        let listing = try unzipList(url)
        guard let opfEntry = listing.first(where: { $0.hasSuffix(".opf") }),
              let opfData = try? unzipData(url, entry: opfEntry) else {
            throw DocEngineError.unreadable("no OPF manifest in EPUB package")
        }
        let delegate = OPFDelegate()
        let parser = XMLParser(data: opfData)
        parser.delegate = delegate
        parser.parse()

        let base = (opfEntry as NSString).deletingLastPathComponent
        var out = ""
        for idref in delegate.spine.prefix(60) {
            guard let href = delegate.manifest[idref] else { continue }
            let chapterPath = base.isEmpty ? href : "\(base)/\(href)"
            guard let data = try? unzipData(url, entry: chapterPath),
                  let html = String(data: data, encoding: .utf8) else { continue }
            out += stripHTMLTags(html) + "\n\n"
            if out.count > maxExtractedCharacters { break }
        }
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocEngineError.unreadable("no chapter text extracted from EPUB")
        }
        return cap(out, format: "epub", pages: delegate.spine.count)
    }

    /// Crude tag stripper for EPUB chapter XHTML (good enough for agent
    /// context; NOT a sanitizer — output never reaches WebKit).
    private static func stripHTMLTags(_ html: String) -> String {
        var text = html
        // Drop script/style blocks entirely.
        for tag in ["script", "style"] {
            while let open = text.range(of: "<\(tag)[^>]*>", options: .regularExpression),
                  let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - CREATE

    /// Creates a document at `url` from agent-authored `content`.
    /// Format is inferred from the path extension. Returns bytes written.
    ///
    /// Content conventions:
    ///   - txt/md/rtf/pdf/docx/odt: plain text; blank lines split paragraphs
    ///   - csv/tsv/xlsx: comma/tab-separated rows (or markdown tables)
    @discardableResult
    static func create(_ url: URL, content: String, title: String? = nil) throws -> Int {
        let ext = formatName(for: url)
        switch ext {
        case "txt", "md", "markdown":
            return try writeData(url, Data(content.utf8))
        case "csv", "tsv":
            let rows = parseDelimited(content, separator: ext == "csv" ? "," : "\t")
            let text = rows.map { $0.joined(separator: ext == "csv" ? "," : "\t") }
                .joined(separator: "\n") + "\n"
            return try writeData(url, Data(text.utf8))
        case "rtf":
            return try writeRTF(url, content: content)
        case "pdf":
            return try writePDF(url, content: content, title: title)
        case "docx":
            return try writeDOCX(url, content: content, title: title)
        case "xlsx":
            let rows = parseDelimited(content, separator: nil)  // auto: csv/tsv/markdown
            return try writeXLSX(url, rows: rows, sheetName: title ?? "Sheet1")
        case "odt":
            return try writeODT(url, content: content, title: title)
        case "xls", "ppt", "pptx", "ods", "odp":
            throw DocEngineError.unsupportedFormat(
                "Creating .\(ext) is Phase 2 — create .xlsx/.docx/.pdf instead.")
        default:
            throw DocEngineError.unsupportedFormat(
                "cannot create '.\(ext)' — supported: txt, md, csv, tsv, rtf, pdf, docx, xlsx, odt")
        }
    }

    @discardableResult
    private static func writeData(_ url: URL, _ data: Data) throws -> Int {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    // MARK: RTF (native)

    private static func writeRTF(_ url: URL, content: String) throws -> Int {
        let attr = NSAttributedString(
            string: content,
            attributes: [.font: NSFont.systemFont(ofSize: 12)])
        guard let data = try? attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            throw DocEngineError.createFailed("RTF serialization failed")
        }
        return try writeData(url, data)
    }

    // MARK: PDF (CoreText framesetter, auto-paginated)

    private static func writePDF(_ url: URL, content: String, title: String?) throws -> Int {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
            throw DocEngineError.createFailed("could not create PDF context")
        }

        var text = title.map { $0 + "\n\n" } ?? ""
        text += content
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        var range = CFRange(location: 0, length: 0)
        var pageCount = 0

        while range.location < attr.length {
            context.beginPDFPage(nil)
            // Modern CoreText draws glyphs upright with top-down layout in
            // a PDF context with NO transforms (4-variant verified): any
            // textMatrix/CTM flip breaks either glyph orientation or
            // layout order. Keep identity.
            context.textMatrix = .identity
            let framePath = CGPath(
                rect: pageRect.insetBy(dx: 54, dy: 54), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, range, framePath, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }  // safety: never loop forever
            range.location += visible.length
            context.endPDFPage()
            pageCount += 1
            if pageCount > 2000 { break }     // runaway-content guard
        }
        context.closePDF()
        return Int((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    // MARK: DOCX (minimal OOXML)

    private static func writeDOCX(_ url: URL, content: String, title: String?) throws -> Int {
        let paragraphs = (title.map { [$0] } ?? []) + content.components(separatedBy: "\n")
        let bodyXML = paragraphs.map { para -> String in
            // Empty paragraphs are legal spacers.
            "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(para))</w:t></w:r></w:p>"
        }.joined()

        let files: [String: String] = [
            "[Content_Types].xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
                """,
            "_rels/.rels": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
                """,
            "word/document.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(bodyXML)</w:body></w:document>
                """,
        ]
        return try zipPackage(url: url, files: files.mapValues { Data($0.utf8) })
    }

    // MARK: XLSX (minimal OOXML, inline strings)

    /// Public row-based XLSX writer (spreadsheet editor write-back).
    @discardableResult
    static func createXLSX(_ url: URL, rows: [[String]], sheetName: String) throws -> Int {
        try writeXLSX(url, rows: rows, sheetName: sheetName)
    }

    private static func writeXLSX(_ url: URL, rows: [[String]], sheetName: String) throws -> Int {
        var sheetRows = ""
        for (rowIndex, row) in rows.enumerated() {
            var cells = ""
            for (colIndex, value) in row.enumerated() {
                guard !value.isEmpty else { continue }
                let ref = "\(columnName(colIndex))\(rowIndex + 1)"
                cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
            }
            sheetRows += "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }

        let files: [String: String] = [
            "[Content_Types].xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
                """,
            "_rels/.rels": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
                """,
            "xl/workbook.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xmlEscape(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
                """,
            "xl/worksheets/sheet1.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(sheetRows)</sheetData></worksheet>
                """,
        ]
        return try zipPackage(url: url, files: files.mapValues { Data($0.utf8) })
    }

    // MARK: ODT (minimal ODF)

    /// ODF requires `mimetype` as the FIRST zip entry, STORED (no
    /// compression) — /usr/bin/zip handles this in two passes.
    private static func writeODT(_ url: URL, content: String, title: String?) throws -> Int {
        let paragraphs = (title.map { [$0] } ?? []) + content.components(separatedBy: "\n")
        let bodyXML = paragraphs
            .map { "<text:p text:style-name=\"Standard\">\(xmlEscape($0))</text:p>" }
            .joined()

        let files: [String: String] = [
            "mimetype": "application/vnd.oasis.opendocument.text",
            "content.xml": """
                <?xml version="1.0" encoding="UTF-8"?>
                <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:text>\(bodyXML)</office:text></office:body></office:document-content>
                """,
            "styles.xml": """
                <?xml version="1.0" encoding="UTF-8"?>
                <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" office:version="1.2"><office:styles/></office:document-styles>
                """,
            "META-INF/manifest.xml": """
                <?xml version="1.0" encoding="UTF-8"?>
                <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/></manifest:manifest>
                """,
        ]
        return try zipPackage(url: url, files: files.mapValues { Data($0.utf8) }, storedFirstEntry: "mimetype")
    }

    // MARK: - Delimited-content parsing (CSV/TSV/markdown table)

    /// Parses agent-authored table content. `separator` nil = auto-detect
    /// (markdown pipes → TSV → CSV). Handles quoted CSV fields.
    static func parseDelimited(_ content: String, separator: String?) -> [[String]] {
        let lines = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Markdown table?
        if lines.first?.hasPrefix("|") == true {
            return lines
                .filter { !$0.replacingOccurrences(of: "|", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -:")).isEmpty }
                .map { line in
                    line.split(separator: "|", omittingEmptySubsequences: false)
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .dropFirst(1).dropLast(1)
                }
        }

        let sep = separator ?? (content.contains("\t") ? "\t" : ",")
        return lines.map { parseCSVLine($0, separator: sep) }
    }

    /// One CSV line with RFC-4180 quote handling.
    private static func parseCSVLine(_ line: String, separator: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if inQuotes {
                if char == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex && line[next] == "\"" {
                        current.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if String(char) == separator {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    // MARK: - Rich content with DOCX header/footer enrichment

    /// TextKit's DOCX importer drops page headers/footers entirely —
    /// letterheads, government logos, running titles all vanish. This
    /// loader composes them back: header images + text are prepended,
    /// footer text appended, around the TextKit body. Use this everywhere
    /// rich DOCX content is displayed (viewer, DAM thumbnails).
    static func richAttributedContent(_ url: URL) throws -> NSAttributedString {
        let body = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        guard url.pathExtension.lowercased() == "docx" else { return body }

        let extras = docxHeaderFooter(url)

        // Also check for images in the body XML (TextKit often drops them)
        let bodyImages = docxBodyImages(url)
        let allHeaderImages = extras.headerImages + bodyImages

        guard !allHeaderImages.isEmpty
                || !extras.headerText.isEmpty
                || !extras.footerText.isEmpty else { return body }

        let composed = NSMutableAttributedString()
        for image in allHeaderImages {
            let attachment = NSTextAttachment()
            attachment.image = image
            // Cap inline logos to the reading column width.
            let maxWidth: CGFloat = 640
            if image.size.width > maxWidth {
                let scale = maxWidth / image.size.width
                attachment.bounds = CGRect(
                    x: 0, y: 0,
                    width: maxWidth, height: image.size.height * scale)
            }
            composed.append(NSAttributedString(attachment: attachment))
            composed.append(NSAttributedString(string: "\n"))
        }
        if !extras.headerText.isEmpty {
            composed.append(NSAttributedString(
                string: extras.headerText + "\n\n",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
        }
        composed.append(body)
        if !extras.footerText.isEmpty {
            composed.append(NSAttributedString(
                string: "\n\n" + extras.footerText,
                attributes: [.font: NSFont.systemFont(ofSize: 9),
                             .foregroundColor: NSColor.darkGray]))
        }
        return composed
    }

    /// Extracted page-header/footer content from a DOCX package.
    struct DocxExtras {
        var headerText = ""
        var headerImages: [NSImage] = []
        var footerText = ""
    }

    /// Walks word/headerN.xml (+ footers): collects <w:t> text and resolves
    /// <a:blip r:embed> references through each part's .rels into images.
    static func docxHeaderFooter(_ url: URL) -> DocxExtras {
        var extras = DocxExtras()
        guard let listing = try? unzipList(url) else { return extras }

        let headers = listing
            .filter { $0.hasPrefix("word/header") && $0.hasSuffix(".xml") }.sorted()
        for header in headers {
            let (text, images) = docxPartContent(url, part: header)
            if extras.headerText.isEmpty { extras.headerText = text }
            extras.headerImages.append(contentsOf: images)
        }

        let footers = listing
            .filter { $0.hasPrefix("word/footer") && $0.hasSuffix(".xml") }.sorted()
        for footer in footers {
            let (text, _) = docxPartContent(url, part: footer)
            if !text.isEmpty {
                extras.footerText += (extras.footerText.isEmpty ? "" : "  ·  ") + text
            }
        }
        return extras
    }

    /// Text + images of one header/footer part.
    private static func docxPartContent(_ url: URL, part: String) -> (String, [NSImage]) {
        guard let data = try? unzipData(url, entry: part) else { return ("", []) }
        let delegate = DocxHeaderDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        var images: [NSImage] = []
        let partName = (part as NSString).lastPathComponent
        if let relsData = try? unzipData(url, entry: "word/_rels/\(partName).rels") {
            let relsDelegate = DocxRelsDelegate()
            let relsParser = XMLParser(data: relsData)
            relsParser.delegate = relsDelegate
            relsParser.parse()
            for embedID in delegate.embedIDs {
                guard var target = relsDelegate.targets[embedID] else { continue }
                if target.hasPrefix("/") { target.removeFirst() }
                if !target.hasPrefix("word/") { target = "word/" + target }
                if let imageData = try? unzipData(url, entry: target),
                   let image = NSImage(data: imageData) {
                    images.append(image)
                }
            }
        }
        return (delegate.text.trimmingCharacters(in: .whitespacesAndNewlines), images)
    }

    /// Extracts inline images from the DOCX body (word/document.xml).
    /// TextKit's NSAttributedString importer often drops these.
    private static func docxBodyImages(_ url: URL) -> [NSImage] {
        guard let data = try? unzipData(url, entry: "word/document.xml") else { return [] }
        let delegate = DocxHeaderDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        var images: [NSImage] = []
        guard let relsData = try? unzipData(url, entry: "word/_rels/document.xml.rels") else { return [] }
        let relsDelegate = DocxRelsDelegate()
        let relsParser = XMLParser(data: relsData)
        relsParser.delegate = relsDelegate
        relsParser.parse()

        for embedID in delegate.embedIDs {
            guard var target = relsDelegate.targets[embedID] else { continue }
            if target.hasPrefix("/") { target.removeFirst() }
            if !target.hasPrefix("word/") { target = "word/" + target }
            if let imageData = try? unzipData(url, entry: target),
               let image = NSImage(data: imageData) {
                images.append(image)
            }
        }
        return images
    }

    // MARK: - ZIP plumbing (unzip/zip CLIs — offline, Apple-shipped)

    /// Lists entries in a ZIP package.
    static func unzipList(_ url: URL) throws -> [String] {
        let data = try runCommand("/usr/bin/unzip", ["-Z1", url.path])
        guard let listing = String(data: data, encoding: .utf8) else {
            throw DocEngineError.unreadable("could not list ZIP package")
        }
        return listing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Extracts one entry's bytes from a ZIP package.
    static func unzipData(_ url: URL, entry: String) throws -> Data {
        try runCommand("/usr/bin/unzip", ["-p", url.path, entry])
    }

    /// Stages `files` (relative path → contents) in a temp dir and zips them
    /// into a package at `url`. `storedFirstEntry` (ODF mimetype) is added
    /// first with zero compression, per the ODF spec. Internal (not private)
    /// so DocxWriter can package binary media alongside the XML parts.
    static func zipPackage(
        url: URL, files: [String: Data], storedFirstEntry: String? = nil
    ) throws -> Int {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("maestrodocs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for (relative, data) in files {
            let dest = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
        }

        try? FileManager.default.removeItem(at: url)  // zip refuses to update non-zip
        if let first = storedFirstEntry {
            _ = try runCommand("/usr/bin/zip", ["-X", "-0", "-q", "-j", url.path,
                                                staging.appendingPathComponent(first).path],
                               cwd: staging.path)
            _ = try runCommand("/usr/bin/zip", ["-X", "-9", "-q", "-r", url.path, ".",
                                                "-x", first], cwd: staging.path)
        } else {
            _ = try runCommand("/usr/bin/zip", ["-X", "-9", "-q", "-r", url.path, "."],
                               cwd: staging.path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocEngineError.createFailed("zip packaging produced no output file")
        }
        return Int((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Short-lived system command runner (stdout only; non-zero exit throws).
    static func runCommand(_ launchPath: String, _ arguments: [String], cwd: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DocEngineError.unreadable("\((launchPath as NSString).lastPathComponent) exited \(process.terminationStatus)")
        }
        return data
    }

    // MARK: - Small helpers

    /// 0 → "A", 1 → "B", … 25 → "Z", 26 → "AA" (spreadsheet column refs).
    static func columnName(_ index: Int) -> String {
        var value = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(65 + (value % 26))!) + name
            value = value / 26 - 1
        } while value >= 0
        return name
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - XMLParser delegates

/// xl/sharedStrings.xml → [String]; concatenates rich runs inside one <si>.
private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var insideSI = false
    private var insideT = false
    private var current = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        if name == "si" { insideSI = true; current = "" }
        if name == "t" && insideSI { insideT = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideT { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        if name == "t" { insideT = false }
        if name == "si" { insideSI = false; strings.append(current) }
    }
}

/// xl/workbook.xml → sheet display names.
private final class WorkbookNameDelegate: NSObject, XMLParserDelegate {
    var names: [String] = []

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        if name == "sheet", let display = attributes["name"] {
            names.append(display)
        }
    }
}

/// One worksheet → rows of display strings. Handles shared strings
/// (t="s"), inline strings (t="inlineStr"), and raw <v> numerics.
private final class SheetDelegate: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let maxRows: Int
    private let maxCols: Int
    var rows: [[String]] = []

    private var currentRow: [Int: String] = [:]
    private var currentCol = 0
    private var cellType = ""
    private var cellText = ""
    private var insideV = false
    private var insideT = false

    init(sharedStrings: [String], maxRows: Int, maxCols: Int) {
        self.sharedStrings = sharedStrings
        self.maxRows = maxRows
        self.maxCols = maxCols
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        switch name {
        case "row":
            guard rows.count < maxRows else { parser.abortParsing(); return }
            currentRow = [:]
        case "c":
            currentCol = columnIndex(attributes["r"] ?? "")
            cellType = attributes["t"] ?? ""
            cellText = ""
        case "v": insideV = true
        case "t": insideT = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideV || insideT { cellText += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        switch name {
        case "v": insideV = false
        case "t": insideT = false
        case "c":
            var value = cellText
            if cellType == "s", let idx = Int(cellText), idx >= 0, idx < sharedStrings.count {
                value = sharedStrings[idx]
            }
            if currentCol >= 0, currentCol < maxCols {
                currentRow[currentCol] = value
            }
        case "row":
            if !currentRow.isEmpty {
                let maxCol = currentRow.keys.max() ?? -1
                rows.append((0...maxCol).map { currentRow[$0] ?? "" })
            }
        default: break
        }
    }

    /// "B7" → 1; "AA12" → 26; unparseable → running order.
    private func columnIndex(_ ref: String) -> Int {
        let letters = ref.prefix(while: { $0.isLetter })
        guard !letters.isEmpty else { return currentRow.count }
        var value = 0
        for scalar in letters.uppercased().unicodeScalars {
            value = value * 26 + Int(scalar.value) - 64
        }
        return value - 1
    }
}

/// ppt/slides/slideN.xml → concatenated <a:t> text runs.
private final class SlideTextDelegate: NSObject, XMLParserDelegate {
    var text = ""
    private var insideT = false

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if (element.split(separator: ":").last.map(String.init) ?? element) == "t" {
            insideT = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideT { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if (element.split(separator: ":").last.map(String.init) ?? element) == "t" {
            insideT = false
            text += " "
        }
    }
}

/// EPUB content.opf → manifest (id → href) + spine (ordered idrefs).
private final class OPFDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        if name == "item",
           let id = attributes["id"], let href = attributes["href"] {
            manifest[id] = href
        }
        if name == "itemref", let idref = attributes["idref"] {
            spine.append(idref)
        }
    }
}

/// word/headerN.xml / footerN.xml → concatenated <w:t> text + ordered
/// <a:blip r:embed="…"> image relationship ids.
private final class DocxHeaderDelegate: NSObject, XMLParserDelegate {
    var text = ""
    var embedIDs: [String] = []
    private var insideT = false

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        if name == "t" { insideT = true }
        if name == "blip" {
            // Key arrives qualified ("r:embed"); accept any *embed key.
            for (key, value) in attributes where key.hasSuffix("embed") {
                embedIDs.append(value)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideT { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if (element.split(separator: ":").last.map(String.init) ?? element) == "t" {
            insideT = false
            text += " "
        }
    }
}

/// word/_rels/*.rels → Relationship Id → Target map.
private final class DocxRelsDelegate: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}
