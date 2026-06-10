import SwiftUI

@Observable
@MainActor
final class OMLXServerManager {
    enum StartupState: Equatable {
        case idle
        case checking
        case launching
        case ready
        case failed(String)
    }

    private var process: Process?
    private(set) var state: StartupState = .idle
    private(set) var availableModelIDs: [String] = []
    private(set) var lastCheckedAt: Date?

    var autoStartEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "server.autoStartOnLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "server.autoStartOnLaunch") }
    }

    var endpointURL: String {
        get { UserDefaults.standard.string(forKey: "models.endpointURL") ?? "http://localhost:8012" }
        set { UserDefaults.standard.set(newValue, forKey: "models.endpointURL") }
    }

    var startupScriptPath: String {
        get {
            UserDefaults.standard.string(forKey: "server.startScriptPath")
                ?? "~/GitHub/AI-ML-Agents/SwiftMaestro/scripts/start-omlx.sh"
        }
        set { UserDefaults.standard.set(newValue, forKey: "server.startScriptPath") }
    }

    var configuredModelID: String {
        UserDefaults.standard.string(forKey: "models.modelID") ?? ModelTierPolicy.defaultModelID
    }

    var configuredModelIsAvailable: Bool {
        availableModelIDs.contains(configuredModelID)
    }

    func ensureServerReadyOnLaunch() {
        guard autoStartEnabled else { return }
        Task {
            let healthy = await checkHealth()
            if healthy {
                await MainActor.run { self.state = .ready }
                return
            }
            await MainActor.run { self.state = .launching }
            do {
                try launchServer()
                let ready = await waitForHealthyEndpoint(timeoutSeconds: 30)
                await MainActor.run {
                    self.state = ready ? .ready : .failed("oMLX did not become healthy in time")
                }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    func checkHealth() async -> Bool {
        await MainActor.run { self.state = .checking }
        guard let url = URL(string: endpointURL + "/v1/models") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let modelIDs = Self.parseModelIDs(from: data)
                await MainActor.run {
                    self.availableModelIDs = modelIDs
                    self.lastCheckedAt = Date()
                    self.state = .ready
                }
                return true
            }
        } catch {
            await MainActor.run {
                self.availableModelIDs = []
                self.lastCheckedAt = Date()
                self.state = .failed(error.localizedDescription)
            }
            return false
        }
        await MainActor.run {
            self.availableModelIDs = []
            self.lastCheckedAt = Date()
            self.state = .failed("Endpoint did not return a successful /v1/models response")
        }
        return false
    }

    private nonisolated static func parseModelIDs(from data: Data) -> [String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataArray = json["data"] as? [[String: Any]]
        else { return [] }
        return dataArray.compactMap { $0["id"] as? String }
    }

    private func launchServer() throws {
        if process?.isRunning == true { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [startupScriptPath]
        try proc.run()
        process = proc
    }

    private func waitForHealthyEndpoint(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if await checkHealth() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}

enum SwiftMaestroDefaultsMigration {
    static func applyIfNeeded() {
        let defaults = UserDefaults.standard
        let endpointKey = "models.endpointURL"
        let modelKey = "models.modelID"
        let modelMigrationKey = "migration.defaultModel.v2"
        let targetEndpoint = "http://localhost:8012"
        let targetModel = ModelTierPolicy.defaultModelID

        let currentEndpoint = defaults.string(forKey: endpointKey)
        if currentEndpoint == nil || currentEndpoint == "http://localhost:8000" {
            defaults.set(targetEndpoint, forKey: endpointKey)
        }

        let currentModel = defaults.string(forKey: modelKey)
        if currentModel == nil || currentModel?.isEmpty == true {
            defaults.set(targetModel, forKey: modelKey)
        } else if currentModel == ModelTierPolicy.legacyDefaultModelID,
                  !defaults.bool(forKey: modelMigrationKey) {
            // One-time: move installs off the old auto-set 122B default (which
            // preloaded a 65GB model every launch) to the fast MoE default.
            // Gated by a flag so a later deliberate 122B choice is never clobbered.
            defaults.set(targetModel, forKey: modelKey)
        }
        defaults.set(true, forKey: modelMigrationKey)
    }
}

@main
struct SwiftMaestroApp: App {
    @State private var engine = MLXInferenceEngine()
    @State private var catalog = ModelCatalog()
    @State private var serverManager = OMLXServerManager()
    @State private var workspace = WorkspaceStore()
    @State private var todoStore = TodoStore()
    private let mcpService = MCPClientService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .environment(catalog)
                .environment(serverManager)
                .environment(workspace)
                .environment(todoStore)
                .task {
                    SwiftMaestroDefaultsMigration.applyIfNeeded()
                    // Only auto-start the oMLX server when it's the selected
                    // backend; the default in-process MLX backend needs no server.
                    if (UserDefaults.standard.string(forKey: "models.backend") ?? "inprocess") == "omlx" {
                        serverManager.ensureServerReadyOnLaunch()
                    }
                    // Expose the workspace to native delegation/workspace tools.
                    MaestroTools.workspace = workspace
                    // Expose the live-todo store to the native todo tools.
                    MaestroTools.todoStore = todoStore
                    // Wire client-side MCP tools into the inference engine and
                    // spawn the user-enabled servers (permissioned by MCP flags).
                    engine.mcpService = mcpService
                    await mcpService.startEnabledServers()
                }
        }
        .defaultSize(width: 1100, height: 760)

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .environment(catalog)
                .environment(serverManager)
                .environment(workspace)
                .environment(todoStore)
        }
        .defaultSize(width: 720, height: 760)
        #endif
    }
}
