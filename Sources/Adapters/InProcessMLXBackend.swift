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
        NSLog("[MLXBackend] model=\(model.id) hf=\(model.huggingFaceID) toolCallFormat=\(String(describing: model.toolCallFormat)) tools=\(tools?.count ?? 0) lite=\(model.isLiteModel)")
        // Gemma 4's chat template expects image parts as `{"type": "image"}`,
        // not OpenAI-style `{"type": "image_url", ...}`. The current
        // mlx-swift-lm Gemma 4 implementation also only supports a single image
        // per prompt; multiple images cause an "image token count mismatch"
        // crash. We therefore keep at most one image and only from the most
        // recent user message.
        let isGemma4 = model.huggingFaceID.lowercased().contains("gemma-4")
        let preparedConvo: [[String: Any]]
        nonisolated(unsafe) let images: [UserInput.Image]
        if isGemma4 {
            let prepared = Self.prepareGemma4Convo(convo)
            preparedConvo = prepared.convo
            images = prepared.images
        } else {
            preparedConvo = convo
            images = Self.extractAllImages(from: convo)
        }
        let wireMessages = Self.toWireMessages(preparedConvo)
        NSLog("[InProcessMLXBackend] streamRound model=\(model.id) images=\(images.count) messages=\(wireMessages.count) gemma4=\(isGemma4)")
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
        for (index, msg) in convo.enumerated() {
            let content = msg["content"]
            if let string = content as? String { continue }
            guard let parts = content as? [[String: Any]] else {
                if content != nil {
                    NSLog("[InProcessMLXBackend] message \(index) has non-array content: \(type(of: content))")
                }
                continue
            }
            for part in parts {
                guard let type = part["type"] as? String else { continue }
                if type == "image_url",
                   let urlObj = part["image_url"] as? [String: Any],
                   let urlString = urlObj["url"] as? String {
                    if let data = Data(base64Encoded: extractBase64(urlString)),
                       let ciImage = CIImage(data: data) {
                        images.append(.ciImage(ciImage))
                        NSLog("[InProcessMLXBackend] extracted image from message \(index)")
                    } else {
                        NSLog("[InProcessMLXBackend] failed to decode image from message \(index)")
                    }
                }
            }
        }
        if !images.isEmpty {
            NSLog("[InProcessMLXBackend] extracted \(images.count) image(s) from conversation")
        }
        return images
    }

    /// Prepare a conversation for Gemma 4:
    /// 1. Convert the most recent user message's `image_url` part(s) to the
    ///    plain `{"type": "image"}` shape that Gemma 4's Jinja template expects.
    /// 2. Keep at most one image total — the current mlx-swift-lm Gemma 4
    ///    implementation only supports a single image per prompt.
    /// 3. Drop any image parts from earlier turns and any stray `{"type": "image"}`
    ///    placeholders so the image token count always matches the number of
    ///    supplied images, preventing the Gemma4 image token mismatch crash.
    private static func prepareGemma4Convo(
        _ convo: [[String: Any]]
    ) -> (convo: [[String: Any]], images: [UserInput.Image]) {
        let lastUserIndex = convo.lastIndex { msg in
            (msg["role"] as? String)?.lowercased() == "user"
        } ?? -1
        var images: [UserInput.Image] = []
        var haveImage = false
        let rewritten = convo.enumerated().map { (index, msg) -> [String: Any] in
            var out = msg
            let role = (msg["role"] as? String)?.lowercased() ?? ""
            let isLastUser = role == "user" && index == lastUserIndex
            guard let parts = msg["content"] as? [[String: Any]] else { return out }
            var newParts: [[String: Any]] = []
            for part in parts {
                let type = part["type"] as? String
                if type == "image_url" {
                    if isLastUser, !haveImage,
                       let urlObj = part["image_url"] as? [String: Any],
                       let urlString = urlObj["url"] as? String,
                       let data = Data(base64Encoded: extractBase64(urlString)),
                       let ciImage = CIImage(data: data) {
                        images.append(.ciImage(ciImage))
                        haveImage = true
                        newParts.append(["type": "image"])
                        NSLog("[InProcessMLXBackend] Gemma 4 keeping image from last user message \(index)")
                    } else {
                        NSLog("[InProcessMLXBackend] Gemma 4 dropping image part from message \(index) (isLastUser=\(isLastUser), haveImage=\(haveImage))")
                    }
                } else if type == "image" {
                    // Drop stray legacy placeholders.
                    NSLog("[InProcessMLXBackend] Gemma 4 dropping stray plain image part from message \(index)")
                } else {
                    newParts.append(part)
                }
            }
            out["content"] = newParts
            return out
        }
        if !images.isEmpty {
            NSLog("[InProcessMLXBackend] Gemma 4 prepared: \(images.count) image(s), \(rewritten.count) messages")
        }
        return (rewritten, images)
    }

    private static func extractBase64(_ urlString: String) -> String {
        if let range = urlString.range(of: ",") {
            return String(urlString[range.upperBound...])
        }
        return urlString
    }
}
