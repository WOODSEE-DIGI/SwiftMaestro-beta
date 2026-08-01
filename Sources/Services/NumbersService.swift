import Foundation

// MARK: - Apple Numbers service

/// Bridges SwiftMaestro to the native Apple Numbers app via JXA (JavaScript
/// for Automation), mirroring `AppleNotesService`. Lists open documents,
/// creates/opens documents, lists sheets/tables, reads/writes cells, and
/// exports to CSV/PDF/Excel. Runs entirely through the shared
/// `AppleScriptRunner` so the main thread is never blocked.
///
/// Addressing: `NumbersDocument.id` is Numbers' own stable per-document UUID
/// (exposed via JXA's `document.id()`), so once a document is listed or
/// created it can always be re-addressed unambiguously — important since new
/// documents default to the name "Untitled" until saved, and several can be
/// open at once. Sheets and tables do NOT expose a stable id via JXA, so
/// they're addressed by name within a document (same convention as this
/// codebase's Kanban board/column lookups).
///
/// New documents are intentionally left to save wherever Numbers wants by
/// default (typically iCloud Drive) — see the "Numbers document save
/// location" decision. Use `export(documentID:toPath:format:)` when a
/// specific external file/format is actually requested.
@Observable
@MainActor
final class NumbersService {

    enum AuthorizationStatus: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var status: AuthorizationStatus = .notDetermined
    private(set) var documents: [NumbersDocument] = []
    private(set) var error: String?
    private(set) var isLoading = false

