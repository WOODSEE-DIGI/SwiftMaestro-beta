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
    /// `secret://` reference for the API key (online providers). Never the
    /// raw key. Nil for local servers.
    var apiKeyRef: String?
    /// Streaming request timeout in seconds. Local servers answer fast;
    /// hosted models can spend a while in prefill.
    var requestTimeout: TimeInterval = 180

    /// The models this provider contributes to the catalog.
    func catalogModels() -> [MaestroModel] {
        modelIDs.map { modelID in
            // Kimi/Moonshot models enforce fixed sampling; sending other values
            // returns HTTP 400 "invalid temperature" / "invalid top_p".
            let lowercased = modelID.lowercased()
            let isKimi = lowercased.hasPrefix("kimi-")
            let fixedTemperature: Double? = isKimi ? 1.0 : nil
            let fixedTopP: Double? = isKimi ? 0.95 : nil
            return MaestroModel(
                id: "remote-\(id.uuidString)-\(modelID)",
                displayName: "\(modelID) · \(name)",
                huggingFaceID: modelID,
                isVision: false,
                localPath: nil,
                estimatedMemoryGB: 0,
                supportsTools: true,
                toolCallFormat: nil,   // remote backend uses OpenAI function calling
                recTemperature: fixedTemperature,
                recTopP: fixedTopP,
                fixedTemperature: fixedTemperature,
                fixedTopP: fixedTopP,
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
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([RemoteProvider].self, from: data)
        } catch {
            NSLog("[REMOTE] failed to decode providers (starting empty): \(error.localizedDescription)")
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
    /// `GET {base}/api/tags`. Returns the discovered model IDs when known.
    static func probe(_ provider: RemoteProvider) async -> (ProbeResult, [String]) {
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
                let ids = list.compactMap { $0["id"] as? String }
                return (.ok(modelCount: ids.count), ids)
            }
            if status == 401 || status == 403 {
                // The server answered — it just wants the API key. That is a
                // REACHABLE endpoint, not "no answer".
                return (.reachableNeedsAuth, [])
            }
            if provider.kind != .ollama {
                // HTTP answered but with an unexpected status — alive, wrong
                // path or non-standard server.
                return (.reachableUnexpected(status), [])
            }
        }

        // Ollama native listing.
        if provider.kind == .ollama,
           let (data, status) = await get("\(provider.baseURL.openAIBase)/api/tags", authorize: false),
           (200...299).contains(status),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["models"] as? [[String: Any]] {
            let ids = list.compactMap { $0["name"] as? String }
            return (.ok(modelCount: ids.count), ids)
        }

        return (.failed("No answer at \(provider.baseURL) — is the server running and the URL correct?"), [])
    }
}
