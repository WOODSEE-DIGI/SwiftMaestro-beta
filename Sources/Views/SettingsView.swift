import SwiftUI

// MARK: - Settings View (4-tab layout matching original SwiftMaestro)

struct SettingsView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine

    var body: some View {
        TabView {
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
            TuningSettingsTab()
                .tabItem { Label("Tuning", systemImage: "slider.horizontal.3") }
            ContextSettingsTab()
                .tabItem { Label("Context", systemImage: "folder") }
            MCPSettingsTab()
                .tabItem { Label("MCP", systemImage: "server.rack") }
        }
        .frame(width: 620, height: 680)
    }
}

// MARK: - Models Tab

struct ModelsSettingsTab: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine

    @AppStorage("models.endpointURL") private var endpointURL: String = "http://localhost:8000"
    @AppStorage("models.modelID") private var modelID: String = ""
    @AppStorage("models.requiresAPIKey") private var requiresAPIKey: Bool = false
    @State private var connectionStatus: String = "Connection not checked yet."
    @State private var connectionOK: Bool? = nil
    @State private var allowedModels: [String] = []
    @State private var hubModelID: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Default LLM Connection
                GroupBox("Default LLM Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Selected backend default endpoint: \(endpointURL)")
                            .font(.caption).foregroundStyle(.secondary)

                        LabeledContent("Endpoint URL") {
                            TextField("http://localhost:8000", text: $endpointURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Model ID") {
                            TextField("e.g. mlx-community/Qwen3-8B-4bit", text: $modelID)
                                .textFieldStyle(.roundedBorder)
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

                        Button("Discover Models") {
                            // TODO: query endpoint /v1/models
                        }

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
                            Button("Test Connection") {
                                testConnection()
                            }
                        }
                    }
                    .padding(8)
                }

                // Built-in MLX Models
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

                // Agent Model Assignment
                GroupBox("Agent Model Assignment") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Per-agent model overrides will appear here once agents are configured.")
                            .font(.caption).foregroundStyle(.secondary)
                        // TODO: iterate agents, show connection + model picker per agent
                    }
                    .padding(8)
                }

                Spacer()
                HStack { Spacer(); Button("Save Settings") { /* persisted via AppStorage */ } }
            }
            .padding()
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

// MARK: - Tuning Tab

struct TuningSettingsTab: View {
    @AppStorage("tuning.temperature") private var temperature: Double = 0.7
    @AppStorage("tuning.maxTokens") private var maxTokens: Int = 4096
    @AppStorage("tuning.topP") private var topP: Double = 0.9
    @AppStorage("tuning.repetitionPenalty") private var repetitionPenalty: Double = 1.05
    @AppStorage("tuning.contextBudget") private var contextBudget: Int = 18000
    @AppStorage("tuning.factBudget") private var factBudget: Int = 8000

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
                        HStack {
                            Text("Repetition Penalty").frame(width: 140, alignment: .leading)
                            Slider(value: $repetitionPenalty, in: 1.0...1.5, step: 0.01)
                            Text(String(format: "%.2f", repetitionPenalty)).monospacedDigit().frame(width: 44)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Limits") {
                    VStack(spacing: 12) {
                        Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 256...32768, step: 256)
                    }
                    .padding(8)
                }

                GroupBox("Memory Budgets") {
                    VStack(spacing: 12) {
                        Stepper("Context budget: \(contextBudget) chars", value: $contextBudget, in: 1000...100000, step: 1000)
                        Stepper("Fact budget: \(factBudget) chars", value: $factBudget, in: 1000...50000, step: 1000)
                        Text("Memory recall budgets control how much context and fact data is injected into each prompt.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                Spacer()
                HStack { Spacer(); Button("Save Settings") { } }
            }
            .padding()
        }
    }
}

// MARK: - Context Tab

