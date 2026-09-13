import Foundation
import CoreFoundation

/// A minimal representation of the main app's `RemoteProvider` model, used by
/// the Setup app to pre-configure an online/local model endpoint before the
/// user launches SwiftMaestro.
struct MainAppRemoteProvider: Codable {
    var id: UUID = UUID()
    var name: String
    var kind: Kind
    var baseURL: String
    var modelIDs: [String]
    var modelDescriptions: [String: String] = [:]
    var apiKeyRef: String?
    var requestTimeout: TimeInterval = 180

    enum Kind: String, Codable {
        case lmStudio = "LM Studio"
        case ollama = "Ollama"
        case online = "Online (OpenAI-compatible)"
    }
}

/// Named online presets for the Setup app's optional post-install provider
/// configuration. These mirror the main app's `RemoteProviderPreset` values.
struct MainAppRemoteProviderPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let suggestedModels: [String]
    let keyHelp: String

    static let presets: [MainAppRemoteProviderPreset] = [
        MainAppRemoteProviderPreset(
            id: "moonshot",
            name: "Kimi (Moonshot AI)",
            baseURL: "https://api.moonshot.ai/v1",
            suggestedModels: ["kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6"],
            keyHelp: "API key from platform.moonshot.ai — add it in SwiftMaestro Settings → Secrets after launch."),
        MainAppRemoteProviderPreset(
            id: "dashscope",
            name: "Qwen (Alibaba DashScope)",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            suggestedModels: ["qwen-max", "qwen-plus", "qwen-turbo"],
            keyHelp: "API key from Alibaba Cloud DashScope — add it in SwiftMaestro Settings → Secrets after launch."),
        MainAppRemoteProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            suggestedModels: ["qwen/qwen3-235b-a22b", "moonshotai/kimi-k2"],
            keyHelp: "API key from openrouter.ai — add it in SwiftMaestro Settings → Secrets after launch."),
    ]
}

extension MainAppRemoteProvider {
    /// Writes this provider into the main SwiftMaestro app's UserDefaults so it
    /// appears in Settings → Models on first launch. Uses CFPreferences so the
    /// Setup app (bundle `com.woodseedigi.swiftmaestro.setup`) can write the
    /// main app's (`com.woodseedigi.swiftmaestro`) preferences directly.
    func writeToMainApp() throws {
        let mainAppID = "com.woodseedigi.swiftmaestro" as CFString
        let key = "models.remoteProviders.v1" as CFString

        // Merge with any providers already written by a previous Setup run.
        var providers = Self.existingProviders()
        providers.append(self)

        let data = try JSONEncoder().encode(providers)
        let cfData = data as CFData
        CFPreferencesSetAppValue(key, cfData, mainAppID)
        CFPreferencesAppSynchronize(mainAppID)
    }

    private static func existingProviders() -> [MainAppRemoteProvider] {
        let mainAppID = "com.woodseedigi.swiftmaestro" as CFString
        let key = "models.remoteProviders.v1" as CFString
        guard let value = CFPreferencesCopyAppValue(key, mainAppID),
              let data = value as? Data,
              let providers = try? JSONDecoder().decode([MainAppRemoteProvider].self, from: data) else {
            return []
        }
        return providers
    }
}
