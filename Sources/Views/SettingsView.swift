import SwiftUI

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
                AuthorizedFolder(path: "~/GitHub", enabled: true),
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
    @Environment(OMLXServerManager.self) private var serverManager
    @AppStorage("models.endpointURL") private var endpointURL: String = "http://localhost:8012"
    @AppStorage("models.modelID") private var modelID: String = "Qwen3.6-35B-A3B-MLX-4bit"
    @AppStorage("models.allowSub70B") private var allowSub70B: Bool = true
    @AppStorage("models.requiresAPIKey") private var requiresAPIKey: Bool = false
    @State private var connectionStatus: String = "Connection not checked yet."
    @State private var connectionOK: Bool? = nil
    @State private var allowedModels: [String] = []
    @State private var hubModelID: String = ""
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Default LLM Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Selected backend default endpoint: \(endpointURL)")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Endpoint URL") {
                            TextField("http://localhost:8012", text: $endpointURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Model ID") {
                            TextField("e.g. mlx-community/Qwen3-8B-4bit", text: $modelID)
                                .textFieldStyle(.roundedBorder)
                        }
                        if let tier = ModelTierPolicy.extractTierB(from: modelID) {
                            Text("Detected model tier: \(tier, specifier: "%.1f")B")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if ModelTierPolicy.isBelowPreferredTier(modelID), !allowSub70B {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sub-70B model detected. Current policy prefers 70B+ for reliability.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                Button("Use recommended 122B model") {
                                    modelID = ModelTierPolicy.recommendedModelID
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        HStack {
                            Button("Add Current Model to Allow List") {
                                if !modelID.isEmpty && !allowedModels.contains(modelID) {
                                    allowedModels.append(modelID)
                                }
                            }
                            Button("Clear Allow List") { allowedModels.removeAll() }
                        }
                        if !allowedModels.isEmpty {
                            Text("Allowed Models").font(.caption.bold())
                            ForEach(allowedModels, id: \.self) { m in
                                Text(m).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Discover Models") {}
                        Divider()
                        HStack {
                            Circle()
                                .fill(connectionOK == true ? .green : connectionOK == false ? .red : .gray)
                                .frame(width: 8, height: 8)
                            Text(connectionStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Toggle("Requires API Key", isOn: $requiresAPIKey)
                            Spacer()
                            Button("Test Connection") { testConnection() }
                        }
                        Toggle("Allow models below 70B", isOn: $allowSub70B)
                    }
                    .padding(8)
                }
                GroupBox("Built-in MLX Models (download on first use)") {
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
                GroupBox("oMLX Startup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Auto-start oMLX on launch",
                            isOn: Binding(
                                get: { serverManager.autoStartEnabled },
                                set: { serverManager.autoStartEnabled = $0 }
                            )
                        )
                        TextField(
                            "Startup script path",
                            text: Binding(
                                get: { serverManager.startupScriptPath },
                                set: { serverManager.startupScriptPath = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Check Health") {
                                Task { _ = await serverManager.checkHealth() }
                            }
                            Button("Start Now") {
                                serverManager.ensureServerReadyOnLaunch()
                            }
                            Text(serverStatusText)
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
                        SwiftMaestroSettingsStore.saveAllowedModels(allowedModels)
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
        .onAppear {
            allowedModels = SwiftMaestroSettingsStore.loadAllowedModels()
        }
    }

    private var serverStatusText: String {
        switch serverManager.state {
        case .idle: return "idle"
        case .checking: return "checking..."
        case .launching: return "launching..."
        case .ready: return "ready"
        case .failed(let message): return "failed: \(message)"
        }
    }
    private func testConnection() {
        connectionStatus = "Testing..."
        connectionOK = nil
        guard let url = URL(string: endpointURL + "/v1/models") else {
            connectionStatus = "Invalid URL"
            connectionOK = false
            return
        }
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    connectionStatus = "Connected ✓"
                    connectionOK = true
                } else {
                    connectionStatus = "HTTP error"
                    connectionOK = false
                }
            } catch {
                connectionStatus = error.localizedDescription
                connectionOK = false
            }
        }
    }
}

struct TuningSettingsTab: View {
    @AppStorage("tuning.temperature") private var temperature: Double = 0.7
    @AppStorage("tuning.maxTokens") private var maxTokens: Int = 4096
    @AppStorage("tuning.topP") private var topP: Double = 0.9
    @AppStorage("tuning.repetitionPenalty") private var repetitionPenalty: Double = 1.05
    @AppStorage("tuning.contextBudget") private var contextBudget: Int = 18000
    @AppStorage("tuning.factBudget") private var factBudget: Int = 8000
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Sampling Parameters") {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Temperature").frame(width: 140, alignment: .leading)
                            Slider(value: $temperature, in: 0...2, step: 0.05)
                            Text(String(format: "%.2f", temperature)).monospacedDigit().frame(width: 44)
                        }
                        HStack {
                            Text("Top-P").frame(width: 140, alignment: .leading)
                            Slider(value: $topP, in: 0...1, step: 0.05)
                            Text(String(format: "%.2f", topP)).monospacedDigit().frame(width: 44)
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
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "settings.tuning.lastSavedAt")
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
    }
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

    static let xcodeBuildMCPPath =
        "~/GitHub/AI-ML-Agents/XcodeBuildMCP"

    static let defaults: [MCPServerEntry] = [
        MCPServerEntry(name: "ai-context-bridge", command: "/opt/homebrew/bin/node", scriptPath: "~/.ai-context/mcp-server/server.js", env: "", workingDir: "~/Library/Mobile Documents/com~apple~CloudDocs/.ai-context", timeout: 8, enabled: true),
        MCPServerEntry(name: "crawlkit-mcp", command: "/opt/homebrew/bin/node", scriptPath: "~/.ai-context/mcp-crawlkit/server.js", env: "", workingDir: "", timeout: 8, enabled: true),
        MCPServerEntry(name: "xcodebuildmcp", command: "/opt/homebrew/bin/node", scriptPath: "\(xcodeBuildMCPPath)/build/cli.js", env: "XCODEBUILDMCP_ENABLED_WORKFLOWS=session-management,project-discovery,macos,simulator,utilities", workingDir: xcodeBuildMCPPath, timeout: 15, enabled: true, args: ["\(xcodeBuildMCPPath)/build/cli.js", "mcp"]),
        MCPServerEntry(name: "firecrawl-mcp", command: "/opt/homebrew/bin/node", scriptPath: "", env: "", workingDir: "", timeout: 8, enabled: false),
        MCPServerEntry(name: "playwright", command: "/opt/homebrew/bin/node", scriptPath: "", env: "", workingDir: "", timeout: 8, enabled: false),
    ]
}