struct ContextSettingsTab: View {
    @State private var selectedAgent: String = "Navi"
    @State private var authorizedFolders: [AuthorizedFolder] = [
        AuthorizedFolder(path: "~/.ai-context", enabled: true),
        AuthorizedFolder(path: "~/GitHub", enabled: true),
    ]
    @State private var newFolderPath: String = ""
    @State private var importScope: String = "Navigator (parent)"
    @State private var importFolderPath: String = ""
    @State private var importStatus: String = ""
    @State private var filesInMemory: Int = 0
    @State private var lastImportDate: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Authorized Folders
                GroupBox("Authorized Folders") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Agent")
                            Picker("", selection: $selectedAgent) {
                                Text("Navi").tag("Navi")
                                Text("All Agents").tag("All")
                            }
                            .frame(width: 150)
                        }

                        ForEach($authorizedFolders) { $folder in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                                Text(folder.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Toggle("", isOn: $folder.enabled)
                                    .labelsHidden()
                                Button { authorizedFolders.removeAll { $0.id == folder.id } } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button("Grant Folder Access...") {
                            // TODO: NSOpenPanel for sandbox bookmark
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

                        Text("Use \"Grant Folder Access...\" to request sandbox read/write permission and save a bookmark. \"Add Path\" appends a folder path and reuses an existing bookmark if available.")
                            .font(.caption).foregroundStyle(.secondary)

                        if authorizedFolders.contains(where: { $0.enabled }) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Granted access to \(authorizedFolders.filter { $0.enabled }.count) folder(s).")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(8)
                }

                // Import Folder Into Memory
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

                        Text("No explicit Navigator agent found; import still uses navigator parent memory scope.")
                            .font(.caption).foregroundStyle(.secondary)

                        HStack {
                            TextField("/absolute/path", text: $importFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose Folder...") {
                                // TODO: NSOpenPanel
                            }
                        }

                        Button("Import Folder") {
                            // TODO: scan UTF-8 files and import into memory context store
                            importStatus = "Importing..."
                        }

                        Text("Imports UTF-8 text files into the native memory context store. Use Navigator scope for shared parent knowledge and Agent project scope for project-specific child memory.")
                            .font(.caption).foregroundStyle(.secondary)

                        if filesInMemory > 0 {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text("\(filesInMemory) file(s) in memory").font(.caption.bold())
                                    Text(lastImportDate).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                    .padding(8)
                }

                Spacer()
                HStack { Spacer(); Button("Save Settings") { } }
            }
            .padding()
        }
    }
}

// MARK: - MCP Tab

struct MCPSettingsTab: View {
    @State private var servers: [MCPServerEntry] = MCPServerEntry.defaults

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                HStack {
                    Text("Self-Hosted MCP Servers").font(.headline)
                    Spacer()
                    let readyCount = servers.filter { $0.enabled }.count
                    Text("\(readyCount)/\(servers.count) ready").foregroundStyle(.green).font(.caption.bold())
                }

                Text("Configure local stdio MCP servers. Use Fields for guided entry or Snippet to paste a JSON config block.")
                    .font(.caption).foregroundStyle(.secondary)

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
                HStack { Spacer(); Button("Save Settings") { } }
            }
            .padding()
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
                    Text("Enabled")
                    Toggle("", isOn: $server.enabled).labelsHidden()
                    Button { onDelete() } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }

                HStack {
                    Button(showFields ? "Fields" : "Fields") {
                        showFields = true
                    }
                    .buttonStyle(.bordered)
                    .tint(showFields ? .blue : .gray)
                    Button("Snippet") {
                        showFields = false
                    }
                    .buttonStyle(.bordered)
                    .tint(!showFields ? .blue : .gray)
                }

                if showFields {
                    TextField("Command (e.g. /opt/homebrew/bin/node)", text: $server.command)
                        .textFieldStyle(.roundedBorder)
                    TextField("Script path", text: $server.scriptPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Env (KEY=VALUE, comma-separated)", text: $server.env)
                        .textFieldStyle(.roundedBorder)
                    TextField("Working directory", text: $server.workingDir)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Startup Timeout (seconds)")
                        Spacer()
                        Stepper("\(server.timeout)", value: $server.timeout, in: 1...60)
                            .frame(width: 100)
                    }
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Supporting Types

struct AuthorizedFolder: Identifiable {
    let id = UUID()
    var path: String
    var enabled: Bool
}

struct MCPServerEntry: Identifiable {
    let id = UUID()
    var name: String
    var command: String
    var scriptPath: String
    var env: String
    var workingDir: String
    var timeout: Int
    var enabled: Bool

    static let defaults: [MCPServerEntry] = [
        MCPServerEntry(
            name: "ai-context-bridge",
            command: "/opt/homebrew/bin/node",
            scriptPath: "~/.ai-context/mcp-server/server.js",
            env: "",
            workingDir: "~/Library/Mobile Documents/com~apple~CloudDocs/.ai-context",
            timeout: 8,
            enabled: true
        ),
        MCPServerEntry(
            name: "crawlkit-mcp",
            command: "/opt/homebrew/bin/node",
            scriptPath: "~/.ai-context/mcp-crawlkit/server.js",
            env: "",
            workingDir: "",
            timeout: 8,
            enabled: true
        ),
        MCPServerEntry(
            name: "firecrawl-mcp",
            command: "/opt/homebrew/bin/node",
            scriptPath: "",
            env: "",
            workingDir: "",
            timeout: 8,
            enabled: false
        ),
        MCPServerEntry(
            name: "playwright",
            command: "/opt/homebrew/bin/node",
            scriptPath: "",
            env: "",
            workingDir: "",
            timeout: 8,
            enabled: false
        ),
    ]
}
