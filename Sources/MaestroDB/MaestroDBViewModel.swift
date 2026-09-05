import Foundation
import SwiftUI

// MARK: - MaestroDB View Model

@Observable
@MainActor
final class MaestroDBViewModel {

    /// Resolved per use — never cache: demo-mode toggling swaps the shared
    /// instance, and a cached reference keeps talking to the old database.
    private var database: MaestroDBDatabase { MaestroDBDatabase.shared }

    // MARK: Navigation state

    private(set) var bases: [MaestroBase] = []
    var selectedBaseID: String? {
        didSet {
            UserDefaults.standard.set(selectedBaseID, forKey: "maestrodb.selectedBaseID")
            Task { await loadTables() }
        }
    }
    private(set) var tables: [DBTable] = []
    var selectedTableID: String? {
        didSet {
            UserDefaults.standard.set(selectedTableID, forKey: "maestrodb.selectedTableID")
            Task { await loadTableContent() }
        }
    }

    // MARK: Current table content

    private(set) var fields: [DBField] = []
    private(set) var rows: [DBRow] = []

    /// Resolution contexts for the current table's relation fields, keyed by
    /// FIELD id. Loaded alongside the table content (and reloaded by the
    /// external-change observer) so relation cells can display and pick by
    /// title instead of raw row ids.
    private(set) var relationData: [String: MaestroDBRelations.Context] = [:]

    /// Text search across all cell values.
    var searchQuery = "" {
        didSet { Task { await loadRows() } }
    }

    /// Sort: field id + ascending. Clicking a header cycles asc → desc → none.
    var sort: (fieldID: String, ascending: Bool)? {
        didSet { Task { await loadRows() } }
    }

    /// View mode: grid or the shared Kanban board.
    enum ViewMode: String { case grid, board }
    var viewMode: ViewMode = .grid

    var errorMessage: String?

    /// Transient success notice (CSV import/export results), shown green in
    /// the header alongside the red error text.
    var noticeMessage: String?

    var isDemoMode: Bool { MaestroDBDatabase.isDemoMode }

    // MARK: - Load

    func loadAll() async {
        do {
            bases = try database.bases()
            if selectedBaseID == nil {
                selectedBaseID = UserDefaults.standard.string(forKey: "maestrodb.selectedBaseID")
                    ?? bases.first?.id
            }
            if let selectedBaseID, bases.contains(where: { $0.id == selectedBaseID }) {
                await loadTables()
            } else {
                selectedBaseID = bases.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not load bases: \(error.localizedDescription)"
        }
    }

    func loadTables() async {
        guard let baseID = selectedBaseID else { tables = []; return }
        do {
            tables = try database.tables(baseID: baseID)
            if let selectedTableID, tables.contains(where: { $0.id == selectedTableID }) {
                await loadTableContent()
            } else {
                selectedTableID = tables.first?.id
            }
            if tables.isEmpty {
                fields = []; rows = []
            }
        } catch {
            errorMessage = "Could not load tables: \(error.localizedDescription)"
        }
    }

    func loadTableContent() async {
        guard let tableID = selectedTableID else { fields = []; rows = []; relationData = [:]; return }
        do {
            fields = try database.fields(tableID: tableID)
            relationData = MaestroDBRelations.contexts(forFields: fields, database: database)
            await loadRows()
            errorMessage = nil
        } catch {
            errorMessage = "Could not load table: \(error.localizedDescription)"
        }
    }

    func loadRows() async {
        guard let tableID = selectedTableID else { rows = []; return }
        do {
            var result = try database.searchRows(tableID: tableID, query: searchQuery)
            if let sort {
                result.sort { a, b in
                    let av = a.value(for: sort.fieldID)
                    let bv = b.value(for: sort.fieldID)
                    // Numbers compare numerically; everything else lexically.
                    if let an = Double(av), let bn = Double(bv), av != bv {
                        return sort.ascending ? an < bn : an > bn
                    }
                    return sort.ascending
                        ? av.localizedStandardCompare(bv) == .orderedAscending
                        : av.localizedStandardCompare(bv) == .orderedDescending
                }
            }
            rows = result
        } catch {
            errorMessage = "Could not load rows: \(error.localizedDescription)"
        }
    }

    /// Debounce task for external-change reloads: a bulk mutation (CSV
    /// import, kanban drag burst) posts many notifications — collapse them
    /// into one reload 300ms after the last one.
    private var externalReloadTask: Task<Void, Never>?

    /// Called when the database changed outside this view model (agent db_*
    /// tools, the kanban write-through bridge, another panel). Reloads the
    /// whole navigation state after a short debounce; selection is preserved
    /// (loadAll only re-picks when the saved selection no longer exists).
    func scheduleExternalReload() {
        externalReloadTask?.cancel()
        externalReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.loadAll()
        }
    }

