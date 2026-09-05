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
    /// seller profile, and disables Xero sync. Kept as a stored property so
    /// SwiftUI observes changes when the database instance is swapped.
    private(set) var isDemo: Bool = BooksDatabase.isDemoMode

    private(set) var clients: [BooksClient] = []
    private(set) var products: [BooksProduct] = []
    private(set) var expenses: [BooksExpense] = []
    private(set) var invoices: [BooksInvoice] = []
    private(set) var accounts: [BooksAccount] = []
    private(set) var suppliers: [BooksSupplier] = []
    private(set) var bills: [BooksBill] = []
    private(set) var journalEntries: [BooksJournalEntry] = []
    private(set) var reminders: [BooksInvoiceReminder] = []
    private(set) var crmLeads: [BooksCRMLead] = []
    private(set) var crmOpportunities: [BooksCRMOpportunity] = []
    private(set) var crmActivities: [BooksCRMActivity] = []
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
        isDemo = BooksDatabase.isDemoMode
        do {
            clients = try database.clients()
            products = try database.products()
            expenses = try database.expenses()
            invoices = try database.invoices()
            accounts = try database.accounts()
            suppliers = try database.suppliers()
            bills = try database.bills()
            journalEntries = try database.journalEntries()
            reminders = try database.pendingReminders(before: Date.distantFuture)
            crmLeads = try database.crmLeads()
            crmOpportunities = try database.crmOpportunities()
            crmActivities = try database.crmActivities()
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
            await verifyTaxNumberIfNeeded(name: client.name, taxNumber: client.taxNumber, country: client.poCountry)
            statusMessage = "Saved \(client.name)"
        } catch {
            errorMessage = "Could not save client: \(error.localizedDescription)"
        }
    }

    private func verifyTaxNumberIfNeeded(name: String, taxNumber: String?, country: String?) async {
        guard let taxNumber, !taxNumber.isEmpty,
              (country ?? LocaleSettings.shared.country).uppercased() == "AU" else { return }
        let normalised = ABNVerifierService.normalise(taxNumber)
        guard ABNVerifierService.isValidFormat(normalised) else {
            statusMessage = "Saved. ABN format appears invalid."
            return
        }
        let result = await ABNVerifierService.shared.verify(abn: normalised)
        if result.isVerified {
            statusMessage = "Saved. ABN verified: \(result.entityName ?? name)"
        } else {
            statusMessage = "Saved. ABN could not be verified against bulk extract or lookup."
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

    // MARK: - Chart of Accounts

    func saveAccount(_ account: inout BooksAccount) async {
        do {
            _ = try database.saveAccount(&account)
            accounts = try database.accounts()
            statusMessage = "Saved account \(account.code)"
        } catch {
            errorMessage = "Could not save account: \(error.localizedDescription)"
        }
    }

    func deleteAccount(id: Int64) async {
        do {
            try database.deleteAccount(id: id)
            accounts = try database.accounts()
            statusMessage = "Account deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Suppliers

    func saveSupplier(_ supplier: inout BooksSupplier) async {
        do {
            _ = try database.saveSupplier(&supplier)
            suppliers = try database.suppliers()
            statusMessage = "Saved \(supplier.name)"
        } catch {
            errorMessage = "Could not save supplier: \(error.localizedDescription)"
        }
    }

    func deleteSupplier(id: Int64) async {
        do {
            try database.deleteSupplier(id: id)
            suppliers = try database.suppliers()
            statusMessage = "Supplier deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bills(forSupplier supplierID: Int64) -> [BooksBill] {
        bills.filter { $0.supplierID == supplierID }
    }

    // MARK: - Bills

    @discardableResult
    func createBill(
        supplierName: String,
        items: [(description: String, quantity: Double, unitAmount: Double, discount: Double)],
        dueDays: Int, notes: String?,
        accountCode: String? = nil
    ) throws -> BooksBill {
        let supplier = try findOrCreateSupplier(named: supplierName)
        guard let supplierID = supplier.id else { throw CocoaError(.coreData) }
        let due = dueDays > 0
            ? Calendar.current.date(byAdding: .day, value: dueDays, to: Date()) : nil
        let resolvedAccountCode = accountCode ?? supplier.defaultExpenseAccountCode ?? seller.defaultExpenseAccountCode
        let bill = try database.createBill(
            supplierID: supplierID, items: items,
            dueDate: due, notes: notes, accountCode: resolvedAccountCode,
            currency: seller.currency, taxRate: seller.taxRate,
            taxType: seller.expenseTaxType, taxLabel: seller.taxLabel)
        bills = try database.bills()
        statusMessage = "Created \(bill.number)"
        return bill
    }

    func setBillStatus(_ billID: Int64, _ status: BooksBillStatus) async {
        do {
            try database.setBillStatus(billID, status)
            bills = try database.bills()
            statusMessage = "Bill marked \(status.displayName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBill(id: Int64) async {
        do {
            try database.deleteBill(id: id)
            bills = try database.bills()
            statusMessage = "Bill deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func findOrCreateSupplier(named name: String) throws -> BooksSupplier {
        if let existing = try database.supplier(named: name) { return existing }
        var supplier = BooksSupplier(
            id: nil, name: name, email: nil, phone: nil,
            addressLine1: nil, addressLine2: nil, city: nil, region: nil,
            postalCode: nil, country: nil, taxNumber: nil,
            paymentTerms: nil, defaultExpenseAccountCode: nil, notes: nil,
            xeroID: nil, createdAt: Date(), updatedAt: Date())
        let saved = try database.saveSupplier(&supplier)
        suppliers = try database.suppliers()
        return saved
    }

    // MARK: - Journal entries

    func saveJournalEntry(
        _ entry: inout BooksJournalEntry,
        lines: [BooksJournalLine]
    ) async {
        do {
            _ = try database.saveJournalEntry(&entry, lines: lines)
            journalEntries = try database.journalEntries()
            statusMessage = "Saved journal entry"
        } catch {
            errorMessage = "Could not save journal entry: \(error.localizedDescription)"
        }
    }

    func deleteJournalEntry(id: Int64) async {
        do {
            try database.deleteJournalEntry(id: id)
            journalEntries = try database.journalEntries()
            statusMessage = "Journal entry deleted"
        } catch {
            errorMessage = error.localizedDescription
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
            xeroID: nil, reportToBlacklist: true, createdAt: Date(), updatedAt: Date())
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

    func setInvoiceReportToBlacklist(_ value: Bool?) async {
        guard let id = selectedInvoice?.id else { return }
        do {
            try database.setInvoiceReportToBlacklist(id, value)
            invoices = try database.invoices()
            await selectInvoice(id)
            statusMessage = "Reporting preference updated"
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

    // MARK: - Reminders

    func sendReminder(_ reminderID: Int64) async {
        do {
            guard let reminder = reminders.first(where: { $0.id == reminderID }),
                  let invoice = invoices.first(where: { $0.id == reminder.invoiceID }),
                  let client = clients.first(where: { $0.id == invoice.clientID }),
                  let email = client.email, !email.isEmpty else {
                errorMessage = "Cannot send reminder: missing invoice, client, or email."
                return
            }
            let subject = reminder.subject
            let body = reminder.body
            let success = await AppleMailService.shared.compose(to: email, subject: subject, body: body)
            if success {
                try database.markReminderSent(id: reminderID)
                statusMessage = "Reminder sent to \(client.name)"
            } else {
                try database.markReminderSent(id: reminderID, error: "Mail compose cancelled or failed")
                errorMessage = "Reminder compose failed for \(client.name)"
            }
            reminders = try database.pendingReminders(before: Date.distantFuture)
        } catch {
            self.errorMessage = "Could not send reminder: \(error.localizedDescription)"
        }
    }

    func sendDueReminders() async {
        do {
            let due = try database.pendingReminders(before: Date())
            var sent = 0
            var failed = 0
            for reminder in due {
                guard let invoice = invoices.first(where: { $0.id == reminder.invoiceID }),
                      let client = clients.first(where: { $0.id == invoice.clientID }),
                      let email = client.email, !email.isEmpty else {
                    try database.markReminderSent(id: reminder.id ?? 0, error: "Missing client email")
                    failed += 1
                    continue
                }
                let success = await AppleMailService.shared.compose(
                    to: email, subject: reminder.subject, body: reminder.body)
                if success {
                    try database.markReminderSent(id: reminder.id ?? 0)
                    sent += 1
                } else {
                    try database.markReminderSent(id: reminder.id ?? 0, error: "Mail compose failed")
                    failed += 1
                }
            }
            reminders = try database.pendingReminders(before: Date.distantFuture)
            statusMessage = "Sent \(sent) reminders, \(failed) failed"
        } catch {
            self.errorMessage = "Could not send reminders: \(error.localizedDescription)"
        }
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

    // MARK: - Accountant export

    /// Writes a zip of accountant-ready reports to a chosen folder.
    func exportAccountantPack() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "maestrobooks-accountant-pack.zip"
        panel.message = "Choose where to save the accountant pack"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let reports = try AccountantExportService.generateAll(database: database, seller: seller)
            let files: [(name: String, content: String)] = [
                ("trial_balance.csv", reports.trialBalance),
                ("profit_and_loss.csv", reports.profitAndLoss),
                ("balance_sheet.csv", reports.balanceSheet),
                ("general_ledger.csv", reports.generalLedger),
                ("ar_aging.csv", reports.arAging),
                ("ap_aging.csv", reports.apAging),
            ]
            try createZip(files: files, destination: url)
            statusMessage = "Accountant pack saved to \(url.lastPathComponent)"
        } catch {
            self.errorMessage = "Accountant export failed: \(error.localizedDescription)"
        }
    }

    private func createZip(files: [(name: String, content: String)], destination: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for file in files {
            let fileURL = tempDir.appendingPathComponent(file.name)
            try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", destination.path, "."]
        process.currentDirectoryURL = tempDir
        try process.run()
        process.waitUntilExit()
        try FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Import

    func importFile(at url: URL, source: BooksImportService.ImportSource) async {
        do {
            let result = try await BooksImportService.importFile(at: url, source: source, database: database)
            await reload()
            if result.errors.isEmpty {
                statusMessage = "Imported \(result.imported), skipped \(result.skipped)"
            } else {
                statusMessage = "Imported \(result.imported), skipped \(result.skipped), \(result.errors.count) errors"
                errorMessage = result.errors.prefix(3).joined(separator: "; ")
            }
        } catch {
            self.errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - CRM Leads

    func saveCRMLead(_ lead: inout BooksCRMLead) async {
        do {
            _ = try database.saveCRMLead(&lead)
            crmLeads = try database.crmLeads()
            await verifyTaxNumberIfNeeded(name: lead.name, taxNumber: lead.taxNumber, country: lead.country)
            statusMessage = "Saved \(lead.name)"
        } catch {
            self.errorMessage = "Could not save lead: \(error.localizedDescription)"
        }
    }

    func deleteCRMLead(id: Int64) async {
        do {
            try database.deleteCRMLead(id: id)
            crmLeads = try database.crmLeads()
            statusMessage = "Lead deleted"
        } catch {
            self.errorMessage = "Could not delete lead: \(error.localizedDescription)"
        }
    }

    func convertCRMLeadToClient(id: Int64) async {
        do {
            let client = try database.convertCRMLeadToClient(id)
            await reload()
            statusMessage = "Converted to client: \(client.name)"
        } catch {
            self.errorMessage = "Could not convert lead: \(error.localizedDescription)"
        }
    }

    // MARK: - CRM Opportunities

    func saveCRMOpportunity(_ opp: inout BooksCRMOpportunity) async {
        do {
            _ = try database.saveCRMOpportunity(&opp)
            crmOpportunities = try database.crmOpportunities()
            statusMessage = "Saved \(opp.title)"
        } catch {
            self.errorMessage = "Could not save opportunity: \(error.localizedDescription)"
        }
    }

    func deleteCRMOpportunity(id: Int64) async {
        do {
            try database.deleteCRMOpportunity(id: id)
            crmOpportunities = try database.crmOpportunities()
            statusMessage = "Opportunity deleted"
        } catch {
            self.errorMessage = "Could not delete opportunity: \(error.localizedDescription)"
        }
    }

    // MARK: - CRM Activities

    func crmActivities(contactKind: String, contactID: Int64) -> [BooksCRMActivity] {
        (try? database.crmActivities(contactKind: contactKind, contactID: contactID)) ?? []
    }

    func saveCRMActivity(_ activity: inout BooksCRMActivity) async {
        do {
            _ = try database.saveCRMActivity(&activity)
            crmActivities = try database.crmActivities()
            statusMessage = "Activity saved"
        } catch {
            self.errorMessage = "Could not save activity: \(error.localizedDescription)"
        }
    }

    func deleteCRMActivity(id: Int64) async {
        do {
            try database.deleteCRMActivity(id: id)
            crmActivities = try database.crmActivities()
            statusMessage = "Activity deleted"
        } catch {
            self.errorMessage = "Could not delete activity: \(error.localizedDescription)"
        }
    }
}

/// Shared @MainActor BooksViewModel for agent tools (the books_* handlers
/// need one instance, hop-safe from off-actor via MainActor.run).
@MainActor
enum BooksViewModelHolder {
    static let shared = BooksViewModel()
}
