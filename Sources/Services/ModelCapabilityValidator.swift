import Foundation
import MLXLMCommon

// MARK: - Capability report

/// Statically-derived capability profile for a locally-installed MLX model.
///
/// The validator reads the model's `config.json`, `tokenizer_config.json`, and
/// `generation_config.json` to discover the tool-call wire format, whether the
/// model supports thinking blocks, and recommended sampling defaults. These
/// values are then merged into the catalog entry so SwiftMaestro advertises the
/// right feature set for every model without hard-coding per-checkpoint trivia.
struct ModelCapabilityReport: Sendable, Codable {
    let modelType: String?
    let supportsTools: Bool
    let toolCallFormat: ToolCallFormat?
    let supportsThinking: Bool
    let recommendedTemperature: Double?
    let recommendedTopP: Double?
    let recommendedRepetitionPenalty: Double?
    let recommendedMaxTokens: Int?
    let validationErrors: [String]
    let validatedAt: Date
}

// MARK: - Validator

/// Validates model capabilities from on-disk configuration files.
///
/// This is intentionally a static, file-system-only validator: it is fast enough
/// to run on every `refreshLocalPaths()` call and does not require loading the
/// model weights. A separate smoke-test path (optional, heavier) can be layered
/// on top once the model is loaded.
enum ModelCapabilityValidator {

    /// Inspect the directory at `modelDirectory` and return a capability report.
    static func validate(modelDirectory: String) -> ModelCapabilityReport {
        let fm = FileManager.default
        var errors: [String] = []

        guard fm.fileExists(atPath: modelDirectory) else {
            return report(
                errors: ["Model directory does not exist: \(modelDirectory)"]
            )
        }

        let dir = URL(fileURLWithPath: modelDirectory)
        let config = readJSON(dir.appendingPathComponent("config.json"), errors: &errors)
        let tokenizerConfig = readJSON(dir.appendingPathComponent("tokenizer_config.json"), errors: &errors)
        let generationConfig = readJSON(dir.appendingPathComponent("generation_config.json"), errors: &errors)

        let modelType = config?["model_type"] as? String
        let configData = try? Data(contentsOf: dir.appendingPathComponent("config.json"))
        let chatTemplate = (tokenizerConfig?["chat_template"] as? String) ?? ""

        let inferredFormat = inferToolCallFormat(
            modelType: modelType,
            configData: configData,
            chatTemplate: chatTemplate
        )

        let supportsThinking = detectsThinking(chatTemplate: chatTemplate, config: config)
        let supportsTools = detectsTools(
            chatTemplate: chatTemplate,
            tokenizerConfig: tokenizerConfig,
            modelType: modelType
        )

        let sampling = extractSampling(generationConfig: generationConfig, config: config)

        return report(
            modelType: modelType,
            supportsTools: supportsTools,
            toolCallFormat: inferredFormat,
            supportsThinking: supportsThinking,
            temperature: sampling.temperature,
            topP: sampling.topP,
            repetitionPenalty: sampling.repetitionPenalty,
            maxTokens: sampling.maxTokens,
            errors: errors
        )
    }

    // MARK: - File helpers

    private static func readJSON(_ url: URL, errors: inout [String]) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let data = try? Data(contentsOf: url) else {
            errors.append("Could not read \(url.lastPathComponent)")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errors.append("Could not parse \(url.lastPathComponent)")
            return nil
        }

