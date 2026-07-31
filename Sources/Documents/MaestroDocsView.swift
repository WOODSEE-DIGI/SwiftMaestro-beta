import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - MaestroDocs App
//
// The document surface of SwiftMaestro — view and edit documents natively,
// powered by the same MaestroDocs engine the agents use (DocEngine.swift):
//
//   PDF / iWork (preview.pdf) → PDFKit PDFView (multi-page, vector)
//   RTF/RTFD/DOC              → rich NSTextView editing (native read+write)
//   TXT/MD/CSV/HTML/code      → plain NSTextView editing
//   DOCX/ODT                  → rich read-only (TextKit reads, can't write)
//   XLSX/XLSM                 → spreadsheet grid (first sheet, read-only)
//   PPTX/EPUB                 → extracted text (read-only)
//
// Saves go through ChangeGuard snapshots (data-safeguard rule) and files
// stay agent-accessible — document_read sees exactly what you see here.

// MARK: View Model

@Observable
@MainActor
final class MaestroDocsViewModel {

    enum DocKind: String {
        case none, pdf, iWork, richText, plainText, spreadsheet, readOnlyText
    }

    var currentURL: URL?
    var kind: DocKind = .none
    var isDirty = false
    var errorMessage: String?
    var statusMessage: String?

    var pdfDocument: PDFDocument?
    var richContent: NSAttributedString?
    var plainText = ""
    var sheetRows: [[String]] = []
    var readOnlyText = ""
    var recents: [URL] = []

    /// Spreadsheet editing: the active cell (formula-bar target). Nil = no
    /// cell selected. Edits write straight into sheetRows + mark dirty.
    var selectedCell: (row: Int, col: Int)?

    /// Shared handle to the live NSTextView (rich saves need the current
    /// attributed contents, which only the text view holds).
    let textViewRef = TextViewRef()

