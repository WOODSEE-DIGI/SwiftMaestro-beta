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
        guard let tableID = selectedTableID else { fields = []; rows = []; return }
        do {
            fields = try database.fields(tableID: tableID)
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

    func createBase(named name: String) async {
        do {
            let base = try database.createBase(name: name)
            await loadAll()
            selectedBaseID = base.id
        } catch { errorMessage = "Could not create base: \(error.localizedDescription)" }
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

    func addField(named name: String, type: DBFieldType, options: [String] = []) async {
        guard let tableID = selectedTableID else { return }
        do {
            _ = try database.addField(tableID: tableID, name: name, type: type, options: options)
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
    /// Always exports the FULL table, not the current search-filtered view.
    func exportCSV(to url: URL) async {
        guard let tableID = selectedTableID else { return }
        do {
            let allRows = try database.rows(tableID: tableID)
            let csv = MaestroDBCSV.exportCSV(
                fields: try database.fields(tableID: tableID), rows: allRows)
            try csv.write(to: url, atomically: true, encoding: .utf8)
            noticeMessage = "Exported \(allRows.count) rows to \(url.lastPathComponent)"
            errorMessage = nil
        } catch {
            errorMessage = "CSV export failed: \(error.localizedDescription)"
            noticeMessage = nil
        }
    }

    /// Title-ish value for a row: first text-ish field's value, else "Row N".
    func title(for row: DBRow) -> String {
        if let titleField = fields.first(where: { [.text, .url, .email, .phone].contains($0.type) }) {
            let value = row.value(for: titleField.id)
            if !value.isEmpty { return value }
        }
        return "Row \(row.position + 1)"
    }
}
