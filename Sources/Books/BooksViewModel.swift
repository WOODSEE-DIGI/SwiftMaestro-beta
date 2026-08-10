import AppKit
import Foundation

// MARK: - MaestroBooks View Model
//
// Drives the invoicing app: client/invoice lists, creation, status flow,
// payments, PDF publishing (renderer → file → DAM auto-file), Xero export.
@Observable
@MainActor
final class BooksViewModel {

    private var database: BooksDatabase { BooksDatabase.shared }

    /// Demo mode (mirrors the database swap). Drives the banner, the demo
    /// seller profile, and disables Xero sync.
    var isDemo: Bool { BooksDatabase.isDemoMode }

    private(set) var clients: [BooksClient] = []
    private(set) var products: [BooksProduct] = []
    private(set) var expenses: [BooksExpense] = []
    private(set) var invoices: [BooksInvoice] = []
    private(set) var selectedInvoice: BooksInvoice?
    private(set) var selectedClient: BooksClient?
    private(set) var selectedItems: [BooksLineItem] = []
    private(set) var selectedPayments: [BooksPayment] = []
    var errorMessage: String?
    var statusMessage: String?
    var isPublishing = false

    /// Business profile (letterhead + payment footer), UserDefaults-backed.
    /// Business profile. Real mode persists to UserDefaults on every edit
    /// (didSet); demo mode swaps in the fictional studio IN MEMORY ONLY —
    /// the user's real profile is never read, never written.
    var seller: BooksSeller {
        get { isDemo ? demoSeller : storedSeller }
        set {
            if isDemo {
                demoSeller = newValue
            } else {
                storedSeller = newValue
                storedSeller.save()
            }
        }
    }
    private var storedSeller = BooksSeller.load()
    private var demoSeller = DemoData.seller

