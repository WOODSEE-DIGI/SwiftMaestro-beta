import Foundation

/// Configuration for remote LM Studio instance.
///
/// SECURITY: The endpoint URL and API key are NEVER hard-coded here.
/// They are injected at runtime from Keychain (via the Settings → Secrets tab)
/// or, for local development convenience only, from environment variables.
struct LMStudioConfig {
    let baseURL: String
    let apiKey: String

    // Available models (based on actual memory constraints)
    // Note: Models above ~8GB are blocked by LM Studio memory guardrails
    static let codingModel = "deepseek-math-7b-instruct"            // 7B - works! Good for coding
    static let reasoningModel = "qwen/qwen3.5-122b-a10b"            // 122B - needs 60GB+
    static let fastModel = "deepseek-r1-distill-qwen-1.5b"          // 1.5B - works! Fast & light

    init(
        baseURL: String = ProcessInfo.processInfo.environment["LMSTUDIO_BASE_URL"] ?? "",
        apiKey: String = ProcessInfo.processInfo.environment["LMSTUDIO_API_KEY"] ?? ""
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    var chatCompletionURL: URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/v1/chat/completions")
    }
}
