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
        if enabled {
            // Demo mode is a sandbox: delete any existing demo database so we
            // always seed a fresh, coherent dataset (and so updated demo data
            // actually appears without manual file cleanup).
            let url = demoURL()
            let path = url.path
            for ext in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path + ext))
            }
        }
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

    /// Wipes every Books table. Only allowed in demo mode — used by DemoData
    /// so updated demo datasets are applied without manual file deletion.
    func resetDemoDatabase() throws {
        guard BooksDatabase.isDemoMode else {
            throw validationError("resetDemoDatabase can only be called in demo mode.")
        }
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer {
                try? db.execute(sql: "DELETE FROM sqlite_sequence WHERE name IN ('clients','suppliers','products','expenses','invoices','bills','journal_entries','accounts','crm_leads','crm_opportunities','crm_activities')")
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let tables = [
                "journal_lines", "journal_entries",
                "bill_line_items", "bills",
                "invoice_reminders", "line_items", "payments", "invoices",
                "crm_activities", "crm_opportunities", "crm_leads",
                "expenses", "products", "suppliers", "clients", "accounts"
            ]
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
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

        // v5: proper bookkeeping foundation — Chart of Accounts, Suppliers,
        // Bills with line items, and Journal Entries for double-entry GL.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id INTEGER PRIMARY KEY,
                    code TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    type TEXT NOT NULL,
                    tax_type TEXT NOT NULL DEFAULT 'NONE',
                    tax_label TEXT NOT NULL DEFAULT 'None',
                    is_bank INTEGER NOT NULL DEFAULT 0,
                    bank_account_number TEXT,
                    opening_balance REAL NOT NULL DEFAULT 0,
                    balance REAL NOT NULL DEFAULT 0,
                    description TEXT,
                    xero_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_accounts_type ON accounts(type)")

            try db.execute(sql: """
                CREATE TABLE suppliers (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    email TEXT,
                    phone TEXT,
                    address_line1 TEXT,
                    address_line2 TEXT,
                    city TEXT,
                    region TEXT,
                    postal_code TEXT,
                    country TEXT,
                    tax_number TEXT,
                    payment_terms TEXT,
                    default_expense_account_code TEXT,
                    notes TEXT,
                    xero_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_suppliers_name ON suppliers(name)")

            try db.execute(sql: """
                CREATE TABLE bills (
                    id INTEGER PRIMARY KEY,
                    number TEXT NOT NULL UNIQUE,
                    supplier_id INTEGER NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
                    reference TEXT,
                    issue_date REAL NOT NULL,
                    due_date REAL,
                    status TEXT NOT NULL DEFAULT 'DRAFT',
                    currency TEXT NOT NULL DEFAULT 'AUD',
                    tax_rate REAL NOT NULL DEFAULT 0.10,
                    tax_label TEXT NOT NULL DEFAULT 'GST',
                    tax_type TEXT NOT NULL DEFAULT 'INPUT',
                    notes TEXT,
                    xero_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_bills_status ON bills(status)")
            try db.execute(sql: "CREATE INDEX idx_bills_supplier ON bills(supplier_id)")

            try db.execute(sql: """
                CREATE TABLE bill_line_items (
                    id INTEGER PRIMARY KEY,
                    bill_id INTEGER NOT NULL REFERENCES bills(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL DEFAULT 0,
                    description TEXT NOT NULL,
                    quantity REAL NOT NULL DEFAULT 1,
                    unit_amount REAL NOT NULL DEFAULT 0,
                    discount REAL NOT NULL DEFAULT 0,
                    account_code TEXT,
                    tax_type TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_bill_line_items_bill ON bill_line_items(bill_id)")

            try db.execute(sql: """
                CREATE TABLE journal_entries (
                    id INTEGER PRIMARY KEY,
                    date REAL NOT NULL,
                    reference TEXT,
                    memo TEXT NOT NULL,
                    currency TEXT NOT NULL DEFAULT 'AUD',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_journal_entries_date ON journal_entries(date)")

            try db.execute(sql: """
                CREATE TABLE journal_lines (
                    id INTEGER PRIMARY KEY,
                    journal_entry_id INTEGER NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
                    account_code TEXT NOT NULL REFERENCES accounts(code) ON DELETE RESTRICT,
                    debit REAL NOT NULL DEFAULT 0,
                    credit REAL NOT NULL DEFAULT 0,
                    description TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_journal_lines_entry ON journal_lines(journal_entry_id)")
            try db.execute(sql: "CREATE INDEX idx_journal_lines_account ON journal_lines(account_code)")

            // Seed a sensible default Chart of Accounts so users can start
            // invoicing, expensing, and importing immediately.
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO accounts (code, name, type, tax_type, tax_label, is_bank, opening_balance, balance, created_at, updated_at) VALUES
                ('120', 'Accounts Receivable', 'Asset', 'NONE', 'None', 0, 0, 0, ?, ?),
                ('200', 'Sales', 'Income', 'OUTPUT', 'GST', 0, 0, 0, ?, ?),
                ('429', 'General Expenses', 'Expense', 'INPUT', 'GST', 0, 0, 0, ?, ?),
                ('500', 'Cost of Goods Sold', 'Expense', 'INPUT', 'GST', 0, 0, 0, ?, ?),
                ('610', 'Office Supplies', 'Expense', 'INPUT', 'GST', 0, 0, 0, ?, ?),
                ('800', 'Bank Account', 'Asset', 'NONE', 'None', 1, 0, 0, ?, ?),
                ('820', 'Credit Card', 'Liability', 'NONE', 'None', 1, 0, 0, ?, ?),
                ('900', 'Owner Equity', 'Equity', 'NONE', 'None', 0, 0, 0, ?, ?)
                """, arguments: [
                    now, now, now, now, now, now, now, now,
                    now, now, now, now, now, now, now, now
                ])
        }

        // v6: invoice reminder automation. Reminders are scheduled when an
        // invoice is sent and cancelled when it is paid/voided.
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
                CREATE TABLE invoice_reminders (
                    id INTEGER PRIMARY KEY,
                    invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    channel TEXT NOT NULL DEFAULT 'EMAIL',
                    scheduled_date REAL NOT NULL,
                    sent_date REAL,
                    subject TEXT NOT NULL,
                    body TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'PENDING',
                    error_message TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_invoice_reminders_invoice ON invoice_reminders(invoice_id)")
            try db.execute(sql: "CREATE INDEX idx_invoice_reminders_scheduled ON invoice_reminders(scheduled_date)")
            try db.execute(sql: "CREATE INDEX idx_invoice_reminders_status ON invoice_reminders(status)")
        }

        // v7: per-client and per-invoice opt-out for p2p blacklist reporting.
        migrator.registerMigration("v7") { db in
            try db.execute(sql: "ALTER TABLE clients ADD COLUMN report_to_blacklist INTEGER NOT NULL DEFAULT 1")
            try db.execute(sql: "ALTER TABLE invoices ADD COLUMN report_to_blacklist INTEGER")
        }

        // v8: lightweight CRM integrated into MaestroBooks (leads, opportunities, activities).
        migrator.registerMigration("v8") { db in
            try db.execute(sql: """
                CREATE TABLE crm_leads (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    company TEXT,
                    email TEXT,
                    phone TEXT,
                    tax_number TEXT,
                    country TEXT,
                    status TEXT NOT NULL DEFAULT 'NEW',
                    source TEXT,
                    estimated_value REAL,
                    currency TEXT NOT NULL,
                    assigned_to TEXT,
                    notes TEXT,
                    converted_client_id INTEGER REFERENCES clients(id) ON DELETE SET NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_crm_leads_status ON crm_leads(status)")
            try db.execute(sql: "CREATE INDEX idx_crm_leads_name ON crm_leads(name)")

            try db.execute(sql: """
                CREATE TABLE crm_opportunities (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    lead_id INTEGER REFERENCES crm_leads(id) ON DELETE SET NULL,
                    client_id INTEGER REFERENCES clients(id) ON DELETE SET NULL,
                    stage TEXT NOT NULL DEFAULT 'LEAD',
                    value REAL,
                    currency TEXT NOT NULL,
                    probability INTEGER NOT NULL DEFAULT 0,
                    expected_close_date REAL,
                    notes TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_crm_opportunities_stage ON crm_opportunities(stage)")
            try db.execute(sql: "CREATE INDEX idx_crm_opportunities_lead ON crm_opportunities(lead_id)")
            try db.execute(sql: "CREATE INDEX idx_crm_opportunities_client ON crm_opportunities(client_id)")

            try db.execute(sql: """
                CREATE TABLE crm_activities (
                    id INTEGER PRIMARY KEY,
                    kind TEXT NOT NULL,
                    contact_kind TEXT NOT NULL,
                    contact_id INTEGER NOT NULL,
                    subject TEXT NOT NULL,
                    notes TEXT,
                    due_date REAL,
                    completed_date REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_crm_activities_contact ON crm_activities(contact_kind, contact_id)")
            try db.execute(sql: "CREATE INDEX idx_crm_activities_due ON crm_activities(due_date)")
        }

        migrator.registerMigration("v9") { db in
            try db.alter(table: "clients") { t in
                t.add(column: "custom_fields", .text)
            }
        }

        // v10: image attachments for products, expenses, suppliers and bills.
        migrator.registerMigration("v10") { db in
            try db.alter(table: "products") { t in
                t.add(column: "image_url", .text)
            }
            try db.alter(table: "expenses") { t in
                t.add(column: "image_url", .text)
            }
            try db.alter(table: "suppliers") { t in
                t.add(column: "image_url", .text)
            }
            try db.alter(table: "bills") { t in
                t.add(column: "image_url", .text)
            }
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
            let customFieldsJSON: String? = client.customFields.flatMap { fields in
                (try? JSONEncoder().encode(fields)).flatMap { String(data: $0, encoding: .utf8) }
            }
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO clients (name, email, phone, po_address_line1, po_address_line2,
                                         po_city, po_region, po_postal_code, po_country, tax_number,
                                         notes, xero_id, report_to_blacklist, custom_fields, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        client.name, client.email, client.phone,
                        client.poAddressLine1, client.poAddressLine2, client.poCity,
                        client.poRegion, client.poPostalCode, client.poCountry,
                        client.taxNumber, client.notes, client.xeroID, client.reportToBlacklist,
                        customFieldsJSON, client.createdAt, client.updatedAt])
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
            reportToBlacklist: nil, createdAt: now, updatedAt: now)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO invoices (number, client_id, issue_date, due_date, status,
                                      currency, tax_rate, tax_label, tax_type, account_code,
                                      notes, pdf_path, xero_id, report_to_blacklist,
                                      created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    invoice.number, invoice.clientID, invoice.issueDate, invoice.dueDate,
                    invoice.statusRaw, invoice.currency, invoice.taxRate, invoice.taxLabel,
                    invoice.taxType, invoice.accountCode, invoice.notes, invoice.pdfPath,
                    invoice.xeroID, invoice.reportToBlacklist, invoice.createdAt, invoice.updatedAt])
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

        // Schedule or cancel automated reminders based on the new status.
        if status == .authorised {
            try scheduleRemindersIfNeeded(invoiceID: invoiceID)
        } else if status == .paid || status == .voided {
            try cancelReminders(for: invoiceID)
        }
    }

    private func scheduleRemindersIfNeeded(invoiceID: Int64) throws {
        guard let invoice = try self.invoice(id: invoiceID),
              let client = try self.client(id: invoice.clientID),
              let dueDate = invoice.dueDate else { return }
        let canReport = client.reportToBlacklist && (invoice.reportToBlacklist ?? true)
        let items = try lineItems(invoiceID: invoiceID)
        let subtotal = items.reduce(0) { $0 + $1.amount }
        let total = subtotal * (1 + invoice.taxRate)
        try scheduleReminders(
            for: invoiceID, dueDate: dueDate, clientName: client.name,
            invoiceNumber: invoice.number, total: total, currency: invoice.currency,
            canReportToBlacklist: canReport)
    }

    private func invoice(id: Int64) throws -> BooksInvoice? {
        try dbQueue.read { db in
            try BooksInvoice.fetchOne(db, id: id)
        }
    }

    private func client(id: Int64) throws -> BooksClient? {
        try dbQueue.read { db in
            try BooksClient.fetchOne(db, id: id)
        }
    }

    func setInvoicePDFPath(_ invoiceID: Int64, path: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE invoices SET pdf_path = ?, updated_at = ? WHERE id = ?",
                arguments: [path, Date().timeIntervalSince1970, invoiceID])
        }
        audit("invoice", invoiceID, "pdf", path)
    }

    func setInvoiceReportToBlacklist(_ invoiceID: Int64, _ value: Bool?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE invoices SET report_to_blacklist = ?, updated_at = ? WHERE id = ?",
                arguments: [value, Date().timeIntervalSince1970, invoiceID])
        }
        audit("invoice", invoiceID, "report_to_blacklist", value.map { $0 ? "true" : "false" })
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
                                          subtotal, notes, image_url, xero_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        expense.supplier, expense.expenseDescription, expense.reference,
                        expense.accountCode, expense.issueDate, expense.statusRaw,
                        expense.currency, expense.taxRate, expense.taxType,
                        expense.subtotal, expense.notes, expense.imageURL, expense.xeroID,
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
                                          tax_type, code, image_url, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        product.name, product.details, product.unitPrice,
                        product.accountCode, product.taxType, product.code,
                        product.imageURL, product.createdAt, product.updatedAt])
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

    // MARK: - Chart of Accounts

    func accounts() throws -> [BooksAccount] {
        try dbQueue.read { db in
            try BooksAccount.order(BooksAccount.Columns.code).fetchAll(db)
        }
    }

    func account(code: String) throws -> BooksAccount? {
        try dbQueue.read { db in
            try BooksAccount.filter(BooksAccount.Columns.code == code).fetchOne(db)
        }
    }

    @discardableResult
    func saveAccount(_ account: inout BooksAccount) throws -> BooksAccount {
        let isNew = account.id == nil
        let now = Date()
        account.updatedAt = now
        if isNew { account.createdAt = now }
        account.code = account.code.trimmingCharacters(in: .whitespaces)
        account.name = account.name.trimmingCharacters(in: .whitespaces)
        guard !account.code.isEmpty else {
            throw validationError("Account code is required.")
        }
        guard !account.name.isEmpty else {
            throw validationError("Account name is required.")
        }
        if let clash = try dbQueue.read({ db in
            try BooksAccount
                .filter(sql: "code = ? AND id != ?", arguments: [account.code, account.id ?? -1])
                .fetchOne(db)
        }) {
            throw validationError("Account code '\(account.code)' is already used by '\(clash.name)'.")
        }
        if isNew {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO accounts (code, name, type, tax_type, tax_label, is_bank,
                                          bank_account_number, opening_balance, balance,
                                          description, xero_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        account.code, account.name, account.type.rawValue,
                        account.taxType, account.taxLabel, account.isBank ? 1 : 0,
                        account.bankAccountNumber, account.openingBalance, account.balance,
                        account.description, account.xeroID,
                        account.createdAt, account.updatedAt])
                account.id = db.lastInsertedRowID
            }
        } else {
            try dbQueue.write { db in try account.update(db) }
        }
        audit("account", account.id ?? 0, isNew ? "create" : "update", "\(account.code) \(account.name)")
        return account
    }

    func deleteAccount(id: Int64) throws {
        // Guard: accounts referenced by journal lines or bill/invoice lines
        // should not be deleted (accounting records are immutable).
        let journalCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal_lines WHERE account_code = (SELECT code FROM accounts WHERE id = ?)", arguments: [id]) ?? 0
        }
        guard journalCount == 0 else {
            throw validationError("Account is used in journal entries — cannot delete.")
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id])
        }
        audit("account", id, "delete", nil)
    }

    // MARK: - Suppliers

    func suppliers() throws -> [BooksSupplier] {
        try dbQueue.read { db in
            try BooksSupplier.order(BooksSupplier.Columns.name).fetchAll(db)
        }
    }

    func supplier(named name: String) throws -> BooksSupplier? {
        try dbQueue.read { db in
            try BooksSupplier.filter(BooksSupplier.Columns.name == name).fetchOne(db)
        }
    }

    @discardableResult
    func saveSupplier(_ supplier: inout BooksSupplier) throws -> BooksSupplier {
        let isNew = supplier.id == nil
        let now = Date()
        supplier.updatedAt = now
        if isNew { supplier.createdAt = now }
        supplier.name = supplier.name.trimmingCharacters(in: .whitespaces)
        guard !supplier.name.isEmpty else {
            throw validationError("Supplier name is required.")
        }
        if let clash = try dbQueue.read({ db in
            try BooksSupplier
                .filter(sql: "name = ? AND id != ?", arguments: [supplier.name, supplier.id ?? -1])
                .fetchOne(db)
        }) {
            throw validationError("A supplier named '\(supplier.name)' already exists (id \(clash.id ?? -1)).")
        }
        if isNew {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO suppliers (name, email, phone, address_line1, address_line2,
                                           city, region, postal_code, country, tax_number,
                                           payment_terms, default_expense_account_code, notes,
                                           image_url, xero_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        supplier.name, supplier.email, supplier.phone,
                        supplier.addressLine1, supplier.addressLine2, supplier.city,
                        supplier.region, supplier.postalCode, supplier.country,
                        supplier.taxNumber, supplier.paymentTerms,
                        supplier.defaultExpenseAccountCode, supplier.notes, supplier.imageURL,
                        supplier.xeroID, supplier.createdAt, supplier.updatedAt])
                supplier.id = db.lastInsertedRowID
            }
        } else {
            try dbQueue.write { db in try supplier.update(db) }
        }
        audit("supplier", supplier.id ?? 0, isNew ? "create" : "update", supplier.name)
        return supplier
    }

    func deleteSupplier(id: Int64) throws {
        let billCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bills WHERE supplier_id = ?", arguments: [id]) ?? 0
        }
        guard billCount == 0 else {
            throw validationError("Supplier has \(billCount) bill(s) — void them first or leave the supplier in place.")
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM suppliers WHERE id = ?", arguments: [id])
        }
        audit("supplier", id, "delete", nil)
    }

    // MARK: - Bills

    func bills(status: BooksBillStatus? = nil) throws -> [BooksBill] {
        try dbQueue.read { db in
            var request = BooksBill.all()
            if let status {
                request = request.filter(BooksBill.Columns.statusRaw == status.rawValue)
            }
            return try request.order(BooksBill.Columns.issueDate.desc).fetchAll(db)
        }
    }

    func bill(number: String) throws -> BooksBill? {
        try dbQueue.read { db in
            try BooksBill.filter(sql: "number = ?", arguments: [number]).fetchOne(db)
        }
    }

    func billLineItems(billID: Int64) throws -> [BooksBillLineItem] {
        try dbQueue.read { db in
            try BooksBillLineItem
                .filter(sql: "bill_id = ?", arguments: [billID])
                .order(sql: "position")
                .fetchAll(db)
        }
    }

    /// Next sequential bill number: BILL-<year>-NNNN.
    func nextBillNumber() throws -> String {
        try dbQueue.write { db in
            let raw = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'next_bill_number'") ?? "1"
            let next = Int(raw) ?? 1
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('next_bill_number', ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: ["\(next + 1)"])
            let year = Calendar.current.component(.year, from: Date())
            return String(format: "BILL-%d-%04d", year, next)
        }
    }

    @discardableResult
    func createBill(
        supplierID: Int64,
        items: [(description: String, quantity: Double, unitAmount: Double, discount: Double)],
        dueDate: Date?, notes: String?, accountCode: String,
        currency: String = "AUD", taxRate: Double = 0.10,
        taxType: String = "INPUT", taxLabel: String = "GST"
    ) throws -> BooksBill {
        let now = Date()
        let number = try nextBillNumber()
        var bill = BooksBill(
            id: nil, number: number, supplierID: supplierID,
            reference: nil, issueDate: now, dueDate: dueDate,
            statusRaw: BooksBillStatus.draft.rawValue,
            currency: currency, taxRate: taxRate, taxLabel: taxLabel, taxType: taxType,
            notes: notes, xeroID: nil,
            createdAt: now, updatedAt: now)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO bills (number, supplier_id, reference, issue_date, due_date, status,
                                   currency, tax_rate, tax_label, tax_type, notes, image_url, xero_id,
                                   created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    bill.number, bill.supplierID, bill.reference, bill.issueDate, bill.dueDate,
                    bill.statusRaw, bill.currency, bill.taxRate, bill.taxLabel,
                    bill.taxType, bill.notes, bill.imageURL, bill.xeroID,
                    bill.createdAt, bill.updatedAt])
            bill.id = db.lastInsertedRowID
            guard let billID = bill.id else {
                throw NSError(domain: "MaestroBooks", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Bill insert returned no id"])
            }
            for (index, item) in items.enumerated() {
                try db.execute(sql: """
                    INSERT INTO bill_line_items (bill_id, position, description, quantity,
                                                 unit_amount, discount, account_code, tax_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        billID, index, item.description, item.quantity,
                        item.unitAmount, item.discount, accountCode, taxType])
            }
        }
        audit("bill", bill.id ?? 0, "create", bill.number)
        return bill
    }

    func setBillStatus(_ billID: Int64, _ status: BooksBillStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE bills SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Date().timeIntervalSince1970, billID])
        }
        audit("bill", billID, "status", status.rawValue)
    }

    func deleteBill(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM bills WHERE id = ?", arguments: [id])
        }
        audit("bill", id, "delete", nil)
    }

    // MARK: - Journal entries

    func journalEntries() throws -> [BooksJournalEntry] {
        try dbQueue.read { db in
            try BooksJournalEntry.order(sql: "date DESC").fetchAll(db)
        }
    }

    func journalLines(entryID: Int64) throws -> [BooksJournalLine] {
        try dbQueue.read { db in
            try BooksJournalLine.filter(sql: "journal_entry_id = ?", arguments: [entryID])
                .fetchAll(db)
        }
    }

    /// Saves a journal entry with its lines. Validates that total debits == total credits.
    @discardableResult
    func saveJournalEntry(
        _ entry: inout BooksJournalEntry,
        lines: [BooksJournalLine]
    ) throws -> BooksJournalEntry {
        let totalDebits = lines.reduce(0) { $0 + $1.debit }
        let totalCredits = lines.reduce(0) { $0 + $1.credit }
        guard abs(totalDebits - totalCredits) < 0.005 else {
            throw validationError("Journal entry is out of balance: debits \(totalDebits), credits \(totalCredits).")
        }
        guard lines.count >= 2 else {
            throw validationError("A journal entry needs at least two lines.")
        }

        let isNew = entry.id == nil
        let now = Date()
        entry.updatedAt = now
        if isNew { entry.createdAt = now }

        try dbQueue.write { db in
            if isNew {
                try db.execute(sql: """
                    INSERT INTO journal_entries (date, reference, memo, currency, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        entry.date, entry.reference, entry.memo, entry.currency,
                        entry.createdAt, entry.updatedAt])
                entry.id = db.lastInsertedRowID
            } else {
                try entry.update(db)
                try db.execute(sql: "DELETE FROM journal_lines WHERE journal_entry_id = ?",
                               arguments: [entry.id!])
            }
            guard let entryID = entry.id else {
                throw NSError(domain: "MaestroBooks", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Journal entry insert returned no id"])
            }
            for line in lines {
                try db.execute(sql: """
                    INSERT INTO journal_lines (journal_entry_id, account_code, debit, credit, description)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [
                        entryID, line.accountCode, line.debit, line.credit, line.description])
            }
        }
        audit("journal_entry", entry.id ?? 0, isNew ? "create" : "update", entry.reference)
        return entry
    }

    func deleteJournalEntry(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM journal_entries WHERE id = ?", arguments: [id])
        }
        audit("journal_entry", id, "delete", nil)
    }

    // MARK: - Invoice reminders

    func reminders(forInvoiceID invoiceID: Int64) throws -> [BooksInvoiceReminder] {
        try dbQueue.read { db in
            try BooksInvoiceReminder
                .filter(sql: "invoice_id = ?", arguments: [invoiceID])
                .order(sql: "scheduled_date")
                .fetchAll(db)
        }
    }

    func pendingReminders(before date: Date = Date()) throws -> [BooksInvoiceReminder] {
        try dbQueue.read { db in
            try BooksInvoiceReminder
                .filter(sql: "status = 'PENDING' AND scheduled_date <= ?", arguments: [date.timeIntervalSince1970])
                .order(sql: "scheduled_date")
                .fetchAll(db)
        }
    }

    /// Schedules the standard escalation sequence for an invoice.
    func scheduleReminders(
        for invoiceID: Int64,
        dueDate: Date,
        clientName: String,
        invoiceNumber: String,
        total: Double,
        currency: String,
        canReportToBlacklist: Bool = true
    ) throws {
        // Clear any existing pending reminders first.
        try cancelReminders(for: invoiceID)

        let now = Date()
        var kinds: [BooksInvoiceReminder.Kind] = [.friendly, .overdue7, .overdue14, .overdue30, .overdue45, .finalDemand]
        if canReportToBlacklist {
            kinds.append(.blacklistNotice)
        }
        let calendar = Calendar.current

        try dbQueue.write { db in
            for kind in kinds {
                let scheduled = calendar.date(byAdding: .day, value: kind.daysAfterDue, to: dueDate) ?? dueDate
                guard scheduled > now || kind == .friendly else { continue }
                let subject = kind.defaultSubject
                let body = reminderBody(
                    kind: kind, clientName: clientName, invoiceNumber: invoiceNumber,
                    total: total, currency: currency, dueDate: dueDate)
                try db.execute(sql: """
                    INSERT INTO invoice_reminders (invoice_id, kind, channel, scheduled_date,
                                                   subject, body, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        invoiceID, kind.rawValue, BooksInvoiceReminder.Channel.email.rawValue,
                        scheduled.timeIntervalSince1970, subject, body,
                        BooksInvoiceReminder.Status.pending.rawValue,
                        now.timeIntervalSince1970, now.timeIntervalSince1970])
            }
        }
    }

    /// Removes pending reminders for an invoice (e.g., when paid or voided).
    func cancelReminders(for invoiceID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM invoice_reminders WHERE invoice_id = ? AND status = 'PENDING'",
                arguments: [invoiceID])
        }
    }

    func markReminderSent(id: Int64, error: String? = nil) throws {
        let status = error == nil ? BooksInvoiceReminder.Status.sent : .failed
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE invoice_reminders
                    SET status = ?, sent_date = ?, error_message = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    status.rawValue,
                    error == nil ? Date().timeIntervalSince1970 : nil,
                    error,
                    Date().timeIntervalSince1970,
                    id])
        }
    }

    private func reminderBody(
        kind: BooksInvoiceReminder.Kind,
        clientName: String,
        invoiceNumber: String,
        total: Double,
        currency: String,
        dueDate: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let totalString = String(format: "%.2f", total)
        switch kind {
        case .friendly:
            return "Hi \(clientName),\n\nJust a friendly reminder that invoice \(invoiceNumber) for \(currency) \(totalString) was due on \(formatter.string(from: dueDate)).\n\nIf payment has already been arranged, please disregard this message.\n\nThank you."
        case .overdue7, .overdue14, .overdue30, .overdue45:
            return "Hi \(clientName),\n\nInvoice \(invoiceNumber) for \(currency) \(totalString) is now \(kind.daysAfterDue) days overdue (due \(formatter.string(from: dueDate))).\n\nPlease arrange payment at your earliest convenience.\n\nThank you."
        case .finalDemand:
            return "Hi \(clientName),\n\nFINAL DEMAND: invoice \(invoiceNumber) for \(currency) \(totalString) remains unpaid and is now 60 days overdue.\n\nUnless payment is received within 7 days, this debt may be registered with the SwiftMaestro p2p unpaid-invoice network.\n\nThank you."
        case .blacklistNotice:
            return "Hi \(clientName),\n\nInvoice \(invoiceNumber) for \(currency) \(totalString) is over 60 days overdue. This notice confirms the debt is eligible for registration with the SwiftMaestro p2p unpaid-invoice network.\n\nImmediate payment is required to avoid registration.\n\nThank you."
        }
    }

    // MARK: - CRM Leads

    func crmLeads(status: BooksCRMLead.LeadStatus? = nil) throws -> [BooksCRMLead] {
        try dbQueue.read { db in
            var request = BooksCRMLead.all()
            if let status {
                request = request.filter(BooksCRMLead.Columns.status == status.rawValue)
            }
            return try request.order(BooksCRMLead.Columns.name).fetchAll(db)
        }
    }

    func crmLead(id: Int64) throws -> BooksCRMLead? {
        try dbQueue.read { db in try BooksCRMLead.fetchOne(db, id: id) }
    }

    @discardableResult
    func saveCRMLead(_ lead: inout BooksCRMLead) throws -> BooksCRMLead {
        let isNew = lead.id == nil
        let now = Date()
        lead.updatedAt = now
        if isNew { lead.createdAt = now }
        lead.name = lead.name.trimmingCharacters(in: .whitespaces)
        guard !lead.name.isEmpty else { throw validationError("Lead name is required.") }
        try dbQueue.write { db in
            if isNew {
                try lead.insert(db)
            } else {
                try lead.update(db)
            }
        }
        audit("crm_lead", lead.id ?? 0, isNew ? "create" : "update", lead.name)
        return lead
    }

    func deleteCRMLead(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM crm_activities WHERE contact_kind = 'lead' AND contact_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM crm_opportunities WHERE lead_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM crm_leads WHERE id = ?", arguments: [id])
        }
        audit("crm_lead", id, "delete", nil)
    }

    /// Converts a lead into a BooksClient and links the lead to it.
    @discardableResult
    func convertCRMLeadToClient(_ leadID: Int64) throws -> BooksClient {
        guard var lead = try crmLead(id: leadID) else {
            throw validationError("Lead not found.")
        }
        var client = BooksClient(
            id: nil, name: lead.company ?? lead.name, email: lead.email, phone: lead.phone,
            poAddressLine1: nil, poAddressLine2: nil, poCity: nil, poRegion: nil,
            poPostalCode: nil, poCountry: lead.country, taxNumber: lead.taxNumber,
            notes: lead.notes, xeroID: nil, reportToBlacklist: true,
            createdAt: Date(), updatedAt: Date())
        let saved = try saveClient(&client)
        lead.status = .converted
        lead.convertedClientID = saved.id
        var mutable = lead
        _ = try saveCRMLead(&mutable)
        audit("crm_lead", leadID, "convert", saved.name)
        return saved
    }

    // MARK: - CRM Opportunities

    func crmOpportunities(stage: BooksCRMOpportunity.OpportunityStage? = nil) throws -> [BooksCRMOpportunity] {
        try dbQueue.read { db in
            var request = BooksCRMOpportunity.all()
            if let stage {
                request = request.filter(BooksCRMOpportunity.Columns.stage == stage.rawValue)
            }
            return try request.order(BooksCRMOpportunity.Columns.expectedCloseDate).fetchAll(db)
        }
    }

    func crmOpportunity(id: Int64) throws -> BooksCRMOpportunity? {
        try dbQueue.read { db in try BooksCRMOpportunity.fetchOne(db, id: id) }
    }

    @discardableResult
    func saveCRMOpportunity(_ opp: inout BooksCRMOpportunity) throws -> BooksCRMOpportunity {
        let isNew = opp.id == nil
        let now = Date()
        opp.updatedAt = now
        if isNew { opp.createdAt = now }
        opp.title = opp.title.trimmingCharacters(in: .whitespaces)
        guard !opp.title.isEmpty else { throw validationError("Opportunity title is required.") }
        guard opp.leadID != nil || opp.clientID != nil else {
            throw validationError("Opportunity must be linked to a lead or a client.")
        }
        try dbQueue.write { db in
            if isNew {
                try opp.insert(db)
            } else {
                try opp.update(db)
            }
        }
        audit("crm_opportunity", opp.id ?? 0, isNew ? "create" : "update", opp.title)
        return opp
    }

    func deleteCRMOpportunity(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM crm_activities WHERE contact_kind = 'opportunity' AND contact_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM crm_opportunities WHERE id = ?", arguments: [id])
        }
        audit("crm_opportunity", id, "delete", nil)
    }

    // MARK: - CRM Activities

    func crmActivities(contactKind: String, contactID: Int64) throws -> [BooksCRMActivity] {
        try dbQueue.read { db in
            try BooksCRMActivity
                .filter(sql: "contact_kind = ? AND contact_id = ?", arguments: [contactKind, contactID])
                .order(sql: "due_date DESC")
                .fetchAll(db)
        }
    }

    func crmActivities() throws -> [BooksCRMActivity] {
        try dbQueue.read { db in
            try BooksCRMActivity
                .order(sql: "due_date DESC")
                .fetchAll(db)
        }
    }

    @discardableResult
    func saveCRMActivity(_ activity: inout BooksCRMActivity) throws -> BooksCRMActivity {
        let isNew = activity.id == nil
        let now = Date()
        activity.updatedAt = now
        if isNew { activity.createdAt = now }
        activity.subject = activity.subject.trimmingCharacters(in: .whitespaces)
        guard !activity.subject.isEmpty else { throw validationError("Activity subject is required.") }
        try dbQueue.write { db in
            if isNew {
                try activity.insert(db)
            } else {
                try activity.update(db)
            }
        }
        audit("crm_activity", activity.id ?? 0, isNew ? "create" : "update", activity.subject)
        return activity
    }

    func deleteCRMActivity(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM crm_activities WHERE id = ?", arguments: [id])
        }
        audit("crm_activity", id, "delete", nil)
    }
}