    func toggleDemoMode() {
        // Clear persisted selection too — the saved IDs belong to the OTHER
        // database, and restoring them fires the "selection has no tag" picker
        // warning on the first frame after the swap.
        UserDefaults.standard.removeObject(forKey: "maestrodb.selectedBaseID")
        UserDefaults.standard.removeObject(forKey: "maestrodb.selectedTableID")
        MaestroDBDatabase.setDemoMode(!MaestroDBDatabase.isDemoMode)
        selectedBaseID = nil
        selectedTableID = nil
        Task { await loadAll() }
    }

    // MARK: - Header sort cycling

    func cycleSort(on fieldID: String) {
        guard let current = sort, current.fieldID == fieldID else {
            sort = (fieldID, true)
            return
        }
        sort = current.ascending ? (fieldID, false) : nil
    }

    // MARK: - Bases

    /// Field/row counts used in delete-confirmation text (sync reads — the
    /// database layer is synchronous; the async wrappers are for UI flow).
    func summary(forTableID tableID: String) -> (fields: Int, rows: Int) {
        let fields = (try? database.fields(tableID: tableID).count) ?? 0
        let rows = (try? database.rows(tableID: tableID).count) ?? 0
        return (fields, rows)
    }

    func summary(forBaseID baseID: String) -> (tables: Int, rows: Int) {
        guard let tables = try? database.tables(baseID: baseID) else { return (0, 0) }
        var rows = 0
        for table in tables {
            rows += (try? database.rows(tableID: table.id).count) ?? 0
        }
        return (tables.count, rows)
    }

    /// Delete any base by id (clears the selection if it was selected).
    func deleteBase(id baseID: String) async {
        do {
            try database.deleteBase(baseID)
            if selectedBaseID == baseID {
                selectedBaseID = nil
                selectedTableID = nil
            }
            await loadAll()
        } catch { errorMessage = "Could not delete base: \(error.localizedDescription)" }
    }

    /// Rename any base by id.
    func renameBase(id baseID: String, to name: String) async {
        do { try database.renameBase(baseID, name: name); await loadAll() }
        catch { errorMessage = "Could not rename base: \(error.localizedDescription)" }
    }

    /// Delete any table by id (clears the selection if it was selected).
    func deleteTable(id tableID: String) async {
        do {
            try database.deleteTable(tableID)
            if selectedTableID == tableID { selectedTableID = nil }
            await loadTables()
        } catch { errorMessage = "Could not delete table: \(error.localizedDescription)" }
    }

    /// Rename any table by id.
    func renameTable(id tableID: String, to name: String) async {
        do { try database.renameTable(tableID, name: name); await loadTables() }
        catch { errorMessage = "Could not rename table: \(error.localizedDescription)" }
    }

    func createBase(named name: String) async {
        do {
            let base = try database.createBase(name: name)
            await loadAll()
            selectedBaseID = base.id
        } catch { errorMessage = "Could not create base: \(error.localizedDescription)" }
    }

