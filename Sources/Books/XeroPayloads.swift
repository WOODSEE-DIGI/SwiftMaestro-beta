import Foundation

// MARK: - Xero API payload builders (pure — fully unit-testable)
//
// Maps MaestroBooks records to the JSON shapes the Xero Accounting API
// expects. Dictionaries (not Codable) because Xero payloads are sparse:
// only non-empty fields are sent, per Xero validation rules.
enum XeroPayloads {

    // MARK: Contacts — https://developer.xero.com/documentation/api/accounting/contacts

    static func contact(from client: BooksClient) -> [String: Any] {
        var payload: [String: Any] = ["Name": client.name]
        if let email = client.email { payload["EmailAddress"] = email }
        if let taxNumber = client.taxNumber { payload["TaxNumber"] = taxNumber }
        if let phone = client.phone {
            payload["Phones"] = [["PhoneType": "DEFAULT", "PhoneNumber": phone]]
        }
        var address: [String: Any] = ["AddressType": "POBOX"]
        if let line1 = client.poAddressLine1 { address["AddressLine1"] = line1 }
        if let line2 = client.poAddressLine2 { address["AddressLine2"] = line2 }
        if let city = client.poCity { address["City"] = city }
        if let region = client.poRegion { address["Region"] = region }
        if let postalCode = client.poPostalCode { address["PostalCode"] = postalCode }
        if let country = client.poCountry { address["Country"] = country }
        if address.count > 1 { payload["Addresses"] = [address] }
        return payload
    }

    // MARK: Invoices — https://developer.xero.com/documentation/api/accounting/invoices

    /// Xero status for our status; nil = do not push this invoice.
    /// PAID pushes as AUTHORISED (payments sync is a later step); VOIDED
    /// invoices are skipped (a Xero invoice can only be voided after
    /// authorisation, and re-pushing voided history is never what you want).
    static func xeroStatus(for status: BooksInvoiceStatus) -> String? {
        switch status {
        case .draft: return "DRAFT"
        case .authorised: return "AUTHORISED"
        case .paid: return "AUTHORISED"
        case .voided: return nil
        }
    }

    static func invoice(
        from invoice: BooksInvoice, client: BooksClient, items: [BooksLineItem]
    ) -> [String: Any]? {
        guard let status = xeroStatus(for: invoice.status),
              let xeroContactID = client.xeroID else { return nil }

        var lineDicts: [[String: Any]] = []
        for item in items.sorted(by: { $0.position < $1.position }) {
            var line: [String: Any] = [
                "Description": item.description,
                "Quantity": item.quantity,
                "UnitAmount": item.unitAmount,
                "AccountCode": item.accountCode ?? invoice.accountCode,
                "TaxType": item.taxType ?? invoice.taxType,
            ]
            if item.discount > 0 { line["DiscountPercent"] = item.discount }
            lineDicts.append(line)
        }

        var payload: [String: Any] = [
            "Type": "ACCREC",
            "InvoiceNumber": invoice.number,
            "Contact": ["ContactID": xeroContactID],
            "Date": xeroDate(invoice.issueDate),
            "CurrencyCode": invoice.currency,
            "LineAmountTypes": "Exclusive",
            "Status": status,
            "LineItems": lineDicts,
        ]
        if let due = invoice.dueDate { payload["DueDate"] = xeroDate(due) }
        if let notes = invoice.notes, !notes.isEmpty { payload["Reference"] = notes }
        return payload
    }

    static func xeroDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: Items (price list) — Items API, scope: accounting.settings
    //
    // Items upsert by Code in Xero, so sync is naturally idempotent.

    static func item(
        from product: BooksProduct, defaultAccountCode: String, defaultTaxType: String
    ) -> [String: Any]? {
        guard let code = product.code, !code.isEmpty else { return nil }
        var payload: [String: Any] = [
            "Code": code,
            "Name": product.name,
            "SalesDetails": [
                "UnitPrice": product.unitPrice,
                "AccountCode": product.accountCode ?? defaultAccountCode,
                "TaxType": product.taxType ?? defaultTaxType,
            ],
        ]
        if let details = product.details, !details.isEmpty {
            payload["Description"] = details
        }
        return payload
    }

    // MARK: Bills (expenses) — Invoices API with Type ACCPAY
    //
    // The supplier is a Xero contact (created/adopted during sync and
    // auto-flagged as a supplier by Xero once bills exist).

    static func bill(from expense: BooksExpense, supplierContactID: String) -> [String: Any]? {
        guard let status = xeroStatus(for: expense.status) else { return nil }
        var payload: [String: Any] = [
            "Type": "ACCPAY",
            // Supplier's own invoice number when we have it; a stable local
            // fallback keeps Xero's uniqueness rule satisfied.
            "InvoiceNumber": expense.reference?.isEmpty == false
                ? expense.reference! : "EXP-MAESTRO-\(expense.id ?? 0)",
            "Contact": ["ContactID": supplierContactID],
            "Date": xeroDate(expense.issueDate),
            "CurrencyCode": expense.currency,
            "LineAmountTypes": "Exclusive",
            "Status": status,
            "LineItems": [[
                "Description": expense.expenseDescription,
                "Quantity": 1.0,
                "UnitAmount": expense.subtotal,
                "AccountCode": expense.accountCode,
                "TaxType": expense.taxType,
            ]],
        ]
        if let notes = expense.notes, !notes.isEmpty { payload["Reference"] = notes }
        return payload
    }
}
