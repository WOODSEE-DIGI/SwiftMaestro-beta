import SwiftUI
import UniformTypeIdentifiers

struct NumbersView: View {
    @Environment(NumbersService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var selectedDocumentID: String?
    @State private var error: String?
    @AppStorage("numbers.documentListWidth") private var documentListWidth = 220.0
    /// Owned explicitly here (rather than letting `NavigationStack` manage
    /// its own implicit internal path) because tapping a sheet row was
    /// reported to not navigate anywhere — confirmed live: the sheet list
    /// stayed on screen showing the selected document's sheet with no way
    /// to drill into its tables. `detailStack` is a *computed property*
    /// returning a fresh `NavigationStack` value on every `NumbersView.body`
    /// re-evaluation, then wrapped in `AnyView` by `ResizablePanelHost`'s
    /// `ResizablePane` — an implicit, un-bound `NavigationStack`'s push
    /// state lives entirely inside that value's own opaque internal
    /// storage, which is exactly the kind of state type-erasure through
    /// `AnyView` in a custom container is most likely to fail to carry
    /// forward correctly. An explicit `NavigationPath` is real `@State`
    /// owned directly by `NumbersView` itself (never erased), so pushes are
    /// guaranteed to actually mutate visible, persistent state regardless
    /// of how the destination view is hosted.
    @State private var navigationPath = NavigationPath()
    /// A browsable tree of `.numbers` files found on disk — distinct from
    /// `service.documents`, which only lists documents CURRENTLY OPEN in
    /// Numbers.app. Reported gap: the sidebar only ever showed that flat
    /// "Open Documents" list, with no way to browse to a file that isn't
    /// already open; the folder-icon button only opens a one-shot system
    /// picker dialog, not a persistent in-panel browser. Built once (and on
    /// manual refresh) by scanning known likely save locations.
    @State private var fileTree: [NumbersFileNode] = []
    @State private var isLoadingFileTree = false

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
        .task {
            await reloadFileTree()
        }
        .onChange(of: service.status) { _, newValue in
            if newValue == .authorized {
                Task { await service.loadDocuments() }
            }
        }
        // Switching documents while a sheet/table is pushed would otherwise
        // leave that now-unrelated destination view on screen, referencing
        // the PREVIOUS document's data — reset to the sheet list root.
        .onChange(of: selectedDocumentID) { _, _ in
            navigationPath = NavigationPath()
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

                Section("Files") {
                    if isLoadingFileTree {
                        Text("Scanning…")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if fileTree.isEmpty {
                        Text("No .numbers files found")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        ForEach(fileTree) { node in
                            NumbersFileTreeRow(node: node, onOpenFile: openFile(at:))
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
                    Task {
                        await service.loadDocuments()
                        await reloadFileTree()
                    }
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
        NavigationStack(path: $navigationPath) {
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
        SheetListView(
            documentID: selectedDocumentID, documentName: selectedDocumentName,
            // Explicit push via the owning view's own `navigationPath`,
            // rather than `NavigationLink(value:)`'s implicit value-matching
            // against `.navigationDestination(for:)` — see the long comment
            // on `navigationPath` for why: tapping a sheet was reported to
            // not navigate anywhere, and this removes any dependency on
            // that implicit machinery working correctly through a
            // `ResizablePanelHost`/`AnyView`-hosted `NavigationStack`.
            onSelect: { sheet in navigationPath.append(sheet) }
        )
    }

    private func tableList(sheet: NumbersSheet) -> some View {
        TableListView(
            documentID: selectedDocumentID ?? "",
            documentName: selectedDocumentName,
            sheet: sheet,
            onSelect: { table in
                navigationPath.append(NumbersTableRoute(
                    documentID: selectedDocumentID ?? "", documentName: selectedDocumentName,
                    sheetName: sheet.name, table: table
                ))
            }
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

    /// Opens a `.numbers` file tapped in the sidebar's file tree — same
    /// underlying JXA "open" call the folder-icon picker uses, just
    /// triggered from a tree row instead of a one-shot system dialog.
    private func openFile(at path: String) {
        Task {
            do {
                let doc = try await service.openDocument(atPath: path)
                selectedDocumentID = doc.id
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Rebuilds the sidebar's `.numbers` file tree by scanning the two
    /// locations Numbers documents actually end up in on this machine: the
    /// user's `~/Documents` folder, and (if present) the iCloud Drive
    /// container Numbers.app itself uses when a document is saved to
    /// iCloud. Scanning happens off the main actor since it's real
    /// synchronous disk I/O across a whole directory subtree.
    private func reloadFileTree() async {
        isLoadingFileTree = true
        defer { isLoadingFileTree = false }
        fileTree = await Task.detached(priority: .userInitiated) {
            NumbersFileNode.scanKnownLocations()
        }.value
    }
}

// MARK: - File tree (sidebar .numbers browser)

/// One entry in the sidebar's `.numbers` file browser — either a folder
/// (with children already scanned in, since folders containing no
/// `.numbers` files anywhere inside them are pruned entirely rather than
/// shown as always-empty dead ends) or a leaf `.numbers` file.
private struct NumbersFileNode: Identifiable {
    let id: String // full filesystem path — always unique
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [NumbersFileNode]

    /// Scans `~/Documents` and, if it exists, the iCloud Drive container
    /// Numbers.app saves into (`~/Library/Mobile Documents/com~apple~Numbers`),
    /// each as its own top-level root node so the two are clearly
    /// distinguished in the tree rather than silently merged.
    static func scanKnownLocations() -> [NumbersFileNode] {
        let fm = FileManager.default
        var roots: [NumbersFileNode] = []

        if let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let children = scan(directory: documentsURL, depth: 0)
            if !children.isEmpty {
                roots.append(NumbersFileNode(
                    id: documentsURL.path, name: "Documents", path: documentsURL.path,
                    isDirectory: true, children: children
                ))
            }
        }

        let iCloudNumbersURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~Numbers/Documents")
        if fm.fileExists(atPath: iCloudNumbersURL.path) {
            let children = scan(directory: iCloudNumbersURL, depth: 0)
            if !children.isEmpty {
                roots.append(NumbersFileNode(
                    id: iCloudNumbersURL.path, name: "iCloud Drive – Numbers", path: iCloudNumbersURL.path,
                    isDirectory: true, children: children
                ))
            }
        }

        return roots
    }

    /// Recursively scans one directory. Non-`.numbers`, non-directory
    /// entries are ignored entirely; directories with no `.numbers` file
    /// anywhere in their subtree are pruned so the tree only ever shows a
    /// path that actually leads somewhere useful. Capped at a sane depth so
    /// a huge/symlink-looping Documents folder can't hang the scan.
    private static func scan(directory: URL, depth: Int, maxDepth: Int = 8) -> [NumbersFileNode] {
        guard depth <= maxDepth,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var nodes: [NumbersFileNode] = []
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            // A `.numbers` document can itself be a package/directory on
            // disk depending on how it was created — treat anything with
            // this extension as an opaque leaf file, never recurse into it.
            if entry.pathExtension.lowercased() == "numbers" {
                nodes.append(NumbersFileNode(
                    id: entry.path, name: entry.deletingPathExtension().lastPathComponent,
                    path: entry.path, isDirectory: false, children: []
                ))
                continue
            }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            let children = scan(directory: entry, depth: depth + 1, maxDepth: maxDepth)
            guard !children.isEmpty else { continue }
            nodes.append(NumbersFileNode(
                id: entry.path, name: entry.lastPathComponent, path: entry.path,
                isDirectory: true, children: children
            ))
        }
        return nodes
    }
}

/// Recursively renders one `NumbersFileNode` — a `DisclosureGroup` for a
/// folder, a plain tappable row for a `.numbers` file.
private struct NumbersFileTreeRow: View {
    let node: NumbersFileNode
    let onOpenFile: (String) -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup {
                ForEach(node.children) { child in
                    NumbersFileTreeRow(node: child, onOpenFile: onOpenFile)
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .lineLimit(1)
            }
        } else {
            Button {
                onOpenFile(node.path)
            } label: {
                Label(node.name, systemImage: "tablecells")
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Sheet list (per selected document)

private struct SheetListView: View {
    let documentID: String?
    let documentName: String
    let onSelect: (NumbersSheet) -> Void

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
                        Button {
                            onSelect(sheet)
                        } label: {
                            HStack {
                                Text(sheet.name)
                                Spacer()
                                Text("\(sheet.tableCount) table\(sheet.tableCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            // Matches AppleNotesView's note row: without this,
                            // the `Spacer()`'s empty area isn't part of the
                            // tap target, only the text glyphs themselves are.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
    let onSelect: (NumbersTable) -> Void

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
                        Button {
                            onSelect(table)
                        } label: {
                            HStack {
                                Text(table.name)
                                Spacer()
                                Text("\(table.rowCount)×\(table.columnCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