    /// Folder invoice PDFs publish into (auto-filed in MaestroDAM).
    static var invoicesFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("MaestroBooks/Invoices", isDirectory: true)
    }

    init() {}

    // MARK: - Loading

    func reload() async {
        do {
            clients = try database.clients()
            products = try database.products()
            expenses = try database.expenses()
            invoices = try database.invoices()
            if let selected = selectedInvoice, let id = selected.id {
                await selectInvoice(id)
            }
            await refreshXeroState()
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
        }
    }

    func selectInvoice(_ invoiceID: Int64) async {
        do {
            guard let invoice = invoices.first(where: { $0.id == invoiceID }) else { return }
            selectedInvoice = invoice
            selectedClient = clients.first { $0.id == invoice.clientID }
            selectedItems = try database.lineItems(invoiceID: invoiceID)
            selectedPayments = try database.payments(invoiceID: invoiceID)
        } catch {
            errorMessage = "Could not load invoice: \(error.localizedDescription)"
        }
    }

    /// Import a macOS Contacts entry as an invoicing client. Existing client
    /// with the same name is returned as-is (never clobbered). Overrides win
    /// over the defaults (org-first name, first email/phone on the card).
    @discardableResult
    func importContact(
        _ contact: Contact, nameOverride: String? = nil,
        emailOverride: String? = nil, phoneOverride: String? = nil
    ) async throws -> BooksClient {
        let mapped = BooksClient(
            contact: contact, nameOverride: nameOverride,
            emailOverride: emailOverride, phoneOverride: phoneOverride)
        if let existing = try database.client(named: mapped.name) { return existing }
        var client = mapped
        client = try database.saveClient(&client)
        clients = try database.clients()
        statusMessage = "Imported \(client.name) from Contacts"
        return client
    }

    // MARK: - Xero connection (PKCE, tokens in Keychain)

    /// The user's "Auth Code with PKCE" app Client ID (developer.xero.com).
    /// Not a secret — safe in UserDefaults.
    var xeroClientID: String {
        get { UserDefaults.standard.string(forKey: "maestrobooks.xero.clientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "maestrobooks.xero.clientID") }
    }
    private(set) var xeroConnected = false
    private(set) var xeroTenantName: String?
    var xeroSyncing = false
    private(set) var xeroReport: [XeroSyncResult] = []

    func refreshXeroState() async {
        xeroConnected = await XeroAPIClient.shared.isConnected
        xeroTenantName = await XeroAPIClient.shared.tenantName
    }

    /// PKCE sign-in: opens the browser consent page and waits on the
    /// localhost callback (2-minute window). Disabled in demo mode.
    func connectXero() async {
        guard !isDemo else {
            errorMessage = "Xero is disabled in demo mode — exit demo to connect"
            return
        }
        let clientID = xeroClientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else {
            errorMessage = "Paste your Xero app's Client ID first"
            return
        }
        do {
            let pkce = XeroAPIClient.makePKCE()
            let state = UUID().uuidString
            let url = XeroAPIClient.authorizeURL(
                clientID: clientID, state: state, challenge: pkce.challenge)
            NSWorkspace.shared.open(url)
            statusMessage = "Waiting for Xero sign-in in your browser…"
            let code = try await XeroLoopbackServer.waitForCallback(expectedState: state)
            try await XeroAPIClient.shared.connect(
                code: code, verifier: pkce.verifier, clientID: clientID)
            await refreshXeroState()
            statusMessage = "Connected to \(xeroTenantName ?? "Xero")"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func disconnectXero() async {
        do {
            try await XeroAPIClient.shared.disconnect()
            statusMessage = "Disconnected from Xero"
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshXeroState()
    }

    /// Push contacts (matched by name), then invoices (matched by number).
    /// Idempotent: anything with a stored xero_id is skipped. Disabled in
    /// demo mode — demo data must never reach a real Xero organisation.
    func syncWithXero() async {
        guard !isDemo else {
            errorMessage = "Xero sync is disabled in demo mode"
            return
        }
        guard xeroConnected else {
            errorMessage = "Connect to Xero first"
            return
        }
        xeroSyncing = true
        defer { xeroSyncing = false }
        statusMessage = "Syncing with Xero…"
        let service = XeroSyncService(api: XeroAPIClient.shared, database: database)
        // Contacts before invoices; suppliers before bills. Items upsert by
        // code so they can run any time.
        let contactResults = await service.syncContacts()
        let supplierResults = await service.syncSuppliers()
        let itemResults = await service.syncItems(
            defaultAccountCode: seller.defaultAccountCode, defaultTaxType: seller.taxType)
        let invoiceResults = await service.syncInvoices()
        let expenseResults = await service.syncExpenses()
        xeroReport = contactResults + supplierResults + itemResults
            + invoiceResults + expenseResults
        await reload()
        let failures = xeroReport.filter { !$0.ok }.count
        if failures == 0 {
            statusMessage = xeroReport.isEmpty
                ? "Xero sync: everything already up to date"
                : "Xero sync complete (\(xeroReport.count) items)"
        } else {
            errorMessage = "Xero sync finished with \(failures) failure(s) — see report"
        }
    }

    // MARK: - Expenses (supplier bills)

    func saveExpense(_ expense: inout BooksExpense) async {
        do {
            _ = try database.saveExpense(&expense)
            expenses = try database.expenses()
            statusMessage = "Saved expense — \(expense.supplier)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setExpenseStatus(_ expenseID: Int64, _ status: BooksInvoiceStatus) async {
        do {
            try database.setExpenseStatus(expenseID, status)
            expenses = try database.expenses()
            statusMessage = "Expense marked \(status.displayName.lowercased())"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteExpense(id: Int64) async {
        do {
            try database.deleteExpense(id: id)
            expenses = try database.expenses()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Client editing (Clients page)

    func saveClient(_ client: inout BooksClient) async {
        do {
            _ = try database.saveClient(&client)
            clients = try database.clients()
            if selectedClient?.id == client.id { selectedClient = client }
            statusMessage = "Saved \(client.name)"
        } catch {
            errorMessage = "Could not save client: \(error.localizedDescription)"
        }
    }

    func deleteClient(id: Int64) async {
        do {
            try database.deleteClient(id: id)
            clients = try database.clients()
            statusMessage = "Client deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func invoices(forClient clientID: Int64) -> [BooksInvoice] {
        invoices.filter { $0.clientID == clientID }
    }

    // MARK: - Products (price list)

    func saveProduct(_ product: inout BooksProduct) async {
        do {
            _ = try database.saveProduct(&product)
            products = try database.products()
            statusMessage = "Saved \(product.name)"
        } catch {
            errorMessage = "Could not save product: \(error.localizedDescription)"
        }
    }

    func deleteProduct(id: Int64) async {
        do {
            try database.deleteProduct(id: id)
            products = try database.products()
        } catch {
            errorMessage = "Could not delete product: \(error.localizedDescription)"
        }
    }

    // MARK: - Computed

    var selectedTotals: (subtotal: Double, tax: Double, total: Double, paid: Double) {
        let rate = selectedInvoice?.taxRate ?? 0.10
        let subtotal = selectedItems.reduce(0) { $0 + $1.amount }
        let tax = subtotal * rate
        let paid = selectedPayments.reduce(0) { $0 + $1.amount }
        return (subtotal, tax, subtotal + tax, paid)
    }

    var overdueNumbers: [String] {
        invoices.filter {
            $0.status == .authorised && ($0.dueDate ?? .distantFuture) < Date()
        }.map(\.number)
    }

    // MARK: - Client / invoice creation

    @discardableResult
    func findOrCreateClient(named name: String, email: String? = nil) throws -> BooksClient {
        if let existing = try database.client(named: name) { return existing }
        var client = BooksClient(
            id: nil, name: name, email: email, phone: nil,
            poAddressLine1: nil, poAddressLine2: nil, poCity: nil, poRegion: nil,
            poPostalCode: nil, poCountry: nil, taxNumber: nil, notes: nil,
            xeroID: nil, createdAt: Date(), updatedAt: Date())
        let saved = try database.saveClient(&client)
        clients = try database.clients()
        return saved
    }

    @discardableResult
    func createInvoice(
        clientName: String, clientEmail: String?,
        items: [(description: String, quantity: Double, unitAmount: Double, discount: Double)],
        dueDays: Int, notes: String?,
        currency: String? = nil, taxRate: Double? = nil, taxLabel: String? = nil
    ) throws -> BooksInvoice {
        let client = try findOrCreateClient(named: clientName, email: clientEmail)
        guard let clientID = client.id else { throw CocoaError(.coreData) }
        let due = dueDays > 0
            ? Calendar.current.date(byAdding: .day, value: dueDays, to: Date()) : nil
        // Overrides let agents invoice a foreign client in their currency;
        // everything else follows the Business settings snapshot.
        let resolvedTaxRate = taxRate ?? seller.taxRate
        let invoice = try database.createInvoice(
            clientID: clientID, items: items,
            dueDate: due, notes: notes, accountCode: seller.defaultAccountCode,
            currency: currency ?? seller.currency, taxRate: resolvedTaxRate,
            taxType: resolvedTaxRate == seller.taxRate ? seller.taxType
                : BooksSeller.taxDefaults(forCurrency: currency ?? seller.currency).taxType,
            taxLabel: taxLabel ?? seller.taxLabel)
        invoices = try database.invoices()
        statusMessage = "Created \(invoice.number)"
        return invoice
    }

    // MARK: - Status + payments

    func setStatus(_ status: BooksInvoiceStatus) async {
        guard let id = selectedInvoice?.id else { return }
        do {
            try database.setInvoiceStatus(id, status)
            invoices = try database.invoices()
            await selectInvoice(id)
            statusMessage = "Marked \(status.displayName.lowercased())"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordPayment(amount: Double, method: String?) async {
        guard let id = selectedInvoice?.id else { return }
        do {
            try database.recordPayment(invoiceID: id, amount: amount, method: method, note: nil)
            invoices = try database.invoices()
            await selectInvoice(id)
            statusMessage = "Payment recorded"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Publishing (PDF → file → DAM)

    /// Renders the selected invoice to a PDF in the invoices folder, records
    /// the path, and triggers a DAM delta import so it appears in
    /// MaestroDAM with a thumbnail. Returns the PDF URL.
    @discardableResult
    func publishSelectedInvoice() async throws -> URL {
        guard let invoice = selectedInvoice, let invoiceID = invoice.id,
              let client = selectedClient else {
            throw CocoaError(.coreData)
        }
        isPublishing = true
        defer { isPublishing = false }

        let folder = Self.invoicesFolder
        let dest = folder.appendingPathComponent("\(invoice.number).pdf")
        // Template designer wins when the user has saved one; otherwise the
        // built-in CoreGraphics layout (always available, zero setup).
        if BooksTemplate.templateExists {
            _ = try InvoiceTemplateRenderer.render(
                invoice: invoice, client: client, items: selectedItems,
                payments: selectedPayments, seller: seller,
                templateURL: BooksTemplate.templateFileURL, to: dest)
        } else {
            try InvoicePDFRenderer.render(
                invoice: invoice, client: client, items: selectedItems,
                payments: selectedPayments, seller: seller, to: dest)
        }

        try database.setInvoicePDFPath(invoiceID, path: dest.path)
        invoices = try database.invoices()
        await selectInvoice(invoiceID)

        // DAM auto-file: delta-import the invoices folder (cheap — only new
        // files get cataloged; existing rows are mtime-checked).
        Task.detached(priority: .utility) {
            _ = try? await DAMImportService.shared.importFolder(at: folder)
        }

        statusMessage = "Published \(dest.lastPathComponent) → MaestroDAM"
        return dest
    }

    // MARK: - Xero export

    /// Writes Xero import CSVs (invoices + contacts) to a chosen folder.
    func exportForXero() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a folder for the Xero import CSVs"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        do {
            let allInvoices = try database.invoices()
            let allClients = try database.clients()
            var clientMap: [Int64: BooksClient] = [:]
            for client in allClients { if let id = client.id { clientMap[id] = client } }
            var itemsMap: [Int64: [BooksLineItem]] = [:]
            var paidMap: [Int64: Double] = [:]
            for invoice in allInvoices {
                guard let id = invoice.id else { continue }
                itemsMap[id] = try database.lineItems(invoiceID: id)
                paidMap[id] = try database.amountPaid(id)
            }

            let invoicesCSV = XeroExportService.invoicesCSV(
                invoices: allInvoices, clients: clientMap,
                lineItems: itemsMap, amountPaid: paidMap)
            let contactsCSV = XeroExportService.contactsCSV(
                allClients, defaultAccountCode: seller.defaultAccountCode)

            let stamp = Self.exportStamp()
            let invoicesURL = folder.appendingPathComponent("xero-invoices-\(stamp).csv")
            let contactsURL = folder.appendingPathComponent("xero-contacts-\(stamp).csv")
            try invoicesCSV.write(to: invoicesURL, atomically: true, encoding: .utf8)
            try contactsCSV.write(to: contactsURL, atomically: true, encoding: .utf8)
            statusMessage = "Xero export: \(invoicesURL.lastPathComponent), \(contactsURL.lastPathComponent)"
        } catch {
            errorMessage = "Xero export failed: \(error.localizedDescription)"
        }
    }

    private static func exportStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}

/// Shared @MainActor BooksViewModel for agent tools (the books_* handlers
/// need one instance, hop-safe from off-actor via MainActor.run).
@MainActor
enum BooksViewModelHolder {
    static let shared = BooksViewModel()
}
