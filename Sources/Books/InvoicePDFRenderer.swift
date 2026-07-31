import AppKit
import Foundation

// MARK: - Invoice PDF Renderer (A4, Australian "TAX INVOICE" layout)
//
// CoreGraphics vector PDF: seller letterhead, bill-to, itemized table,
// GST breakdown, payment footer. Multi-page when items overflow.
enum InvoicePDFRenderer {

    private static let margin: CGFloat = 50

    /// Renders the invoice to `dest`. Returns bytes written.
    @discardableResult
    static func render(
        invoice: BooksInvoice, client: BooksClient, items: [BooksLineItem],
        payments: [BooksPayment], seller: BooksSeller, to dest: URL
    ) throws -> Int {
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
        guard let consumer = CGDataConsumer(url: dest as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let painter = Painter(ctx: ctx, pageRect: pageRect)
        let rightX = pageRect.width - margin

        // MARK: Header

        painter.beginPage()
        var cursorY = margin   // distance from page top
        painter.draw(seller.name.isEmpty ? "Your Business" : seller.name,
                     x: margin, y: cursorY, font: .boldSystemFont(ofSize: 16))
        cursorY += 22
        for detail in [seller.abn.isEmpty ? nil : "\(seller.taxRegistrationLabel) \(seller.abn)",
                       seller.address, seller.email, seller.phone]
            .compactMap({ $0 }).filter({ !$0.isEmpty }) {
            painter.draw(detail, x: margin, y: cursorY,
                         font: .systemFont(ofSize: 9), color: .darkGray)
            cursorY += 13
        }

        var titleY = margin
        painter.drawRight(
            seller.resolvedInvoiceTitle(fallbackTaxLabel: invoice.taxLabel,
                                        taxRate: invoice.taxRate),
            rightX: rightX, y: titleY, font: .boldSystemFont(ofSize: 20))
        titleY += 26
        painter.drawRight(invoice.number, rightX: rightX, y: titleY,
                          font: .boldSystemFont(ofSize: 11))
        titleY += 16
        painter.drawRight("Issued \(dateString(invoice.issueDate))", rightX: rightX,
                          y: titleY, font: .systemFont(ofSize: 10))
        titleY += 14
        if let due = invoice.dueDate {
            painter.drawRight("Due \(dateString(due))", rightX: rightX,
                              y: titleY, font: .systemFont(ofSize: 10))
            titleY += 14
        }
        painter.drawRight(invoice.status.displayName.uppercased(), rightX: rightX, y: titleY,
                          font: .boldSystemFont(ofSize: 10),
                          color: invoice.status == .paid ? .systemGreen : .darkGray)

        cursorY = max(cursorY, titleY) + 20   // below whichever column ran longer
        painter.rule(x1: margin, x2: rightX, y: cursorY)
        cursorY += 22

        // Bill To
        painter.draw("BILL TO", x: margin, y: cursorY,
                     font: .boldSystemFont(ofSize: 10), color: .darkGray)
        cursorY += 16
        painter.draw(client.name, x: margin, y: cursorY, font: .boldSystemFont(ofSize: 11))
        cursorY += 15
        for text in [client.addressBlock, client.email, client.taxNumber.map { "Tax ID \($0)" }]
            .compactMap({ $0 }).filter({ !$0.isEmpty }) {
            painter.draw(text, x: margin, y: cursorY, font: .systemFont(ofSize: 10))
            cursorY += 14
        }
        cursorY += 16

        // MARK: Items + totals + footer (part 2)

        finishBody(
            painter: painter, invoice: invoice, items: items, payments: payments,
            seller: seller, cursorY: &cursorY, rightX: rightX)

        ctx.closePDF()
        return Int((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Body (items table, totals, notes, payment footer)

    private static func finishBody(
        painter: Painter, invoice: BooksInvoice, items: [BooksLineItem],
        payments: [BooksPayment], seller: BooksSeller,
        cursorY: inout CGFloat, rightX: CGFloat
    ) {
        let bold10 = NSFont.boldSystemFont(ofSize: 10)
        let regular10 = NSFont.systemFont(ofSize: 10)
        let regular9 = NSFont.systemFont(ofSize: 9)
        let gray = NSColor.darkGray
        let contentWidth = painter.pageRect.width - margin * 2
        let qtyRight = margin + contentWidth * 0.62
        let unitRight = margin + contentWidth * 0.80

        func tableHeader() {
            painter.draw("Description", x: margin, y: cursorY, font: bold10, color: gray)
            painter.drawRight("Qty", rightX: qtyRight, y: cursorY, font: bold10, color: gray)
            painter.drawRight("Unit", rightX: unitRight, y: cursorY, font: bold10, color: gray)
            painter.drawRight("Amount", rightX: rightX, y: cursorY, font: bold10, color: gray)
            cursorY += 14
            painter.rule(x1: margin, x2: rightX, y: cursorY, gray: 0.5)
            cursorY += 8
        }

        tableHeader()

        for item in items {
            if cursorY > painter.pageRect.height - margin - 170 {
                painter.endPage()
                painter.beginPage()
                cursorY = margin
                tableHeader()
            }
            painter.draw(item.description, x: margin, y: cursorY, font: regular10)
            painter.drawRight(BooksMoney.plain(item.quantity), rightX: qtyRight,
                              y: cursorY, font: regular10)
            painter.drawRight(BooksMoney.plain(item.unitAmount), rightX: unitRight,
                              y: cursorY, font: regular10)
            painter.drawRight(BooksMoney.plain(item.amount), rightX: rightX,
                              y: cursorY, font: regular10)
            cursorY += 16
            if item.discount > 0 {
                painter.draw("Less \(String(format: "%g", item.discount))% discount",
                             x: margin + 14, y: cursorY - 3, font: regular9, color: gray)
                cursorY += 11
            }
        }

        painter.rule(x1: margin, x2: rightX, y: cursorY, gray: 0.5)
        cursorY += 18

        // Totals block (right-aligned).
        let subtotal = items.reduce(0) { $0 + $1.amount }
        let tax = subtotal * invoice.taxRate
        let total = subtotal + tax
        let paid = payments.reduce(0) { $0 + $1.amount }
        let balance = total - paid

        painter.drawRight("Subtotal", rightX: unitRight, y: cursorY, font: regular10, color: gray)
        painter.drawRight(BooksMoney.format(subtotal, currency: invoice.currency),
                          rightX: rightX, y: cursorY, font: regular10)
        cursorY += 15
        // Tax row only when the invoice actually carries tax (0% = tax-free).
        if invoice.taxRate > 0 {
            painter.drawRight("\(invoice.taxLabel) (\(invoice.taxRatePercentString)%)",
                              rightX: unitRight, y: cursorY, font: regular10, color: gray)
            painter.drawRight(BooksMoney.format(tax, currency: invoice.currency),
                              rightX: rightX, y: cursorY, font: regular10)
            cursorY += 15
        }
        cursorY += 2
        painter.rule(x1: unitRight - 60, x2: rightX, y: cursorY, gray: 0.5)
        cursorY += 8
        painter.drawRight("TOTAL \(invoice.currency)", rightX: unitRight, y: cursorY, font: bold10)
        painter.drawRight(BooksMoney.format(total, currency: invoice.currency),
                          rightX: rightX, y: cursorY, font: NSFont.boldSystemFont(ofSize: 12))
        cursorY += 20

        if paid > 0 {
            painter.drawRight("Paid", rightX: unitRight, y: cursorY, font: regular10, color: gray)
            painter.drawRight("-" + BooksMoney.format(paid, currency: invoice.currency),
                              rightX: rightX, y: cursorY, font: regular10)
            cursorY += 15
            painter.drawRight("Balance due", rightX: unitRight, y: cursorY, font: bold10)
            painter.drawRight(BooksMoney.format(balance, currency: invoice.currency),
                              rightX: rightX, y: cursorY, font: bold10)
            cursorY += 20
        }

        // Notes.
        if let notes = invoice.notes, !notes.isEmpty {
            cursorY += 10
            painter.draw("NOTES", x: margin, y: cursorY, font: bold10, color: gray)
            cursorY += 15
            for line in notes.components(separatedBy: "\n") {
                painter.draw(line, x: margin, y: cursorY, font: regular9)
                cursorY += 13
            }
        }

        // Payment footer (pinned to the bottom of the LAST page, top-based y).
        if !seller.paymentDetails.isEmpty {
            let footerTop = painter.pageRect.height - margin - 30
            painter.rule(x1: margin, x2: rightX, y: footerTop - 8, gray: 0.6)
            painter.draw("PAYMENT", x: margin, y: footerTop, font: bold10, color: gray)
            for (index, line) in seller.paymentDetails.components(separatedBy: "\n").enumerated() {
                painter.draw(line, x: margin, y: footerTop + 14 + CGFloat(index) * 12,
                             font: regular9)
            }
        }

        painter.endPage()
    }
}

// MARK: - Painter (page drawing primitives)

/// Flipped top-left-origin drawing into a PDF context.
///
/// CRITICAL: NSAttributedString.draw is AppKit drawing — it renders NOTHING
/// without a current NSGraphicsContext (pure-CG rules still drew, which is
/// why the "blank PDF" bug showed lines but no text). beginPage installs a
/// flipped NSGraphicsContext + flipped CTM; all primitives then use
/// distance-from-top y directly and text draws upright.
final class Painter {
    let ctx: CGContext
    let pageRect: CGRect

    init(ctx: CGContext, pageRect: CGRect) {
        self.ctx = ctx
        self.pageRect = pageRect
    }

    func beginPage() {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(pageRect)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageRect.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    }

    func endPage() {
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        ctx.endPDFPage()
    }

    /// y = distance from page top (text top edge).
    func draw(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor = .black) {
        let attr = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        attr.draw(at: NSPoint(x: x, y: y))
    }

    func drawRight(_ text: String, rightX: CGFloat, y: CGFloat, font: NSFont, color: NSColor = .black) {
        let attr = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        draw(text, x: rightX - attr.size().width, y: y, font: font, color: color)
    }

    /// y = distance from page top (matches text coordinates).
    func rule(x1: CGFloat, x2: CGFloat, y: CGFloat, gray: CGFloat = 0.75) {
        ctx.setStrokeColor(NSColor(white: gray, alpha: 1).cgColor)
        ctx.setLineWidth(0.7)
        ctx.move(to: CGPoint(x: x1, y: y))
        ctx.addLine(to: CGPoint(x: x2, y: y))
        ctx.strokePath()
    }
}
