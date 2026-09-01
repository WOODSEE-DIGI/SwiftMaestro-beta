import Foundation
import Observation

// MARK: - Remote model providers (LM Studio, Ollama, online OpenAI-compatible)
//
// For Macs below ~32GB unified memory — where even the smallest bundled local
// model strains the budget — generation can be handed to an OpenAI-compatible
// endpoint instead of in-process MLX: a LM Studio server on the same machine
// or another Mac on the LAN, Ollama, or a hosted API (Kimi/Moonshot, Qwen via
// Alibaba DashScope, OpenRouter, …).
//
// Generation itself was already implemented in `RemoteLMStudioBackend`
// (OpenAI SSE + function calling); this layer owns the provider records,
// persistence, connection testing, and the bridge into `ModelCatalog`.
//
// SECURITY: API keys are NEVER stored here — only a `secret://` reference into
// the Keychain (created/managed via Settings → Secrets). The raw key resolves
// at the HTTP boundary only, per the app's secrets policy.

/// Deterministic color assignment for a source identifier. String.hashValue is
/// not stable across launches, so this uses djb2 to keep a provider's color
/// constant every time the app runs. Well-known online providers get fixed,
/// distinct colors so users can instantly tell which endpoint a model bills to.
func sourceColorName(for sourceID: String) -> String {
    switch sourceID {
    case "local":
        return "green"
    case "remote-lmStudio":
        return "blue"
    case "remote-ollama":
        return "purple"
    default:
        // Fixed colors for common online providers; fall back to a stable hash
        // for anything else.
        if sourceID.contains("moonshot.ai") { return "orange" }
        if sourceID.contains("googleapis.com") { return "purple" }
        if sourceID.contains("dashscope") { return "cyan" }
        if sourceID.contains("openrouter.ai") { return "pink" }
        if sourceID.contains("openai.com") { return "teal" }
        if sourceID.contains("anthropic") { return "red" }

        let palette = ["orange", "pink", "cyan", "yellow", "red", "indigo", "teal", "mint", "brown"]
        var hash = 5381
        for byte in sourceID.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        let index = abs(hash) % palette.count
        return palette[index]
    }
}

enum RemoteProviderKind: String, Codable, CaseIterable, Sendable {
    case lmStudio = "LM Studio"
    case ollama = "Ollama"
    case online = "Online (OpenAI-compatible)"

    var defaultBaseURL: String {
        switch self {
        case .lmStudio: return "http://localhost:1234"
        case .ollama: return "http://localhost:11434"
        case .online: return ""
        }
    }

    var needsAPIKey: Bool { self == .online }
}

/// A named online preset for the add-provider sheet. Pure sugar over `online`
/// — pre-fills the base URL and suggests well-known model IDs.
struct RemoteProviderPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let suggestedModels: [String]
    let keyHelp: String

    static let presets: [RemoteProviderPreset] = [
        RemoteProviderPreset(
            id: "moonshot",
            name: "Kimi (Moonshot AI)",
            baseURL: "https://api.moonshot.ai/v1",
            suggestedModels: ["kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6"],
            keyHelp: "API key from platform.moonshot.ai — stored in Keychain via Secrets."),
        RemoteProviderPreset(
            id: "dashscope",
            name: "Qwen (Alibaba DashScope)",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            suggestedModels: ["qwen-max", "qwen-plus", "qwen-turbo"],
            keyHelp: "API key from Alibaba Cloud DashScope — stored in Keychain via Secrets."),
        RemoteProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            suggestedModels: ["qwen/qwen3-235b-a22b", "moonshotai/kimi-k2"],
            keyHelp: "API key from openrouter.ai — stored in Keychain via Secrets."),
    ]
}

