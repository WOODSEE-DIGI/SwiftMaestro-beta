import Foundation
import MLXLLM
import MLXVLM
import MLXLMCommon

// MARK: - MaestroModel

/// A model available in SwiftMaestro — either from the built-in registry,
/// a local directory, or downloadable from HuggingFace Hub.
struct MaestroModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let huggingFaceID: String
    let isVision: Bool
    var localPath: String?
    let estimatedMemoryGB: Int
    /// Whether this model has passed the tool-calling round-trip verification.
    /// Per the verify-per-model rule, only verified models get tools advertised;
    /// unverified models run as plain chat to avoid a broken tool path.
    var supportsTools: Bool = false
    /// The tool-call wire format this checkpoint emits (XML function/parameter
    /// for Qwen3-Coder/3.5/3.6, JSON/Hermes for classic Qwen3, etc.). Passed
    /// explicitly to the in-process loader so parsing never silently depends on
    /// mlx-swift-lm inferring it from config.json's `model_type`. `nil` = let
    /// mlx infer (its default is the JSON/Hermes format).
    var toolCallFormat: ToolCallFormat? = nil
    /// Per-model recommended sampling, used unless the user overrides via the
    /// Tuning tab. Avoids running every model at one global temperature.
    var recTemperature: Double? = nil
    var recTopP: Double? = nil
    var recRepetitionPenalty: Double? = nil
    /// Per-model recommended max output tokens. nil = use global default (32768).
    var recMaxTokens: Int? = nil
    /// Per-model recommended context length in tokens. nil = use global default (128000).
    var recContextLength: Int? = nil
    /// Active (non-expert) parameter count in billions. MoE models like
    /// 35B-A3B have only 3B active per token; dense models match their total.
    /// Used to decide lite-mode tool sets (models with <10B active params
    /// get a reduced tool set to avoid overwhelming the smaller model).
    var activeParamsB: Int? = nil
    var isLiteModel: Bool { (activeParamsB ?? 999) < 10 }
    /// LM Studio endpoint URL (e.g. `http://localhost:1234`). When set,
    /// the model runs on a remote LM Studio server instead of in-process MLX.
    var remoteBaseURL: String? = nil
    var isRemote: Bool { remoteBaseURL != nil }
    /// HuggingFace download URL shown in Settings so users can grab the model.
    var downloadURL: String? = nil
    /// Whether this entry should appear in the main model picker.
    /// Hidden models (e.g., the vision proxy model) are still loadable.
    var isHidden: Bool = false

    /// Tools are advertised only when the model is verified AND its tool-call
    /// format is known or can be inferred. No known format ⇒ no tools.
    var advertisesTools: Bool {
        supportsTools && (toolCallFormat != nil || mayInferToolFormat)
    }

    /// Whether the mlx-swift-lm loader can infer the tool call format from the
    /// model's config.json model_type. Qwen3.5/3.6, Nemotron, Llama 3, Gemma,
    /// GLM4, LFM2, Mistral3, and others are supported.
    private var mayInferToolFormat: Bool {
        let inferrable = ["qwen3", "qwen3_5", "qwen3_next", "nemotron",
                          "llama", "gemma", "glm4", "lfm2", "mistral3"]
        let type = huggingFaceID.lowercased()
        return inferrable.contains { type.contains($0) }
    }

    var modelConfiguration: ModelConfiguration {
        if let localPath {
            return ModelConfiguration(
                directory: URL(fileURLWithPath: localPath),
                toolCallFormat: toolCallFormat
            )
        }
        return ModelConfiguration(id: huggingFaceID, toolCallFormat: toolCallFormat)
    }

    /// True when the model's local directory actually contains at least one
    /// `.safetensors` weight file. A directory with only JSON/tokenizer files
    /// is considered incomplete and should not be treated as downloaded.
    ///
    /// This is intentionally lenient (presence, not completeness) — it's used
    /// as a cheap first gate before the real check. Use
    /// `hasCompleteLocalWeights` (or `ModelFileHealthService.weightsAreComplete`
    /// directly) to also verify every shard `model.safetensors.index.json`
    /// declares is actually present, which this property does NOT check.
    var hasLocalWeights: Bool {
        guard let localPath else { return false }
        let url = URL(fileURLWithPath: localPath)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return false }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "safetensors" { return true }
        }
        return false
    }

    /// True when `hasLocalWeights` AND every weight shard the checkpoint
    /// actually needs (per `model.safetensors.index.json`) is present on
    /// disk. This is the check that should gate "safe to load" and "show as
    /// fully downloaded" — an interrupted download can leave some shards
    /// present and others missing, which `hasLocalWeights` alone can't catch.
    var hasCompleteLocalWeights: Bool {
        hasLocalWeights && ModelFileHealthService.weightsAreComplete(for: self)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MaestroModel, rhs: MaestroModel) -> Bool { lhs.id == rhs.id }
}

