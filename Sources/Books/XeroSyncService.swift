import Foundation

// MARK: - Xero sync service
//
// Pushes MaestroBooks data to the connected Xero organisation. Contacts go
// first (invoices reference them by ContactID); both match by name/number to
// stay idempotent across runs. Results are per-entity lines for the UI/agent
// report. Rate limits are respected by sequential sends with small datasets.

struct XeroSyncResult: Sendable {
    let entity: String
    let name: String
    let ok: Bool
    let detail: String
}

struct XeroSyncService {

    let api: XeroAPIClient
    let database: BooksDatabase

    // MARK: Contacts

    func syncContacts() async -> [XeroSyncResult] {
        guard let clients = try? database.clients() else { return [] }
        var results: [XeroSyncResult] = []
        for client in clients where client.xeroID == nil {
            do {
                let xeroID = try await pushOrMatchContact(client)
                try database.setClientXeroID(id: client.id ?? -1, xeroID: xeroID)
                results.append(XeroSyncResult(
                    entity: "contact", name: client.name, ok: true,
                    detail: "linked to Xero contact"))
            } catch {
                results.append(XeroSyncResult(
                    entity: "contact", name: client.name, ok: false,
                    detail: error.localizedDescription))
            }
        }
        return results
    }

    /// Xero rejects duplicate contact names, so look up by name first and
    /// adopt the existing ContactID when found. Used for both clients and
    /// expense suppliers.
    private func pushOrMatchContact(_ client: BooksClient) async throws -> String {
        try await matchOrCreateContact(
            name: client.name, payload: XeroPayloads.contact(from: client))
    }

    private func matchOrCreateContact(name: String, payload: [String: Any]) async throws -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let data = try await api.get(
            "/Contacts",
            query: [URLQueryItem(name: "where", value: "Name==\"\(escaped)\"")])
        struct ContactsResponse: Decodable {
            struct Contact: Decodable { let ContactID: String }
            let Contacts: [Contact]
        }
        if let existing = try JSONDecoder().decode(ContactsResponse.self, from: data)
            .Contacts.first {
            return existing.ContactID
        }
        let created = try await api.post("/Contacts", json: ["Contacts": [payload]])
        guard let contactID = try JSONDecoder().decode(ContactsResponse.self, from: created)
            .Contacts.first?.ContactID else {
            throw XeroAPIError.server("Xero accepted the contact but returned no ContactID")
        }
        return contactID
    }

    // MARK: Suppliers (expense payees — Xero contacts by usage)

    /// Distinct supplier names from expenses become Xero contacts (Xero
    /// auto-flags them as suppliers once ACCPAY bills exist).
    func syncSuppliers() async -> [XeroSyncResult] {
        guard let expenses = try? database.expenses() else { return [] }
        var seen = Set<String>()
        var results: [XeroSyncResult] = []
        for expense in expenses {
            guard seen.insert(expense.supplier).inserted else { continue }
            do {
                _ = try await matchOrCreateContact(
                    name: expense.supplier, payload: ["Name": expense.supplier])
                results.append(XeroSyncResult(
                    entity: "supplier", name: expense.supplier, ok: true,
                    detail: "linked to Xero contact"))
            } catch {
                results.append(XeroSyncResult(
                    entity: "supplier", name: expense.supplier, ok: false,
                    detail: error.localizedDescription))
            }
        }
        return results
    }

    // MARK: Items (price list — Xero Items upsert by Code)

    func syncItems(defaultAccountCode: String, defaultTaxType: String) async -> [XeroSyncResult] {
        guard let products = try? database.products() else { return [] }
        var results: [XeroSyncResult] = []
        for product in products {
            do {
                guard let payload = XeroPayloads.item(
                    from: product,
                    defaultAccountCode: defaultAccountCode,
                    defaultTaxType: defaultTaxType) else {
                    throw XeroAPIError.server("product has no item code")
                }
                _ = try await api.post("/Items", json: ["Items": [payload]])
                results.append(XeroSyncResult(
                    entity: "item", name: product.name, ok: true,
                    detail: "upserted by code \(product.code ?? "?")"))
            } catch {
                results.append(XeroSyncResult(
                    entity: "item", name: product.name, ok: false,
                    detail: error.localizedDescription))
            }
        }
        return results
    }

    // MARK: Expenses (supplier bills → ACCPAY invoices)

    func syncExpenses() async -> [XeroSyncResult] {
        guard let expenses = try? database.expenses() else { return [] }
        var results: [XeroSyncResult] = []
        for expense in expenses where expense.xeroID == nil {
            guard XeroPayloads.xeroStatus(for: expense.status) != nil else {
                results.append(XeroSyncResult(
                    entity: "expense", name: expense.supplier, ok: true,
                    detail: "skipped (voided)"))
                continue
            }
            do {
                let contactID = try await matchOrCreateContact(
                    name: expense.supplier, payload: ["Name": expense.supplier])
                guard let payload = XeroPayloads.bill(
                    from: expense, supplierContactID: contactID) else {
                    throw XeroAPIError.server("could not build Xero bill payload")
                }
                let data = try await api.post("/Invoices", json: ["Invoices": [payload]])
                struct InvoicesResponse: Decodable {
                    struct Invoice: Decodable { let InvoiceID: String }
                    let Invoices: [Invoice]
                }
                guard let xeroID = try JSONDecoder().decode(InvoicesResponse.self, from: data)
                    .Invoices.first?.InvoiceID else {
                    throw XeroAPIError.server("Xero accepted the bill but returned no InvoiceID")
                }
                try database.setExpenseXeroID(id: expense.id ?? -1, xeroID: xeroID)
                results.append(XeroSyncResult(
                    entity: "expense",
                    name: "\(expense.supplier) — \(BooksMoney.format(expense.total, currency: expense.currency))",
                    ok: true, detail: "pushed as bill (\(expense.status.rawValue))"))
            } catch {
                results.append(XeroSyncResult(
                    entity: "expense", name: expense.supplier, ok: false,
                    detail: error.localizedDescription))
            }
        }
        return results
    }
}

