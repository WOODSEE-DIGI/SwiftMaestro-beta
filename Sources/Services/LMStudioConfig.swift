import Foundation

/// Configuration for remote LM Studio instance
struct LMStudioConfig {
    let baseURL: String
    let apiKey: String
    
    // Available models (based on actual memory constraints)
    // Note: Models above ~8GB are blocked by LM Studio memory guardrails
    static let codingModel = "deepseek-math-7b-instruct"            // 7B - works! Good for coding
    static let reasoningModel = "qwen/qwen3.5-122b-a10b"            // 122B - needs 60GB+
    static let fastModel = "deepseek-r1-distill-qwen-1.5b"          // 1.5B - works! Fast & light
    
    init(apiKey: String = "sk-lm-IElmefqH:F1ZK16e76qOf8qhI64l2") {
        self.baseURL = "http://192.168.10.207:1234"
        self.apiKey = apiKey
    }
    
    var chatCompletionURL: URL? {
        URL(string: "\(baseURL)/v1/chat/completions")
    }
}
