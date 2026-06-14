import SwiftUI
import AppKit

enum SwiftMaestroSettingsStore {
    private static let allowedModelsKey = "settings.models.allowedModels"
    private static let authorizedFoldersKey = "settings.context.authorizedFolders"
    private static let filesInMemoryKey = "settings.context.filesInMemory"
    private static let lastImportDateKey = "settings.context.lastImportDate"
    private static let mcpServersKey = "settings.mcp.servers"
    private static let agentRulesKey = "settings.rules.agentRules"

    static func loadAllowedModels() -> [String] {
        UserDefaults.standard.stringArray(forKey: allowedModelsKey) ?? []
    }

    static func saveAllowedModels(_ models: [String]) {
        UserDefaults.standard.set(models, forKey: allowedModelsKey)
    }

    static func loadAuthorizedFolders() -> [AuthorizedFolder] {
        guard
            let data = UserDefaults.standard.data(forKey: authorizedFoldersKey),
            let folders = try? JSONDecoder().decode([AuthorizedFolder].self, from: data)
        else {
            return [
                AuthorizedFolder(path: "~/.ai-context", enabled: true),
                AuthorizedFolder(path: NSHomeDirectory() + "/GitHub", enabled: true),
            ]
        }
        return folders
    }

    static func saveAuthorizedFolders(_ folders: [AuthorizedFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: authorizedFoldersKey)
        }
    }

    static func loadFilesInMemory() -> Int {
        UserDefaults.standard.integer(forKey: filesInMemoryKey)
    }

    static func saveFilesInMemory(_ count: Int) {
        UserDefaults.standard.set(count, forKey: filesInMemoryKey)
    }

    static func loadLastImportDate() -> String {
        UserDefaults.standard.string(forKey: lastImportDateKey) ?? ""
    }

    static func saveLastImportDate(_ value: String) {
        UserDefaults.standard.set(value, forKey: lastImportDateKey)
    }

    static func loadMCPServers() -> [MCPServerEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: mcpServersKey),
            let servers = try? JSONDecoder().decode([MCPServerEntry].self, from: data)
        else {
            return MCPServerEntry.defaults
        }
        return servers
    }

    static func saveMCPServers(_ servers: [MCPServerEntry]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: mcpServersKey)
        }
    }

    static func loadRules() -> [AgentRule] {
        guard
            let data = UserDefaults.standard.data(forKey: agentRulesKey),
            let rules = try? JSONDecoder().decode([AgentRule].self, from: data)
        else {
            return AgentRule.defaults
        }
        return rules
    }

    static func saveRules(_ rules: [AgentRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: agentRulesKey)
        }
    }
}

struct SettingsView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine

    var body: some View {
        TabView {
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
            TuningSettingsTab()
                .tabItem { Label("Tuning", systemImage: "slider.horizontal.3") }
            RulesSettingsTab()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            ContextSettingsTab()
                .tabItem { Label("Context", systemImage: "folder") }
            MCPSettingsTab()
                .tabItem { Label("MCP", systemImage: "server.rack") }
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            SecretsSettingsTab()
                .tabItem { Label("Secrets", systemImage: "key.fill") }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 680, idealHeight: 760)
        #if os(macOS)
        .background(
            WindowSizeConfigurator(
                minSize: CGSize(width: 620, height: 680),
                defaultSize: CGSize(width: 720, height: 760)
            )
        )
        #endif
    }
}

// MARK: - Storage tab (Plans & Todos)

/// Shows where the live Todo checklists and Plan documents are stored on disk,
/// with quick access to reveal them in Finder.
struct StorageSettingsTab: View {
    @State private var todoCount = 0
    @State private var planCount = 0