// MARK: - Per-model tuning

extension MaestroModel {
    /// UserDefaults key for a per-model sampling override. Absence of the key
    /// means "use this model's recommended value". Shared by the Tuning tab
    /// (which writes overrides) and the generation path (which reads them) so
    /// the key format can never drift between writer and reader.
    static func tuningKey(_ modelID: String, _ param: String) -> String {
        "tuning.model.\(modelID).\(param)"
    }

    /// Effective sampling for THIS model: the user's per-model override if set,
    /// otherwise the model's recommended value, otherwise a safe default. This
    /// replaces the old single global `tuning.*` value, which silently clamped
    /// every model to one temperature/top-P regardless of its recommendation.
    var tunedTemperature: Double {
        (UserDefaults.standard.object(forKey: Self.tuningKey(id, "temperature")) as? Double)
            ?? recTemperature ?? 1.0
    }
    var tunedTopP: Double {
        (UserDefaults.standard.object(forKey: Self.tuningKey(id, "topP")) as? Double)
            ?? recTopP ?? 0.95
    }
    var tunedRepetitionPenalty: Double {
        (UserDefaults.standard.object(forKey: Self.tuningKey(id, "repetitionPenalty")) as? Double)
            ?? recRepetitionPenalty ?? 1.05
    }

    /// Effective max output tokens for THIS model: the user's per-model override
    /// if set, otherwise the model's recommended value, otherwise 32768.
    /// Controls the maximum number of tokens the model will generate per response.
    var tunedMaxTokens: Int {
        let key = Self.tuningKey(id, "maxTokens")
        if let override = UserDefaults.standard.object(forKey: key) as? Int {
            return override
        }
        return recMaxTokens ?? 32768
    }

    /// Effective context-window size for THIS model: the user's per-model override
    /// if set, otherwise the model's recommended value, otherwise 128000.
    /// Used to decide when chat-history compaction should run.
    var tunedContextLength: Int {
        let key = Self.tuningKey(id, "contextLength")
        if let override = UserDefaults.standard.object(forKey: key) as? Int {
            return override
        }
        return recContextLength ?? 128_000
    }

    var tunedThinkingEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.tuningKey(id, "thinking")) as? Bool)
            ?? false
    }
}

// MARK: - ModelCatalog

/// Manages the list of available models — built-in, local, and user-added.
@Observable
@MainActor
final class ModelCatalog {

    private(set) var models: [MaestroModel] = []
    /// Persisted across launches (UserDefaults) so the user's model choice
    /// sticks instead of resetting to the first catalog entry every launch.
    var selectedModelID: String? {
        didSet {
            guard selectedModelID != oldValue else { return }
            UserDefaults.standard.set(selectedModelID, forKey: Self.selectedModelKey)
        }
    }

    static let selectedModelKey = "models.selectedModelID"
    /// Launch default when no selection has been persisted yet. The 8-bit
    /// Gemma 4 navigator — good quality at 26GB, fits 64GB M1 minimum spec.
    nonisolated static let defaultModelID = "local-gemma4-26b"

    var selectedModel: MaestroModel? {
        guard let id = selectedModelID else { return models.first }
        return models.first { $0.id == id } ?? models.first
    }

    /// Look up a model by its catalog id (e.g. `local-qwen3.5-122b`).
    /// Also accepts unprefixed ids (`qwen3.5-122b`), display-name matches,
    /// and HuggingFace repo ids, so model hints from the LLM resolve robustly.
    /// Returns the first match; use `matchingModels(for:)` to inspect all
    /// matches and pick one based on local-weights availability.
    func model(forID id: String?) -> MaestroModel? {
        guard let id, !id.isEmpty else { return nil }
        if let exact = models.first(where: { $0.id == id }) { return exact }
        let target = Self.normalized(id)
        return models.first {
            Self.normalized($0.id) == target
            || Self.normalized($0.displayName) == target
            || $0.huggingFaceID.lowercased() == id.lowercased()
        }
    }