        return json
    }

    // MARK: - Heuristics

    /// Detect thinking support from the Jinja chat template or config.
    ///
    /// Models that expose `enable_thinking` or wrap thinking content in
    /// `<think>...</think>` are flagged as thinking-capable.
    private static func detectsThinking(chatTemplate: String, config: [String: Any]?) -> Bool {
        let lower = chatTemplate.lowercased()
        if lower.contains("<think>") || lower.contains("</think>") { return true }
        if lower.contains("enable_thinking") { return true }

        // Some checkpoints encode thinking toggles in generation_config instead
        // of the template; a `do_sample_temperature` near 1.0 with an
        // `enable_thinking` doc hint is too weak to act on, so we stick to the
        // template and explicit model-family checks below.
        let modelType = (config?["model_type"] as? String ?? "").lowercased()
        return modelType.hasPrefix("qwen3_5") || modelType.hasPrefix("qwen3_next")
    }

    /// Determine the tool-call wire format from config + chat template. Falls
    /// back to mlx-swift-lm's model_type inference, then scans the Jinja chat
    /// template for concrete XML or JSON tool-call examples (e.g. Qwen3-Coder
    /// uses XML <function=...> blocks but reports model_type "qwen3_moe",
    /// which the library does not map to a format).
    private static func inferToolCallFormat(
        modelType: String?,
        configData: Data?,
        chatTemplate: String
    ) -> ToolCallFormat? {
        let lower = chatTemplate.lowercased()

        // Concrete template examples override model_type inference.
        let hasXMLFunction = lower.contains("<function=") && lower.contains("<parameter=")
        let hasJSONToolCall = lower.contains("<tool_call>") &&
            (lower.contains("\"name\"") || lower.contains("\"arguments\"") || lower.contains("{name:"))

        if hasXMLFunction {
            return .xmlFunction
        }
        if hasJSONToolCall {
            return .json
        }

        return modelType.flatMap { ToolCallFormat.infer(from: $0, configData: configData) }
    }

    /// Detect tool-calling support from the template, tokenizer, and model type.
    private static func detectsTools(
        chatTemplate: String,
        tokenizerConfig: [String: Any]?,
        modelType: String?
    ) -> Bool {
        let lower = chatTemplate.lowercased()
        let toolMarkers = [
            "<tool_call>", "</tool_call>", "<|tool_call", "tool_calls", "tool_calling",
            "functions", "function_call", "[tool_calls]", "invoke"
        ]
        if toolMarkers.contains(where: lower.contains) { return true }

        if let tokenizerConfig {
            if tokenizerConfig["tool_call_template"] != nil { return true }

            if let added = tokenizerConfig["added_tokens_decoder"] as? [String: Any] {
                for (_, value) in added {
                    guard let token = value as? [String: Any],
                          let content = token["content"] as? String else { continue }
                    if content.lowercased().contains("tool") { return true }
                }
            }
        }

        let mt = (modelType ?? "").lowercased()
        let knownToolFamilies = [
            "qwen3", "nemotron", "llama", "gemma", "glm4", "mistral3",
            "deepseek", "minimax", "kimi"
        ]
        return knownToolFamilies.contains { mt.hasPrefix($0) }
    }

    /// Pull recommended sampling defaults from generation_config.json, falling
    /// back to config.json, and clamping clearly-invalid values.
    private static func extractSampling(
        generationConfig: [String: Any]?,
        config: [String: Any]?
    ) -> (temperature: Double?, topP: Double?, repetitionPenalty: Double?, maxTokens: Int?) {
        let merged = generationConfig ?? config ?? [:]

        let temperature = merged["temperature"] as? Double
            ?? merged["do_sample_temperature"] as? Double
        let topP = merged["top_p"] as? Double
        let repetitionPenalty = merged["repetition_penalty"] as? Double
        let maxTokens = merged["max_new_tokens"] as? Int
            ?? merged["max_position_embeddings"] as? Int

        return (
            temperature: clamped(temperature, min: 0.0, max: 2.0),
            topP: clamped(topP, min: 0.0, max: 1.0),
            repetitionPenalty: clamped(repetitionPenalty, min: 1.0, max: 2.0),
            maxTokens: maxTokens.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func clamped(_ value: Double?, min: Double, max: Double) -> Double? {
        guard let value else { return nil }
        let clamped = Swift.min(max, Swift.max(min, value))
        return clamped.isFinite ? clamped : nil
    }

    // MARK: - Report factory

    private static func report(
        modelType: String? = nil,
        supportsTools: Bool = false,
        toolCallFormat: ToolCallFormat? = nil,
        supportsThinking: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        repetitionPenalty: Double? = nil,
        maxTokens: Int? = nil,
        errors: [String]
    ) -> ModelCapabilityReport {
        ModelCapabilityReport(
            modelType: modelType,
            supportsTools: supportsTools,
            toolCallFormat: toolCallFormat,
            supportsThinking: supportsThinking,
            recommendedTemperature: temperature,
            recommendedTopP: topP,
            recommendedRepetitionPenalty: repetitionPenalty,
            recommendedMaxTokens: maxTokens,
            validationErrors: errors,
            validatedAt: Date()
        )
    }
}