    private var root: URL { WorkspaceStore.appSupportDir() }
    private var todosDir: URL { root.appendingPathComponent("todos", isDirectory: true) }
    private var plansDir: URL { root.appendingPathComponent("plans", isDirectory: true) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Storage Locations") {
                    VStack(alignment: .leading, spacing: 12) {
                        locationRow("Data folder", root,
                            subtitle: "All SwiftMaestro app data")
                        Divider()
                        locationRow("Todos", todosDir,
                            subtitle: "\(todoCount) checklist file(s) — one JSON per agent")
                        Divider()
                        locationRow("Plans", plansDir,
                            subtitle: "\(planCount) scope file(s) — per agent + per project, each plan also mirrored as .md")
                    }
                    .padding(8)
                }
                GroupBox("About") {
                    Text("Todos are a per-agent live checklist. Plans are markdown design "
                        + "documents scoped either to an agent (personal) or a project (shared). "
                        + "Each plan is mirrored as a .md file for easy viewing in Finder or Obsidian.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                Spacer()
            }
            .padding()
        }
        .onAppear { refresh() }
    }

    @ViewBuilder
    private func locationRow(_ title: String, _ url: URL, subtitle: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.bold())
                Text(url.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal in Finder") {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .font(.caption)
        }
    }

    private func refresh() {
        todoCount = jsonCount(todosDir)
        planCount = jsonCount(plansDir)
    }

    private func jsonCount(_ dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.count ?? 0
    }
}

// MARK: - Secrets tab

