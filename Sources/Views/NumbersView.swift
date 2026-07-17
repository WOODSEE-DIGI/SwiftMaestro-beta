import SwiftUI
import UniformTypeIdentifiers

struct NumbersView: View {
    @Environment(NumbersService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var selectedDocumentID: String?
    @State private var error: String?
    @AppStorage("numbers.documentListWidth") private var documentListWidth = 220.0

    var body: some View {
        ResizablePanelHost(panes: [
            ResizablePane(
                id: "documents",
                length: Binding(get: { CGFloat(documentListWidth) }, set: { documentListWidth = Double($0) }),
                minLength: 180,
                maxLength: 340
            ) {
                documentList
            },
            ResizablePane(id: "detail", length: nil) {
                detailStack
            },
        ])
        .task {
            await service.loadIfPreviouslyAuthorized()
        }
        .onChange(of: service.status) { _, newValue in
            if newValue == .authorized {
                Task { await service.loadDocuments() }
            }
        }
        .alert("Numbers Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Document list

    private var documentList: some View {
        VStack(spacing: 0) {
            documentListHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            List(selection: $selectedDocumentID) {
                Section("Open Documents") {
                    if service.documents.isEmpty {
                        Text(service.status == .authorized ? "No documents open" : "Grant access")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        ForEach(service.documents) { doc in
                            Text(doc.name)
                                .tag(doc.id)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var documentListHeader: some View {
        HStack {
            Text("Numbers")
                .font(.headline)
            Spacer()
            if service.status != .authorized {
                Button("Authorize") {
                    Task { await service.requestAuthorization() }
                }
            } else {
                Button {
                    Task { await createDocument() }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New document")

                Button {
                    openDocumentPicker()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Open existing .numbers file")

                Button {
                    Task { await service.loadDocuments() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
    }

    // MARK: - Detail stack (document -> sheets -> tables -> cell grid)

    private var detailStack: some View {
        NavigationStack {
            sheetList
                .navigationTitle(selectedDocumentName)
                .navigationDestination(for: NumbersSheet.self) { sheet in
                    tableList(sheet: sheet)
                }
                .navigationDestination(for: NumbersTableRoute.self) { route in
                    NumbersTableGridView(
                        documentID: route.documentID,
                        documentName: route.documentName,
                        sheetName: route.sheetName,
                        table: route.table
                    )
                }
        }
    }

    private var selectedDocumentName: String {
        service.documents.first { $0.id == selectedDocumentID }?.name ?? "Numbers"
    }

    private var sheetList: some View {
        SheetListView(documentID: selectedDocumentID, documentName: selectedDocumentName)
    }

    private func tableList(sheet: NumbersSheet) -> some View {
        TableListView(
            documentID: selectedDocumentID ?? "",
            documentName: selectedDocumentName,
            sheet: sheet
        )
    }

    // MARK: - Actions

    private func createDocument() async {
        do {
            let doc = try await service.createDocument()
            selectedDocumentID = doc.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openDocumentPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "numbers") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let doc = try await service.openDocument(atPath: url.path)
                selectedDocumentID = doc.id
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Sheet list (per selected document)

private struct SheetListView: View {
    let documentID: String?
    let documentName: String

    @Environment(NumbersService.self) private var service
    @State private var sheets: [NumbersSheet] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if documentID == nil {
                    Text("Select a document")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if sheets.isEmpty {
                    Text(isLoading ? "Loading…" : "No sheets")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    ForEach(sheets, id: \.name) { sheet in
                        NavigationLink(value: sheet) {
                            HStack {
                                Text(sheet.name)
                                Spacer()
                                Text("\(sheet.tableCount) table\(sheet.tableCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task(id: documentID) {
            await load()
        }
        .alert("Numbers Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func load() async {
        guard let documentID else { sheets = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            sheets = try await service.listSheets(documentID: documentID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Table list (per selected sheet)

private struct TableListView: View {
    let documentID: String
    let documentName: String
    let sheet: NumbersSheet

    @Environment(NumbersService.self) private var service
    @State private var tables: [NumbersTable] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if tables.isEmpty {
                    Text(isLoading ? "Loading…" : "No tables")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    ForEach(tables, id: \.name) { table in
                        NavigationLink(value: NumbersTableRoute(
                            documentID: documentID, documentName: documentName,
                            sheetName: sheet.name, table: table
                        )) {
                            HStack {
                                Text(table.name)
                                Spacer()
                                Text("\(table.rowCount)×\(table.columnCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(sheet.name)
        .task {
            await load()
        }
        .alert("Numbers Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tables = try await service.listTables(documentID: documentID, sheetName: sheet.name)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NumbersTableRoute: Hashable {
    let documentID: String
    let documentName: String
    let sheetName: String
    let table: NumbersTable
}

// MARK: - Editable cell grid (per selected table)

/// Renders a table's cells as an editable grid. Large tables are capped for
/// display (SwiftUI `Grid` doesn't scale to thousands of live text fields) —
/// the full table remains readable/writable via the agent tools regardless.
private struct NumbersTableGridView: View {
    let documentID: String
    let documentName: String
    let sheetName: String
    let table: NumbersTable

    @Environment(NumbersService.self) private var service
    @State private var rows: [[String]] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showExportSheet = false

    private static let maxDisplayRows = 100
    private static let maxDisplayColumns = 26

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if isLoading {
                ProgressView("Loading table…")
                    .padding()
            } else if rows.isEmpty {
                Text("Empty table")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                grid
                    .padding()
            }
        }
        .navigationTitle(table.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export document…")
            }
        }
        .task {
            await load()
        }
        .fileExporter(
            isPresented: $showExportSheet,
            document: NumbersExportRequestDocument(),
            contentType: .commaSeparatedText,
            defaultFilename: documentName
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await export(to: url) }
        }
        .alert("Numbers Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var displayedColumnCount: Int {
        min(table.columnCount, Self.maxDisplayColumns)
    }

    private var truncated: Bool {
        table.rowCount > Self.maxDisplayRows || table.columnCount > Self.maxDisplayColumns
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            if truncated {
                Text("Showing first \(min(table.rowCount, Self.maxDisplayRows)) of \(table.rowCount) rows, "
                    + "\(displayedColumnCount) of \(table.columnCount) columns. "
                    + "Use the agent's read_numbers_table tool for the full table.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                ForEach(Array(rows.prefix(Self.maxDisplayRows).enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.prefix(displayedColumnCount).enumerated()), id: \.offset) { colIndex, _ in
                            cellField(row: rowIndex, column: colIndex)
                        }
                    }
                }
            }
        }
    }

    private func cellField(row: Int, column: Int) -> some View {
        TextField("", text: Binding(
            get: { rows[safe: row]?[safe: column] ?? "" },
            set: { newValue in
                guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
                rows[row][column] = newValue
            }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .frame(minWidth: 70, maxWidth: 140)
        .padding(4)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(Rectangle().stroke(Color.gray.opacity(0.25), lineWidth: 0.5))
        .onSubmit {
            Task { await commitCell(row: row, column: column) }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await service.readTable(documentID: documentID, sheetName: sheetName, tableName: table.name)
            rows = data.rows
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func commitCell(row: Int, column: Int) async {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        let cellRef = Self.a1Reference(column: column, row: row)
        do {
            try await service.writeCell(
                documentID: documentID, sheetName: sheetName, tableName: table.name,
                cell: cellRef, value: rows[row][column]
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func export(to url: URL) async {
        let format: NumbersExportFormat
        switch url.pathExtension.lowercased() {
        case "pdf": format = .pdf
        case "xlsx": format = .xlsx
        default: format = .csv
        }
        do {
            try await service.exportDocument(documentID: documentID, toPath: url.path, format: format)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Zero-based (row, column) -> A1-style reference, e.g. (0,0) -> "A1", (1,27) -> "B28".
    static func a1Reference(column: Int, row: Int) -> String {
        var col = column
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(65 + col % 26)!) + letters
            col = col / 26 - 1
        } while col >= 0
        return "\(letters)\(row + 1)"
    }
}

/// Minimal `FileDocument` placeholder to drive `.fileExporter`'s save panel —
/// the actual export is performed by Numbers itself via `exportDocument`, so
/// this document's content is never written; only the chosen `url` is used.
private struct NumbersExportRequestDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .pdf, .data] }
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    NumbersView()
        .environment(NumbersService())
}