    private let decoder = JSONDecoder()
    private static let authorizedDefaultsKey = "numbers.authorized"

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            _ = try await AppleScriptRunner.run(Self.helloScript)
            status = .authorized
            error = nil
            UserDefaults.standard.set(true, forKey: Self.authorizedDefaultsKey)
        } catch {
            status = .denied
            self.error = "Numbers access denied or failed: \(error.localizedDescription)"
            UserDefaults.standard.set(false, forKey: Self.authorizedDefaultsKey)
        }
    }

    func loadIfPreviouslyAuthorized() async {
        guard UserDefaults.standard.bool(forKey: Self.authorizedDefaultsKey) else { return }
        await loadDocuments()
    }

    // MARK: - Documents

    func loadDocuments() async {
        isLoading = true
        defer { isLoading = false }
        error = nil
        do {
            let json = try await AppleScriptRunner.run(Self.listDocumentsScript)
            documents = try decoder.decode([NumbersDocument].self, from: Data(json.utf8))
            status = .authorized
            UserDefaults.standard.set(true, forKey: Self.authorizedDefaultsKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Creates a new blank document (one default sheet/table) and activates
    /// Numbers. Does not force a save location — see type-level doc comment.
    @discardableResult
    func createDocument() async throws -> NumbersDocument {
        let json = try await AppleScriptRunner.run(Self.createDocumentScript)
        let doc = try decoder.decode(NumbersDocument.self, from: Data(json.utf8))
        await loadDocuments()
        return doc
    }

    /// Opens an existing `.numbers` file from disk.
    @discardableResult
    func openDocument(atPath path: String) async throws -> NumbersDocument {
        let json = try await AppleScriptRunner.run(Self.openDocumentScript, arguments: [path])
        let doc = try decoder.decode(NumbersDocument.self, from: Data(json.utf8))
        await loadDocuments()
        return doc
    }

    func closeDocument(id: String, saving: Bool) async throws {
        let json = try await AppleScriptRunner.run(Self.closeDocumentScript, arguments: [id, saving ? "yes" : "no"])
        try throwIfErrorPayload(json)
        await loadDocuments()
    }

    // MARK: - Sheets / tables

    func listSheets(documentID: String) async throws -> [NumbersSheet] {
        let json = try await AppleScriptRunner.run(Self.listSheetsScript, arguments: [documentID])
        return try decoder.decode([NumbersSheet].self, from: Data(json.utf8))
    }

    func listTables(documentID: String, sheetName: String) async throws -> [NumbersTable] {
        let json = try await AppleScriptRunner.run(Self.listTablesScript, arguments: [documentID, sheetName])
        return try decoder.decode([NumbersTable].self, from: Data(json.utf8))
    }

    // MARK: - Cells

    /// Reads a table's cells in one bulk call (JXA's `table.cells.value()`,
    /// confirmed row-major) rather than iterating cell-by-cell.
    func readTable(documentID: String, sheetName: String, tableName: String) async throws -> NumbersTableData {
        let json = try await AppleScriptRunner.run(
            Self.readTableScript, arguments: [documentID, sheetName, tableName])
        try throwIfErrorPayload(json)
        return try decoder.decode(NumbersTableData.self, from: Data(json.utf8))
    }

    /// Writes a single cell. `cell` is an A1-style reference (e.g. "B2").
    /// Values that parse as a plain integer/decimal are written as numbers;
    /// everything else is written as a string.
    func writeCell(
        documentID: String, sheetName: String, tableName: String,
        cell: String, value: String
    ) async throws {
        let json = try await AppleScriptRunner.run(
            Self.writeCellScript, arguments: [documentID, sheetName, tableName, cell, value])
        try throwIfErrorPayload(json)
    }

    // MARK: - Export

    func exportDocument(documentID: String, toPath path: String, format: NumbersExportFormat) async throws {
        let json = try await AppleScriptRunner.run(
            Self.exportScript, arguments: [documentID, path, format.jxaValue])
        try throwIfErrorPayload(json)
    }

    // MARK: - Error payload helper
    //
    // Several scripts return `{"error": "..."}` instead of throwing (JXA's
    // own thrown errors don't always carry a useful message), so callers
    // that need a genuine Swift `throws` surface funnel through this.

    private func throwIfErrorPayload(_ json: String) throws {
        struct ErrorPayload: Decodable { let error: String? }
        guard let payload = try? decoder.decode(ErrorPayload.self, from: Data(json.utf8)),
              let message = payload.error
        else { return }
        throw AppleScriptError.scriptFailed(message)
    }

    // MARK: - Shared JXA helpers (textually duplicated into each script below
    // since separate `osascript -e` invocations can't share JS modules)

    private static let findDocByIDHelper = """
    function findDocByID(Numbers, id) {
        var docs = Numbers.documents();
        for (var i = 0; i < docs.length; i++) {
            if (docs[i].id() === id) return docs[i];
        }
        return null;
    }
    """

    private static let findTableHelper = """
    function findTable(doc, sheetName, tableName) {
        var sheets = doc.sheets();
        for (var i = 0; i < sheets.length; i++) {
            if (sheets[i].name() === sheetName) {
                var tables = sheets[i].tables();
                for (var j = 0; j < tables.length; j++) {
                    if (tables[j].name() === tableName) return tables[j];
                }
            }
        }
        return null;
    }
    """

    private static func docJSON(_ varName: String) -> String {
        """
        var path = null;
        try { path = \(varName).file().toString(); } catch (e) {}
        return JSON.stringify({ id: \(varName).id(), name: \(varName).name(), path: path });
        """
    }

    // MARK: - Scripts

    private static let helloScript = """
    function run(argv) {
        var Numbers = Application('Numbers');
        Numbers.name();
        return "ok";
    }
    """

    private static let listDocumentsScript = """
    function run(argv) {
        var Numbers = Application('Numbers');
        var docs = [];
        Numbers.documents().forEach(function(doc) {
            var path = null;
            try { path = doc.file().toString(); } catch (e) {}
            docs.push({ id: doc.id(), name: doc.name(), path: path });
        });
        return JSON.stringify(docs);
    }
    """

    private static let createDocumentScript = """
    function run(argv) {
        var Numbers = Application('Numbers');
        Numbers.activate();
        var doc = Numbers.Document();
        Numbers.documents.push(doc);
        delay(0.5);
        \(docJSON("doc"))
    }
    """

    private static let openDocumentScript = """
    function run(argv) {
        var Numbers = Application('Numbers');
        Numbers.activate();
        var doc = Numbers.open(Path(argv[0]));
        delay(0.5);
        \(docJSON("doc"))
    }
    """

    private static let closeDocumentScript = """
    \(findDocByIDHelper)
    function run(argv) {
        var Numbers = Application('Numbers');
        var doc = findDocByID(Numbers, argv[0]);
        if (!doc) return JSON.stringify({ error: 'document not found' });
        doc.close({ saving: argv[1] === 'yes' ? 'yes' : 'no' });
        return JSON.stringify({ status: 'closed' });
    }
    """

    private static let listSheetsScript = """
    \(findDocByIDHelper)
    function run(argv) {
        var Numbers = Application('Numbers');
        var doc = findDocByID(Numbers, argv[0]);
        if (!doc) return JSON.stringify([]);
        var sheets = [];
        doc.sheets().forEach(function(sheet) {
            sheets.push({ name: sheet.name(), tableCount: sheet.tables().length });
        });
        return JSON.stringify(sheets);
    }
    """

    private static let listTablesScript = """
    \(findDocByIDHelper)
    function run(argv) {
        var Numbers = Application('Numbers');
        var doc = findDocByID(Numbers, argv[0]);
        if (!doc) return JSON.stringify([]);
        var sheetName = argv[1];
        var sheet = null;
        var sheets = doc.sheets();
        for (var i = 0; i < sheets.length; i++) {
            if (sheets[i].name() === sheetName) { sheet = sheets[i]; break; }
        }
        if (!sheet) return JSON.stringify([]);
        var tables = [];
        sheet.tables().forEach(function(table) {
            tables.push({ name: table.name(), rowCount: table.rowCount(), columnCount: table.columnCount() });
        });
        return JSON.stringify(tables);
    }
    """

    private static let readTableScript = """
    \(findDocByIDHelper)
    \(findTableHelper)
    function run(argv) {
        var Numbers = Application('Numbers');
        var doc = findDocByID(Numbers, argv[0]);
        if (!doc) return JSON.stringify({ error: 'document not found' });
        var table = findTable(doc, argv[1], argv[2]);
        if (!table) return JSON.stringify({ error: 'table not found' });
        var flat = table.cells.value();
        var columnCount = table.columnCount();
        var rowCount = table.rowCount();
        var rows = [];
        for (var r = 0; r < rowCount; r++) {
            var row = [];
            for (var c = 0; c < columnCount; c++) {
                var v = flat[r * columnCount + c];
                row.push(v === null || v === undefined ? "" : String(v));
            }
            rows.push(row);
        }
        return JSON.stringify({ rowCount: rowCount, columnCount: columnCount, rows: rows });
    }
    """

    private static let writeCellScript = """
    \(findDocByIDHelper)
    \(findTableHelper)
    function run(argv) {
        var Numbers = Application('Numbers');
        var doc = findDocByID(Numbers, argv[0]);
        if (!doc) return JSON.stringify({ error: 'document not found' });
        var table = findTable(doc, argv[1], argv[2]);
        if (!table) return JSON.stringify({ error: 'table not found' });
        var cellRef = argv[3];
        var rawValue = argv[4];
        var isNumeric = /^-?\\d+(\\.\\d+)?$/.test(rawValue);
        var value = isNumeric ? Number(rawValue) : rawValue;
        try {
            table.cells[cellRef].value = value;
        } catch (e) {
            return JSON.stringify({ error: 'invalid cell reference: ' + cellRef });
        }
        return JSON.stringify({ status: 'written', cell: cellRef, value: value });
    }
    """

    private static let exportScript = """
    \(findDocByIDHelper)
    function run(argv) {
        var Numbers = Application('Numbers');
        var doc = findDocByID(Numbers, argv[0]);
        if (!doc) return JSON.stringify({ error: 'document not found' });
        try {
            doc.export({ to: Path(argv[1]), as: argv[2] });
        } catch (e) {
            return JSON.stringify({ error: 'export failed: ' + e });
        }
        return JSON.stringify({ status: 'exported', path: argv[1] });
    }
    """
}

// MARK: - Models

struct NumbersDocument: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String?
}

struct NumbersSheet: Codable, Hashable, Sendable {
    let name: String
    let tableCount: Int
}

struct NumbersTable: Codable, Hashable, Sendable {
    let name: String
    let rowCount: Int
    let columnCount: Int
}

struct NumbersTableData: Codable, Hashable, Sendable {
    let rowCount: Int
    let columnCount: Int
    let rows: [[String]]
}

/// Export formats Numbers' JXA `export({as:})` accepts, confirmed by live
/// testing (values are exactly what the JXA call expects — not guesses).
enum NumbersExportFormat: String, Sendable {
    case csv
    case pdf
    case xlsx

    var jxaValue: String {
        switch self {
        case .csv: return "CSV"
        case .pdf: return "PDF"
        case .xlsx: return "Microsoft Excel"
        }
    }
}