struct SecretsSettingsTab: View {
    @State private var secrets: [SecretMetadata] = []
    @State private var showingAdd = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Stored Secrets") {
                    VStack(alignment: .leading, spacing: 10) {
                        if secrets.isEmpty {
                            Text("No secrets stored yet. Add a token below; the agent references it by name and never sees the raw value.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(secrets) { meta in
                            HStack(alignment: .top) {
                                Image(systemName: "key.fill").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meta.name).font(.body.bold())
                                    HStack(spacing: 8) {
                                        scopeBadge(meta)
                                        if meta.synced {
                                            Label("iCloud", systemImage: "icloud")
                                                .font(.caption2).foregroundStyle(.blue)
                                        }
                                        Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let used = meta.lastUsedAt {
                                        Text("last used \(used.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) { delete(meta) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            Divider()
                        }
                        let projects = Set(secrets.compactMap { $0.projectId }).sorted()
                        if !projects.isEmpty {
                            ForEach(projects, id: \.self) { pid in
                                HStack {
                                    Text("Project scope: \(pid)").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Purge project secrets", role: .destructive) { purge(pid) }
                                        .font(.caption)
                                }
                            }
                        }
                        HStack {
                            Button("Add Secret") { showingAdd = true }
                            Spacer()
                            if let errorMessage {
                                Text(errorMessage).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(8)
                }
                GroupBox("How secrets are used") {
                    Text("Reference a secret anywhere a token is needed as secret://<name>. SwiftMaestro and sibling agents (via ai-context-bridge) resolve it from the Keychain at the moment of the request \u{2014} the value is never written to chat history, logs, or the shared memory store.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(8)
                }
                Spacer()
            }
            .padding()
        }
        .onAppear { reload() }
        .sheet(isPresented: $showingAdd) {
            AddSecretSheet { name, value, scope, synced, note in
                add(name: name, value: value, scope: scope, synced: synced, note: note)
            }
        }
    }

    @ViewBuilder
    private func scopeBadge(_ meta: SecretMetadata) -> some View {
        switch meta.scope {
        case .global:
            Label("Permanent", systemImage: "globe").font(.caption2).foregroundStyle(.green)
        case .project(let id):
            Label("Project: \(id)", systemImage: "folder").font(.caption2).foregroundStyle(.purple)
        }
    }

    private func reload() {
        secrets = SecretsStore.listMetadata().sorted { $0.name < $1.name }
    }

    private func add(name: String, value: String, scope: SecretScope, synced: Bool, note: String?) {
        do {
            try SecretsStore.upsert(name: name, value: value, scope: scope, synced: synced, note: note)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ meta: SecretMetadata) {
        do { try SecretsStore.delete(meta); reload() }
        catch { errorMessage = error.localizedDescription }
    }

    private func purge(_ projectId: String) {
        do { try SecretsStore.purgeProject(projectId); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct AddSecretSheet: View {
    enum ScopeChoice: String, CaseIterable, Identifiable {
        case permanent, project
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var scopeChoice: ScopeChoice = .permanent
    @State private var projectId = ""
    @State private var syncAcrossMacs = true
    @State private var note = ""

    let onSave: (String, String, SecretScope, Bool, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Secret").font(.title3.bold())
            Form {
                TextField("Name (e.g. github_token)", text: $name)
                SecureField("Value (paste token)", text: $value)
                Picker("Scope", selection: $scopeChoice) {
                    Text("Permanent (all projects)").tag(ScopeChoice.permanent)
                    Text("This project only").tag(ScopeChoice.project)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: scopeChoice) { _, newValue in
                    syncAcrossMacs = (newValue == .permanent)
                }
                if scopeChoice == .project {
                    TextField("Project name", text: $projectId)
                }
                Toggle("Sync across my Macs (iCloud Keychain)", isOn: $syncAcrossMacs)
                TextField("Note (optional)", text: $note)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let scope: SecretScope = scopeChoice == .project
                        ? .project(projectId.trimmingCharacters(in: .whitespaces))
                        : .global
                    onSave(name, value, scope, syncAcrossMacs, note.isEmpty ? nil : note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.isEmpty
            && (scopeChoice == .permanent || !projectId.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

struct ModelsSettingsTab: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine
    @AppStorage("models.localRoot") private var modelsRoot: String = ""
    @State private var hubModelID: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Inference") {
                    Text("All generation runs fully on-device via Apple MLX (mlx-swift-lm). No server, no external runtime.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                GroupBox("Resident Models (loaded in memory)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("~\(engine.residentUsedBytes / 1_073_741_824) GB of ~\(engine.residentBudgetBytes / 1_073_741_824) GB budget used (reserves 10% of system RAM for the OS). Models stay loaded for instant switching; the least-recently-used is evicted only when a new model won't fit.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let list = engine.residentModelsReadout
                        if list.isEmpty {
                            Text("No models loaded yet.").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(list) { item in
                                HStack {
                                    Text(item.name).font(.caption)
                                    Spacer()
                                    Text("~\(item.gb) GB").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                GroupBox("Models folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Where MLX models are stored and downloaded. Defaults to this app's Application Support folder (portable to any Mac). Set a custom path to use an existing collection. Relaunch to apply.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField(ModelCatalog.modelsRoot, text: $modelsRoot)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(8)
                }
                GroupBox("MLX Models (download from Hugging Face on first use)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(catalog.models) { model in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.displayName).font(.body.bold())
                                    Text(model.huggingFaceID).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("~\(model.estimatedMemoryGB)GB").font(.caption).foregroundStyle(.secondary)
                                if model.isVision {
                                    Image(systemName: "eye").foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 2)
                            Divider()
                        }
                        HStack {
                            TextField("Hub ID (e.g. mlx-community/Qwen3-8B-4bit)", text: $hubModelID)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                guard !hubModelID.isEmpty else { return }
                                let name = hubModelID.components(separatedBy: "/").last ?? hubModelID
                                catalog.addHubModel(name: name, huggingFaceID: hubModelID, isVision: false, memoryGB: 4)
                                hubModelID = ""
                            }
                            .disabled(hubModelID.isEmpty)
                        }
                    }
                    .padding(8)
                }
                Spacer()
            }
            .padding()
        }
    }
}

/// Per-model sampling. A model picker scopes every slider to one model, so it's
/// always clear WHICH model is being tuned. Values default to that model's
/// recommended sampling and are saved per `model.id`; "Reset to recommended"
/// clears the override. The generation path reads the same values via
/// `MaestroModel.tuned*`, so chat honours exactly what's shown here.
struct TuningSettingsTab: View {
    @Environment(ModelCatalog.self) private var catalog
    /// Thinking/reasoning isn't a per-model recommended value, so it stays a
    /// global toggle (clearly labelled "all models" below).
    @AppStorage("tuning.enableThinking") private var enableThinking: Bool = false

    @State private var selectedModelID: String = ""
    @State private var temperature: Double = 1.0
    @State private var topP: Double = 0.95
    @State private var repetitionPenalty: Double = 1.05

    private var model: MaestroModel? {
        catalog.models.first { $0.id == selectedModelID } ?? catalog.selectedModel
    }
    private var recTemp: Double { model?.recTemperature ?? 1.0 }
    private var recTopP: Double { model?.recTopP ?? 0.95 }
    private var recRepPen: Double { model?.recRepetitionPenalty ?? 1.05 }
    private var hasOverride: Bool {
        isCustom(temperature, recTemp) || isCustom(topP, recTopP)
            || isCustom(repetitionPenalty, recRepPen)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Model") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Tuning for", selection: $selectedModelID) {
                            ForEach(catalog.models) { m in Text(m.displayName).tag(m.id) }
                        }
                        Text("Sampling below is saved for this model and applies wherever it runs — for every agent that uses it. Each model keeps its own values.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Sampling — \(model?.displayName ?? "model")") {
                    VStack(spacing: 14) {
                        sliderRow("Temperature", $temperature, range: 0...2, step: 0.05,
                                  recommended: recTemp, param: "temperature")
                        sliderRow("Top-P", $topP, range: 0...1, step: 0.05,
                                  recommended: recTopP, param: "topP")
                        sliderRow("Repetition Penalty", $repetitionPenalty, range: 1...1.5, step: 0.01,
                                  recommended: recRepPen, param: "repetitionPenalty")
                        HStack {
                            Spacer()
                            Button("Reset to recommended") { resetToRecommended() }
                                .disabled(!hasOverride)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Generation (all models)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Enable thinking / reasoning", isOn: $enableThinking)
                        Text("Lets models that support it reason step-by-step before answering. Applies to every model.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
                Spacer()
            }
            .padding()
        }
        .onAppear {
            if selectedModelID.isEmpty {
                selectedModelID = catalog.selectedModel?.id ?? catalog.models.first?.id ?? ""
            }
            loadValues()
        }
        .onChange(of: selectedModelID) { _, _ in loadValues() }
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String, _ value: Binding<Double>,
        range: ClosedRange<Double>, step: Double, recommended: Double, param: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).frame(width: 150, alignment: .leading)
                Slider(value: value, in: range, step: step, onEditingChanged: { editing in
                    if !editing {
                        UserDefaults.standard.set(
                            value.wrappedValue,
                            forKey: MaestroModel.tuningKey(selectedModelID, param))
                    }
                })
                Text(fmt(value.wrappedValue)).monospacedDigit().frame(width: 46)
            }
            Text(isCustom(value.wrappedValue, recommended)
                 ? "Custom · recommended \(fmt(recommended))"
                 : "Using model recommended (\(fmt(recommended)))")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadValues() {
        guard let model else { return }
        let d = UserDefaults.standard
        temperature = (d.object(forKey: MaestroModel.tuningKey(model.id, "temperature")) as? Double)
            ?? (model.recTemperature ?? 1.0)
        topP = (d.object(forKey: MaestroModel.tuningKey(model.id, "topP")) as? Double)
            ?? (model.recTopP ?? 0.95)
        repetitionPenalty = (d.object(forKey: MaestroModel.tuningKey(model.id, "repetitionPenalty")) as? Double)
            ?? (model.recRepetitionPenalty ?? 1.05)
    }

    private func resetToRecommended() {
        let d = UserDefaults.standard
        for p in ["temperature", "topP", "repetitionPenalty"] {
            d.removeObject(forKey: MaestroModel.tuningKey(selectedModelID, p))
        }
        loadValues()
    }

    private func isCustom(_ value: Double, _ recommended: Double) -> Bool {
        abs(value - recommended) > 0.0001
    }
    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

struct RulesSettingsTab: View {
    @State private var rules: [AgentRule] = []
    @State private var selectedScope: String = "All"
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Agent Rules") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Scope")
                            Picker("", selection: $selectedScope) {
                                Text("All Agents").tag("All")
                                ForEach(Agent.defaultAgentNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .frame(width: 200)
                        }
                        Text(selectedScope == "All"
                             ? "Rules applied to every agent."
                             : "Rules applied to \(selectedScope), in addition to All Agents rules.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        if !rules.contains(where: { $0.scope == selectedScope }) {
                            Text("No rules yet. Add a rule below; enabled rules are injected as a system instruction at the start of each conversation.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach($rules) { $rule in
                            if rule.scope == selectedScope {
                                HStack(alignment: .top) {
                                    Toggle("", isOn: $rule.enabled).labelsHidden()
                                    TextField("Rule text", text: $rule.text, axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(1...6)
                                    Button { rules.removeAll { $0.id == rule.id } } label: {
                                        Image(systemName: "trash").foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Button {
                            rules.append(AgentRule(text: "", enabled: true, scope: selectedScope))
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                        }
                    }
                    .padding(8)
                }
                Spacer()
                HStack {
                    if let saveMessage {
                        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Settings") {
                        let cleaned = rules.filter {
                            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
                        }
                        SwiftMaestroSettingsStore.saveRules(cleaned)
                        rules = cleaned
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
        .onAppear {
            rules = SwiftMaestroSettingsStore.loadRules()
        }
    }
}

struct ContextSettingsTab: View {
    @State private var selectedAgent: String = "All"
    @State private var authorizedFolders: [AuthorizedFolder] = []
    @State private var newFolderPath: String = ""
    @State private var importScope: String = "Navigator (parent)"
    @State private var importFolderPath: String = ""
    @State private var importStatus: String = ""
    @State private var filesInMemory: Int = 0
    @State private var lastImportDate: String = ""
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Authorized Folders") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Agent")
                            Picker("", selection: $selectedAgent) {
                                Text("All Agents").tag("All")
                                ForEach(Agent.defaultAgentNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .frame(width: 150)
                        }
                        ForEach($authorizedFolders) { $folder in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                                Text(folder.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Toggle("", isOn: $folder.enabled).labelsHidden()
                                Button { authorizedFolders.removeAll { $0.id == folder.id } } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            TextField("/absolute/path", text: $newFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Add Path") {
                                guard !newFolderPath.isEmpty else { return }
                                authorizedFolders.append(AuthorizedFolder(path: newFolderPath, enabled: true))
                                newFolderPath = ""
                            }
                        }
                        Text(importStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
                GroupBox("Import Folder Into Memory (v2)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Scope")
                            Picker("", selection: $importScope) {
                                Text("Navigator (parent)").tag("Navigator (parent)")
                                Text("Agent project (child)").tag("Agent project (child)")
                            }
                            .pickerStyle(.segmented)
                        }
                        HStack {
                            TextField("/absolute/path", text: $importFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Import Folder") {
                                importStatus = "Importing..."
                            }
                        }
                        if filesInMemory > 0 {
                            Text("\(filesInMemory) file(s) in memory — \(lastImportDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                Spacer()
                HStack {
                    if let saveMessage {
                        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Settings") {
                        SwiftMaestroSettingsStore.saveAuthorizedFolders(authorizedFolders)
                        SwiftMaestroSettingsStore.saveFilesInMemory(filesInMemory)
                        SwiftMaestroSettingsStore.saveLastImportDate(lastImportDate)
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
        .onAppear {
            authorizedFolders = SwiftMaestroSettingsStore.loadAuthorizedFolders()
            filesInMemory = SwiftMaestroSettingsStore.loadFilesInMemory()
            lastImportDate = SwiftMaestroSettingsStore.loadLastImportDate()
        }
    }
}

struct MCPSettingsTab: View {
    @State private var servers: [MCPServerEntry] = []
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach($servers) { $server in
                    MCPServerRow(server: $server, onDelete: {
                        servers.removeAll { $0.id == server.id }
                    })
                }
                Button {
                    servers.append(MCPServerEntry(name: "new-server", command: "/opt/homebrew/bin/node", scriptPath: "", env: "", workingDir: "", timeout: 8, enabled: false))
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                Spacer()
                HStack {
                    if let saveMessage {
                        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Settings") {
                        SwiftMaestroSettingsStore.saveMCPServers(servers)
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
        .onAppear {
            servers = SwiftMaestroSettingsStore.loadMCPServers()
        }
    }
}

struct MCPServerRow: View {
    @Binding var server: MCPServerEntry
    var onDelete: () -> Void
    @State private var showFields: Bool = true

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(server.enabled ? .green : .gray).frame(width: 8, height: 8)
                    TextField("Server name", text: $server.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Spacer()
                    Toggle("", isOn: $server.enabled).labelsHidden()
                    Button { onDelete() } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    Text("Advertise tools to:")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Chat agents", isOn: Binding(
                        get: { server.advertisesToAgents },
                        set: { server.advertise = $0 }
                    ))
                    Toggle("Delegated sub-agents", isOn: Binding(
                        get: { server.advertisesToDelegates },
                        set: { server.advertiseToSubAgents = $0 }
                    ))
                    Spacer()
                }
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("Untick to keep the server connected but leave its tools out of "
                    + "the prompt for that audience. Fewer advertised tools = smaller "
                    + "prompt = faster prefill. Applies from the next message.")
                HStack {
                    Button("Fields") { showFields = true }
                        .buttonStyle(.bordered)
                        .tint(showFields ? .blue : .gray)
                    Button("Snippet") { showFields = false }
                        .buttonStyle(.bordered)
                        .tint(!showFields ? .blue : .gray)
                }
                if showFields {
                    TextField("Command", text: $server.command).textFieldStyle(.roundedBorder)
                    TextField("Script path", text: $server.scriptPath).textFieldStyle(.roundedBorder)
                    TextField("Arguments (one per line; overrides script path)", text: Binding(
                        get: { (server.args ?? []).joined(separator: "\n") },
                        set: { newValue in
                            let parts = newValue
                                .split(separator: "\n", omittingEmptySubsequences: true)
                                .map(String.init)
                            server.args = parts.isEmpty ? nil : parts
                        }
                    ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    TextField("Env", text: $server.env).textFieldStyle(.roundedBorder)
                    TextField("Working directory", text: $server.workingDir).textFieldStyle(.roundedBorder)
                }
            }
            .padding(6)
        }
    }
}

struct AuthorizedFolder: Identifiable, Codable {
    var id: UUID = UUID()
    var path: String
    var enabled: Bool
}

/// A single behavioral rule for an agent. `scope` is either "All" (applies to
/// every agent) or a specific agent name.
struct AgentRule: Identifiable, Codable {
    var id: UUID = UUID()
    var text: String
    var enabled: Bool
    var scope: String

    /// Starter rules shown in the Rules tab and injected into the system prompt.
    /// These are user-editable; deleting or toggling them only affects the soft
    /// guidance layer — the hard anti-fabrication safety rules live in code and
    /// always apply. "All" rules apply to every agent; named scopes add on top.
    static let defaults: [AgentRule] = [
        AgentRule(text: "When a question can be answered with a tool you have, call "
            + "that tool instead of guessing or telling the user to do it themselves "
            + "(e.g. use execute_command for shell/system info, memory tools for "
            + "stored context, CrawlKit for web content).", enabled: true, scope: "All"),
        AgentRule(text: "Never claim you ran a command, created a file, or performed "
            + "any action unless a real tool result confirms it. If a tool returns "
            + "nothing, say exactly that — do not invent output.", enabled: true, scope: "All"),
        AgentRule(text: "After using a tool, report what it actually returned, then "
            + "answer the user's question based on that real result.", enabled: true, scope: "All"),
        AgentRule(text: "Be concise and direct. Skip filler, preamble, and repeated "
            + "disclaimers.", enabled: true, scope: "All"),
        AgentRule(text: "This is a self-hosted, offline-first macOS assistant. Prefer "
            + "the user's local models, files, and tools over external services.", enabled: true, scope: "All"),
        AgentRule(text: "If a request is ambiguous, ask one short clarifying question "
            + "instead of assuming.", enabled: true, scope: "All"),
        AgentRule(text: "Default to Swift for macOS/iOS work; do not assume Python or "
            + "any other language unless the user specifies it.", enabled: true, scope: "Coding"),
        AgentRule(text: "Provide complete, runnable code and explain only the "
            + "non-obvious parts.", enabled: true, scope: "Coding"),
    ]
}

struct MCPServerEntry: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var command: String
    var scriptPath: String
    var env: String
    var workingDir: String
    var timeout: Int
    var enabled: Bool
    /// Explicit argument vector passed to `command` verbatim. Needed for servers
    /// that take subcommands (e.g. `cli.js mcp`) or multiple args, which a single
    /// `scriptPath` can't express. When nil/empty the launcher falls back to
    /// `[scriptPath]`. Optional so older persisted configs still decode.
    var args: [String]? = nil
    /// Whether this server's tools are advertised to interactive chats (Navigator
    /// and project agents). Tool specs dominate the prompt — and on hybrid-cache
    /// models every fresh round re-prefills it all — so trimming exposure here
    /// directly cuts per-turn latency. Optional (nil = true) so older persisted
    /// configs still decode. The server stays connected either way; this only
    /// controls advertisement, so changes apply from the next message.
    var advertise: Bool? = nil
    /// Same as `advertise`, but for DELEGATED sub-agent runs (ask_project_agent/s).
    /// Sub-agents usually need memory/plan tools, not the full tool surface.
    var advertiseToSubAgents: Bool? = nil

    var advertisesToAgents: Bool { advertise ?? true }
    var advertisesToDelegates: Bool { advertiseToSubAgents ?? true }

    static let xcodeBuildMCPPath =
        NSHomeDirectory() + "/GitHub/AI-ML-Agents/XcodeBuildMCP"

    static let defaults: [MCPServerEntry] = [
        MCPServerEntry(name: "ai-context-bridge", command: "/opt/homebrew/bin/node", scriptPath: "~/.ai-context/mcp-server/server.js", env: "", workingDir: "~/Library/Mobile Documents/com~apple~CloudDocs/.ai-context", timeout: 8, enabled: true),
        MCPServerEntry(name: "crawlkit-mcp", command: "/opt/homebrew/bin/node", scriptPath: "~/.ai-context/mcp-crawlkit/server.js", env: "", workingDir: "", timeout: 8, enabled: true),
        MCPServerEntry(name: "xcodebuildmcp", command: "/opt/homebrew/bin/node", scriptPath: "\(xcodeBuildMCPPath)/build/cli.js", env: "XCODEBUILDMCP_ENABLED_WORKFLOWS=session-management,project-discovery,macos,simulator,utilities", workingDir: xcodeBuildMCPPath, timeout: 15, enabled: true, args: ["\(xcodeBuildMCPPath)/build/cli.js", "mcp"]),
        MCPServerEntry(name: "firecrawl-mcp", command: "/opt/homebrew/bin/node", scriptPath: "", env: "", workingDir: "", timeout: 8, enabled: false),
        MCPServerEntry(name: "playwright", command: "/opt/homebrew/bin/node", scriptPath: "", env: "", workingDir: "", timeout: 8, enabled: false),
    ]
}
