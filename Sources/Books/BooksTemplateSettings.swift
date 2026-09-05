import AppKit
import Foundation

// MARK: - Simple template settings (QuickBooks-style layout editor)
//
// Structured layout choices for users who never want to see a merge field:
// toggles decide which blocks appear, text fields rename labels and set the
// title. Simple mode GENERATES the RTF template from these settings, so the
// publish path stays single (template file → InvoiceTemplateRenderer).
// Advanced (RTF) edits are replaced the next time a Simple setting changes.
struct BooksTemplateSettings: Codable, Equatable, Sendable {

    /// Literal invoice title line; empty = the {invoice.title} merge field
    /// (which follows Business settings: TAX INVOICE / VAT INVOICE / …).
    var invoiceTitle = ""
    var showSellerDetails = true
    var showNumber = true
    var showDates = true
    var showStatus = true
    var showClientDetails = true
    var showNotes = true
    var showPaymentDetails = true
    /// Subtotal / tax / paid / balance rows; the grand total always shows.
    var showTotalsBreakdown = true

    var billToLabel = "BILL TO"
    var notesLabel = "NOTES"
    var paymentLabel = "PAYMENT"

    // MARK: Persistence (UserDefaults — preferences, not secrets)

    static func load() -> BooksTemplateSettings {
        guard let data = UserDefaults.standard.data(forKey: "maestrobooks.templateSettings"),
              let settings = try? JSONDecoder().decode(BooksTemplateSettings.self, from: data)
        else { return BooksTemplateSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "maestrobooks.templateSettings")
        }
    }

    // MARK: Template generation

    /// Builds the RTF template honoring the toggles/labels and writes it to
    /// the template file. Returns the template URL.
    @discardableResult
    func applyToTemplateFile() throws -> URL {
        try FileManager.default.createDirectory(
            at: BooksTemplate.templateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try generateTemplateRTF()
        try data.write(to: BooksTemplate.templateFileURL, options: .atomic)
        return BooksTemplate.templateFileURL
    }

    /// The generated template as RTF data (settings-driven layout).
    func generateTemplateRTF() throws -> Data {
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
        if showSellerDetails {
            append("{seller.details}\n", font: .systemFont(ofSize: 9), color: .darkGray)
        }
        append("\n", font: .systemFont(ofSize: 6))

        append((invoiceTitle.isEmpty ? "{invoice.title}" : invoiceTitle) + "\n",
               font: .boldSystemFont(ofSize: 20), style: right)
        if showNumber {
            append("{invoice.number}\n", font: .boldSystemFont(ofSize: 11), style: right)
        }
        if showDates {
            append("Issued {invoice.issue_date}   Due {invoice.due_date}\n",
                   font: .systemFont(ofSize: 10), style: right)
        }
        if showStatus {
            append("{invoice.status}\n", font: .boldSystemFont(ofSize: 10),
                   color: .darkGray, style: right)
        }
        append("\n", font: .systemFont(ofSize: 8))

        append(billToLabel.isEmpty ? "BILL TO\n" : billToLabel + "\n",
               font: .boldSystemFont(ofSize: 10), color: .darkGray)
        append("{client.name}\n", font: .boldSystemFont(ofSize: 11))
        if showClientDetails {
            append("{client.details}\n", font: .systemFont(ofSize: 10))
        }
        append("\n", font: .systemFont(ofSize: 8))

        append("{items}\n", font: .systemFont(ofSize: 10))
        append("\n", font: .systemFont(ofSize: 8))

        if showTotalsBreakdown {
            append("Subtotal:  {totals.subtotal}\n", font: .systemFont(ofSize: 10), style: right)
            append("{totals.tax_label}:  {totals.tax}\n", font: .systemFont(ofSize: 10), style: right)
        }
        append("Total {invoice.currency}:  {totals.total}\n",
               font: .boldSystemFont(ofSize: 12), style: right)
        if showTotalsBreakdown {
            append("Paid:  {totals.paid}\n", font: .systemFont(ofSize: 10),
                   color: .darkGray, style: right)
            append("Balance due:  {totals.balance}\n",
                   font: .boldSystemFont(ofSize: 10), style: right)
        }

        if showNotes {
            append("\n", font: .systemFont(ofSize: 8))
            append((notesLabel.isEmpty ? "NOTES" : notesLabel) + "\n",
                   font: .boldSystemFont(ofSize: 10), color: .darkGray)
            append("{invoice.notes}\n", font: .systemFont(ofSize: 9))
        }

        if showPaymentDetails {
            append("\n\n\n", font: .systemFont(ofSize: 12))
            append((paymentLabel.isEmpty ? "PAYMENT" : paymentLabel) + "\n",
                   font: .boldSystemFont(ofSize: 10), color: .darkGray)
            append("{seller.payment_details}", font: .systemFont(ofSize: 9))
        }

        return try document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: Sample data (live preview)

    /// A realistic sample invoice for the designer preview. Uses the user's
    /// own business details (seller) so the preview feels like theirs.
    static func sampleData(seller: BooksSeller)
        -> (invoice: BooksInvoice, client: BooksClient,
            items: [BooksLineItem], payments: [BooksPayment]) {
        let now = Date()
        let client = BooksClient(
            id: nil, name: "Sample Client Pty Ltd",
            email: "accounts@sample.example", phone: nil,
            poAddressLine1: "1 Example St", poAddressLine2: nil,
            poCity: "Sydney", poRegion: "NSW", poPostalCode: "2000",
            poCountry: "Australia", taxNumber: nil, notes: nil, xeroID: nil,
            reportToBlacklist: true, createdAt: now, updatedAt: now)
        let invoice = BooksInvoice(
            id: nil, number: "INV-2026-0001", clientID: 0,
            issueDate: now, dueDate: now.addingTimeInterval(14 * 86400),
            statusRaw: BooksInvoiceStatus.authorised.rawValue,
            currency: seller.currency, taxRate: seller.taxRate,
            taxLabel: seller.taxLabel, taxType: seller.taxType,
            accountCode: seller.defaultAccountCode,
            notes: "Thank you for your business.",
            pdfPath: nil, xeroID: nil, reportToBlacklist: nil,
            createdAt: now, updatedAt: now)
        let items = [
            BooksLineItem(
                id: nil, invoiceID: 0, position: 0,
                description: "Professional services", quantity: 8,
                unitAmount: 70.23, discount: 10, accountCode: nil, taxType: nil),
            BooksLineItem(
                id: nil, invoiceID: 0, position: 1,
                description: "Travel", quantity: 1,
                unitAmount: 50, discount: 0, accountCode: nil, taxType: nil),
        ]
        return (invoice, client, items, [])
    }
}
