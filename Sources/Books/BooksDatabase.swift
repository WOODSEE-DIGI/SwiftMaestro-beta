import Foundation
import GRDB

// MARK: - MaestroBooks Database
//
// GRDB/WAL, same patterns as DAMDatabase (proven at 448K rows). Xero-ready
// schema: statuses stored verbatim, account codes + tax types on lines,
// xero_id columns reserved for API sync.
final class BooksDatabase: Sendable {

    // MARK: Shared instance (live ↔ demo swappable)
    //
    // Demo mode swaps the shared instance to a SEPARATE file
    // (books-demo.sqlite) so screenshots/videos never touch real books.
    // Callers read BooksDatabase.shared everywhere, so a swap + VM reload
    // is all it takes.

    /// True while the shared instance points at the demo database.
    /// Access is main-thread driven (toolbar toggle + VM reads); the lock
    /// guards the instance swap. (Swift 6: same nonisolated(unsafe)
    /// pattern as ThumbnailService.memoryCache.)
    nonisolated(unsafe) private(set) static var isDemoMode = false

    nonisolated(unsafe) private static var instance: BooksDatabase?
    private static let instanceLock = NSLock()

    static var shared: BooksDatabase {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        if let instance { return instance }
        let opened = open(currentURL())
        instance = opened
        return opened
    }

