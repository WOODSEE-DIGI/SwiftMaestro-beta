import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Books tools (MaestroBooks invoicing)
//
// Agent-first invoicing on the same BooksDatabase the app uses. All
// mutations are audited (audit_log) like every other Books write.
extension MaestroTools {

    static func registerBooksTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "client_create", spec: booksToolSpecs[0],
                category: ToolCategory.books.rawValue,
                handler: { call in await clientCreate(call) }),
            ToolDefinition(
                name: "client_list", spec: booksToolSpecs[1],
                category: ToolCategory.books.rawValue,
                handler: { call in await clientList(call) }),
            ToolDefinition(
                name: "invoice_create", spec: booksToolSpecs[2],
                category: ToolCategory.books.rawValue,
                handler: { call in await invoiceCreate(call) }),
            ToolDefinition(
                name: "invoice_list", spec: booksToolSpecs[3],
                category: ToolCategory.books.rawValue,
                handler: { call in await invoiceList(call) }),
            ToolDefinition(
                name: "invoice_read", spec: booksToolSpecs[4],
                category: ToolCategory.books.rawValue,
                handler: { call in await invoiceRead(call) }),
            ToolDefinition(
                name: "invoice_status", spec: booksToolSpecs[5],
                category: ToolCategory.books.rawValue,
                handler: { call in await invoiceStatus(call) }),
            ToolDefinition(
                name: "invoice_payment", spec: booksToolSpecs[6],
                category: ToolCategory.books.rawValue,
                handler: { call in await invoicePayment(call) }),
            ToolDefinition(
                name: "invoice_publish", spec: booksToolSpecs[7],
                category: ToolCategory.books.rawValue,
                handler: { call in await invoicePublish(call) }),
            ToolDefinition(
                name: "product_create", spec: booksToolSpecs[8],
                category: ToolCategory.books.rawValue,
                handler: { call in await productCreate(call) }),
            ToolDefinition(
                name: "product_list", spec: booksToolSpecs[9],
                category: ToolCategory.books.rawValue,
                handler: { call in await productList(call) }),
            ToolDefinition(
                name: "client_import", spec: booksToolSpecs[10],
                category: ToolCategory.books.rawValue,
                handler: { call in await clientImport(call) }),
            ToolDefinition(
                name: "xero_status", spec: booksToolSpecs[11],
                category: ToolCategory.books.rawValue,
                handler: { _ in await xeroStatus() }),
            ToolDefinition(
                name: "xero_sync", spec: booksToolSpecs[12],
                category: ToolCategory.books.rawValue,
                handler: { _ in await xeroSync() }),
            ToolDefinition(
                name: "xero_disconnect", spec: booksToolSpecs[13],
                category: ToolCategory.books.rawValue,
                handler: { _ in await xeroDisconnect() }),
            ToolDefinition(
                name: "expense_create", spec: booksToolSpecs[14],
                category: ToolCategory.books.rawValue,
                handler: { call in await expenseCreate(call) }),
            ToolDefinition(
                name: "expense_list", spec: booksToolSpecs[15],
                category: ToolCategory.books.rawValue,
                handler: { _ in await expenseList() }),
        ])
    }

    static var booksToolSpecs: [ToolSpec] {
        [
            rawSpec(
                "client_create",
                "Create an invoicing client (Xero contact shape). Returns the client id.",
                properties: [
                    "name": ["type": "string"],
                    "email": ["type": "string"],
                    "phone": ["type": "string"],
                    "tax_number": ["type": "string", "description": "Client tax id (ABN/VAT No)"],
                ],
                required: ["name"]),
            rawSpec("client_list", "List invoicing clients.",
                    properties: [:], required: []),
            rawSpec(
                "invoice_create",
                "Create a DRAFT invoice (client found/created by name). Items: one per line "
                    + "'Description | qty | unit price [| discount%]'. Wrapped lines without "
                    + "pipes join the previous description. Currency/tax follow the Business "
                    + "settings unless overridden. Returns number + total.",
                properties: [
                    "client": ["type": "string"],
                    "items": ["type": "string"],
                    "due_days": ["type": "integer"],
                    "notes": ["type": "string"],
                    "currency": ["type": "string", "description": "ISO code, e.g. USD"],
                    "tax_rate": ["type": "number", "description": "Fraction, e.g. 0.20 = 20%"],
                    "tax_label": ["type": "string", "description": "e.g. VAT, GST, Sales Tax"],
                ],
                required: ["client", "items"]),
            rawSpec(
                "invoice_list",
                "List invoices (number, client, status, total). Optional status filter.",
                properties: ["status": ["type": "string"]],
                required: []),
            rawSpec(
                "invoice_read",
                "Full invoice detail: client, items, tax, totals, payments, PDF path.",
                properties: ["number": ["type": "string"]],
                required: ["number"]),
            rawSpec(
                "invoice_status",
                "Set status: DRAFT, AUTHORISED (sent), PAID, VOIDED (Xero verbatim). "
                    + "A VOIDED invoice can be set back to DRAFT to un-void.",
                properties: [
                    "number": ["type": "string"],
                    "status": ["type": "string"],
                ],
                required: ["number", "status"]),
            rawSpec(
                "invoice_payment",
                "Record a payment; auto-marks PAID when the balance reaches zero.",
                properties: [
                    "number": ["type": "string"],
                    "amount": ["type": "number"],
                    "method": ["type": "string"],
                ],
                required: ["number", "amount"]),
            rawSpec(
                "invoice_publish",
                "Render the invoice to an A4 invoice PDF and file it in MaestroDAM.",
                properties: ["number": ["type": "string"]],
                required: ["number"]),
            rawSpec(
                "product_create",
                "Add a product/service to the price list. Products are selectable "
                    + "when creating invoices and fill description + unit price.",
                properties: [
                    "name": ["type": "string"],
                    "price": ["type": "number"],
                    "details": ["type": "string", "description": "Invoice line description"],
                    "account_code": ["type": "string", "description": "Xero override"],
                ],
                required: ["name", "price"]),
            rawSpec("product_list", "List price-list products/services.",
                    properties: [:], required: []),
            rawSpec(
                "client_import",
                "Import a macOS Contacts entry as an invoicing client (org name, "
                    + "email, phone, postal address). 'name' is a Contacts search "
                    + "string; best match wins. Existing client is never overwritten. "
                    + "as_name/email/phone override the defaults when the card has "
                    + "multiples or org is used as a personal label.",
                properties: [
                    "name": ["type": "string"],
                    "as_name": ["type": "string", "description": "Client display name override"],
                    "email": ["type": "string", "description": "Pick a specific email"],
                    "phone": ["type": "string", "description": "Pick a specific phone"],
                ],
                required: ["name"]),
            rawSpec("xero_status",
                    "Xero connection status: connected?, tenant name, unsynced counts.",
                    properties: [:], required: []),
            rawSpec("xero_sync",
                    "Push new clients (matched by name) and invoices (matched by "
                    + "number) to Xero. Returns a per-entity report. Voided "
                    + "invoices are skipped; already-synced items are left alone.",
                    properties: [:], required: []),
            rawSpec("xero_disconnect",
                    "Disconnect the Xero organisation (deletes Keychain tokens).",
                    properties: [:], required: []),
            rawSpec(
                "expense_create",
                "Record a business expense (supplier bill → Xero ACCPAY on sync). "
                    + "Amount is ex-tax; tax/account follow Business settings.",
                properties: [
                    "supplier": ["type": "string"],
                    "description": ["type": "string"],
                    "amount": ["type": "number", "description": "ex-tax amount"],
                    "reference": ["type": "string", "description": "supplier invoice no."],
                    "account_code": ["type": "string"],
                    "notes": ["type": "string"],
                ],
                required: ["supplier", "description", "amount"]),
            rawSpec("expense_list", "List expenses (supplier, description, total, status).",
                    properties: [:], required: []),
        ]
    }

    // MARK: - Args + helpers

    private struct ClientCreateArgs: Codable {
        let name, email, phone, abn, tax_number: String?
    }

    private struct ClientImportArgs: Codable {
        let name, as_name, email, phone: String?
    }

    private struct ExpenseCreateArgs: Codable {
        let supplier, description, reference, account_code, notes: String?
        let amount: Double?
    }

    private struct ProductCreateArgs: Codable {
        let name, details, account_code: String?
        let price: Double?
    }

    private struct InvoiceCreateArgs: Codable {
        let client, items, notes, currency, tax_label: String?
        let due_days: Int?
        let tax_rate: Double?
    }

    private struct InvoiceListArgs: Codable { let status: String? }
    private struct NumberArgs: Codable { let number: String? }
    private struct StatusArgs: Codable { let number, status: String? }
    private struct PaymentArgs: Codable {
        let number, method: String?
        let amount: Double?
    }

    @MainActor
    private static var booksVM: BooksViewModel { BooksViewModelHolder.shared }

    /// Parse "Description | qty | price [| discount%]" lines (shared parser;
    /// wrapped lines without pipes join the previous description).
    private static func parseItems(_ text: String) -> [(String, Double, Double, Double)] {
        BooksItemParser.parse(text).map { ($0.description, $0.quantity, $0.unitAmount, $0.discount) }
    }

    // MARK: - Handlers

    static func clientCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ClientCreateArgs.self),
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return errorJSON("client_create requires 'name'")
        }
        let vm = await MainActor.run { booksVM }
        do {
            var client = try await MainActor.run {
                try vm.findOrCreateClient(named: name, email: args.email)
            }
            // Enrich with phone/tax number on first create (tax_number
            // preferred; abn accepted for backwards compatibility).
            let taxNumber = args.tax_number ?? args.abn
            if (args.phone != nil || taxNumber != nil), client.taxNumber == nil, client.phone == nil {
                client.phone = args.phone
                client.taxNumber = taxNumber
                let db = BooksDatabase.shared
                client = try db.saveClient(&client)
            }
            return jsonString(["status": "ok", "id": "\(client.id ?? -1)", "name": client.name])
        } catch {
            return errorJSON("client_create failed: \(error.localizedDescription)")
        }
    }

    static func clientList(_ call: ToolCall) async -> String {
        do {
            let clients = try BooksDatabase.shared.clients()
            let lines = clients.map {
                "\($0.id ?? -1): \($0.name)"
                    + ($0.email.map { " <\($0)>" } ?? "")
                    + ($0.taxNumber.map { " Tax ID \($0)" } ?? "")
            }
            return jsonString(["status": "ok", "count": "\(clients.count)",
                               "clients": lines.joined(separator: "\n")])
        } catch {
            return errorJSON("client_list failed: \(error.localizedDescription)")
        }
    }

    static func clientImport(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ClientImportArgs.self),
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return errorJSON("client_import requires 'name'")
        }
        do {
            let service = await MainActor.run { ContactsService() }
            let matches = try await service.searchContacts(query: name, limit: 5)
            guard let best = matches.first else {
                return errorJSON("no contact matching '\(name)'")
            }
            let vm = await MainActor.run { booksVM }
            let client = try await vm.importContact(
                best, nameOverride: args.as_name,
                emailOverride: args.email, phoneOverride: args.phone)
            return jsonString([
                "status": "ok", "id": "\(client.id ?? -1)", "name": client.name,
                "email": client.email ?? "",
            ])
        } catch {
            return errorJSON("client_import failed: \(error.localizedDescription)")
        }
    }

    static func xeroStatus() async -> String {
        let api = XeroAPIClient.shared
        guard await api.isConnected else {
            return jsonString(["status": "not_connected",
                               "hint": "connect from the MaestroBooks Xero page"])
        }
        let tenant = await api.tenantName ?? "?"
        let db = BooksDatabase.shared
        let unsyncedClients = (try? db.clients().filter { $0.xeroID == nil }.count) ?? 0
        let unsyncedInvoices = (try? db.invoices().filter { $0.xeroID == nil }.count) ?? 0
        return jsonString([
            "status": "connected", "tenant": tenant,
            "unsynced_clients": "\(unsyncedClients)",
            "unsynced_invoices": "\(unsyncedInvoices)",
        ])
    }

    static func xeroSync() async -> String {
        let api = XeroAPIClient.shared
        guard await api.isConnected else {
            return errorJSON("not connected to Xero — connect from the Xero page first")
        }
        let service = XeroSyncService(api: api, database: BooksDatabase.shared)
        let results = await service.syncContacts() + service.syncInvoices()
        let vm = await MainActor.run { booksVM }
        await vm.reload()
        let failures = results.filter { !$0.ok }
        let lines = results.map {
            "\($0.ok ? "✓" : "✗") \($0.entity) \($0.name): \($0.detail)"
        }
        return jsonString([
            "status": failures.isEmpty ? "ok" : "partial",
            "synced": "\(results.count - failures.count)",
            "failed": "\(failures.count)",
            "report": lines.joined(separator: "\n"),
        ])
    }

    static func xeroDisconnect() async -> String {
        do {
            try await XeroAPIClient.shared.disconnect()
            let vm = await MainActor.run { booksVM }
            await vm.reload()
            return jsonString(["status": "disconnected"])
        } catch {
            return errorJSON("xero_disconnect failed: \(error.localizedDescription)")
        }
    }

    static func expenseCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ExpenseCreateArgs.self),
              let supplier = args.supplier?.trimmingCharacters(in: .whitespaces),
              !supplier.isEmpty,
              let description = args.description?.trimmingCharacters(in: .whitespaces),
              !description.isEmpty,
              let amount = args.amount, amount >= 0 else {
            return errorJSON("expense_create requires 'supplier', 'description', 'amount'")
        }
        let vm = await MainActor.run { booksVM }
        let seller = await MainActor.run { vm.seller }
        let now = Date()
        var expense = BooksExpense(
            id: nil, supplier: supplier, expenseDescription: description,
            reference: args.reference,
            accountCode: args.account_code ?? seller.defaultExpenseAccountCode,
            issueDate: now, statusRaw: BooksInvoiceStatus.draft.rawValue,
            currency: seller.currency, taxRate: seller.taxRate,
            taxType: seller.expenseTaxType,
            subtotal: amount, notes: args.notes, xeroID: nil,
            createdAt: now, updatedAt: now)
        do {
            try BooksDatabase.shared.saveExpense(&expense)
            let vm = await MainActor.run { booksVM }
            await vm.reload()
            return jsonString([
                "status": "created", "id": "\(expense.id ?? -1)",
                "total": BooksMoney.format(expense.total, currency: expense.currency),
                "hint": "xero_sync pushes it as an ACCPAY bill",
            ])
        } catch {
            return errorJSON("expense_create failed: \(error.localizedDescription)")
        }
    }

    static func expenseList() async -> String {
        do {
            let expenses = try BooksDatabase.shared.expenses()
            let lines = expenses.map {
                "\($0.id ?? -1): \($0.supplier) — \($0.expenseDescription) "
                    + "\(BooksMoney.format($0.total, currency: $0.currency)) [\($0.statusRaw)]"
            }
            return jsonString(["status": "ok", "count": "\(expenses.count)",
                               "expenses": lines.joined(separator: "\n")])
        } catch {
            return errorJSON("expense_list failed: \(error.localizedDescription)")
        }
    }

    static func productCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ProductCreateArgs.self),
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let price = args.price, price >= 0 else {
            return errorJSON("product_create requires 'name' and 'price'")
        }
        var product = BooksProduct(
            id: nil, name: name, details: args.details, unitPrice: price,
            accountCode: args.account_code, taxType: nil, createdAt: Date(), updatedAt: Date())
        do {
            product = try BooksDatabase.shared.saveProduct(&product)
            return jsonString(["status": "ok", "id": "\(product.id ?? -1)", "name": product.name])
        } catch {
            return errorJSON("product_create failed: \(error.localizedDescription)")
        }
    }

    static func productList(_ call: ToolCall) async -> String {
        do {
            let products = try BooksDatabase.shared.products()
            let lines = products.map {
                "\($0.id ?? -1): \($0.name) — \(BooksMoney.plain($0.unitPrice))"
                    + ($0.details.map { " (\($0))" } ?? "")
            }
            return jsonString(["status": "ok", "count": "\(products.count)",
                               "products": lines.joined(separator: "\n")])
        } catch {
            return errorJSON("product_list failed: \(error.localizedDescription)")
        }
    }

    static func invoiceCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: InvoiceCreateArgs.self),
              let clientName = args.client?.trimmingCharacters(in: .whitespaces),
              !clientName.isEmpty, let itemsText = args.items else {
            return errorJSON("invoice_create requires 'client' and 'items'")
        }
        let items = parseItems(itemsText)
        guard !items.isEmpty else {
            return errorJSON("no valid items — use 'Description | qty | unit price' per line")
        }
        let vm = await MainActor.run { booksVM }
        do {
            let invoice = try await MainActor.run {
                try vm.createInvoice(
                    clientName: clientName, clientEmail: nil,
                    items: items.map {
                        (description: $0.0, quantity: $0.1, unitAmount: $0.2, discount: $0.3)
                    },
                    dueDays: args.due_days ?? 14, notes: args.notes,
                    currency: args.currency?.uppercased(),
                    taxRate: args.tax_rate, taxLabel: args.tax_label)
            }
            let total = try BooksDatabase.shared.invoiceTotal(invoice.id ?? -1)
            return jsonString([
                "status": "created", "number": invoice.number,
                "total": BooksMoney.format(total, currency: invoice.currency),
                "hint": "invoice_publish to render the PDF into MaestroDAM",
            ])
        } catch {
            return errorJSON("invoice_create failed: \(error.localizedDescription)")
        }
    }

    static func invoiceList(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: InvoiceListArgs.self)
        let status = args?.status.flatMap { BooksInvoiceStatus(rawValue: $0.uppercased()) }
        do {
            let invoices = try BooksDatabase.shared.invoices(status: status)
            let clients = try BooksDatabase.shared.clients()
            var lines: [String] = []
            for invoice in invoices {
                let clientName = clients.first { $0.id == invoice.clientID }?.name ?? "?"
                let total = try BooksDatabase.shared.invoiceTotal(invoice.id ?? -1)
                lines.append("\(invoice.number) | \(clientName) | \(invoice.statusRaw) | "
                             + BooksMoney.format(total, currency: invoice.currency))
            }
            return jsonString(["status": "ok", "count": "\(invoices.count)",
                               "invoices": lines.joined(separator: "\n")])
        } catch {
            return errorJSON("invoice_list failed: \(error.localizedDescription)")
        }
    }

    static func invoiceRead(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumberArgs.self),
              let number = args.number?.trimmingCharacters(in: .whitespaces), !number.isEmpty else {
            return errorJSON("invoice_read requires 'number'")
        }
        let db = BooksDatabase.shared
        do {
            guard let invoice = try db.invoice(number: number), let invoiceID = invoice.id else {
                return errorJSON("no invoice '\(number)'")
            }
            let client = try db.clients().first { $0.id == invoice.clientID }
            let items = try db.lineItems(invoiceID: invoiceID)
            let payments = try db.payments(invoiceID: invoiceID)
            let subtotal = items.reduce(0) { $0 + $1.amount }
            let tax = subtotal * invoice.taxRate
            let total = subtotal + tax
            let paid = payments.reduce(0) { $0 + $1.amount }

            var text = "\(invoice.number) — \(client?.name ?? "?") [\(invoice.statusRaw)]\n"
            for item in items {
                text += "  \(item.description) | \(BooksMoney.plain(item.quantity)) × "
                    + "\(BooksMoney.plain(item.unitAmount)) = \(BooksMoney.plain(item.amount))\n"
            }
            text += "Subtotal \(BooksMoney.plain(subtotal)) + \(invoice.taxLabel) \(BooksMoney.plain(tax)) "
                + "= \(BooksMoney.plain(total)) \(invoice.currency)\n"
            if paid > 0 { text += "Paid \(BooksMoney.plain(paid)), balance \(BooksMoney.plain(total - paid))\n" }
            if let path = invoice.pdfPath { text += "PDF: \(path)" }
            return jsonString(["status": "ok", "detail": text])
        } catch {
            return errorJSON("invoice_read failed: \(error.localizedDescription)")
        }
    }

    static func invoiceStatus(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: StatusArgs.self),
              let number = args.number?.trimmingCharacters(in: .whitespaces), !number.isEmpty,
              let statusRaw = args.status?.uppercased(),
              let status = BooksInvoiceStatus(rawValue: statusRaw) else {
            return errorJSON("invoice_status requires 'number' and 'status' (DRAFT/AUTHORISED/PAID/VOIDED)")
        }
        let db = BooksDatabase.shared
        do {
            guard let invoice = try db.invoice(number: number), let id = invoice.id else {
                return errorJSON("no invoice '\(number)'")
            }
            try db.setInvoiceStatus(id, status)
            return jsonString(["status": "ok", "number": number, "new_status": status.rawValue])
        } catch {
            return errorJSON("invoice_status failed: \(error.localizedDescription)")
        }
    }

    static func invoicePayment(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PaymentArgs.self),
              let number = args.number?.trimmingCharacters(in: .whitespaces), !number.isEmpty,
              let amount = args.amount, amount > 0 else {
            return errorJSON("invoice_payment requires 'number' and 'amount'")
        }
        let db = BooksDatabase.shared
        do {
            guard let invoice = try db.invoice(number: number), let id = invoice.id else {
                return errorJSON("no invoice '\(number)'")
            }
            try db.recordPayment(invoiceID: id, amount: amount, method: args.method, note: nil)
            let paid = try db.amountPaid(id)
            let total = try db.invoiceTotal(id)
            let status = (try? db.invoice(number: number))?.statusRaw ?? invoice.statusRaw
            return jsonString([
                "status": "ok", "number": number,
                "paid_total": BooksMoney.plain(paid),
                "balance": BooksMoney.plain(total - paid),
                "invoice_status": status,
            ])
        } catch {
            return errorJSON("invoice_payment failed: \(error.localizedDescription)")
        }
    }

    static func invoicePublish(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NumberArgs.self),
              let number = args.number?.trimmingCharacters(in: .whitespaces), !number.isEmpty else {
            return errorJSON("invoice_publish requires 'number'")
        }
        let vm = await MainActor.run { booksVM }
        do {
            await MainActor.run {
                vm.errorMessage = nil
            }
            await vm.reload()
            let db = BooksDatabase.shared
            guard let invoice = try db.invoice(number: number), let id = invoice.id else {
                return errorJSON("no invoice '\(number)'")
            }
            await vm.selectInvoice(id)
            let url = try await vm.publishSelectedInvoice()
            return jsonString(["status": "published", "path": url.path,
                               "note": "filed in MaestroDAM (delta import triggered)"])
        } catch {
            return errorJSON("invoice_publish failed: \(error.localizedDescription)")
        }
    }
}
