import Foundation

// MARK: - Xero Export Service
//
// Emits CSV files in Xero's own import-template shapes, so everything
// raised in MaestroBooks drops straight into Xero:
//   Settings → Import → Invoices  (full Xero invoice header)
//   Settings → Import → Contacts  (core contact columns)
//
// One CSV row per LINE ITEM — Xero groups rows into invoices by
// InvoiceNumber. Dates dd/MM/yyyy, amounts 2dp, Type ACCREC (sales).
enum XeroExportService {

    // MARK: - Invoices CSV (Xero import template)

    /// Full Xero invoice-import header (unused columns left blank).
    private static let invoiceHeader = [
        "ContactName", "EmailAddress", "POAddressLine1", "POAddressLine2",
        "POAddressLine3", "POAddressLine4", "POCity", "PORegion",
        "POPostalCode", "POCountry", "InvoiceNumber", "Reference",
        "InvoiceDate", "DueDate", "PlannedPaymentDate", "SubTotal",
        "TotalTax", "Total", "InvoiceAmountPaid", "InvoiceAmountDue",
        "InventoryItemCode", "Description", "Quantity", "UnitAmount",
        "Discount", "AccountCode", "TaxType", "TaxAmount",
        "TrackingName1", "TrackingOption1", "TrackingName2", "TrackingOption2",
        "Currency", "Type", "Status", "Sent", "ExpectedPaymentDate",
        "PaidDate", "BilledTo", "BrandingTheme", "Url", "DirectDebit",
    ]

    /// Builds the Xero invoices CSV for the given invoice set.
    static func invoicesCSV(
        invoices: [BooksInvoice],
        clients: [Int64: BooksClient],
        lineItems: [Int64: [BooksLineItem]],
        amountPaid: [Int64: Double]
    ) -> String {
        var rows = [invoiceHeader.map(csvField).joined(separator: ",")]

        for invoice in invoices {
            guard let invoiceID = invoice.id,
                  let client = clients[invoice.clientID] else { continue }
            let items = lineItems[invoiceID] ?? []
            let subtotal = items.reduce(0) { $0 + $1.amount }
            let tax = subtotal * invoice.taxRate
            let total = subtotal + tax
            let paid = amountPaid[invoiceID] ?? 0
            let due = total - paid

            for item in items {
                let row: [String] = [
                    client.name,                                   // ContactName
                    client.email ?? "",                            // EmailAddress
                    client.poAddressLine1 ?? "",
                    client.poAddressLine2 ?? "",
                    "", "",                                        // POAddressLine3/4
                    client.poCity ?? "",
                    client.poRegion ?? "",
                    client.poPostalCode ?? "",
                    client.poCountry ?? "",
                    invoice.number,                                // InvoiceNumber
                    "",                                            // Reference
                    xeroDate(invoice.issueDate),                   // InvoiceDate
                    invoice.dueDate.map(xeroDate) ?? "",           // DueDate
                    "",                                            // PlannedPaymentDate
                    BooksMoney.plain(subtotal),                    // SubTotal
                    BooksMoney.plain(tax),                         // TotalTax
                    BooksMoney.plain(total),                       // Total
                    BooksMoney.plain(paid),                        // InvoiceAmountPaid
                    BooksMoney.plain(due),                         // InvoiceAmountDue
                    "",                                            // InventoryItemCode
                    item.description,                              // Description
                    BooksMoney.plain(item.quantity),               // Quantity
                    BooksMoney.plain(item.unitAmount),             // UnitAmount
                    item.discount > 0
                        ? String(format: "%g", item.discount) : "",   // Discount
                    item.accountCode ?? invoice.accountCode,       // AccountCode
                    item.taxType ?? invoice.taxType,               // TaxType
                    "",                                            // TaxAmount (line-level, Xero recomputes)
                    "", "", "", "",                                // Tracking 1/2
                    invoice.currency,                              // Currency
                    "ACCREC",                                      // Type (sales invoice)
                    invoice.statusRaw,                             // Status (verbatim Xero)
                    invoice.status.xeroSent,                       // Sent
                    "",                                            // ExpectedPaymentDate
                    invoice.status == .paid ? xeroDate(Date()) : "", // PaidDate
                    "", "", "", "",                                // BilledTo/BrandingTheme/Url/DirectDebit
                ]
                rows.append(row.map(csvField).joined(separator: ","))
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Contacts CSV (Xero import template, core columns)

    private static let contactHeader = [
        "Name", "EmailAddress", "POAddressLine1", "POAddressLine2",
        "POAddressLine3", "POAddressLine4", "POCity", "PORegion",
        "POPostalCode", "POCountry", "Phone", "Mobile", "Website",
        "TaxNumber", "DefaultSalesAccount",
    ]

    static func contactsCSV(_ clients: [BooksClient], defaultAccountCode: String) -> String {
        var rows = [contactHeader.map(csvField).joined(separator: ",")]
        for client in clients {
            rows.append([
                client.name,
                client.email ?? "",
                client.poAddressLine1 ?? "",
                client.poAddressLine2 ?? "",
                "", "",
                client.poCity ?? "",
                client.poRegion ?? "",
                client.poPostalCode ?? "",
                client.poCountry ?? "",
                client.phone ?? "",
                "", "",
                client.taxNumber ?? "",
                defaultAccountCode,
            ].map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Helpers

    /// Xero date format: dd/MM/yyyy.
    private static func xeroDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }

    /// RFC-4180 field quoting.
    private static func csvField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
