import SwiftUI

/// Manual plan-creation sheet for the agent chat. Opens directly from the
/// sidebar/toolbar as a single markdown-capable editor, with no nested plan
/// browser. Users can also import plans from Apple Notes or Reminders.
struct NewPlanSheet: View {
    @Environment(PlanStore.self) private var planStore
    @Environment(\.dismiss) private var dismiss

    let agentId: UUID
    /// Project names selectable as scopes (besides the personal scope).
    let projects: [String]
    /// When set, the initially-selected scope is this project (project agents).
    let defaultProjectName: String?

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var selectedScopeKey: String
    @State private var importSheet: ImportSheet?
    /// Extra project scopes typed by the user in this sheet (not yet workspace projects).
    @State private var extraScopes: [String] = []
    @State private var showingNewScopePrompt = false
    @State private var showingScopeManagement = false
    @State private var newScopeName = ""

    init(agentId: UUID, projects: [String], defaultProjectName: String?) {
        self.agentId = agentId
        self.projects = projects
        self.defaultProjectName = defaultProjectName
        let defaultScope = defaultProjectName.map { PlanScope.project($0).key }
            ?? PlanScope.agent(agentId).key
        self._selectedScopeKey = State(initialValue: defaultScope)
    }

    private enum ImportSheet: Identifiable {
        case notes
        case reminders

        var id: String {
            switch self {
            case .notes: return "notes"
            case .reminders: return "reminders"
            }
        }
    }

    private var allProjects: [String] {
        projects + extraScopes
    }

    private var scopes: [(label: String, scope: PlanScope)] {
        var out: [(String, PlanScope)] = [("Personal", .agent(agentId))]
        out += allProjects.map { ($0, .project($0)) }
        return out
    }

    private var selectedScope: PlanScope {
        scopes.first { $0.scope.key == selectedScopeKey }?.scope ?? .agent(agentId)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 540, idealHeight: 640)
        .sheet(item: $importSheet) { source in
            switch source {
            case .notes:
                AppleNotesImportSheet { importedTitle, body in
                    applyImport(title: importedTitle, body: body)
                }
            case .reminders:
                RemindersImportSheet { importedTitle, body in
                    applyImport(title: importedTitle, body: body)
                }
            }
        }
        .alert("New Project Scope", isPresented: $showingNewScopePrompt) {
            TextField("Project name", text: $newScopeName)
            Button("Add") { addNewScope() }
            Button("Cancel", role: .cancel) { newScopeName = "" }
        } message: {
            Text("Create a new scope. The plan will be saved under this project name.")
        }
        .sheet(isPresented: $showingScopeManagement) {
            ScopeManagementSheet()
                .environment(planStore)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("New Plan")
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { createPlan() }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Plan title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                    Picker("Scope", selection: $selectedScopeKey) {
                        ForEach(scopes, id: \.scope.key) { entry in
                            Text(entry.label).tag(entry.scope.key)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Button {
                        showingNewScopePrompt = true
                    } label: {
                        Label("New Scope", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Create a new project scope for this plan")

                    Button {
                        showingScopeManagement = true
                    } label: {
                        Label("Manage", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Archive, unarchive, or delete old project scopes")
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $content)
                        .font(.body)
                        .lineSpacing(2)
                        .frame(minHeight: 260)
                    if content.isEmpty {
                        Text("Type or paste the plan body here (markdown supported)")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(16)

            Spacer(minLength: 0)

            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        importSheet = .notes
                    } label: {
                        Label("Import from Notes", systemImage: "note.text")
                    }
                    .help("Import a plan from the Apple Notes app")

                    Button {
                        importSheet = .reminders
                    } label: {
                        Label("Import from Reminders", systemImage: "checklist")
                    }
                    .help("Import reminders as a checklist plan")
                }
                .controlSize(.small)

                Spacer()

                Text("Plans are saved to your personal scope unless you choose a shared project scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(16)
        }
    }

    private func applyImport(title importedTitle: String, body: String) {
        if !importedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = importedTitle
        }
        content = body
        importSheet = nil
    }

    private func addNewScope() {
        let trimmed = newScopeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !allProjects.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            newScopeName = ""
            return
        }
        extraScopes.append(trimmed)
        selectedScopeKey = PlanScope.project(trimmed).key
        newScopeName = ""
    }

    private func createPlan() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        planStore.create(title: trimmed, content: content, in: selectedScope)
        dismiss()
    }
}

/// Imports an Apple Note into a plan.
struct AppleNotesImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = AppleNotesService()
    @State private var selectedFolderID: String?
    @State private var selectedNoteID: String?
    @State private var isLoadingBody = false
    @State private var error: String?