/// One remote endpoint plus the model IDs it serves.
struct RemoteProvider: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: RemoteProviderKind
    var baseURL: String
    /// The served model identifiers sent as the wire `model` field
    /// (e.g. "qwen3:8b" for Ollama, "kimi-k3" for Moonshot).
    var modelIDs: [String]
    /// Optional human-readable descriptions fetched from the provider's
    /// `/v1/models` endpoint, keyed by model ID.
    var modelDescriptions: [String: String] = [:]
    /// `secret://` reference for the API key (online providers). Never the
    /// raw key. Nil for local servers.
    var apiKeyRef: String?
    /// Streaming request timeout in seconds. Local servers answer fast;
    /// hosted models can spend a while in prefill.
    var requestTimeout: TimeInterval = 180

    /// Backwards-compatible decoding: older persisted providers may lack
    /// `modelDescriptions` or `requestTimeout`, so default values are used
    /// when those keys are missing instead of failing the whole store load.
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, modelIDs, modelDescriptions, apiKeyRef, requestTimeout
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: RemoteProviderKind,
        baseURL: String,
        modelIDs: [String],
        modelDescriptions: [String: String] = [:],
        apiKeyRef: String? = nil,
        requestTimeout: TimeInterval = 180
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.modelIDs = modelIDs
        self.modelDescriptions = modelDescriptions
        self.apiKeyRef = apiKeyRef
        self.requestTimeout = requestTimeout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(RemoteProviderKind.self, forKey: .kind)
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        self.modelIDs = try container.decode([String].self, forKey: .modelIDs)
        self.modelDescriptions = try container.decodeIfPresent([String: String].self, forKey: .modelDescriptions) ?? [:]
        self.apiKeyRef = try container.decodeIfPresent(String.self, forKey: .apiKeyRef)
        self.requestTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 180
    }

    /// Stable source identifier used for grouping and color assignment.
    var sourceID: String {
        switch kind {
        case .lmStudio:
            return "remote-lmStudio"
        case .ollama:
            return "remote-ollama"
        case .online:
            return "remote-online-\(baseURL)"
        }
    }

    /// Badge for this provider, matching the color used for its models.
    var badge: (icon: String, colorName: String) {
        let icon: String
        switch kind {
        case .lmStudio: icon = "server.rack"
        case .ollama: icon = "shippingbox"
        case .online: icon = "globe"
        }
        return (icon, sourceColorName(for: sourceID))
    }

    /// The models this provider contributes to the catalog.
    func catalogModels() -> [MaestroModel] {
        modelIDs.map { modelID in
            // Kimi/Moonshot models enforce fixed sampling; sending other values
            // returns HTTP 400 "invalid temperature" / "invalid top_p".
            let lowercased = modelID.lowercased()
            let isKimi = lowercased.hasPrefix("kimi-")
            let fixedTemperature: Double? = isKimi ? 1.0 : nil
            let fixedTopP: Double? = isKimi ? 0.95 : nil
            // Online providers default to Compact Tool Mode: every tool is still
            // reachable, but most schemas are deferred behind search_tools/call_tool
            // instead of being inlined in every request. This keeps full capability
            // parity with local models while avoiding the 160-tool prompt flood.
            let isOnline = kind == .online
            return MaestroModel(
                id: "remote-\(id.uuidString)-\(modelID)",
                displayName: "\(modelID) · \(name)",
                huggingFaceID: modelID,
                description: modelDescriptions[modelID],
                isVision: false,
                localPath: nil,
                estimatedMemoryGB: 0,
                supportsTools: true,
                toolCallFormat: nil,   // remote backend uses OpenAI function calling
                recTemperature: fixedTemperature,
                recTopP: fixedTopP,
                fixedTemperature: fixedTemperature,
                fixedTopP: fixedTopP,
                prefersCompactToolMode: isOnline,
                remoteBaseURL: baseURL,
                remoteProviderKind: kind,
                remoteRequestTimeout: requestTimeout,
                remoteAPIKeyRef: apiKeyRef
            )
        }
    }
}

/// UserDefaults-persisted store of configured remote providers. Posts
/// `RemoteProviderStore.didChangeNotification` after every mutation so
/// `ModelCatalog` can rebuild its remote section.
@MainActor
@Observable
final class RemoteProviderStore {

    static let shared = RemoteProviderStore()
    static let didChangeNotification = Notification.Name("RemoteProviderStore.didChange")

    private static let storageKey = "models.remoteProviders.v1"

    private(set) var providers: [RemoteProvider] = []

    private init() {
        providers = Self.load()
    }

    /// All models across all providers, as catalog entries.
    func catalogModels() -> [MaestroModel] {
        providers.flatMap { $0.catalogModels() }
    }

    func add(_ provider: RemoteProvider) {
        providers.append(provider)
        save()
    }

    func update(_ provider: RemoteProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        save()
    }