    /// Swap between the live and demo databases. Seeds demo content on
    /// first entry. View models must reload after this.
    static func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoMode else { return }
        instanceLock.lock()
        isDemoMode = enabled
        instance = nil
        instanceLock.unlock()
        if enabled {
            // Open + seed eagerly so a failure surfaces immediately.
            do {
                try DemoData.seedIfEmpty(shared)
            } catch {
                NSLog("[Books] Demo seed failed: %@", String(describing: error))
            }
        }
    }

    private static func currentURL() -> URL {
        isDemoMode ? demoURL() : defaultURL()
    }

    private static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro/Books", isDirectory: true)
            .appendingPathComponent("books.sqlite")
    }

    private static func demoURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro/Books", isDirectory: true)
            .appendingPathComponent("books-demo.sqlite")
    }

    private static func open(_ makeURL: @autoclosure () throws -> URL) -> BooksDatabase {
        do {
            return try BooksDatabase(makeURL: makeURL)
        } catch {
            NSLog("[Books] Failed to open database at %@: %@ — using in-memory fallback.",
                  (try? makeURL().path) ?? "?", String(describing: error))
            // swiftlint:disable:next force_try
            return try! BooksDatabase(inMemory: ())
        }
    }

    let dbQueue: DatabaseQueue

    private init(makeURL: () throws -> URL) throws {
        let url = try makeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    private init(inMemory: ()) throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Migrations

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE clients (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    email TEXT, phone TEXT,
                    po_address_line1 TEXT, po_address_line2 TEXT,
                    po_city TEXT, po_region TEXT, po_postal_code TEXT, po_country TEXT,
                    tax_number TEXT,
                    notes TEXT,
                    xero_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE invoices (
                    id INTEGER PRIMARY KEY,
                    number TEXT NOT NULL UNIQUE,
                    client_id INTEGER NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
                    issue_date REAL NOT NULL,
                    due_date REAL,
                    status TEXT NOT NULL DEFAULT 'DRAFT',
                    currency TEXT NOT NULL DEFAULT 'AUD',
                    tax_rate REAL NOT NULL DEFAULT 0.10,
                    tax_type TEXT NOT NULL DEFAULT 'OUTPUT',
                    account_code TEXT NOT NULL DEFAULT '200',
                    notes TEXT,
                    pdf_path TEXT,
                    xero_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_invoices_status ON invoices(status)")
            try db.execute(sql: "CREATE INDEX idx_invoices_client ON invoices(client_id)")

            try db.execute(sql: """
                CREATE TABLE line_items (
                    id INTEGER PRIMARY KEY,
                    invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL DEFAULT 0,
                    description TEXT NOT NULL,
                    quantity REAL NOT NULL DEFAULT 1,
                    unit_amount REAL NOT NULL DEFAULT 0,
                    account_code TEXT,
                    tax_type TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_line_items_invoice ON line_items(invoice_id)")

            try db.execute(sql: """
                CREATE TABLE payments (
                    id INTEGER PRIMARY KEY,
                    invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
                    date REAL NOT NULL,
                    amount REAL NOT NULL,
                    method TEXT, note TEXT,
                    created_at REAL NOT NULL
                )
                """)

            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")

            try db.execute(sql: """
                CREATE TABLE audit_log (
                    id INTEGER PRIMARY KEY,
                    entity TEXT NOT NULL,
                    entity_id INTEGER NOT NULL,
                    action TEXT NOT NULL,
                    detail TEXT,
                    at REAL NOT NULL
                )
                """)
        }

        // v2: international tax support — invoices snapshot the tax display
        // name ("GST"/"VAT"/...) so old invoices keep their original wording.
        migrator.registerMigration("v2") { db in
            try db.execute(
                sql: "ALTER TABLE invoices ADD COLUMN tax_label TEXT NOT NULL DEFAULT 'GST'")
        }

        // v3: per-line discounts + the price-list (products/services) table.
        migrator.registerMigration("v3") { db in
            try db.execute(
                sql: "ALTER TABLE line_items ADD COLUMN discount REAL NOT NULL DEFAULT 0")
            try db.execute(sql: """
                CREATE TABLE products (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    description TEXT,
                    unit_price REAL NOT NULL DEFAULT 0,
                    account_code TEXT,
                    tax_type TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
        }

        // v4: expenses (supplier bills → Xero ACCPAY) + Xero Item code on
        // products (the Items API's unique key).
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE TABLE expenses (
                    id INTEGER PRIMARY KEY,
                    supplier TEXT NOT NULL,
                    description TEXT NOT NULL,
                    reference TEXT,
                    account_code TEXT NOT NULL DEFAULT '429',
                    issue_date REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'DRAFT',
                    currency TEXT NOT NULL DEFAULT 'AUD',
                    tax_rate REAL NOT NULL DEFAULT 0.10,
                    tax_type TEXT NOT NULL DEFAULT 'INPUT',
                    subtotal REAL NOT NULL DEFAULT 0,
                    notes TEXT,
                    xero_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "ALTER TABLE products ADD COLUMN code TEXT")
        }

        return migrator
    }()

    // MARK: - Audit

    private func validationError(_ message: String) -> NSError {
        NSError(domain: "MaestroBooks", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    func audit(_ entity: String, _ entityID: Int64, _ action: String, _ detail: String? = nil) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO audit_log (entity, entity_id, action, detail, at) VALUES (?, ?, ?, ?, ?)",
                arguments: [entity, entityID, action, detail, Date().timeIntervalSince1970])
        }
    }

    // MARK: - Invoice numbering

    /// Next sequential invoice number: INV-<year>-NNNN (counter in meta).
    func nextInvoiceNumber() throws -> String {
        try dbQueue.write { db in
            let raw = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'next_invoice_number'") ?? "1"
            let next = Int(raw) ?? 1
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('next_invoice_number', ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: ["\(next + 1)"])
            let year = Calendar.current.component(.year, from: Date())
            return String(format: "INV-%d-%04d", year, next)
        }
    }

    // MARK: - Clients

    func clients() throws -> [BooksClient] {
        try dbQueue.read { db in
            try BooksClient.order(BooksClient.Columns.name).fetchAll(db)
        }
    }

    func client(named name: String) throws -> BooksClient? {
        try dbQueue.read { db in
            try BooksClient.filter(BooksClient.Columns.name == name).fetchOne(db)
        }
    }

    @discardableResult
    func saveClient(_ client: inout BooksClient) throws -> BooksClient {
        let isNew = client.id == nil
        let now = Date()
        client.updatedAt = now
        if isNew { client.createdAt = now }
        // Xero alignment: contact names are required + unique (Xero rejects
        // duplicate contact names at the API — catch it here instead).
        let trimmedName = client.name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            throw validationError("Client name is required (Xero contact Name).")
        }
        client.name = trimmedName
        if let clash = try dbQueue.read({ db in
            try BooksClient
                .filter(sql: "name = ? AND id != ?", arguments: [trimmedName, client.id ?? -1])
                .fetchOne(db)
        }) {
            throw validationError(
                "A client named '\(trimmedName)' already exists "
                    + "(id \(clash.id ?? -1)) — Xero requires unique contact names.")
        }
        // Explicit INSERT + lastInsertedRowID — the DAMDatabase-proven
        // pattern. (GRDB's save()/inserted() don't populate struct ids
        // reliably for raw-SQL-created tables.)
        if isNew {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO clients (name, email, phone, po_address_line1, po_address_line2,
                                         po_city, po_region, po_postal_code, po_country, tax_number,
                                         notes, xero_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        client.name, client.email, client.phone,
                        client.poAddressLine1, client.poAddressLine2, client.poCity,
                        client.poRegion, client.poPostalCode, client.poCountry,
                        client.taxNumber, client.notes, client.xeroID,
                        client.createdAt, client.updatedAt])
                client.id = db.lastInsertedRowID
            }
        } else {
            try dbQueue.write { db in try client.update(db) }
        }
        if let id = client.id {
            audit("client", id, isNew ? "create" : "update", client.name)
        }
        return client
    }

    // MARK: - Invoices

    func invoices(status: BooksInvoiceStatus? = nil) throws -> [BooksInvoice] {
        try dbQueue.read { db in
            var request = BooksInvoice.all()
            if let status {
                request = request.filter(BooksInvoice.Columns.statusRaw == status.rawValue)
            }
            return try request.order(BooksInvoice.Columns.issueDate.desc).fetchAll(db)
        }
    }

    func invoice(number: String) throws -> BooksInvoice? {
        try dbQueue.read { db in
            try BooksInvoice.filter(sql: "number = ?", arguments: [number]).fetchOne(db)
        }
    }

    func lineItems(invoiceID: Int64) throws -> [BooksLineItem] {
        try dbQueue.read { db in
            try BooksLineItem
                .filter(sql: "invoice_id = ?", arguments: [invoiceID])
                .order(sql: "position")
                .fetchAll(db)
        }
    }

    func payments(invoiceID: Int64) throws -> [BooksPayment] {
        try dbQueue.read { db in
            try BooksPayment.filter(sql: "invoice_id = ?", arguments: [invoiceID]).fetchAll(db)
        }
    }

    /// Creates an invoice + line items atomically, assigning the next number.
    @discardableResult
    func createInvoice(
        clientID: Int64,
        items: [(description: String, quantity: Double, unitAmount: Double, discount: Double)],
        dueDate: Date?, notes: String?, accountCode: String,
        currency: String = "AUD", taxRate: Double = 0.10,
        taxType: String = "OUTPUT", taxLabel: String = "GST"
    ) throws -> BooksInvoice {
        let now = Date()
        let number = try nextInvoiceNumber()
        var invoice = BooksInvoice(
            id: nil, number: number, clientID: clientID,
            issueDate: now, dueDate: dueDate,
            statusRaw: BooksInvoiceStatus.draft.rawValue,
            currency: currency, taxRate: taxRate, taxLabel: taxLabel, taxType: taxType,
            accountCode: accountCode, notes: notes, pdfPath: nil, xeroID: nil,
            createdAt: now, updatedAt: now)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO invoices (number, client_id, issue_date, due_date, status,
                                      currency, tax_rate, tax_label, tax_type, account_code,
                                      notes, pdf_path, xero_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    invoice.number, invoice.clientID, invoice.issueDate, invoice.dueDate,
                    invoice.statusRaw, invoice.currency, invoice.taxRate, invoice.taxLabel,
                    invoice.taxType, invoice.accountCode, invoice.notes, invoice.pdfPath,
                    invoice.xeroID, invoice.createdAt, invoice.updatedAt])
            invoice.id = db.lastInsertedRowID
            guard let invoiceID = invoice.id else {
                throw NSError(domain: "MaestroBooks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invoice insert returned no id"])
            }
            for (index, item) in items.enumerated() {
                let line = BooksLineItem(
                    id: nil, invoiceID: invoiceID, position: index,
                    description: item.description, quantity: item.quantity,
                    unitAmount: item.unitAmount, discount: item.discount,
                    accountCode: nil, taxType: nil)
                try line.insert(db)
            }
        }
        if let id = invoice.id { audit("invoice", id, "create", number) }
        return invoice
    }

    func setInvoiceStatus(_ invoiceID: Int64, _ status: BooksInvoiceStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE invoices SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Date().timeIntervalSince1970, invoiceID])
        }
        audit("invoice", invoiceID, "status", status.rawValue)
    }

    func setInvoicePDFPath(_ invoiceID: Int64, path: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE invoices SET pdf_path = ?, updated_at = ? WHERE id = ?",
                arguments: [path, Date().timeIntervalSince1970, invoiceID])
        }
        audit("invoice", invoiceID, "pdf", path)
    }

    /// Links a synced client to its Xero ContactID (idempotent sync anchor).
    func setClientXeroID(id: Int64, xeroID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clients SET xero_id = ?, updated_at = ? WHERE id = ?",
                arguments: [xeroID, Date().timeIntervalSince1970, id])
        }
        audit("client", id, "xero-link", xeroID)
    }

    /// Links a pushed invoice to its Xero InvoiceID.
    func setInvoiceXeroID(id: Int64, xeroID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE invoices SET xero_id = ?, updated_at = ? WHERE id = ?",
                arguments: [xeroID, Date().timeIntervalSince1970, id])
        }
        audit("invoice", id, "xero-link", xeroID)
    }

    /// Links a pushed expense to its Xero (ACCPAY) InvoiceID.
    func setExpenseXeroID(id: Int64, xeroID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE expenses SET xero_id = ?, updated_at = ? WHERE id = ?",
                arguments: [xeroID, Date().timeIntervalSince1970, id])
        }
        audit("expense", id, "xero-link", xeroID)
    }

    // MARK: - Expenses (supplier bills → Xero ACCPAY)

    func expenses(status: BooksInvoiceStatus? = nil) throws -> [BooksExpense] {
        try dbQueue.read { db in
            var request = BooksExpense.all()
            if let status {
                request = request.filter(BooksExpense.Columns.statusRaw == status.rawValue)
            }
            return try request.order(BooksExpense.Columns.issueDate.desc).fetchAll(db)
        }
    }

    @discardableResult
    func saveExpense(_ expense: inout BooksExpense) throws -> BooksExpense {
        let isNew = expense.id == nil
        let now = Date()
        expense.updatedAt = now
        if isNew { expense.createdAt = now }
        expense.supplier = expense.supplier.trimmingCharacters(in: .whitespaces)
        guard !expense.supplier.isEmpty else {
            throw validationError("Supplier is required (Xero Contact on the bill).")
        }
        expense.expenseDescription = expense.expenseDescription
            .trimmingCharacters(in: .whitespaces)
        guard !expense.expenseDescription.isEmpty else {
            throw validationError("Description is required (Xero line item).")
        }
        if isNew {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO expenses (supplier, description, reference, account_code,
                                          issue_date, status, currency, tax_rate, tax_type,
                                          subtotal, notes, xero_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        expense.supplier, expense.expenseDescription, expense.reference,
                        expense.accountCode, expense.issueDate, expense.statusRaw,
                        expense.currency, expense.taxRate, expense.taxType,
                        expense.subtotal, expense.notes, expense.xeroID,
                        expense.createdAt, expense.updatedAt])
                expense.id = db.lastInsertedRowID
            }
        } else {
            try dbQueue.write { db in try expense.update(db) }
        }
        audit("expense", expense.id ?? 0, isNew ? "create" : "update", expense.supplier)
        return expense
    }

    func setExpenseStatus(_ expenseID: Int64, _ status: BooksInvoiceStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE expenses SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Date().timeIntervalSince1970, expenseID])
        }
        audit("expense", expenseID, "status", status.rawValue)
    }

    /// Local-only delete (never synced ones by UI rule; a synced expense
    /// stays in Xero and would need voiding there).
    func deleteExpense(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM expenses WHERE id = ?", arguments: [id])
        }
        audit("expense", id, "delete", nil)
    }

    /// Records a payment; auto-marks PAID when the balance reaches zero.
    @discardableResult
    func recordPayment(
        invoiceID: Int64, amount: Double, method: String?, note: String?
    ) throws -> BooksPayment {
        var payment = BooksPayment(
            id: nil, invoiceID: invoiceID, date: Date(),
            amount: amount, method: method, note: note, createdAt: Date())
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO payments (invoice_id, date, amount, method, note, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    payment.invoiceID, payment.date, payment.amount,
                    payment.method, payment.note, payment.createdAt])
            payment.id = db.lastInsertedRowID
        }
        audit("payment", payment.id ?? 0, "record", "\(amount) on invoice \(invoiceID)")
        let paid = try amountPaid(invoiceID)
        let total = try invoiceTotal(invoiceID)
        if paid >= total - 0.005 {
            try setInvoiceStatus(invoiceID, .paid)
        }
        return payment
    }

    // MARK: - Totals

    func invoiceTotal(_ invoiceID: Int64) throws -> Double {
        let items = try lineItems(invoiceID: invoiceID)
        let subtotal = items.reduce(0) { $0 + $1.amount }
        let rate = try dbQueue.read { db in
            try Double.fetchOne(
                db, sql: "SELECT tax_rate FROM invoices WHERE id = ?",
                arguments: [invoiceID]) ?? 0
        }
        return subtotal * (1 + rate)
    }

    func amountPaid(_ invoiceID: Int64) throws -> Double {
        try dbQueue.read { db in
            try Double.fetchOne(
                db, sql: "SELECT COALESCE(SUM(amount), 0) FROM payments WHERE invoice_id = ?",
                arguments: [invoiceID]) ?? 0
        }
    }

    // MARK: - Products (price list)

    func products() throws -> [BooksProduct] {
        try dbQueue.read { db in
            try BooksProduct.order(BooksProduct.Columns.name).fetchAll(db)
        }
    }

    @discardableResult
    func saveProduct(_ product: inout BooksProduct) throws -> BooksProduct {
        let isNew = product.id == nil
        let now = Date()
        product.updatedAt = now
        if isNew { product.createdAt = now }
        // Xero Items API alignment: Code is required + unique. Blank becomes
        // an auto-slug of the name; clashes are rejected before Xero sees them.
        product.name = product.name.trimmingCharacters(in: .whitespaces)
        guard !product.name.isEmpty else {
            throw validationError("Product name is required (Xero Item Name).")
        }
        if product.code?.trimmingCharacters(in: .whitespaces).isEmpty != false {
            product.code = BooksProduct.itemCode(fromName: product.name)
        }
        if let code = product.code,
           let clash = try dbQueue.read({ db in
               try BooksProduct
                   .filter(sql: "code = ? AND id != ?", arguments: [code, product.id ?? -1])
                   .fetchOne(db)
           }) {
            throw validationError(
                "Product code '\(code)' is already used by '\(clash.name)' "
                    + "— Xero item codes must be unique.")
        }
        if isNew {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO products (name, description, unit_price, account_code,
                                          tax_type, code, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        product.name, product.details, product.unitPrice,
                        product.accountCode, product.taxType, product.code,
                        product.createdAt, product.updatedAt])
                product.id = db.lastInsertedRowID
            }
        } else {
            try dbQueue.write { db in try product.update(db) }
        }
        audit("product", product.id ?? 0, isNew ? "create" : "update", product.name)
        return product
    }

    func deleteProduct(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [id])
        }
        audit("product", id, "delete", nil)
    }

    /// Deletes a client ONLY when they have no invoices (invoices are
    /// accounting records — they keep their client snapshot forever).
    func deleteClient(id: Int64) throws {
        let invoiceCount = try dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM invoices WHERE client_id = ?",
                arguments: [id]) ?? 0
        }
        guard invoiceCount == 0 else {
            throw NSError(
                domain: "MaestroBooks", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Client has \(invoiceCount) invoice(s) — void them first "
                    + "or leave the client in place"])
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clients WHERE id = ?", arguments: [id])
        }
        audit("client", id, "delete", nil)
    }
}
