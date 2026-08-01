import AppKit
import Foundation

// MARK: - Invoice template store
//
// The user-editable invoice template lives outside the database so it can
// be opened, designed, and versioned like any document. Missing template →
// publish falls back to the built-in InvoicePDFRenderer layout.
enum BooksTemplate {

    static var templateFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro/Books", isDirectory: true)
            .appendingPathComponent("invoice-template.rtf")
    }

    static var templateExists: Bool {
        FileManager.default.fileExists(atPath: templateFileURL.path)
    }

    /// Merge fields grouped for the designer's Insert Field menu.
    static let fieldGroups: [(group: String, fields: [String])] = [
        ("Invoice", [
            "{invoice.title}", "{invoice.number}", "{invoice.issue_date}",
            "{invoice.due_date}", "{invoice.status}", "{invoice.currency}",
            "{invoice.notes}",
        ]),
        ("Client", ["{client.name}", "{client.details}"]),
        ("Business", ["{seller.name}", "{seller.details}", "{seller.payment_details}"]),
        ("Items", ["{items}"]),
        ("Totals", [
            "{totals.subtotal}", "{totals.tax_label}", "{totals.tax}",
            "{totals.total}", "{totals.paid}", "{totals.balance}",
        ]),
    ]

    /// Writes the default template (mirroring the built-in PDF layout) when
    /// none exists yet. Returns the template URL either way.
    @discardableResult
    static func ensureDefaultTemplate() throws -> URL {
        if !templateExists {
            try FileManager.default.createDirectory(
                at: templateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try defaultTemplateRTF().write(to: templateFileURL, options: .atomic)
        }
        return templateFileURL
    }

    /// Destructive reset — the page asks for confirmation first.
    static func resetToDefault() throws {
        try? FileManager.default.removeItem(at: templateFileURL)
        try ensureDefaultTemplate()
    }

    /// The built-in layout as an editable RTF: business header, right-aligned
    /// title block, BILL TO, {items} table anchor, totals block, notes,
    /// payment footer. Users redesign from here.
    static func defaultTemplateRTF() throws -> Data {
        let document = NSMutableAttributedString()
        let right = NSMutableParagraphStyle()
        right.alignment = .right

        func append(_ text: String, font: NSFont, color: NSColor = .black,
                    style: NSParagraphStyle? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color]
            if let style { attributes[.paragraphStyle] = style }
            document.append(NSAttributedString(string: text, attributes: attributes))
        }

        append("{seller.name}\n", font: .boldSystemFont(ofSize: 16))
        append("{seller.details}\n", font: .systemFont(ofSize: 9), color: .darkGray)
        append("\n", font: .systemFont(ofSize: 6))

        append("{invoice.title}\n", font: .boldSystemFont(ofSize: 20), style: right)
        append("{invoice.number}\n", font: .boldSystemFont(ofSize: 11), style: right)
        append("Issued {invoice.issue_date}   Due {invoice.due_date}\n",
               font: .systemFont(ofSize: 10), style: right)
        append("{invoice.status}\n", font: .boldSystemFont(ofSize: 10),
               color: .darkGray, style: right)
        append("\n", font: .systemFont(ofSize: 8))

        append("BILL TO\n", font: .boldSystemFont(ofSize: 10), color: .darkGray)
        append("{client.name}\n", font: .boldSystemFont(ofSize: 11))
        append("{client.details}\n", font: .systemFont(ofSize: 10))
        append("\n", font: .systemFont(ofSize: 8))

        append("{items}\n", font: .systemFont(ofSize: 10))
        append("\n", font: .systemFont(ofSize: 8))

        append("Subtotal:  {totals.subtotal}\n", font: .systemFont(ofSize: 10), style: right)
        append("{totals.tax_label}:  {totals.tax}\n", font: .systemFont(ofSize: 10), style: right)
        append("Total {invoice.currency}:  {totals.total}\n",
               font: .boldSystemFont(ofSize: 12), style: right)
        append("Paid:  {totals.paid}\n", font: .systemFont(ofSize: 10),
               color: .darkGray, style: right)
        append("Balance due:  {totals.balance}\n",
               font: .boldSystemFont(ofSize: 10), style: right)
        append("\n", font: .systemFont(ofSize: 8))

        append("NOTES\n", font: .boldSystemFont(ofSize: 10), color: .darkGray)
        append("{invoice.notes}\n", font: .systemFont(ofSize: 9))
        append("\n\n\n\n", font: .systemFont(ofSize: 12))

        append("PAYMENT\n", font: .boldSystemFont(ofSize: 10), color: .darkGray)
        append("{seller.payment_details}", font: .systemFont(ofSize: 9))

        let range = NSRange(location: 0, length: document.length)
        return try document.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}