    func remove(id: UUID) {
        providers.removeAll { $0.id == id }
        save()
    }

    func provider(for id: UUID) -> RemoteProvider? {
        providers.first { $0.id == id }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(providers)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            NSLog("[REMOTE] failed to persist providers: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private static func load() -> [RemoteProvider] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            NSLog("[REMOTE] no persisted providers found")
            return []
        }
        do {
            let providers = try JSONDecoder().decode([RemoteProvider].self, from: data)
            NSLog("[REMOTE] loaded \(providers.count) persisted provider(s) (\(data.count) bytes)")
            return providers
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(500) ?? "<not utf8>"
            NSLog("[REMOTE] failed to decode providers (starting empty): \(error.localizedDescription)")
            NSLog("[REMOTE] persisted data preview: \(preview)")
            return []
        }
    }

    // MARK: - Connection test & model discovery

    enum ProbeResult: Equatable {
        case ok(modelCount: Int)
        /// The server answered HTTP 401/403 — it IS alive, it just wants the
        /// API key (hosted providers do this for /v1/models without auth).
        case reachableNeedsAuth
        /// The server answered, but not with a models list (unexpected status).
        case reachableUnexpected(Int)
        /// No HTTP response at all — server down, wrong URL, or offline.
        case failed(String)
    }

    /// Probe the endpoint. Tries the OpenAI `GET {base}/v1/models` listing
    /// first; for Ollama additionally falls back to its native
    /// `GET {base}/api/tags`. Returns the discovered model IDs and any
    /// descriptions the endpoint reports.
    static func probe(_ provider: RemoteProvider) async -> (result: ProbeResult, ids: [String], descriptions: [String: String]) {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 10
            return c
        }())

        func get(_ urlString: String, authorize: Bool) async -> (Data, Int)? {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            if authorize, let ref = provider.apiKeyRef,
               let key = SecretsStore.resolve(reference: ref, currentProject: nil) {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            guard let result = try? await session.data(for: request),
                  let response = result.1 as? HTTPURLResponse else { return nil }
            return (result.0, response.statusCode)
        }

        // OpenAI-compatible listing (LM Studio, most hosted providers, and
        // Ollama ≥ 0.5 all answer this). `openAIBase` strips a preset's
        // trailing "/v1" so the path is never doubled.
        if let (data, status) = await get("\(provider.baseURL.openAIBase)/v1/models", authorize: true) {
            if (200...299).contains(status),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["data"] as? [[String: Any]] {
                var descriptions: [String: String] = [:]
                let ids = list.compactMap { item -> String? in
                    guard let id = item["id"] as? String else { return nil }
                    if let desc = item["description"] as? String, !desc.isEmpty {
                        descriptions[id] = desc
                    }
                    return id
                }
                return (.ok(modelCount: ids.count), ids, descriptions)
            }
            if status == 401 || status == 403 {
                // The server answered — it just wants the API key. That is a
                // REACHABLE endpoint, not "no answer".
                return (.reachableNeedsAuth, [], [:])
            }
            if provider.kind != .ollama {
                // HTTP answered but with an unexpected status — alive, wrong
                // path or non-standard server.
                return (.reachableUnexpected(status), [], [:])
            }
        }

        // Ollama native listing.
        if provider.kind == .ollama,
           let (data, status) = await get("\(provider.baseURL.openAIBase)/api/tags", authorize: false),
           (200...299).contains(status),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["models"] as? [[String: Any]] {
            var descriptions: [String: String] = [:]
            let ids = list.compactMap { item -> String? in
                guard let name = item["name"] as? String else { return nil }
                // Ollama's native listing carries model details under `details`.
                if let details = item["details"] as? [String: Any] {
                    var parts: [String] = []
                    if let parameterSize = details["parameter_size"] as? String, !parameterSize.isEmpty {
                        parts.append(parameterSize)
                    }
                    if let family = details["family"] as? String, !family.isEmpty {
                        parts.append(family)
                    }
                    if !parts.isEmpty {
                        descriptions[name] = parts.joined(separator: " · ")
                    }
                }
                return name
            }
            return (.ok(modelCount: ids.count), ids, descriptions)
        }

        return (.failed("No answer at \(provider.baseURL) — is the server running and the URL correct?"), [], [:])
    }
}
