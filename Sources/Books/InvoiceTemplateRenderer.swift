import AppKit
import CoreText
import Foundation

// MARK: - Invoice template renderer
//
// Renders an invoice through the user-editable rich-text template
// (~/Library/Application Support/SwiftMaestro/Books/invoice-template.rtf):
// merge fields like {client.name} are replaced in place (inheriting the
// template's own formatting at that spot), {items} becomes a tab-aligned
// items table, and the merged document is paginated to A4 via CoreText.
// The structured database stays authoritative — design lives in the file.
enum InvoiceTemplateRenderer {

    static func render(
        invoice: BooksInvoice, client: BooksClient, items: [BooksLineItem],
        payments: [BooksPayment], seller: BooksSeller, templateURL: URL, to dest: URL
    ) throws -> Int {
        let merged = try mergedDocument(
            invoice: invoice, client: client, items: items,
            payments: payments, seller: seller, templateURL: templateURL)
        return try paginateToPDF(merged, to: dest)
    }

    /// Template + live data merged into one document — exposed for the
    /// designer's live preview (no PDF round-trip needed on screen).
    static func mergedDocument(
        invoice: BooksInvoice, client: BooksClient, items: [BooksLineItem],
        payments: [BooksPayment], seller: BooksSeller, templateURL: URL
    ) throws -> NSAttributedString {
        let template = try NSAttributedString(
            url: templateURL,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
        let merged = NSMutableAttributedString(attributedString: template)

        replaceItems(in: merged, invoice: invoice, items: items)
        for (token, value) in scalarFields(
            invoice: invoice, client: client, items: items, payments: payments, seller: seller
        ) {
            replaceAll(token, with: value, in: merged)
        }
        return merged
    }

    // MARK: - Scalar fields

    private static func scalarFields(
        invoice: BooksInvoice, client: BooksClient, items: [BooksLineItem],
        payments: [BooksPayment], seller: BooksSeller
    ) -> [(token: String, value: String)] {
        let subtotal = items.reduce(0) { $0 + $1.amount }
        let tax = subtotal * invoice.taxRate
        let total = subtotal + tax
        let paid = payments.reduce(0) { $0 + $1.amount }
        let money: (Double) -> String = { BooksMoney.format($0, currency: invoice.currency) }

        let sellerDetails = [
            seller.abn.isEmpty ? nil : "\(seller.taxRegistrationLabel) \(seller.abn)",
            seller.address, seller.email, seller.phone,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let clientDetails = [
            client.addressBlock, client.email, client.taxNumber.map { "Tax ID \($0)" },
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

        return [
            ("{invoice.title}",
             seller.resolvedInvoiceTitle(fallbackTaxLabel: invoice.taxLabel,
                                         taxRate: invoice.taxRate)),
            ("{invoice.number}", invoice.number),
            ("{invoice.issue_date}", InvoicePDFRenderer.dateString(invoice.issueDate)),
            ("{invoice.due_date}",
             invoice.dueDate.map { InvoicePDFRenderer.dateString($0) } ?? "—"),
            ("{invoice.status}", invoice.status.displayName.uppercased()),
            ("{invoice.currency}", invoice.currency),
            ("{invoice.notes}", invoice.notes ?? ""),
            ("{client.name}", client.name),
            ("{client.details}", clientDetails),
            ("{seller.name}", seller.name.isEmpty ? "Your Business" : seller.name),
            ("{seller.details}", sellerDetails),
            ("{seller.payment_details}", seller.paymentDetails),
            ("{totals.subtotal}", money(subtotal)),
            ("{totals.tax_label}",
             "\(invoice.taxLabel) (\(invoice.taxRatePercentString)%)"),
            ("{totals.tax}", money(tax)),
            ("{totals.total}", money(total)),
            ("{totals.paid}", money(paid)),
            ("{totals.balance}", money(total - paid)),
        ]
    }

    /// Replaces every occurrence of `token`, scanning forward so a
    /// replacement value can never be re-matched (no infinite loops).
    private static func replaceAll(
        _ token: String, with value: String, in text: NSMutableAttributedString
    ) {
        var position = 0
        while true {
            let current = text.string as NSString
            guard position < current.length else { return }
            let found = current.range(
                of: token, range: NSRange(location: position, length: current.length - position))
            guard found.location != NSNotFound else { return }
            text.replaceCharacters(in: found, with: value)
            position = found.location + value.count
        }
    }

    // MARK: - Items table

    private static func replaceItems(
        in merged: NSMutableAttributedString, invoice: BooksInvoice, items: [BooksLineItem]
    ) {
        let found = (merged.string as NSString).range(of: "{items}")
        guard found.location != NSNotFound else { return }
        let table = itemsTable(
            items: items.sorted { $0.position < $1.position }, invoice: invoice)
        merged.replaceCharacters(in: found, with: table)
    }

    /// Tab-aligned items table for the A4 text width (495pt at 50pt margins):
    /// description flexible, Qty/Unit/Amount right-aligned at fixed stops.
    private static func itemsTable(items: [BooksLineItem], invoice: BooksInvoice) -> NSAttributedString {
        let stops = [
            NSTextTab(textAlignment: .right, location: 330, options: [:]),
            NSTextTab(textAlignment: .right, location: 415, options: [:]),
            NSTextTab(textAlignment: .right, location: 495, options: [:]),
        ]
        let columnStyle = NSMutableParagraphStyle()
        columnStyle.tabStops = stops

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "Description\tQty\tUnit\tAmount\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.darkGray,
                .paragraphStyle: columnStyle,
            ]))
        for item in items {
            result.append(NSAttributedString(
                string: "\(item.description)\t\(BooksMoney.plain(item.quantity))"
                    + "\t\(BooksMoney.plain(item.unitAmount))\t\(BooksMoney.plain(item.amount))\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .paragraphStyle: columnStyle,
                ]))
            if item.discount > 0 {
                result.append(NSAttributedString(
                    string: "    Less \(String(format: "%g", item.discount))% discount\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 9),
                        .foregroundColor: NSColor.darkGray,
                    ]))
            }
        }
        return result
    }

    // MARK: - CoreText pagination (A4, 50pt margins)

    private static func paginateToPDF(_ content: NSAttributedString, to dest: URL) throws -> Int {
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: dest as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        var location = 0
        while location < content.length {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(pageRect)
            // Modern CoreText draws glyphs upright with top-down layout in
            // a PDF context with NO transforms (4-variant verified): any
            // textMatrix/CTM flip breaks either glyph orientation or layout
            // order. Keep identity.
            ctx.textMatrix = .identity
            let path = CGPath(rect: pageRect.insetBy(dx: 50, dy: 50), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }   // overflow safeguard
            location += visible.length
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return Int((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
