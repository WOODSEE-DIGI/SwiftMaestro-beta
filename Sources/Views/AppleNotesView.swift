import SwiftUI

struct AppleNotesView: View {
    @Environment(AppleNotesService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var selectedFolderID: String?
    @State private var noteBody = ""
    @State private var isLoadingBody = false
    @State private var showCreateSheet = false
    @State private var newNoteTitle = ""
    @State private var newNoteBody = ""
    @State private var error: String?

    var body: some View {
        NavigationSplitView {
            folderList
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            detailStack
        }
        .task {
            await service.loadIfPreviouslyAuthorized()
        }
        .onChange(of: service.status) { _, newValue in
            if newValue == .authorized {
                Task { await service.loadFolders() }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            createSheet
        }
        .alert("Apple Notes Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Folder list

    private var folderList: some View {
        List(selection: $selectedFolderID) {
            Section("Folders") {
                if service.folders.isEmpty {
                    Text(service.status == .authorized ? "No folders" : "Grant access")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    ForEach(service.folders) { folder in
                        Text(folder.name)
                            .tag(folder.id)
                            .lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle("Apple Notes")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if service.status != .authorized {
                    Button("Authorize") {
                        Task { await service.requestAuthorization() }
                    }
                } else {
                    Button {
                        Task { await service.loadFolders() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onChange(of: selectedFolderID) { _, newValue in
            guard let id = newValue else {
                service.notes = []
                return
            }
            Task { await service.loadNotes(in: id) }
        }
    }

    // MARK: - Detail stack

    private var detailStack: some View {
        NavigationStack {
            noteList
                .navigationTitle(selectedFolderName)
                .navigationDestination(for: AppleNotesNote.self) { note in
                    noteDetailView(for: note)
                }
        }
    }

    private var selectedFolderName: String {
        service.folders.first { $0.id == selectedFolderID }?.name ?? "Notes"
    }

    // MARK: - Note list

    private var noteList: some View {
        List {
            Section {
                if service.notes.isEmpty {
                    Text(selectedFolderID == nil ? "Select a folder" : "No notes")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    ForEach(service.notes) { note in
                        NavigationLink(value: note) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(note.name)
                                        .lineLimit(1)
                                    if let modified = note.modified {
                                        Text(modified, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(service.status != .authorized || selectedFolderID == nil)
            }
        }
    }

    // MARK: - Note detail

    private func noteDetailView(for note: AppleNotesNote) -> some View {
        ScrollView {
            Text(noteBody)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(note.name)
        .task {
            await loadBody(for: note)
        }
    }

    // MARK: - Create sheet

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Apple Note").font(.title3.bold())
            Form {
                TextField("Title", text: $newNoteTitle)
                TextEditor(text: $newNoteBody)
                    .frame(minHeight: 120)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    showCreateSheet = false
                    resetCreateForm()
                }
                Button("Create") {
                    Task { await createNote() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newNoteTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 460, height: 280)
    }

    // MARK: - Actions

    private func loadBody(for note: AppleNotesNote) async {
        isLoadingBody = true
        defer { isLoadingBody = false }
        do {
            noteBody = try await service.loadBody(for: note.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createNote() async {
        let title = newNoteTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            try await service.createNote(
                title: title,
                body: newNoteBody,
                in: selectedFolderID
            )
            showCreateSheet = false
            resetCreateForm()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resetCreateForm() {
        newNoteTitle = ""
        newNoteBody = ""
    }
}

#Preview {
    AppleNotesView()
}
