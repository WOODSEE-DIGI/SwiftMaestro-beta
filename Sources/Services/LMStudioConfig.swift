import Foundation

/// Configuration for a remote LM Studio instance.
///
/// SECURITY: The endpoint URL and API key are NEVER hard-coded here.
/// They are injected at runtime from the model's `remoteBaseURL` or from
/// Keychain (via the Settings → Secrets tab).
struct LMStudioConfig {
    let baseURL: String
    let apiKey: String
    /// Idle timeout for the streaming request. Local disk-streamed models
    /// (Deltafin/K3) can spend minutes in prefill before the first SSE delta
    /// arrives, so they need a much longer window than LM Studio's fast
    /// resident models.
    let requestTimeout: TimeInterval

    init(baseURL: String, apiKey: String = "", requestTimeout: TimeInterval = 120) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
    }

    var chatCompletionURL: URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/v1/chat/completions")
    }
}