    /// Creates or refreshes a special "Accounting" base that mirrors the
    /// current MaestroBooks data. Tables are overwritten on each sync.
    func syncAccountingBase() async {
        do {
            let books = BooksDatabase.shared
            let base = try database.bases().first(where: { $0.name == "Accounting" })
                ?? database.createBase(name: "Accounting", icon: "dollarsign.circle")

            let tableDefs: [(name: String, fields: [(name: String, type: DBFieldType)])] = [
                ("Clients", [
                    ("Name", .text), ("Email", .email), ("Phone", .phone),
                    ("Address", .longText), ("Tax Number", .text), ("Xero ID", .text)
                ]),
                ("Suppliers", [
                    ("Name", .text), ("Email", .email), ("Phone", .phone),
                    ("Address", .longText), ("Tax Number", .text), ("Default Account", .text)
                ]),
                ("Accounts", [
                    ("Code", .text), ("Name", .text), ("Type", .select),
                    ("Tax Type", .text), ("Is Bank", .checkbox), ("Balance", .number)
                ]),
                ("Invoices", [
                    ("Number", .text), ("Client", .text), ("Issue Date", .date),
                    ("Due Date", .date), ("Status", .select), ("Total", .number)
                ]),
                ("Bills", [
                    ("Number", .text), ("Supplier", .text), ("Issue Date", .date),
                    ("Due Date", .date), ("Status", .select), ("Total", .number)
                ]),
                ("Journal Entries", [
                    ("Date", .date), ("Reference", .text), ("Memo", .longText),
                    ("Account", .text), ("Debit", .number), ("Credit", .number)
                ]),
            ]

            var tableIDs: [String: String] = [:]
            var tableFields: [String: [DBField]] = [:]

            // Create or reuse tables and fields.
            let existingTables = try database.tables(baseID: base.id)
            for def in tableDefs {
                let table: DBTable
                if let existing = existingTables.first(where: { $0.name == def.name }) {
                    table = existing
                } else {
                    table = try database.createTable(baseID: base.id, name: def.name)
                }
                tableIDs[def.name] = table.id

                let existingFields = try database.fields(tableID: table.id)
                var fields: [DBField] = []
                for fieldDef in def.fields {
                    let field: DBField
                    if let existing = existingFields.first(where: { $0.name == fieldDef.name }) {
                        field = existing
                    } else {
                        field = try database.addField(
                            tableID: table.id, name: fieldDef.name, type: fieldDef.type,
                            options: fieldDef.type == .select ? [] : [], config: [:])
                    }
                    fields.append(field)
                }
                if def.name == "Accounts" || def.name == "Invoices" || def.name == "Bills" {
                    // Add select options after fields exist.
                    if let typeField = fields.first(where: { $0.name == "Type" }), typeField.type == .select {
                        let options: [String]
                        switch def.name {
                        case "Accounts": options = ["Asset", "Liability", "Equity", "Income", "Expense"]
                        case "Invoices", "Bills": options = ["Draft", "Awaiting Payment", "Paid", "Voided"]
                        default: options = []
                        }
                        for option in options where !typeField.options.contains(option) {
                            try database.addFieldOption(typeField.id, option: option)
                        }
                    }
                    if let statusField = fields.first(where: { $0.name == "Status" }), statusField.type == .select {
                        let options = def.name == "Invoices"
                            ? ["Draft", "Sent", "Paid", "Voided"]
                            : ["Draft", "Awaiting Payment", "Paid", "Voided"]
                        for option in options where !statusField.options.contains(option) {
                            try database.addFieldOption(statusField.id, option: option)
                        }
                    }
                }
                tableFields[table.id] = fields
                try database.clearTable(table.id)
            }

            func fieldID(_ tableName: String, _ fieldName: String) -> String? {
                guard let tableID = tableIDs[tableName] else { return nil }
                return tableFields[tableID]?.first(where: { $0.name == fieldName })?.id
            }

            func set(_ tableName: String, _ values: [String: String]) throws {
                guard let tableID = tableIDs[tableName] else { return }
                _ = try database.addRow(tableID: tableID, values: values)
            }

            // Sync clients.
            for client in try books.clients() {
                var values: [String: String] = [:]
                values[fieldID("Clients", "Name") ?? ""] = client.name
                values[fieldID("Clients", "Email") ?? ""] = client.email ?? ""
                values[fieldID("Clients", "Phone") ?? ""] = client.phone ?? ""
                values[fieldID("Clients", "Address") ?? ""] = client.addressBlock
                values[fieldID("Clients", "Tax Number") ?? ""] = client.taxNumber ?? ""
                values[fieldID("Clients", "Xero ID") ?? ""] = client.xeroID ?? ""
                try set("Clients", values)
            }

            // Sync suppliers.
            for supplier in try books.suppliers() {
                var values: [String: String] = [:]
                values[fieldID("Suppliers", "Name") ?? ""] = supplier.name
                values[fieldID("Suppliers", "Email") ?? ""] = supplier.email ?? ""
                values[fieldID("Suppliers", "Phone") ?? ""] = supplier.phone ?? ""
                values[fieldID("Suppliers", "Address") ?? ""] = supplier.addressBlock
                values[fieldID("Suppliers", "Tax Number") ?? ""] = supplier.taxNumber ?? ""
                values[fieldID("Suppliers", "Default Account") ?? ""] = supplier.defaultExpenseAccountCode ?? ""
                try set("Suppliers", values)
            }

            // Sync accounts.
            for account in try books.accounts() {
                var values: [String: String] = [:]
                values[fieldID("Accounts", "Code") ?? ""] = account.code
                values[fieldID("Accounts", "Name") ?? ""] = account.name
                values[fieldID("Accounts", "Type") ?? ""] = account.type.rawValue
                values[fieldID("Accounts", "Tax Type") ?? ""] = account.taxType
                values[fieldID("Accounts", "Is Bank") ?? ""] = account.isBank ? "1" : ""
                values[fieldID("Accounts", "Balance") ?? ""] = String(account.balance + account.openingBalance)
                try set("Accounts", values)
            }

            // Sync invoices.
            for invoice in try books.invoices() {
                let client = try books.clients().first(where: { $0.id == invoice.clientID })?.name ?? ""
                let total = invoice.total(invoices: try books.invoices(), database: books)
                var values: [String: String] = [:]
                values[fieldID("Invoices", "Number") ?? ""] = invoice.number
                values[fieldID("Invoices", "Client") ?? ""] = client
                values[fieldID("Invoices", "Issue Date") ?? ""] = String(invoice.issueDate.timeIntervalSince1970)
                values[fieldID("Invoices", "Due Date") ?? ""] = invoice.dueDate.map { String($0.timeIntervalSince1970) } ?? ""
                values[fieldID("Invoices", "Status") ?? ""] = invoice.status.displayName
                values[fieldID("Invoices", "Total") ?? ""] = String(total)
                try set("Invoices", values)
            }

            // Sync bills.
            for bill in try books.bills() {
                let supplier = try books.suppliers().first(where: { $0.id == bill.supplierID })?.name ?? ""
                let total = bill.total(database: books)
                var values: [String: String] = [:]
                values[fieldID("Bills", "Number") ?? ""] = bill.number
                values[fieldID("Bills", "Supplier") ?? ""] = supplier
                values[fieldID("Bills", "Issue Date") ?? ""] = String(bill.issueDate.timeIntervalSince1970)
                values[fieldID("Bills", "Due Date") ?? ""] = bill.dueDate.map { String($0.timeIntervalSince1970) } ?? ""
                values[fieldID("Bills", "Status") ?? ""] = bill.status.displayName
                values[fieldID("Bills", "Total") ?? ""] = String(total)
                try set("Bills", values)
            }

            // Sync journal entries.
            for entry in try books.journalEntries() {
                let lines = try books.journalLines(entryID: entry.id ?? 0)
                for line in lines {
                    var values: [String: String] = [:]
                    values[fieldID("Journal Entries", "Date") ?? ""] = String(entry.date.timeIntervalSince1970)
                    values[fieldID("Journal Entries", "Reference") ?? ""] = entry.reference ?? ""
                    values[fieldID("Journal Entries", "Memo") ?? ""] = entry.memo
                    values[fieldID("Journal Entries", "Account") ?? ""] = line.accountCode
                    values[fieldID("Journal Entries", "Debit") ?? ""] = String(line.debit)
                    values[fieldID("Journal Entries", "Credit") ?? ""] = String(line.credit)
                    try set("Journal Entries", values)
                }
            }

            await loadAll()
            selectedBaseID = base.id
            noticeMessage = "Accounting base synced from MaestroBooks"
        } catch {
            errorMessage = "Could not sync Accounting base: \(error.localizedDescription)"
        }
    }