// MARK: - Invoice + expense sync steps

extension XeroSyncService {

    // MARK: Invoices

    func syncInvoices() async -> [XeroSyncResult] {
        guard let invoices = try? database.invoices(),
              let clients = try? database.clients() else { return [] }
        var results: [XeroSyncResult] = []
        for invoice in invoices where invoice.xeroID == nil {
            guard XeroPayloads.xeroStatus(for: invoice.status) != nil else {
                results.append(XeroSyncResult(
                    entity: "invoice", name: invoice.number, ok: true,
                    detail: "skipped (voided)"))
                continue
            }
            do {
                guard let client = clients.first(where: { $0.id == invoice.clientID }),
                      client.xeroID != nil else {
                    throw XeroAPIError.server("client has no Xero link — sync contacts first")
                }
                let items = try database.lineItems(invoiceID: invoice.id ?? -1)
                guard let payload = XeroPayloads.invoice(
                    from: invoice, client: client, items: items) else {
                    throw XeroAPIError.server("could not build Xero invoice payload")
                }
                let data = try await api.post("/Invoices", json: ["Invoices": [payload]])
                struct InvoicesResponse: Decodable {
                    struct Invoice: Decodable { let InvoiceID: String }
                    let Invoices: [Invoice]
                }
                guard let xeroID = try JSONDecoder().decode(InvoicesResponse.self, from: data)
                    .Invoices.first?.InvoiceID else {
                    throw XeroAPIError.server("Xero accepted the invoice but returned no InvoiceID")
                }
                try database.setInvoiceXeroID(id: invoice.id ?? -1, xeroID: xeroID)
                results.append(XeroSyncResult(
                    entity: "invoice", name: invoice.number, ok: true,
                    detail: "pushed (\(invoice.status.rawValue))"))
            } catch {
                results.append(XeroSyncResult(
                    entity: "invoice", name: invoice.number, ok: false,
                    detail: error.localizedDescription))
            }
        }
        return results
    }
}
