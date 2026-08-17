import SwiftUI
import AppKit

struct AppleNotesView: View {
    @Environment(AppleNotesService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var selectedFolderID: String?
    @State private var noteBody: AttributedString = AttributedString()
    @State private var isLoadingBody = false
    @State private var showCreateSheet = false
    @State private var newNoteTitle = ""
    @State private var newNoteBody = ""
    @State private var error: String?
    /// Drag-resizable folder list width, persisted like any other docked pane.
    /// Backed by `@AppStorage` (a `Double`) since this is a single view-local
    /// divider, not a multi-panel-type layout — no need to route it through
    /// `PanelLayoutState` for just one width.
    @AppStorage("appleNotes.folderListWidth") private var folderListWidth = 220.0

    var body: some View {
        ResizablePanelHost(panes: [
            ResizablePane(
                id: "folders",
                length: Binding(get: { CGFloat(folderListWidth) }, set: { folderListWidth = Double($0) }),
                minLength: 180,
                maxLength: 340
            ) {
                folderList
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
        VStack(spacing: 0) {
            folderListHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

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
        }
        .onChange(of: selectedFolderID) { _, newValue in
            guard let id = newValue else {
                service.notes = []
                return
            }
            Task { await service.loadNotes(in: id) }
        }
    }

    private var folderListHeader: some View {
        HStack {
            Text("Apple Notes")
                .font(.headline)
            Spacer()
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
                .buttonStyle(.plain)
                .help("Refresh folders")
            }
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
                .textSelection(.enabled)
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
            noteBody = Self.renderHTML(try await service.loadBody(for: note.id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Apple Notes bodies are HTML — render them as formatted content instead of
    /// dumping raw tags into a Text view. The HTML importer returns web-default
    /// serif fonts and black text, so normalize to the system font (preserving
    /// bold/italic traits and relative sizes) and the label color to read as
    /// native app content on any theme. Falls back to the raw string if parsing
    /// fails — never worse than showing nothing.
    private static func renderHTML(_ html: String) -> AttributedString {
        guard let data = html.data(using: .utf8),
              let parsed = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil)
        else {
            return AttributedString(html)
        }

        let rendered = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: rendered.length)

        rendered.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let nsFont = value as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            var descriptor = NSFont.systemFont(ofSize: nsFont.pointSize).fontDescriptor
            let traits = nsFont.fontDescriptor.symbolicTraits
            if traits.contains(.bold) {
                descriptor = descriptor.withSymbolicTraits(.bold)
            }
            if traits.contains(.italic) {
                descriptor = descriptor.withSymbolicTraits(.italic)
            }
            rendered.addAttribute(
                .font,
                value: NSFont(descriptor: descriptor, size: nsFont.pointSize) ?? nsFont,
                range: range)
        }
        rendered.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        return AttributedString(rendered)
    }

    private func createNote() async {
        let title = newNoteTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            try await service.createNote(
                title: title,
                body: Self.escapePlainTextForNotes(newNoteBody),
                in: selectedFolderID
            )
            showCreateSheet = false
            resetCreateForm()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Notes stores bodies as HTML — escape user-entered plain text so literal
    /// `<`/`&` don't break the markup, and keep line breaks visible.
    private static func escapePlainTextForNotes(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private func resetCreateForm() {
        newNoteTitle = ""
        newNoteBody = ""
    }
}

#Preview {
    AppleNotesView()
}