    /// Return every model that matches the given id/name/hf-id hint. Used when
    /// the hint is ambiguous (e.g. "qwen coder" matches several Qwen Coder
    /// variants) so the caller can prefer the one with local weights installed.
    func matchingModels(for id: String?) -> [MaestroModel] {
        guard let id, !id.isEmpty else { return [] }
        if let exact = models.first(where: { $0.id == id }) { return [exact] }
        let target = Self.normalized(id)
        return models.filter {
            Self.normalized($0.id) == target
            || Self.normalized($0.displayName) == target
            || $0.huggingFaceID.lowercased() == id.lowercased()
        }
    }

    /// Case- and punctuation-insensitive normalization for model id/name lookup.
    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "local-", with: "")
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")
    }

    /// The model an agent should run: its per-agent override if set and still
    /// known, otherwise the global selected model.
    func effectiveModel(for agent: AgentRecord) -> MaestroModel? {
        model(forID: agent.modelID) ?? selectedModel
    }

    // MARK: - Vision Proxy

    /// Persistent configuration for the vision proxy feature.
    struct VisionProxyConfiguration: Codable, Equatable {
        var isEnabled: Bool = true
        var provider: Provider = .pythonServer
        var inProcessModelPath: String = ModelCatalog.defaultVisionProxyModelPath
        var serverHost: String = "localhost"
        var serverPort: Int = 8765
        var serverScriptPath: String = VisionProxyServerScript.installedPath
        var serverModelPath: String = VisionProxyServerScript.defaultModelPath
        var captionPrompt: String = "Describe this image concisely in one sentence."
        var maxCaptionTokens: Int = 128

        enum Provider: String, Codable, CaseIterable, Equatable {
            case inProcess = "In-Process MLX"
            case pythonServer = "Python Server"
        }
    }

    /// Default path to the SwiftMaestro vision proxy model.
    /// Resolved relative to the user's configured `modelsRoot` so the proxy uses the
    /// same model directory as the rest of the catalog.
    nonisolated static var defaultVisionProxyModelPath: String {
        (Self.modelsRoot as NSString).appendingPathComponent("mlx-community/Qwen3-VL-8B-Instruct-4bit")
    }

    /// Current vision proxy configuration. Persisted to UserDefaults.
    var visionProxyConfig: VisionProxyConfiguration {
        get {
            if let data = UserDefaults.standard.data(forKey: "visionProxy.config"),
               let decoded = try? JSONDecoder().decode(VisionProxyConfiguration.self, from: data) {
                return decoded
            }
            return VisionProxyConfiguration()
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: "visionProxy.config")
            }
        }
    }

    /// Build a loadable model for the vision proxy. Uses the configured path if it
    /// exists on disk, otherwise falls back to the built-in vision entry.
    func visionProxyModel() -> MaestroModel {
        let config = visionProxyConfig
        let path = config.inProcessModelPath
        let exists = FileManager.default.fileExists(atPath: path)
        return MaestroModel(
            id: "vision-proxy-qwen3-vl",
            displayName: "Qwen3-VL 8B Vision Proxy",
            huggingFaceID: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
            isVision: true,
            localPath: exists ? path : Self.builtInModels.first { $0.id == "local-qwen3-vl-8b-4bit" }?.localPath,
            estimatedMemoryGB: 6,
            isHidden: true
        )
    }

    init() {
        models = Self.builtInModels
        // Restore the persisted selection if it still resolves to a known model;
        // otherwise fall back to the configured default (then first entry).
        let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey)
        if let saved, models.contains(where: { $0.id == saved }) {
            selectedModelID = saved
        } else if models.contains(where: { $0.id == Self.defaultModelID }) {
            selectedModelID = Self.defaultModelID
        } else {
            selectedModelID = models.first?.id
        }
    }

    // MARK: - Local models

    /// Customer-writable root where MLX models are stored / downloaded. Defaults
    /// to the app-support "models" dir (portable to ANY macOS user); override via
    /// the `models.localRoot` UserDefault (Settings → Models) to point at an
    /// existing collection (e.g. an external drive on a dev machine).
    nonisolated static var modelsRoot: String {
        let override = UserDefaults.standard.string(forKey: "models.localRoot")
        if let override, !override.isEmpty { return override }
        return SwiftMaestroPaths.modelsDir.path
    }

    /// Resolve a model's local directory under `modelsRoot` ONLY if it exists on
    /// disk; otherwise return nil so the model is pulled from Hugging Face Hub by
    /// its `huggingFaceID` on first use. This is what makes a fresh install work
    /// with no preinstalled models.
    nonisolated static func localIfPresent(_ subdir: String) -> String? {
        let path = (modelsRoot as NSString).appendingPathComponent(subdir)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Try several candidate subdirectories under `modelsRoot` and return the
    /// first one that exists. Used when a model may have been downloaded to
    /// different folder conventions (e.g. `swiftmaestro-models/` vs the raw
    /// HuggingFace org/repo layout).
    nonisolated static func localIfPresent(_ subdirs: [String]) -> String? {
        for subdir in subdirs {
            if let path = localIfPresent(subdir) { return path }
        }
        return nil
    }

    static let builtInModels: [MaestroModel] = [
        // === Local models (already downloaded) ===
        // Loaded in-process from the swiftmaestro-models scan dir.
        MaestroModel(
            id: "local-qwen3.6-35b-a3b",
            displayName: "Qwen 3.6 35B-A3B",
            huggingFaceID: "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3.6-35B-A3B-MLX-4bit"),
            estimatedMemoryGB: 20,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 0.8, recTopP: 0.9, recRepetitionPenalty: 1.15,
            recContextLength: 131_072,
            activeParamsB: 3,
            downloadURL: "https://huggingface.co/lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit"
        ),
        MaestroModel(
            id: "local-qwen3.6-27b",
            displayName: "Qwen 3.6 27B (dense)",
            huggingFaceID: "mlx-community/Qwen3.6-27B-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3.6-27B-4bit"),
            estimatedMemoryGB: 15,
            toolCallFormat: .xmlFunction,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recContextLength: 128_000,
            activeParamsB: 27,
            downloadURL: "https://huggingface.co/mlx-community/Qwen3.6-27B-4bit"
        ),
        MaestroModel(
            id: "local-qwen3.6-35b-a3b-8bit",
            displayName: "Qwen 3.6 35B-A3B (8-bit)",
            huggingFaceID: "mlx-community/Qwen3.6-35B-A3B-8bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3.6-35B-A3B-8bit"),
            estimatedMemoryGB: 35,
            toolCallFormat: .xmlFunction,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recContextLength: 131_072,
            activeParamsB: 3,
            downloadURL: "https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-8bit"
        ),
        MaestroModel(
            id: "local-gemma4-12b",
            displayName: "Gemma 4 12B (4-bit)",
            huggingFaceID: "lmstudio-community/gemma-4-12B-it-MLX-4bit",
            isVision: false,
            localPath: localIfPresent([
                "swiftmaestro-models/gemma-4-12B-it-MLX-4bit",
                "lmstudio-community/gemma-4-12B-it-MLX-4bit",
            ]),
            estimatedMemoryGB: 11,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 12,
            downloadURL: "https://huggingface.co/lmstudio-community/gemma-4-12B-it-MLX-4bit"
        ),
        MaestroModel(
            id: "local-gemma4-26b-4bit",
            displayName: "Gemma 4 26B-A4B (Vision+Text, 4-bit)",
            huggingFaceID: "lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/gemma-4-26B-A4B-it-MLX-4bit"),
            estimatedMemoryGB: 16,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 4,
            downloadURL: "https://huggingface.co/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit"
        ),
        MaestroModel(
            id: "local-gemma4-26b",
            displayName: "Gemma 4 26B-A4B (Vision+Text, 8-bit, default)",
            huggingFaceID: "lmstudio-community/gemma-4-26B-A4B-it-MLX-8bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/gemma-4-26B-A4B-it-MLX-8bit"),
            estimatedMemoryGB: 26,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 4,
            downloadURL: "https://huggingface.co/lmstudio-community/gemma-4-26B-A4B-it-MLX-8bit"
        ),
        MaestroModel(
            id: "local-gemma4-26b-qat-4bit",
            displayName: "Gemma 4 26B-A4B QAT 4-bit (Vision+Text)",
            huggingFaceID: "lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/gemma-4-26B-A4B-it-QAT-MLX-4bit"),
            estimatedMemoryGB: 18,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 4,
            downloadURL: "https://huggingface.co/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit"
        ),
        MaestroModel(
            id: "local-gemma4-26b-a4b",
            displayName: "Gemma 4 26B-A4B (Vision+Text, mlx-community 4-bit)",
            huggingFaceID: "mlx-community/gemma-4-26b-a4b-it-4bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/gemma-4-26b-a4b-it-4bit"),
            estimatedMemoryGB: 16,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 4,
            downloadURL: "https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-4bit"
        ),
        MaestroModel(
            id: "local-gemma4-31b-it",
            displayName: "Gemma 4 31B (Vision+Text, QAT 4-bit)",
            huggingFaceID: "mlx-community/gemma-4-31b-it-qat-4bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/gemma-4-31b-it-qat-4bit"),
            estimatedMemoryGB: 17,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 31,
            downloadURL: "https://huggingface.co/mlx-community/gemma-4-31b-it-qat-4bit"
        ),
        MaestroModel(
            id: "local-gemma4-e4b",
            displayName: "Gemma 4 E4B (Vision+Text, small)",
            huggingFaceID: "mlx-community/gemma-4-e4b-it-qat-4bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/gemma-4-e4b-it-qat-4bit"),
            estimatedMemoryGB: 4,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 4,
            downloadURL: "https://huggingface.co/mlx-community/gemma-4-e4b-it-qat-4bit"
        ),
        MaestroModel(
            id: "local-qwen3-coder-30b-a3b",
            displayName: "Qwen 3 Coder 30B-A3B (Instruct)",
            huggingFaceID: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
            isVision: false,
            localPath: localIfPresent([
                "swiftmaestro-models/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
                "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
            ]),
            estimatedMemoryGB: 17,
            // Same XML <function>/<parameter> format as Qwen 3.6/3.5 family.
            // Tools enabled — the coder model is a strong choice for sub-agents.
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 0.7, recTopP: 0.8, recRepetitionPenalty: 1.05,
            recMaxTokens: 65536,
            recContextLength: 128_000,
            activeParamsB: 3
        ),
        MaestroModel(
            id: "local-qwen3.5-27b",
            displayName: "Qwen 3.5 27B (Opus Distilled)",
            huggingFaceID: "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
            isVision: false,
            localPath: localIfPresent([
                "swiftmaestro-models/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
                "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
            ]),
            estimatedMemoryGB: 14,
            supportsTools: true,  // Qwen 3.5 family uses xmlFunction
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.05,
            recContextLength: 262_144,
            activeParamsB: 27
        ),
        MaestroModel(
            id: "local-qwen3.5-122b",
            displayName: "Qwen 3.5 122B (A10B)",
            huggingFaceID: "mlx-community/Qwen3.5-122B-A10B-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3.5-122B-A10B-4bit"),
            estimatedMemoryGB: 65,
            // In-process load works with the current mlx-swift-lm loader, which
            // quantizes a module only when the checkpoint has its `.scales`
            // (Load.swift). This checkpoint's lm_head IS quantized, so the old
            // "lm_head not found" failure (an older loader) no longer applies.
            // Confirmed: this checkpoint's chat_template uses the same XML
            // <function>/<parameter> tool format as the 3.6 default
            // (qwen3_5_moe), so the xmlFunction parser applies identically.
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recMaxTokens: 200_000,
            recContextLength: 262_144,
            activeParamsB: 10
        ),
        MaestroModel(
            id: "local-hermes-70b",
            displayName: "Hermes 4 70B (4-bit)",
            huggingFaceID: "lmstudio-community/Hermes-4-70B-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Hermes-4-70B-MLX-4bit"),
            estimatedMemoryGB: 56
        ),
        MaestroModel(
            id: "local-magistral-small",
            displayName: "Magistral Small 2509",
            huggingFaceID: "lmstudio-community/Magistral-Small-2509-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Magistral-Small-2509-MLX-4bit"),
            estimatedMemoryGB: 13
        ),
        MaestroModel(
            id: "local-deepseek-r1-8b",
            displayName: "DeepSeek R1 0528 (Qwen3 8B)",
            huggingFaceID: "lmstudio-community/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit"),
            estimatedMemoryGB: 4,
            supportsTools: true,  // Qwen3-based, format inferred from model_type
            recTemperature: 0.6, recTopP: 0.95, recRepetitionPenalty: 1.1
        ),
        MaestroModel(
            id: "local-gpt-oss-20b",
            displayName: "GPT-OSS 20B",
            huggingFaceID: "mlx-community/gpt-oss-20b-MXFP4-Q8",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/gpt-oss-20b-MXFP4-Q8"),
            estimatedMemoryGB: 11
        ),
        MaestroModel(
            id: "local-deepseek-vl2-small",
            displayName: "DeepSeek VL2 Small (Vision)",
            huggingFaceID: "mlx-community/deepseek-vl2-small-4bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/deepseek-vl2-small-4bit"),
            estimatedMemoryGB: 9
        ),
        MaestroModel(
            id: "local-qwen3-vl-8b-4bit",
            displayName: "Qwen3-VL 8B (Vision Proxy)",
            huggingFaceID: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
            isVision: true,
            localPath: localIfPresent("swiftmaestro-models/Qwen3-VL-8B-Instruct-4bit"),
            estimatedMemoryGB: 6
        ),
        MaestroModel(
            id: "local-nemotron-30b",
            displayName: "Nemotron Cascade 30B (A3B)",
            huggingFaceID: "JANGQ-AI/Nemotron-Cascade-2-30B-A3B-JANG_4M",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Nemotron-Cascade-2-30B-A3B-JANG_4M"),
            estimatedMemoryGB: 1
        ),

        // === Larger MLX models (download on first use) ===
        MaestroModel(
            id: "local-qwen3.5-35b-a3b",
            displayName: "Qwen 3.5 35B-A3B",
            huggingFaceID: "mlx-community/Qwen3.5-35B-A3B-OptiQ-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3.5-35B-A3B-OptiQ-4bit"),
            estimatedMemoryGB: 20,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recContextLength: 262_144,
            activeParamsB: 3
        ),
        MaestroModel(
            id: "local-qwen3-coder-next",
            displayName: "Qwen 3 Coder Next",
            huggingFaceID: "mlx-community/Qwen3-Coder-Next-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3-Coder-Next-4bit"),
            estimatedMemoryGB: 45,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 0.7, recTopP: 0.8, recRepetitionPenalty: 1.05,
            recContextLength: 128_000
        ),
        MaestroModel(
            id: "local-gpt-oss-120b",
            displayName: "GPT-OSS 120B",
            huggingFaceID: "mlx-community/gpt-oss-120b-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/gpt-oss-120b-4bit"),
            estimatedMemoryGB: 60,
            supportsTools: true,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recContextLength: 128_000
        ),

        // === Experimental / ultra-tier models (download on first use, very high memory) ===
        MaestroModel(
            id: "hub-deepseek-v4-flash",
            displayName: "DeepSeek V4-Flash (4-bit, 1M context)",
            huggingFaceID: "mlx-community/DeepSeek-V4-Flash-4bit",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 151,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "hub-glm-5.1",
            displayName: "GLM-5.1 (MIT, coding)",
            huggingFaceID: "mlx-community/GLM-5.1",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 150,
            toolCallFormat: .glm4,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "hub-minimax-m2.7",
            displayName: "MiniMax M2.7 (4-bit, agentic)",
            huggingFaceID: "mlx-community/MiniMax-M2.7-4bit",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 128,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "hub-kimi-k2.6",
            displayName: "Kimi K2.6 (DQ3, 512 GB Mac)",
            huggingFaceID: "mlx-community/Kimi-K2.6-mlx-DQ3_K_M-q8",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 186,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "hub-llama4-scout",
            displayName: "Llama 4 Scout (4-bit, 10M context)",
            huggingFaceID: "mlx-community/meta-llama-Llama-4-Scout-17B-16E-4bit",
            isVision: true,
            localPath: nil,
            estimatedMemoryGB: 60,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),

        // === Hub models (download on first use) ===
        MaestroModel(
            id: "hub-qwen3-8b",
            displayName: "Qwen 3 8B (Hub)",
            huggingFaceID: "mlx-community/Qwen3-8B-4bit",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 6
        ),
        MaestroModel(
            id: "hub-qwen3-4b",
            displayName: "Qwen 3 4B (Hub)",
            huggingFaceID: "mlx-community/Qwen3-4B-4bit",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 3
        ),
        MaestroModel(
            id: "hub-gemma3n-e4b",
            displayName: "Gemma 3n E4B (Hub)",
            huggingFaceID: "mlx-community/gemma-3n-E4B-it-lm-4bit",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 3,
            supportsTools: true,  // Gemma family, format inferred from model_type
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "hub-llama3.2-1b",
            displayName: "Llama 3.2 1B (Hub)",
            huggingFaceID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            isVision: false,
            localPath: nil,
            estimatedMemoryGB: 1
        ),
    ]

    // MARK: - Add custom model

    func addLocalModel(name: String, path: String, huggingFaceID: String, isVision: Bool, memoryGB: Int) {
        let model = MaestroModel(
            id: "local-\(UUID().uuidString.prefix(8))",
            displayName: name,
            huggingFaceID: huggingFaceID,
            isVision: isVision,
            localPath: path,
            estimatedMemoryGB: memoryGB
        )
        models.append(model)
        Task { await validateAndUpdateCapabilities(for: model.id) }
    }

    func addHubModel(name: String, huggingFaceID: String, isVision: Bool, memoryGB: Int) {
        let model = MaestroModel(
            id: "hub-\(huggingFaceID.replacingOccurrences(of: "/", with: "-"))",
            displayName: name,
            huggingFaceID: huggingFaceID,
            isVision: isVision,
            localPath: nil,
            estimatedMemoryGB: memoryGB
        )
        models.append(model)
    }

    /// Re-read a model's on-disk config files and merge discovered capabilities
    /// into its catalog entry. Only promotes capabilities (never demotes a
    /// built-in `supportsTools=true` to false) and fills missing sampling
    /// defaults so user-added local models behave correctly without manual tuning.
    func validateAndUpdateCapabilities(for id: String) async {
        guard let index = models.firstIndex(where: { $0.id == id }),
              let localPath = models[index].localPath else { return }

        let report = ModelCapabilityValidator.validate(modelDirectory: localPath)
        var model = models[index]

        if report.supportsTools {
            model.supportsTools = true
        }
        if let format = report.toolCallFormat, model.toolCallFormat == nil {
            model.toolCallFormat = format
        }
        if model.recTemperature == nil {
            model.recTemperature = report.recommendedTemperature
        }
        if model.recTopP == nil {
            model.recTopP = report.recommendedTopP
        }
        if model.recRepetitionPenalty == nil {
            model.recRepetitionPenalty = report.recommendedRepetitionPenalty
        }
        if model.recMaxTokens == nil {
            model.recMaxTokens = report.recommendedMaxTokens
        }

        models[index] = model

        if !report.validationErrors.isEmpty {
            NSLog("[ModelCapabilityValidator] \(id): \(report.validationErrors.joined(separator: "; "))")
        }
    }

    /// Re-evaluate capabilities for every catalog entry that has resolved a local path.
    func refreshCapabilities() async {
        for id in models.map(\.id) {
            await validateAndUpdateCapabilities(for: id)
        }
    }

    func removeModel(_ id: String) {
        models.removeAll { $0.id == id }
        if selectedModelID == id { selectedModelID = models.first?.id }
    }

    /// Re-evaluate `localIfPresent` for every built-in model so the UI reflects
    /// newly downloaded files without a relaunch, then refresh each model's
    /// discovered capabilities from its on-disk config.
    func refreshLocalPaths() {
        for i in models.indices {
            guard let sub = Self.localSubdir(for: models[i]) else { continue }
            models[i].localPath = Self.localIfPresent(sub)
        }
        Task { await refreshCapabilities() }
    }

    /// Derive the `localIfPresent` subdirectory for a model. All built-in
    /// local models are expected under the `swiftmaestro-models/` prefix so
    /// the layout is predictable and not fragmented across HF org folders.
    private static func localSubdir(for model: MaestroModel) -> String? {
        let repoName = model.huggingFaceID.components(separatedBy: "/").last ?? model.huggingFaceID
        return "swiftmaestro-models/\(repoName)"
    }
}
