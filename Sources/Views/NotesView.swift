import SwiftUI

// MARK: - Notes view

/// Main Notes browser. Two-pane layout: a folder/note tree on the left and a
/// Markdown editor/preview on the right.
struct NotesView: View {
    @Bindable var viewModel: NotesViewModel
    @Environment(ThemeStore.self) private var theme

    @State private var newNoteName = ""
    @State private var newFolderName = ""
    @State private var renamingItem: NoteItem? = nil
    @State private var renameText = ""
    @State private var showingNewNoteSheet = false
    @State private var showingNewFolderSheet = false
    @State private var importURLs: [URL] = []
    @State private var showingImportChoiceSheet = false
    /// Drag-resizable note-tree width, persisted like `AppleNotesView`'s
    /// folder list — a single view-local divider, so `@AppStorage` is enough.
    @AppStorage("notes.treeWidth") private var treeWidth = 220.0

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedItem?.id },
            set: { newID in
                Task { await selectItem(withID: newID) }
            }
        )
    }

    var body: some View {
        ResizablePanelHost(panes: [
            ResizablePane(
                id: "tree",
                length: Binding(get: { CGFloat(treeWidth) }, set: { treeWidth = Double($0) }),
                minLength: 180,
                maxLength: 360
            ) {
                sidebar
            },
            ResizablePane(id: "detail", length: nil) {
                detailPane
            },
        ])
        // No hardcoded minWidth/minHeight here — NotesView is now hosted in
        // several different contexts (a full docked screen, a workspace grid
        // column, or a small floating window), each of which already owns an
        // appropriate minimum size for its own context. A fixed 700pt minimum
        // dating from when this was always the whole window fought the
        // smaller floating window's own sizing, producing a corrupted layout.
        .task {
            await viewModel.load()
        }
        .alert("New Note", isPresented: $showingNewNoteSheet) {
            TextField("Name", text: $newNoteName)
            Button("Cancel", role: .cancel) { newNoteName = "" }
            Button("Create") {
                Task {
                    await viewModel.createNote(named: newNoteName)
                    newNoteName = ""
                }
            }
            .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Enter a name for the new Markdown note")
        }
        .alert("New Folder", isPresented: $showingNewFolderSheet) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                Task {
                    await viewModel.createFolder(named: newFolderName)
                    newFolderName = ""
                }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Enter a name for the new folder")
        }
        .alert("Rename", isPresented: .init(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil; renameText = "" } }
        )) {
            TextField("New name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingItem = nil; renameText = "" }
            Button("Rename") {
                guard let item = renamingItem else { return }
                Task {
                    await viewModel.rename(item: item, to: renameText)
                    renamingItem = nil
                    renameText = ""
                }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Rename '\(renamingItem?.name ?? "")'")
        }
        .alert("Import Items", isPresented: $showingImportChoiceSheet) {
            Button("Copy into Vault", role: nil) {
                Task {
                    await viewModel.importItems(importURLs, copy: true)
                    importURLs = []
                }
            }
            Button("Link in Place (Symlink)", role: nil) {
                Task {
                    await viewModel.importItems(importURLs, copy: false)
                    importURLs = []
                }
            }
            Button("Cancel", role: .cancel) { importURLs = [] }
        } message: {
            Text("Import \(importURLs.count) item(s) into '\(viewModel.selectedFolderName())'? Copying leaves the originals untouched. Linking creates shortcuts back to the originals.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)
            Divider()
            searchBar
            Divider()
            List(selection: selectionBinding) {
                Section("External Folders") {
                    if viewModel.externalRootItems.isEmpty {
                        Text("No external folders")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.externalRootItems) { item in
                            OutlineGroup([item], children: \.children) { child in
                                treeRow(for: child)
                            }
                        }
                    }
                }
                Section("Vault") {
                    ForEach(viewModel.rootItems) { item in
                        OutlineGroup([item], children: \.children) { child in
                            treeRow(for: child)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)

            Divider()
            sidebarFooter
        }
    }

    @ViewBuilder
    private func treeRow(for item: NoteItem) -> some View {
        Label(item.title, systemImage: iconFor(item))
            .tag(item.id)
            .contextMenu { contextMenu(for: item) }
    }

    private func contextMenu(for item: NoteItem) -> some View {
        Group {
            if viewModel.isExternalRoot(item) {
                Button("Remove External Folder") {
                    viewModel.removeExternalFolder(item)
                }
                Divider()
            }
            if item.isFolder && !item.isReadOnly {
                Button("New Note") { showingNewNoteSheet = true }
                Button("New Folder") { showingNewFolderSheet = true }
            }
            if !item.isReadOnly {
                Button("Rename") {
                    renamingItem = item
                    renameText = item.name
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task { await viewModel.delete(item: item) }
                }
            }
        }
    }

    private var sidebarHeader: some View {
        HStack {
            Text("Notes")
                .font(.headline)
            Spacer()
            Menu {
                Button("New Note") { showingNewNoteSheet = true }
                Button("New Folder") { showingNewFolderSheet = true }
                Divider()
                Button("Import File or Folder…") { presentImportPicker() }
                Button("Add External Folder…") { viewModel.addExternalFolder() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a note, folder, import, or external folder")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search notes", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(theme.secondaryBackground)
        .cornerRadius(8)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Vault: \(viewModel.vaultURL.lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(viewModel.vaultURL.path)

                Spacer()

                Button {
                    viewModel.chooseVaultFolder()
                } label: {
                    Image(systemName: "folder.badge.gear")
                }
                .buttonStyle(.plain)
                .help("Change vault folder")
            }

            HStack {
                Toggle("iCloud Drive", isOn: .init(
                    get: { viewModel.isCloudSyncEnabled },
                    set: { _ in
                        Task { await viewModel.toggleCloudSync() }
                    }
                ))
                .toggleStyle(.switch)
                .font(.caption2)
                .controlSize(.small)

                if !viewModel.cloudSyncStatus.isEmpty {
                    Text(viewModel.cloudSyncStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let item = viewModel.selectedItem {
            if item.isNote {
                NoteEditorView(viewModel: viewModel)
            } else if item.isAsset {
                NoteAssetViewer(item: item)
            } else {
                ContentUnavailableView(
                    "Select a Note",
                    systemImage: "doc.text",
                    description: Text("Choose a Markdown note from the sidebar to start editing")
                )
            }
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "doc.text",
                description: Text("Choose a Markdown note from the sidebar to start editing")
            )
        }
    }

    // MARK: - Helpers

    private func iconFor(_ item: NoteItem) -> String {
        if item.isFolder { return "folder" }
        switch item.assetKind {
        case .html: return "globe"
        case .json: return "curlybraces"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        default: return item.isNote ? "doc.text" : "doc"
        }
    }

    private func selectItem(withID id: String?) async {
        if let id, let item = findItem(withID: id, in: viewModel.rootItems)
            ?? findItem(withID: id, in: viewModel.externalRootItems) {
            viewModel.selectedItem = item
        } else {
            viewModel.selectedItem = nil
        }
    }

    private func findItem(withID id: String, in items: [NoteItem]) -> NoteItem? {
        for item in items {
            if item.id == id { return item }
            if let found = findItem(withID: id, in: item.children ?? []) { return found }
        }
        return nil
    }

    // MARK: - Import & Drag-and-Drop

    private func presentImportPicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Select files or folders to import into the current folder"
        panel.begin { result in
            guard result == .OK else { return }
            Task { @MainActor in
                self.importURLs = panel.urls
                self.showingImportChoiceSheet = true
            }
        }
        #endif
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                // Drag-and-drop always copies; it never moves or replaces the original.
                await self.viewModel.importItems(urls, copy: true)
            }
        }
        return true
    }
}

// MARK: - Preview

#Preview {
    NotesView(viewModel: NotesViewModel())
        .environment(ThemeStore())
}