    let onImport: (_ title: String, _ body: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Import from Notes")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if service.status == .denied {
                deniedView(what: "Apple Notes")
            } else if service.folders.isEmpty && service.isLoading {
                Spacer()
                ProgressView("Loading folders…")
                Spacer()
            } else {
                browser
            }
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .task {
            await service.loadIfPreviouslyAuthorized()
            if service.folders.isEmpty {
                await service.loadFolders()
            }
        }
    }

    private var browser: some View {
        HStack(spacing: 0) {
            List(service.folders, selection: $selectedFolderID) { folder in
                Text(folder.name)
                    .tag(folder.id)
            }
            .frame(width: 200)
            Divider()
            List(service.notes, selection: $selectedNoteID) { note in
                Text(note.name)
                    .tag(note.id)
            }
            .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                Spacer()
                if isLoadingBody {
                    ProgressView("Loading note…")
                } else {
                    Text("Select a note to import its title and body as a plan.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
                Spacer()
                Divider()
                HStack {
                    Spacer()
                    Button("Import Selected") { importSelected() }
                        .disabled(selectedNoteID == nil || isLoadingBody)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .task(id: selectedFolderID) {
            guard let folderID = selectedFolderID else { return }
            await service.loadNotes(in: folderID)
        }
        .alert("Import Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func importSelected() {
        guard let noteID = selectedNoteID else { return }
        guard let note = service.notes.first(where: { $0.id == noteID }) else { return }
        isLoadingBody = true
        Task {
            do {
                let body = try await service.loadBody(for: noteID)
                await MainActor.run {
                    isLoadingBody = false
                    onImport(note.name, body)
                }
            } catch {
                await MainActor.run {
                    isLoadingBody = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func deniedView(what: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("\(what) access is denied.")
                .font(.headline)
            Text("Grant access in System Settings → Privacy & Security → Automation, then try again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Privacy Settings") {
                MacOSIntegration.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Imports a Reminders list into a plan (incomplete reminders become a markdown
/// checklist). Lets the user pick a list and optionally edit the generated title.
struct RemindersImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = EventKitStore()
    @State private var selectedListID: String?
    @State private var importedTitle: String = ""
    @State private var isLoading = false

    let onImport: (_ title: String, _ body: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Import from Reminders")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if store.remindersStatus == .denied || store.remindersStatus == .restricted {
                deniedView(what: "Reminders")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose a reminders list. Incomplete reminders become a markdown checklist.")
                        .foregroundStyle(.secondary)

                    Picker("List", selection: $selectedListID) {
                        Text("All lists").tag(nil as String?)
                        ForEach(store.reminderLists, id: \.id) { list in
                            Text(list.title).tag(list.id as String?)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Plan title", text: $importedTitle)
                        .textFieldStyle(.roundedBorder)

                    Spacer(minLength: 0)
                }
                .padding(16)

                Divider()
                HStack {
                    Spacer()
                    Button("Import") { importSelected() }
                        .disabled(selectedListID == nil || isLoading)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 320, idealHeight: 380)
        .task {
            store.refreshAuthorization()
            if store.remindersStatus == .notDetermined {
                await store.requestRemindersAccess()
            }
            if store.remindersStatus == .granted {
                await store.loadReminderLists()
                if let first = store.reminderLists.first(where: { $0.isDefault }) ?? store.reminderLists.first {
                    selectedListID = first.id
                    importedTitle = "Reminders: \(first.title)"
                }
            }
        }
        .task(id: selectedListID) {
            guard store.remindersStatus == .granted else { return }
            isLoading = true
            await store.loadReminders(listName: selectedListTitle)
            isLoading = false
        }
    }

    private var selectedListTitle: String? {
        store.reminderLists.first { $0.id == selectedListID }?.title
    }

    private func importSelected() {
        let incomplete = store.reminders.filter { !$0.isCompleted }
        let lines = incomplete.map { "- [ ] \($0.title)" }
        let body = lines.isEmpty ? "_No incomplete reminders in this list._" : lines.joined(separator: "\n")
        let title = importedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (selectedListTitle ?? "Reminders")
            : importedTitle
        onImport(title, body)
    }

    private func deniedView(what: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("\(what) access is denied.")
                .font(.headline)
            Text("Grant access in System Settings → Privacy & Security → Reminders, then try again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Privacy Settings") {
                MacOSIntegration.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