    /// Create or reuse an "Imported Assets" base and "Assets" table, then add a
    /// row for the file sent from another panel (e.g. the client asset gallery).
    func importAssetPath(_ path: String) async {
        do {
            let base = try database.bases().first(where: { $0.name == "Imported Assets" })
                ?? database.createBase(name: "Imported Assets", icon: "tray.and.arrow.down")
            let existingTables = try database.tables(baseID: base.id)
            let table: DBTable
            if let existing = existingTables.first(where: { $0.name == "Assets" }) {
                table = existing
            } else {
                table = try database.createTable(baseID: base.id, name: "Assets")
            }
            let fields = try database.fields(tableID: table.id)
            let nameField: DBField
            if let existing = fields.first(where: { $0.name == "Name" }) {
                nameField = existing
            } else {
                nameField = try database.addField(tableID: table.id, name: "Name", type: .text, options: [], config: [:])
            }
            let pathField: DBField
            if let existing = fields.first(where: { $0.name == "File Path" }) {
                pathField = existing
            } else {
                pathField = try database.addField(tableID: table.id, name: "File Path", type: .attachment, options: [], config: [:])
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            _ = try database.addRow(tableID: table.id, values: [nameField.id: name, pathField.id: path])
            await loadAll()
            selectedBaseID = base.id
            selectedTableID = table.id
            noticeMessage = "Imported asset '\(name)'."
        } catch {
            errorMessage = "Could not import asset: \(error.localizedDescription)"
        }
    }

    func renameSelectedBase(to name: String) async {
        guard let baseID = selectedBaseID else { return }
        do { try database.renameBase(baseID, name: name); await loadAll() }
        catch { errorMessage = "Could not rename base: \(error.localizedDescription)" }
    }

    func deleteSelectedBase() async {
        guard let baseID = selectedBaseID else { return }
        do {
            try database.deleteBase(baseID)
            selectedBaseID = nil
            await loadAll()
        } catch { errorMessage = "Could not delete base: \(error.localizedDescription)" }
    }

    // MARK: - Tables

    func createTable(named name: String) async {
        guard let baseID = selectedBaseID else { return }
        do {
            let table = try database.createTable(baseID: baseID, name: name)
            await loadTables()
            selectedTableID = table.id
        } catch { errorMessage = "Could not create table: \(error.localizedDescription)" }
    }

    func renameSelectedTable(to name: String) async {
        guard let tableID = selectedTableID else { return }
        do { try database.renameTable(tableID, name: name); await loadTables() }
        catch { errorMessage = "Could not rename table: \(error.localizedDescription)" }
    }

    func deleteSelectedTable() async {
        guard let tableID = selectedTableID else { return }
        do {
            try database.deleteTable(tableID)
            selectedTableID = nil
            await loadTables()
        } catch { errorMessage = "Could not delete table: \(error.localizedDescription)" }
    }

    // MARK: - Fields

    func addField(named name: String, type: DBFieldType, options: [String] = [],
                  config: [String: String] = [:]) async {
        guard let tableID = selectedTableID else { return }
        do {
            _ = try database.addField(tableID: tableID, name: name, type: type,
                                      options: options, config: config)
            await loadTableContent()
        } catch { errorMessage = "Could not add field: \(error.localizedDescription)" }
    }

    func updateField(_ field: DBField) async {
        do { try database.updateField(field); await loadTableContent() }
        catch { errorMessage = "Could not update field: \(error.localizedDescription)" }
    }

    func deleteField(_ fieldID: String) async {
        do { try database.deleteField(fieldID); await loadTableContent() }
        catch { errorMessage = "Could not delete field: \(error.localizedDescription)" }
    }

    func addFieldOption(_ fieldID: String, option: String) async {
        do { try database.addFieldOption(fieldID, option: option); await loadTableContent() }
        catch { errorMessage = "Could not add option: \(error.localizedDescription)" }
    }

    // MARK: - Rows & cells

    func addRow() async {
        guard let tableID = selectedTableID else { return }
        do {
            _ = try database.addRow(tableID: tableID)
            await loadRows()
        } catch { errorMessage = "Could not add row: \(error.localizedDescription)" }
    }

    func deleteRow(_ rowID: String) async {
        do { try database.deleteRow(rowID); await loadRows() }
        catch { errorMessage = "Could not delete row: \(error.localizedDescription)" }
    }

    func setCell(rowID: String, fieldID: String, value: String) {
        // Write-through + optimistic local update so grids stay snappy.
        if let index = rows.firstIndex(where: { $0.id == rowID }) {
            var row = rows[index]
            if value.isEmpty { row.values.removeValue(forKey: fieldID) }
            else { row.values[fieldID] = value }
            rows[index] = row
        }
        Task {
            do { try database.setCell(rowID: rowID, fieldID: fieldID, value: value) }
            catch { errorMessage = "Could not save cell: \(error.localizedDescription)" }
        }
    }

    // MARK: - CSV import / export

    /// Append a CSV file's rows to the selected table (headers matched to
    /// fields, unknown columns become new fields with inferred types).
    func importCSV(from url: URL) async {
        guard let tableID = selectedTableID else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try MaestroDBCSV.parse(text)
            let report = try MaestroDBCSV.importRows(parsed, into: tableID, database: database)
            noticeMessage = "Imported \(report.rowsAdded) rows"
                + (report.fieldsCreated.isEmpty ? "" : ", added \(report.fieldsCreated.count) fields")
                + (report.cellsSkipped == 0 ? "" : ", skipped \(report.cellsSkipped) values")
            errorMessage = nil
            await loadTableContent()
        } catch {
            errorMessage = "CSV import failed: \(error.localizedDescription)"
            noticeMessage = nil
        }
    }

