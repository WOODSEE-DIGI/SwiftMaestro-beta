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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailPane
        }
        .frame(minWidth: 700, minHeight: 420)
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
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            List(viewModel.rootItems, children: \.children, selection: .init(
                get: { viewModel.selectedItem?.id },
                set: { newID in
                    Task { await selectItem(withID: newID) }
                }
            )) { item in
                Label(item.title, systemImage: item.isFolder ? "folder" : "doc.text")
                    .tag(item.id)
                    .contextMenu {
                        if item.isFolder {
                            Button("New Note") { showingNewNoteSheet = true }
                            Button("New Folder") { showingNewFolderSheet = true }
                        }
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
            .listStyle(.sidebar)

            Divider()
            sidebarFooter
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Note") { showingNewNoteSheet = true }
                    Button("New Folder") { showingNewFolderSheet = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a note or folder")
            }
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
        if let item = viewModel.selectedItem, item.isNote {
            NoteEditorView(viewModel: viewModel)
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "doc.text",
                description: Text("Choose a Markdown note from the sidebar to start editing")
            )
        }
    }

    // MARK: - Helpers

    private func selectItem(withID id: String?) async {
        if let id, let item = findItem(withID: id, in: viewModel.rootItems) {
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
}

// MARK: - Preview

#Preview {
    NotesView(viewModel: NotesViewModel())
        .environment(ThemeStore())
}
