import Foundation
import MLXLMCommon
import CoreImage

// MARK: - In-process MLX backend
//
// Runs generation fully on-device via mlx-swift-lm (no external server), per
// WWDC26 "Run local agentic AI on the Mac using MLX". Renders the OpenAI-wire
// conversation into mlx `Chat.Message` form and delegates one generation round
// to `MLXInferenceEngine.generateRound`. Tool calls are parsed by mlx-swift-lm's
// model-specific parser (e.g. Qwen3.5/3.6 -> xmlFunction) and surfaced as
// `RoundToolCall` for the shared agentic loop in AgentExecutor.

final class InProcessMLXBackend: GenerationBackend {

    let engine: MLXInferenceEngine
    let model: MaestroModel
    /// Identifies the owning agent so the engine keeps a per-agent KV cache.
    let sessionKey: String

    init(engine: MLXInferenceEngine, model: MaestroModel, sessionKey: String = "default") {
        self.engine = engine
        self.model = model
        self.sessionKey = sessionKey
    }

    func streamRound(
        convo: [[String: Any]],
        toolSpecs: [ToolSpec],
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        maxTokens: Int,
        continuation: AsyncThrowingStream<AgentOutput, Error>.Continuation
    ) async throws -> (content: String, toolCalls: [RoundToolCall]) {
        let tools: [ToolSpec]? = toolSpecs.isEmpty ? nil : toolSpecs
        // Pass raw wire messages through to preserve tool_calls on assistant
        // messages and tool_call_id on tool messages. The .messages() path in
        // UserInput/DefaultMessageGenerator passes these untouched to the Jinja
        // template, which needs tool_calls to forward-scan and match tool results.
        let wireMessages = Self.toWireMessages(convo)
        nonisolated(unsafe) let images = Self.extractAllImages(from: convo)
        return try await engine.generateRound(
            wireMessages: wireMessages,
            images: images,
            toolSchemas: tools,
            model: model,
            sessionKey: sessionKey,
            temperature: temperature,
            topP: topP,
            thinkingEnabled: thinkingEnabled,
            maxTokens: maxTokens,
            onToken: { continuation.yield(.token($0)) },
            onInfo: { continuation.yield(.info(tokensPerSecond: $0)) }
        )
    }

    // MARK: - Conversion

    /// Convert `[[String: Any]]` wire messages to `[[String: any Sendable]]` for
    /// the `.messages()` path. Preserves all keys (tool_calls, tool_call_id, etc).
    private static func toWireMessages(_ convo: [[String: Any]]) -> [[String: any Sendable]] {
        // Swift 6 concurrency: Any is not Sendable. JSON round-trip produces
        // NSString/NSNumber/NSArray/NSDictionary which bridge to Sendable types.
        guard let data = try? JSONSerialization.data(withJSONObject: convo as Any) else { return [] }
        let root = try? JSONSerialization.jsonObject(with: data)
        func bridge(_ v: Any) -> any Sendable {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n }
            if let arr = v as? [Any] { return arr.map { bridge($0) } as [any Sendable] }
            if let dict = v as? [String: Any] {
                var out: [String: any Sendable] = [:]
                for (k, val) in dict { out[k] = bridge(val) }
                return out
            }
            return NSNull()
        }
        guard let messages = root as? [Any] else { return [] }
        return messages.compactMap { msg -> [String: any Sendable]? in
            guard let dict = msg as? [String: Any] else { return nil }
            var out: [String: any Sendable] = [:]
            for (k, val) in dict { out[k] = bridge(val) }
            return out
        }
    }

    /// Extract image data from all messages in the wire format for VLM support.
    private static func extractAllImages(from convo: [[String: Any]]) -> [UserInput.Image] {
        var images: [UserInput.Image] = []
        for msg in convo {
            let content = msg["content"]
            if let string = content as? String { continue }
            guard let parts = content as? [[String: Any]] else { continue }
            for part in parts {
                guard let type = part["type"] as? String,
                      type == "image_url",
                      let urlObj = part["image_url"] as? [String: Any],
                      let urlString = urlObj["url"] as? String else { continue }
                if let data = Data(base64Encoded: extractBase64(urlString)),
                   let ciImage = CIImage(data: data) {
                    images.append(.ciImage(ciImage))
                }
            }
        }
        return images
    }

    private static func extractBase64(_ urlString: String) -> String {
        if let range = urlString.range(of: ",") {
            return String(urlString[range.upperBound...])
        }
        return urlString
    }
}
