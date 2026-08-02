import SwiftUI
import UniformTypeIdentifiers

// MARK: - MaestroDB View
//
// Container: bases sidebar + table tabs + grid/board content. The board mode
// reuses the shared KanbanBoardView via the KanbanStore write-through bridge
// (see KanbanStore+MaestroDB.swift) — one kanban implementation, two backends.

struct MaestroDBView: View {
    @State private var viewModel = MaestroDBViewModel()
    @Environment(ThemeStore.self) private var theme
    @State private var isCreatingBase = false
    @State private var isCreatingTable = false
    @State private var isAddingField = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                // Content must claim the leftover frame or the VStack centers
                // header+content vertically at their ideal size (the "rendering
                // halfway down" bug). The frame pins the header to the top and
                // lets grids/boards fill and empty states center in the rest.
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await viewModel.loadAll() }
        .onReceive(NotificationCenter.default.publisher(for: .maestroDBDidChange)) { _ in
            viewModel.scheduleExternalReload()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MaestroDB")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("New Base…") { newName = ""; isCreatingBase = true }
                    Button("New Table…") { newName = ""; isCreatingTable = true }
                        .disabled(viewModel.selectedBaseID == nil)
                    Divider()
                    Button(viewModel.isDemoMode ? "Leave Demo Data" : "Load Demo Data") {
                        viewModel.toggleDemoMode()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: $viewModel.selectedTableID) {
                ForEach(viewModel.bases) { base in
                    Section {
                        if viewModel.selectedBaseID == base.id {
                            ForEach(viewModel.tables) { table in
                                Label(table.name, systemImage: "tablecells")
                                    .tag(table.id)
                            }
                        }
                    } header: {
                        Button { viewModel.selectedBaseID = base.id } label: {
                            Label(base.name, systemImage: base.icon)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(theme.chatText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)

            if viewModel.isDemoMode {
                Text("DEMO DATA — not your real bases")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.12))
            }
        }
        .frame(minWidth: 200, idealWidth: 220, maxWidth: 260, maxHeight: .infinity)
        .background(theme.secondaryBackground.opacity(0.4))
        .alert("New Base", isPresented: $isCreatingBase) {
            TextField("Base name", text: $newName)
            Button("Create") { Task { await viewModel.createBase(named: newName) } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Table", isPresented: $isCreatingTable) {
            TextField("Table name", text: $newName)
            Button("Create") { Task { await viewModel.createTable(named: newName) } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $viewModel.viewMode) {
                Label("Grid", systemImage: "tablecells").tag(MaestroDBViewModel.ViewMode.grid)
                Label("Board", systemImage: "rectangle.split.3x1").tag(MaestroDBViewModel.ViewMode.board)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .disabled(viewModel.selectedTableID == nil)

            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.chatText.opacity(0.6))
            TextField("Search rows…", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .frame(maxWidth: 220)

            Spacer()

            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            if let notice = viewModel.noticeMessage {
                Text(notice).font(.caption).foregroundStyle(.green).lineLimit(1)
            }

            Button { Task { await viewModel.addRow() } } label: {
                Label("Row", systemImage: "plus")
            }
            .disabled(viewModel.selectedTableID == nil || viewModel.fields.isEmpty)

            Button { isAddingField = true } label: {
                Label("Field", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(viewModel.selectedTableID == nil)

            Menu {
                Button("Import CSV…") { importCSV() }
                Divider()
                Button("Export CSV (All Rows)…") { exportCSV(filtered: false) }
                    .disabled(viewModel.fields.isEmpty)
                Button("Export CSV (Filtered View)…") { exportCSV(filtered: true) }
                    .disabled(viewModel.fields.isEmpty
                              || (viewModel.searchQuery.isEmpty && viewModel.sort == nil))
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(viewModel.selectedTableID == nil)
            .help("Import or export this table as CSV")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $isAddingField) {
            MaestroDBAddFieldSheet(tables: viewModel.tables) { name, type, options, config in
                Task { await viewModel.addField(named: name, type: type, options: options, config: config) }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedTableID == nil {
            ContentUnavailableView(
                "No Table Selected",
                systemImage: "tablecells",
                description: Text("Create a base and a table to start building your database.")
            )
        } else if viewModel.fields.isEmpty {
            ContentUnavailableView(
                "No Fields Yet",
                systemImage: "rectangle.grid.1x2",
                description: Text("Add your first field — text, number, checkbox, date, select, rating and more.")
            )
        } else {
            switch viewModel.viewMode {
            case .grid:
                MaestroDBGridView(viewModel: viewModel)
            case .board:
                MaestroDBBoardView(viewModel: viewModel)
            }
        }
    }

    // MARK: - CSV panels

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import rows into the selected table"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.importCSV(from: url) }
    }

    private func exportCSV(filtered: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let tableName = viewModel.tables.first(where: { $0.id == viewModel.selectedTableID })?.name ?? "Table"
        panel.nameFieldStringValue = filtered ? "\(tableName) (filtered).csv" : "\(tableName).csv"
        panel.message = filtered
            ? "Export the current filtered/sorted view as CSV"
            : "Export the full table as CSV"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.exportCSV(to: url, filtered: filtered) }
    }
}