    /// Write the selected table out as CSV (round-trips through importCSV).
    /// `filtered: true` exports the current search/sort view (the rows array);
    /// `false` exports the FULL table regardless of the active filter.
    func exportCSV(to url: URL, filtered: Bool = false) async {
        guard let tableID = selectedTableID else { return }
        do {
            let exportRows = filtered ? rows : try database.rows(tableID: tableID)
            let exportFields = try database.fields(tableID: tableID)
            let csv = MaestroDBCSV.exportCSV(
                fields: exportFields, rows: exportRows,
                relationTitles: MaestroDBRelations.contexts(
                    forFields: exportFields, database: database)
                    .mapValues { $0.titles })
            try csv.write(to: url, atomically: true, encoding: .utf8)
            noticeMessage = "Exported \(exportRows.count) rows to \(url.lastPathComponent)"
                + (filtered ? " (filtered view)" : "")
            errorMessage = nil
        } catch {
            errorMessage = "CSV export failed: \(error.localizedDescription)"
            noticeMessage = nil
        }
    }

    /// Title-ish value for a row: first text-ish field's value, else "Row N".
    /// Thin wrapper over the shared MaestroDBRelations derivation.
    func title(for row: DBRow) -> String {
        MaestroDBRelations.title(for: row, fields: fields)
    }
}