    /// Formats TextKit can both read AND write natively.
    private static let richEditable: Set<String> = ["rtf", "rtfd", "doc", "docx"]
    /// Rich display but read-only (TextKit reads, has no writer).
    private static let richReadOnly: Set<String> = ["odt"]
    /// Plain-text editable formats.
    static let plainEditable: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv",
        "html", "htm", "json", "xml", "yaml", "yml", "log",
    ]

    var isEditableKind: Bool {
        guard let ext = currentURL?.pathExtension.lowercased() else { return false }
        return Self.richEditable.contains(ext) || Self.plainEditable.contains(ext)
    }

    var canSave: Bool {
        isDirty && currentURL != nil && (isEditableKind || kind == .spreadsheet)
    }

    /// Rich document we only read (docx/odt) — offer "Edit an RTF copy".
    var isRichReadOnly: Bool {
        guard let ext = currentURL?.pathExtension.lowercased() else { return false }
        return Self.richReadOnly.contains(ext)
    }

    /// Converts the loaded rich content into an RTF the user places via save
    /// panel, then opens it for editing. The original DOCX/ODT is never
    /// touched — our DOCX writer is string-only, so a copy keeps full
    /// formatting fidelity instead of flattening the user's file on save.
    func editAsCopy() {
        guard let richContent, let url = currentURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".rtf"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            let range = NSRange(location: 0, length: richContent.length)
            let data = try richContent.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: dest, options: .atomic)
            open(dest)
            statusMessage = "Editing an RTF copy — the original is untouched"
        } catch {
            errorMessage = "Could not create editable copy: \(error.localizedDescription)"
        }
    }

    var currentFormatBadge: String {
        currentURL?.pathExtension.uppercased() ?? ""
    }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "maestrodocs.recents") ?? []
        recents = saved.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Open

    func open(_ url: URL) {
        errorMessage = nil
        statusMessage = nil
        isDirty = false
        pdfDocument = nil
        richContent = nil
        plainText = ""
        sheetRows = []
        readOnlyText = ""
        selectedCell = nil

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else {
                errorMessage = "PDFKit could not open \(url.lastPathComponent)"
                return
            }
            pdfDocument = doc
            kind = .pdf

        case "pages", "numbers", "key":
            guard let listing = try? DocEngine.unzipList(url),
                  let entry = listing.first(where: { $0.hasSuffix("preview.pdf") }),
                  let data = try? DocEngine.unzipData(url, entry: entry),
                  let doc = PDFDocument(data: data) else {
                errorMessage = "No embedded preview.pdf in this iWork package"
                return
            }
            pdfDocument = doc
            kind = .iWork

        case _ where Self.richEditable.contains(ext) || Self.richReadOnly.contains(ext):
            do {
                // richAttributedContent composes DOCX page headers/footers
                // (letterheads, logos) that TextKit drops — other formats
                // pass through unchanged.
                richContent = try DocEngine.richAttributedContent(url)
                kind = .richText
            } catch {
                errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }

        case _ where Self.plainEditable.contains(ext):
            do {
                // 8 MB cap — beyond that an NSTextView gets sluggish.
                let handle = try FileHandle(forReadingFrom: url)
                let data = (try? handle.read(upToCount: 8 * 1024 * 1024)) ?? Data()
                try? handle.close()
                plainText = String(data: data, encoding: .utf8) ?? ""
                kind = .plainText
            } catch {
                errorMessage = "Could not read \(url.lastPathComponent)"
                return
            }

        case "xlsx", "xlsm":
            do {
                sheetRows = try DocEngine.xlsxRows(url, sheetIndex: 0, maxRows: 300, maxCols: 26)
                guard !sheetRows.isEmpty else {
                    errorMessage = "No sheet data in \(url.lastPathComponent)"
                    return
                }
                kind = .spreadsheet
            } catch {
                errorMessage = "Could not parse \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }

        case "pptx", "pptm", "epub":
            do {
                readOnlyText = try DocEngine.read(url).text
                kind = .readOnlyText
            } catch {
                errorMessage = "Could not extract text: \(error.localizedDescription)"
                return
            }

        default:
            errorMessage = ".\(ext) isn't a document MaestroDocs can display"
            return
        }

        currentURL = url
        pushRecent(url)
    }

    func openViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open a document"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    // MARK: New

    func newDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "txt") ?? .plainText,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "rtf") ?? .rtf,
            UTType(filenameExtension: "csv") ?? .commaSeparatedText,
        ]
        panel.nameFieldStringValue = "Untitled.txt"
        panel.message = "Create a new text document"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        open(url)
    }

    // MARK: Save

    func save() {
        guard let url = currentURL, canSave else { return }
        let ext = url.pathExtension.lowercased()

        // Data safeguard: snapshot before overwrite (fail closed).
        do {
            try ChangeGuard.shared.snapshotForMutation(
                path: url.path, kind: .overwrite, tool: "maestrodocs")
        } catch {
            errorMessage = "Save blocked: no rollback snapshot (\(error.localizedDescription))"
            return
        }

        do {
            if kind == .plainText {
                try plainText.write(to: url, atomically: true, encoding: .utf8)
            } else if kind == .spreadsheet {
                // Write the edited grid back through the OOXML writer
                // (same engine document_create uses — round-trip verified).
                let base = url.deletingPathExtension().lastPathComponent
                try DocEngine.createXLSX(url, rows: sheetRows, sheetName: base)
            } else if kind == .richText, let storage = textViewRef.textView?.textStorage {
                let range = NSRange(location: 0, length: storage.length)
                switch ext {
                case "rtfd":
                    if textViewRef.textView?.writeRTFD(toFile: url.path, atomically: true) != true {
                        throw CocoaError(.fileWriteUnknown)
                    }
                case "doc":
                    let data = try storage.data(
                        from: range,
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
                    try data.write(to: url, options: .atomic)
                case "docx":
                    // Full rich OOXML writer: text, traits, colors, lists,
                    // links, images — not the string-only engine creator.
                    try DocxWriter.write(storage, to: url)
                default: // rtf
                    let data = try storage.data(
                        from: range,
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                    try data.write(to: url, options: .atomic)
                }
            }
            isDirty = false
            statusMessage = "Saved \(url.lastPathComponent) at \(Self.timeStamp())"
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private static func timeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss a"
        return formatter.string(from: Date())
    }

    // MARK: - Spreadsheet editing

    /// Live binding into the grid — the formula bar edits through this.
    /// Writing past a row's current end pads it with empty cells.
    func cellBinding(row: Int, col: Int) -> Binding<String> {
        Binding(
            get: {
                guard row < self.sheetRows.count, col < self.sheetRows[row].count else { return "" }
                return self.sheetRows[row][col]
            },
            set: { newValue in
                guard row < self.sheetRows.count else { return }
                if col >= self.sheetRows[row].count {
                    self.sheetRows[row] += Array(
                        repeating: "", count: col - self.sheetRows[row].count + 1)
                }
                self.sheetRows[row][col] = newValue
                self.isDirty = true
            })
    }

    /// Appends an empty row (sized to the widest row) and selects its first
    /// cell for immediate editing.
    func appendRow() {
        let cols = max(1, sheetRows.map(\.count).max() ?? 1)
        sheetRows.append(Array(repeating: "", count: cols))
        selectedCell = (row: sheetRows.count - 1, col: 0)
        isDirty = true
    }

    /// "B3"-style reference for the selected cell.
    var selectedCellRef: String? {
        guard let cell = selectedCell else { return nil }
        return "\(DocEngine.columnName(cell.col))\(cell.row + 1)"
    }

    // MARK: - Formatting (rich editable documents)

    /// Whether the formatting bar should show: rich document AND writable
    /// (rtf/rtfd/doc). Read-only rich (docx/odt) and plain text hide it.
    var formattingAvailable: Bool {
        kind == .richText && isEditableKind
    }

    /// The range formatting applies to: the selection, or the whole
    /// document when nothing is selected. `paragraph` expands to full
    /// paragraphs (heading/alignment operations).
    private func effectiveRange(paragraph: Bool) -> NSRange? {
        guard let textView = textViewRef.textView,
              let storage = textView.textStorage, storage.length > 0 else { return nil }
        var range = textView.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: storage.length) }
        if paragraph {
            range = (storage.string as NSString).paragraphRange(for: range)
        }
        return range
    }

    /// B / I — per-run font-trait toggling via NSFontManager (if any run in
    /// the range lacks the trait, all get it; otherwise it's removed).
    func toggleBold() {
        toggleFontTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleFontTrait(.italicFontMask)
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: false) else { return }
        let storage = textView.textStorage!
        let manager = NSFontManager.shared
        storage.beginEditing()
        var anyMissing = false
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            guard let font = value as? NSFont else { anyMissing = true; return }
            if !manager.traits(of: font).contains(trait) { anyMissing = true }
        }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 12)
            let converted = anyMissing
                ? manager.convert(font, toHaveTrait: trait)
                : manager.convert(font, toNotHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        storage.endEditing()
        isDirty = true
    }

    /// U — underline every run, or clear it if the range is fully underlined.
    func toggleUnderline() {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: false) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        var anyMissing = false
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) == 0 { anyMissing = true }
        }
        storage.addAttribute(
            .underlineStyle,
            value: anyMissing ? NSUnderlineStyle.single.rawValue : 0,
            range: range)
        storage.endEditing()
        isDirty = true
    }

    /// H1/H2/H3/Body — rewrites the font of the paragraph(s) at the
    /// selection to a system font at the given size/weight.
    func applyHeading(size: CGFloat, weight: NSFont.Weight) {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: true) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.addAttribute(
            .font, value: NSFont.systemFont(ofSize: size, weight: weight), range: range)
        storage.endEditing()
        isDirty = true
    }

    /// Paragraph alignment at the selection.
    func applyAlignment(_ alignment: NSTextAlignment) {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: true) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        if range.length > 0 && storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) == nil {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        isDirty = true
    }

    /// A+ / A− — scales every font in the selection by `delta` points.
    func changeFontSize(delta: CGFloat) {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: false) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let newSize = max(6, min(288, font.pointSize + delta))
            let converted = NSFontManager.shared.convert(font, toSize: newSize)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        storage.endEditing()
        isDirty = true
    }

    /// Text color from the SwiftUI ColorPicker.
    func applyTextColor(_ color: NSColor) {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: false) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: color, range: range)
        storage.endEditing()
        isDirty = true
    }

    // MARK: - Ribbon: clipboard + undo (all editable kinds)

    /// Responder-chain clipboard actions — the text view handles them when
    /// it's first responder, exactly like the Edit menu would.
    func pasteFromClipboard() {
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }

    func copySelection() {
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
    }

    func cutSelection() {
        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
    }

    func undo() {
        textViewRef.textView?.undoManager?.undo()
    }

    func redo() {
        textViewRef.textView?.undoManager?.redo()
    }

    // MARK: - Ribbon: rich-text extras

    /// S — strikethrough, same toggle semantics as underline.
    func toggleStrikethrough() {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: false) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        var anyMissing = false
        storage.enumerateAttribute(.strikethroughStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) == 0 { anyMissing = true }
        }
        storage.addAttribute(
            .strikethroughStyle,
            value: anyMissing ? NSUnderlineStyle.single.rawValue : 0,
            range: range)
        storage.endEditing()
        isDirty = true
    }

    /// Clear formatting in the range: body font, no decorations, default color.
    func clearFormatting() {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: false) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range)
        storage.addAttribute(.underlineStyle, value: 0, range: range)
        storage.addAttribute(.strikethroughStyle, value: 0, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.endEditing()
        isDirty = true
    }

    /// Highlight (background) color; nil clears it.
    func applyHighlight(_ color: NSColor?) {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: false) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        if let color {
            storage.addAttribute(.backgroundColor, value: color, range: range)
        } else {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        storage.endEditing()
        isDirty = true
    }

    /// Bullet/numbered list toggle on the paragraph(s) at the selection
    /// (TextKit draws the markers for paragraph styles carrying textLists).
    func applyList(_ marker: NSTextList.MarkerFormat) {
        mutateParagraphStyle { style in
            if style.textLists.isEmpty {
                style.textLists = [NSTextList(markerFormat: marker, options: 0)]
                style.headIndent = 22
                style.firstLineHeadIndent = 10
            } else {
                style.textLists = []
                style.headIndent = 0
                style.firstLineHeadIndent = 0
            }
        }
    }

    /// Indent/outdent the paragraph(s) at the selection by 20pt steps.
    func changeIndent(delta: CGFloat) {
        mutateParagraphStyle { style in
            style.headIndent = max(0, style.headIndent + delta)
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + delta)
        }
    }

    /// Shared paragraph-style mutation: applies `change` to every paragraph
    /// style in range, adding a fresh style to paragraphs that lack one.
    private func mutateParagraphStyle(_ change: (NSMutableParagraphStyle) -> Void) {
        guard let textView = textViewRef.textView,
              let range = effectiveRange(paragraph: true) else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            change(style)
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        if range.length > 0,
           storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) == nil {
            let style = NSMutableParagraphStyle()
            change(style)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        isDirty = true
    }

    /// Link the selected text (or insert the URL itself when nothing is
    /// selected) — RTF round-trips the .link attribute.
    func applyLink(_ url: URL) {
        guard let textView = textViewRef.textView,
              let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        storage.beginEditing()
        if range.length == 0 {
            storage.insert(
                NSAttributedString(
                    string: url.absoluteString,
                    attributes: [.link: url, .font: NSFont.systemFont(ofSize: 12)]),
                at: range.location)
        } else {
            storage.addAttribute(.link, value: url, range: range)
        }
        storage.endEditing()
        isDirty = true
    }

    /// Page break at the insertion point (form-feed exports as \page in RTF).
    /// Goes through insertText so it's undoable like typing.
    func insertPageBreak() {
        guard let textView = textViewRef.textView else { return }
        textView.insertText("\u{0C}", replacementRange: textView.selectedRange())
        isDirty = true
    }

    // MARK: - Publishing

    /// Export the current document as a PDF:
    ///   PDF        → save a copy
    ///   iWork      → write the embedded preview.pdf bytes
    ///   text kinds → NSPrintOperation (paginated, exactly the editor content)
    func exportPDF() {
        guard let url = currentURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        do {
            switch kind {
            case .pdf:
                if FileManager.default.fileExists(atPath: dest.path), dest != url {
                    try? FileManager.default.removeItem(at: dest)
                }
                if dest != url { try FileManager.default.copyItem(at: url, to: dest) }
            case .iWork:
                guard let data = pdfDocument?.dataRepresentation() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: dest, options: .atomic)
            case .richText, .plainText, .readOnlyText:
                try printTextToPDF(dest)
            default:
                errorMessage = "PDF export isn't available for spreadsheets yet — use Export CSV."
                return
            }
            statusMessage = "Exported \(dest.lastPathComponent)"
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Paginates text content into a PDF via the print system (offscreen
    /// text view, US Letter with 0.75" margins, no panels).
    private func printTextToPDF(_ dest: URL) throws {
        let content: NSAttributedString
        switch kind {
        case .plainText:
            content = NSAttributedString(
                string: plainText,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
        case .readOnlyText:
            content = NSAttributedString(
                string: readOnlyText,
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        default:
            guard let storage = textViewRef.textView?.textStorage else {
                throw CocoaError(.fileWriteUnknown)
            }
            content = storage
        }

        let printableWidth: CGFloat = 612 - 108
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: printableWidth, height: 792 - 108))
        textView.textStorage?.setAttributedString(content)

        let operation = NSPrintOperation(view: textView)
        let info = operation.printInfo
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = dest
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }

    /// Export the current spreadsheet as CSV (lossless — the grid's data).
    func exportCSV() {
        guard let url = currentURL, kind == .spreadsheet, !sheetRows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".csv"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // RFC-4180 quoting for fields containing the separator/quotes/newlines.
        let text = sheetRows.map { row in
            row.map { field in
                if field.contains(",") || field.contains("\"") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"

        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(dest.lastPathComponent)"
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Misc

    func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func pushRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > 12 { recents = Array(recents.prefix(12)) }
        UserDefaults.standard.set(recents.map(\.path), forKey: "maestrodocs.recents")
    }
}

/// Shared handle to the AppKit text view (rich saves pull the live
/// attributed string from it). Main-thread only, like NSTextView itself.
final class TextViewRef {
    var textView: NSTextView?
}

// MARK: - App View

struct MaestroDocsView: View {

    @State private var viewModel = MaestroDocsViewModel()
    @AppStorage("maestrodocs.showRecents") private var showRecents = true

    var body: some View {
            VStack(spacing: 0) {
                toolbar
                Divider()
                // Ribbon: editing tools for every editable kind; the full
                // formatting set appears for rich editable documents. Rich
                // read-only kinds (docx/odt) get the edit-as-copy offer.
                if viewModel.isEditableKind
                    && (viewModel.kind == .richText || viewModel.kind == .plainText) {
                    DocsRibbon(viewModel: viewModel)
                    Divider()
                } else if viewModel.isRichReadOnly {
                    readOnlyBar
                    Divider()
                }
                HStack(spacing: 0) {
                if showRecents && !viewModel.recents.isEmpty {
                    recentsColumn
                    Divider()
                }
                contentArea
            }
        }
        // Fill the panel window edge-to-edge — without this the VStack wraps
        // its smallest content (the welcome/error states) and the panel
        // chrome floats mid-window in a black void.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in viewModel.open(url) } }
            }
            return true
        }
    }

    // MARK: Toolbar

    /// Adaptive: full labelled layout when the tile is wide, icon-only when
    /// docked narrow. ViewThatFits picks the first variant that fits the
    /// actual width — no overlap, ever.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            wideToolbar
            compactToolbar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Slim notice for rich read-only documents (docx/odt): convert to an
    /// editable RTF copy with one click, original untouched.
    private var readOnlyBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text("Read-only — \(viewModel.currentFormatBadge) opens without editing "
                 + "to protect the original formatting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                viewModel.editAsCopy()
            } label: {
                Label("Edit an RTF Copy", systemImage: "doc.badge.plus")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var recentsToggle: some View {
        Button {
            withAnimation { showRecents.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help("Show/hide Recent Documents")
        .disabled(viewModel.recents.isEmpty)
    }

    private var saveButton: some View {
        Button {
            viewModel.save()
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Save (⌘S)")
        .disabled(!viewModel.canSave)
        .keyboardShortcut("s", modifiers: .command)
    }

    private var revealButton: some View {
        Button {
            viewModel.revealInFinder()
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .help("Reveal in Finder")
        .disabled(viewModel.currentURL == nil)
    }

    private var dirtyDot: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .help("Unsaved changes")
    }

    /// Publishing: export the open document. PDF for everything (spreadsheet
    /// exports CSV instead — lossless for grid data).
    private var exportMenu: some View {
        Menu {
            Button {
                viewModel.exportPDF()
            } label: {
                Label("Export as PDF…", systemImage: "doc.richtext")
            }
            .disabled(viewModel.kind == .spreadsheet || viewModel.kind == .none)

            Button {
                viewModel.exportCSV()
            } label: {
                Label("Export as CSV…", systemImage: "tablecells")
            }
            .disabled(viewModel.kind != .spreadsheet)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Publish / export this document")
        .disabled(viewModel.currentURL == nil)
    }

    private var formatBadge: some View {
        Text(viewModel.currentFormatBadge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var wideToolbar: some View {
        HStack(spacing: 10) {
            recentsToggle

            Button {
                viewModel.openViaPanel()
            } label: {
                Label("Open…", systemImage: "folder")
            }

            Button {
                viewModel.newDocument()
            } label: {
                Label("New", systemImage: "doc.badge.plus")
            }

            Divider()
                .frame(height: 18)

            saveButton
            revealButton
            exportMenu

            if viewModel.isDirty { dirtyDot }

            Spacer()

            if let url = viewModel.currentURL {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320)
                formatBadge
            }

            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 10) {
            recentsToggle

            Button {
                viewModel.openViaPanel()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open…")

            Button {
                viewModel.newDocument()
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .help("New text document")

            saveButton
            revealButton

            Menu {
                Button {
                    viewModel.exportPDF()
                } label: {
                    Label("Export as PDF…", systemImage: "doc.richtext")
                }
                .disabled(viewModel.kind == .spreadsheet || viewModel.kind == .none)

                Button {
                    viewModel.exportCSV()
                } label: {
                    Label("Export as CSV…", systemImage: "tablecells")
                }
                .disabled(viewModel.kind != .spreadsheet)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Publish / export this document")
            .disabled(viewModel.currentURL == nil)

            if viewModel.isDirty { dirtyDot }

            Spacer()

            if viewModel.currentURL != nil { formatBadge }
        }
    }

    // MARK: Recents

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Documents")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            List(viewModel.recents, id: \.self) { url in
                Button {
                    viewModel.open(url)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    url == viewModel.currentURL ? Color.accentColor : Color.primary)
            }
        }
        .frame(width: 210)
    }

    // MARK: Content

    @ViewBuilder
    private var contentArea: some View {
        if let error = viewModel.errorMessage {
            ContentUnavailableView(
                "Can't Open Document",
                systemImage: "doc.questionmark",
                description: Text(error))
        } else {
            switch viewModel.kind {
            case .none:
                welcomeView

            case .pdf, .iWork:
                PDFDocumentView(document: viewModel.pdfDocument)

            case .richText:
                pageColumn {
                    TextDocumentEditor(
                        richContent: viewModel.richContent,
                        isPlain: false,
                        isEditable: viewModel.isEditableKind,
                        onChange: { viewModel.isDirty = true },
                        ref: viewModel.textViewRef)
                }

            case .plainText:
                TextDocumentEditor(
                    text: $viewModel.plainText,
                    isPlain: true,
                    isEditable: true,
                    onChange: { viewModel.isDirty = true },
                    ref: viewModel.textViewRef)

            case .spreadsheet:
                VStack(spacing: 0) {
                    formulaBar
                    Divider()
                    spreadsheetView
                }

            case .readOnlyText:
                pageColumn {
                    ScrollView {
                        Text(viewModel.readOnlyText)
                            .font(.body)
                            .foregroundStyle(.black)   // paper page, like rich docs
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                    .background(Color.white)
                }
            }
        }
    }

    /// Word/Pages-style reading column: content capped at a readable page
    /// width, centered, with gutter background around the "page". Without
    /// this, documents render as a full-tile wall of text (unreadable at
    /// wide dock sizes). Rounded corners + shadow sell the paper metaphor.
    private func pageColumn<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
                .frame(maxWidth: 780, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                .padding(.vertical, 12)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Welcome (empty state)

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.richtext")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text("MaestroDocs")
                .font(.largeTitle.weight(.bold))

            Text("Open or drop a document to view or edit it natively —\nno Microsoft Office, no LibreOffice, no cloud.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Format chips — what the engine handles. Two fixed rows so
            // narrow tiles never overflow.
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(["PDF", "DOCX", "XLSX", "PPTX"], id: \.self) { name in
                        formatChip(name)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(["ODT", "EPUB", "iWork", "TXT"], id: \.self) { name in
                        formatChip(name)
                    }
                }
            }
            .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    welcomeButtons
                }
                VStack(spacing: 10) {
                    welcomeButtons
                }
            }
            .padding(.top, 6)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var welcomeButtons: some View {
        Button {
            viewModel.openViaPanel()
        } label: {
            Label("Open Document…", systemImage: "folder")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Button {
            viewModel.newDocument()
        } label: {
            Label("New Text Document", systemImage: "doc.badge.plus")
        }
        .controlSize(.large)
    }

    private func formatChip(_ name: String) -> some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
    }

    /// Formula bar (spreadsheet): cell reference + value editor, Excel-style.
    /// Editing here writes into the grid and marks the document dirty.
    private var formulaBar: some View {
        HStack(spacing: 10) {
            Text(viewModel.selectedCellRef ?? "—")
                .font(.caption.monospaced())
                .frame(width: 44, alignment: .center)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if let cell = viewModel.selectedCell {
                TextField(
                    "Cell value",
                    text: viewModel.cellBinding(row: cell.row, col: cell.col))
                .textFieldStyle(.roundedBorder)
            } else {
                Text("Select a cell to edit — ⌘S saves back to the spreadsheet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button {
                viewModel.appendRow()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add row")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var spreadsheetView: some View {
        let cols = max(1, viewModel.sheetRows.map(\.count).max() ?? 1)
        return ScrollView([.horizontal, .vertical]) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(150), spacing: 0), count: cols),
                spacing: 0
            ) {
                ForEach(Array(viewModel.sheetRows.enumerated()), id: \.offset) { rowIndex, row in
                    ForEach(0..<cols, id: \.self) { colIndex in
                        let value = colIndex < row.count ? row[colIndex] : ""
                        let isSelected = viewModel.selectedCell?.row == rowIndex
                            && viewModel.selectedCell?.col == colIndex
                        Text(value)
                            .font(rowIndex == 0 ? .caption.weight(.semibold) : .caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.2)
                                    : rowIndex == 0
                                        ? Color(nsColor: .controlBackgroundColor)
                                        : (rowIndex % 2 == 0
                                            ? Color(nsColor: .alternatingContentBackgroundColors[1])
                                            : Color.clear))
                            .overlay(
                                Rectangle()
                                    .frame(height: 0.5)
                                    .foregroundStyle(Color.secondary.opacity(0.3)),
                                alignment: .bottom)
                            .overlay(
                                isSelected
                                    ? Rectangle()
                                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                    : nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedCell = (row: rowIndex, col: colIndex)
                            }
                    }
                }
            }
        }
    }
}

// MARK: - PDFKit bridge

/// Multi-page PDF viewer (continuous scroll, auto-scale).
struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
    }
}

// MARK: - NSTextView bridge

/// Plain/rich text editor backed by NSTextView. Rich content is owned by
/// the text view itself (formatting lives there); plain text is bound.
struct TextDocumentEditor: NSViewRepresentable {
    var text: Binding<String>?
    var richContent: NSAttributedString?
    let isPlain: Bool
    let isEditable: Bool
    let onChange: () -> Void
    let ref: TextViewRef

    init(text: Binding<String>, isPlain: Bool, isEditable: Bool,
         onChange: @escaping () -> Void, ref: TextViewRef) {
        self.text = text
        self.richContent = nil
        self.isPlain = isPlain
        self.isEditable = isEditable
        self.onChange = onChange
        self.ref = ref
    }

    init(richContent: NSAttributedString?, isPlain: Bool, isEditable: Bool,
         onChange: @escaping () -> Void, ref: TextViewRef) {
        self.text = nil
        self.richContent = richContent
        self.isPlain = isPlain
        self.isEditable = isEditable
        self.onChange = onChange
        self.ref = ref
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: TextDocumentEditor
        init(_ parent: TextDocumentEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.isPlain {
                parent.text?.wrappedValue = textView.string
            }
            parent.onChange()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Manual container stack around ListAwareTextView (the
        // scrollableTextView() factory can't take a subclass) — same
        // resizability contract as the factory: vertical-resize,
        // width-tracks-text-view.
        let textView = ListAwareTextView(frame: .zero)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.isRichText = !isPlain
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.usesFontPanel = !isPlain
        textView.isAutomaticQuoteSubstitutionEnabled = !isPlain
        textView.delegate = context.coordinator
        if isPlain {
            // Adaptive colors: the user's own text follows system dark mode.
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.string = text?.wrappedValue ?? ""
        } else {
            // PAPER mode: document-authored colors (e.g. DOCX's explicit
            // black) assume a white page. Rendering them on NSTextView's
            // dark-mode background makes text unreadable — Word/Pages solve
            // this by keeping the page white even in dark mode, with grey
            // gutters (our pageColumn) around it.
            textView.backgroundColor = .white
            textView.textColor = .black   // author-default (uncolored) runs
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .white
            if let richContent {
                textView.textStorage?.setAttributedString(richContent)
            }
        }
        ref.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Plain binding: only push external changes (avoid cursor jumps while
        // typing — the coordinator owns user-originated updates).
        if isPlain, let bound = text?.wrappedValue, textView.string != bound {
            textView.string = bound
        }
    }
}
