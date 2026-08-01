import Foundation

/// Configuration for a remote LM Studio instance.
///
/// SECURITY: The endpoint URL and API key are NEVER hard-coded here.
/// They are injected at runtime from the model's `remoteBaseURL` or from
/// Keychain (via the Settings → Secrets tab).
struct LMStudioConfig {
    let baseURL: String
    let apiKey: String

    init(baseURL: String, apiKey: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    var chatCompletionURL: URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/v1/chat/completions")
    }
}
