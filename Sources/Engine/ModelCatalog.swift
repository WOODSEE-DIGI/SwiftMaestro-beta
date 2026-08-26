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
    /// Maximum KV cache size per layer (in tokens). When set, uses RotatingKVCache
    /// instead of KVCacheSimple, which evicts oldest entries (except first 4) when
    /// the limit is reached. Critical for large models where unbounded KV cache
    /// growth can exceed Metal's ~80GB single-buffer allocation limit.
    /// nil = unbounded (current default — risky for models >40GB).
    var maxKVSize: Int? = nil
    /// Active (non-expert) parameter count in billions. MoE models like
    /// 35B-A3B have only 3B active per token; dense models match their total.
    /// Used to decide lite-mode tool sets (models with <10B active params
    /// get a reduced tool set to avoid overwhelming the smaller model).
    var activeParamsB: Int? = nil
    var isLiteModel: Bool { (activeParamsB ?? 999) < 10 }
    /// Token count at which chat-history compaction should trigger for this
    /// model. MoE models with low active params (e.g. 3-4B) hit generation
    /// speed cliffs well before their nominal context window; setting this
    /// lower forces compaction before degradation. Nil = use the default
    /// formula (contextLength - maxTokens).
    var compactionThreshold: Int? = nil
    /// LM Studio endpoint URL (e.g. `http://localhost:1234`). When set,
    /// the model runs on a remote LM Studio server instead of in-process MLX.
    var remoteBaseURL: String? = nil
    var isRemote: Bool { remoteBaseURL != nil }
    /// Which remote provider serves this model (nil = local in-process MLX).
    /// Drives the color-coded badge in model pickers.
    var remoteProviderKind: RemoteProviderKind? = nil

    /// Badge for pickers: (SF Symbol, color name) distinguishing local MLX
    /// models from each remote provider kind at a glance.
    var providerBadge: (icon: String, colorName: String) {
        guard let kind = remoteProviderKind else {
            return ("cpu", "green")            // local in-process MLX
        }
        switch kind {
        case .lmStudio: return ("server.rack", "blue")
        case .ollama: return ("shippingbox", "purple")
        case .online: return ("globe", "orange")
        }
    }
    /// Idle timeout for remote streaming requests. Deltafin/K3 needs minutes
    /// of prefill tolerance; LM Studio's resident models are fine at 120s.
    var remoteRequestTimeout: TimeInterval? = nil
    /// `secret://` reference for a remote provider's API key (online
    /// providers). NEVER a raw key — resolved at the HTTP boundary via
    /// SecretsStore, per the app's secrets policy.
    var remoteAPIKeyRef: String? = nil
    /// HuggingFace download URL shown in Settings so users can grab the model.
    var downloadURL: String? = nil
    /// Whether this entry should appear in the main model picker.
    /// Hidden models (e.g., the vision proxy model) are still loadable.
    var isHidden: Bool = false

    /// Tools are advertised only when the model is verified AND its tool-call
    /// format is known or can be inferred. No known format ⇒ no tools.
    /// Remote models are exempt from the wire-format check: the remote backend
    /// speaks OpenAI function calling over HTTP, so `toolCallFormat` (an MLX
    /// wire-format concept) simply doesn't apply to them.
    var advertisesTools: Bool {
        if isRemote { return supportsTools }
        return supportsTools && (toolCallFormat != nil || mayInferToolFormat)
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

    /// Effective compaction threshold for THIS model: the model's explicit
    /// `compactionThreshold` if set, otherwise the default formula. MoE models
    /// with low active params set this explicitly to avoid generation speed
    /// cliffs that occur well before the nominal context window is filled.
    var effectiveCompactionThreshold: Int {
        if let explicit = compactionThreshold { return explicit }
        return tunedContextLength - max(tunedMaxTokens, 20_000)
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
    /// Gemma 4 Maestro — good quality at 26GB, fits 64GB M1 minimum spec.
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
    /// same model directory as the rest of the catalog. Checks the actual download
    /// convention FIRST (performDownload lands in `swiftmaestro-models/<repo>`),
    /// then the legacy `mlx-community/` layout; defaults to the download
    /// destination so a fresh download resolves the moment it completes.
    nonisolated static var defaultVisionProxyModelPath: String {
        localIfPresent([
            "swiftmaestro-models/Qwen3-VL-8B-Instruct-4bit",
            "mlx-community/Qwen3-VL-8B-Instruct-4bit",
        ]) ?? (Self.modelsRoot as NSString)
            .appendingPathComponent("swiftmaestro-models/Qwen3-VL-8B-Instruct-4bit")
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
        rebuildRemoteModels()
        // Rebuild the remote section whenever providers change (Settings →
        // Models → Remote Providers edits take effect immediately, no relaunch).
        NotificationCenter.default.addObserver(
            forName: RemoteProviderStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildRemoteModels() }
        }
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

    /// Replace the remote section of the catalog with the current providers'
    /// models. Remote entries carry the "remote-" id prefix and no local path,
    /// so they never collide with built-in or Hub-added local models.
    private func rebuildRemoteModels() {
        models.removeAll { $0.id.hasPrefix("remote-") }
        models.append(contentsOf: RemoteProviderStore.shared.catalogModels())
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

    /// The Mechanic agent's bundled model id (Qwen3-4B instruct, tool-verified).
    nonisolated static let mechanicModelID = "swiftmaestro-mechanic-qwen3-4b"

    /// True when a Mechanic model is on disk under modelsRoot — the fine-tuned
    /// specialist (SwiftMaestro-Mechanic-4bit) is preferred; the stock
    /// Qwen3-4B instruct model serves until a fine-tune exists.
    nonisolated static var mechanicModelAvailable: Bool {
        localIfPresent(["swiftmaestro-models/SwiftMaestro-Mechanic-4bit", "mlx-community/SwiftMaestro-Mechanic-4bit"]) != nil
            || localIfPresent(["swiftmaestro-models/Qwen3-4B-Instruct-2507-4bit", "mlx-community/Qwen3-4B-Instruct-2507-4bit"]) != nil
    }

    /// Effective local path for the Mechanic model: fine-tuned specialist
    /// first, stock bundled model second. Nil when neither is installed.
    nonisolated static var mechanicModelPath: String? {
        localIfPresent(["swiftmaestro-models/SwiftMaestro-Mechanic-4bit", "mlx-community/SwiftMaestro-Mechanic-4bit"])
            ?? localIfPresent(["swiftmaestro-models/Qwen3-4B-Instruct-2507-4bit", "mlx-community/Qwen3-4B-Instruct-2507-4bit"])
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
        // ── Primary: Verified & Daily-Use ──────────────────────────────────

        // Mechanic support model — small, tool-verified, bundled in every DMG
        // so in-app help works even on fresh/broken installs with nothing else
        // configured. The Mechanic agent references it by id; it also appears
        // in the picker so Light-install users have a tiny bundled chat model.
        MaestroModel(
            id: "swiftmaestro-mechanic-qwen3-4b",
            displayName: "SwiftMaestro Mechanic (Qwen3 4B)",
            huggingFaceID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            isVision: false,
            localPath: mechanicModelPath,
            estimatedMemoryGB: 3,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 0.6, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recContextLength: 32_768
        ),

        // Coding workhorse — MoE, fast inference, XML function calls.
        // 30B-A3B active params, 128K context, ~45 GB.
        // Low active params → compact early to avoid gen speed cliff.
        MaestroModel(
            id: "local-qwen3-coder-next",
            displayName: "Qwen 3 Coder Next",
            huggingFaceID: "mlx-community/Qwen3-Coder-Next-4bit",
            isVision: false,
            localPath: localIfPresent(["swiftmaestro-models/Qwen3-Coder-Next-4bit", "mlx-community/Qwen3-Coder-Next-4bit"]),
            estimatedMemoryGB: 45,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 0.7, recTopP: 0.8, recRepetitionPenalty: 1.05,
            recContextLength: 128_000,
            activeParamsB: 3,
            compactionThreshold: 32_000
        ),

        // General/reasoning powerhouse — MoE, 262K context, XML function calls.
        // 122B total, 10B active, ~65 GB.
        // NOTE: recMaxTokens reduced from 200K to 32K because the KV cache for
        // a 65GB model grows to ~200KB per token across ~100 layers. At 200K
        // output tokens the KV cache alone would need ~40GB, which combined
        // with the 65GB weights exceeds Metal's ~80GB single-buffer limit.
        // maxKVSize caps each layer's KV cache at 32K tokens using
        // RotatingKVCache, preventing the metal::malloc crash.
        MaestroModel(
            id: "local-qwen3.5-122b",
            displayName: "Qwen 3.5 122B (A10B)",
            huggingFaceID: "mlx-community/Qwen3.5-122B-A10B-4bit",
            isVision: false,
            localPath: localIfPresent(["swiftmaestro-models/Qwen3.5-122B-A10B-4bit", "mlx-community/Qwen3.5-122B-A10B-4bit"]),
            estimatedMemoryGB: 65,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recMaxTokens: 32_768,
            recContextLength: 262_144,
            maxKVSize: 32_000,
            activeParamsB: 10,
            compactionThreshold: 24_000
        ),

        // Vision+Text — Gemma 4 MoE with native image understanding.
        // 26B total, 4B active, 8-bit, ~26 GB. Default model on launch.
        // Low active params → compact early to avoid gen speed cliff.
        MaestroModel(
            id: "local-gemma4-26b",
            displayName: "Gemma 4 26B-A4B (Vision+Text, 8-bit)",
            huggingFaceID: "lmstudio-community/gemma-4-26B-A4B-it-MLX-8bit",
            isVision: true,
            localPath: localIfPresent(["swiftmaestro-models/gemma-4-26B-A4B-it-MLX-8bit", "lmstudio-community/gemma-4-26B-A4B-it-MLX-8bit"]),
            estimatedMemoryGB: 26,
            supportsTools: true,
            toolCallFormat: .gemma4,
            recTemperature: 0.7, recTopP: 0.9, recRepetitionPenalty: 1.1,
            recContextLength: 128_000,
            activeParamsB: 4,
            compactionThreshold: 20_000,
            downloadURL: "https://huggingface.co/lmstudio-community/gemma-4-26B-A4B-it-MLX-8bit"
        ),

        // ── Alternative: Large Dense ───────────────────────────────────────

        // DeepSeek Coder V2 Lite — MoE coding model, 16B total, 2.4B active.
        // 4-bit quantized, ~8 GB. Fast inference with strong code generation.
        MaestroModel(
            id: "local-deepseek-coder-v2-lite",
            displayName: "DeepSeek Coder V2 Lite (4-bit)",
            huggingFaceID: "mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx",
            isVision: false,
            localPath: localIfPresent(["swiftmaestro-models/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx", "mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx"]),
            estimatedMemoryGB: 8,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 0.6, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recContextLength: 128_000,
            activeParamsB: 2
        ),

        // Open-weight alternative — dense architecture, ~60 GB.
        MaestroModel(
            id: "local-gpt-oss-120b",
            displayName: "GPT-OSS 120B",
            huggingFaceID: "mlx-community/gpt-oss-120b-4bit",
            isVision: false,
            localPath: localIfPresent(["swiftmaestro-models/gpt-oss-120b-4bit", "mlx-community/gpt-oss-120b-4bit"]),
            estimatedMemoryGB: 60,
            supportsTools: true,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05,
            recContextLength: 128_000
        ),

        // Fast MoE alternative — 35B total, 3B active, ~20 GB.
        // Different tool-call format (Qwen3.5-style XML).
        // Low active params → compact early to avoid gen speed cliff.
        MaestroModel(
            id: "local-qwen3.6-35b-a3b",
            displayName: "Qwen 3.6 35B-A3B",
            huggingFaceID: "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
            isVision: false,
            localPath: localIfPresent(["swiftmaestro-models/Qwen3.6-35B-A3B-MLX-4bit", "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit"]),
            estimatedMemoryGB: 20,
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 0.8, recTopP: 0.9, recRepetitionPenalty: 1.15,
            recContextLength: 131_072,
            activeParamsB: 3,
            compactionThreshold: 24_000,
            downloadURL: "https://huggingface.co/lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit"
        ),

        // ── Utility: Vision Proxy & Embeddings (hidden from picker) ────────

        // NOT a chat model — sentence embeddings for local vector RAG via
        // MLXEmbedders. Hidden from picker; downloaded so embedding service works.
        MaestroModel(
            id: "local-qwen3-embedding-0.6b",
            displayName: "Qwen3 Embedding 0.6B (4-bit, RAG)",
            huggingFaceID: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            isVision: false,
            localPath: localIfPresent(["swiftmaestro-models/Qwen3-Embedding-0.6B-4bit-DWQ", "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"]),
            estimatedMemoryGB: 1,
            isHidden: true
        ),

        // Vision proxy — used internally for image captioning/description.
        MaestroModel(
            id: "local-qwen3-vl-8b-4bit",
            displayName: "Qwen3-VL 8B (Vision Proxy)",
            huggingFaceID: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
            isVision: true,
            localPath: localIfPresent(["swiftmaestro-models/Qwen3-VL-8B-Instruct-4bit", "mlx-community/Qwen3-VL-8B-Instruct-4bit"]),
            estimatedMemoryGB: 6
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
            let candidates = Self.localSubdirs(for: models[i])
            models[i].localPath = Self.localIfPresent(candidates)
        }
        // Auto-discover models in the models directory that aren't in the catalog.
        discoverUnlistedModels()
        Task { await refreshCapabilities() }
    }

    /// Derive candidate local subdirectories for a model. Checks all three
    /// known conventions so models downloaded via any mechanism are found:
    /// 1. `swiftmaestro-models/<repo>` — built-in download destination
    /// 2. `<org>/<repo>` — HuggingFace Hub / HubApi convention
    /// 3. `<repo>` — flat (models downloaded without org prefix)
    private static func localSubdirs(for model: MaestroModel) -> [String] {
        let parts = model.huggingFaceID.split(separator: "/", maxSplits: 1)
        let repoName = String(parts.last ?? Substring(model.huggingFaceID))
        var candidates = ["swiftmaestro-models/\(repoName)"]
        if parts.count == 2 {
            let org = String(parts[0])
            candidates.append("\(org)/\(repoName)")
        }
        candidates.append(repoName)
        return candidates
    }

    /// Auto-discover MLX model directories under `modelsRoot` that aren't
    /// already in the catalog. A valid model directory contains `config.json`
    /// (standard MLX/HuggingFace config) or `Weights.plist` (MLX weight index).
    /// Discovered models are appended to the catalog with sensible defaults.
    private func discoverUnlistedModels() {
        let root = URL(fileURLWithPath: Self.modelsRoot)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        // Build a set of known repo names already in the catalog.
        var knownRepos = Set(models.map { model -> String in
            model.huggingFaceID.components(separatedBy: "/").last ?? model.huggingFaceID
        })

        for orgEntry in contents {
            // Skip non-directories and the swiftmaestro-models bucket.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: orgEntry.path, isDirectory: &isDir),
                  isDir.boolValue,
                  orgEntry.lastPathComponent != "swiftmaestro-models" else { continue }

            // Scan one level deep for repo directories.
            guard let repoContents = try? FileManager.default.contentsOfDirectory(
                at: orgEntry, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for repoEntry in repoContents {
                var repoIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: repoEntry.path, isDirectory: &repoIsDir),
                      repoIsDir.boolValue else { continue }

                let repoName = repoEntry.lastPathComponent

                // Skip if already in the catalog.
                guard !knownRepos.contains(repoName) else { continue }

                // Check if this is a valid MLX model directory.
                let configPath = repoEntry.appendingPathComponent("config.json").path
                let weightsPath = repoEntry.appendingPathComponent("Weights.plist").path
                guard FileManager.default.fileExists(atPath: configPath)
                        || FileManager.default.fileExists(atPath: weightsPath) else { continue }

                // Derive org from parent directory name.
                let org = orgEntry.lastPathComponent
                let huggingFaceID = "\(org)/\(repoName)"

                // Estimate memory from directory size (rough heuristic).
                let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: repoEntry.path)[.size] as? Int64) ?? 0
                let sizeGB = max(1, Int(sizeBytes / (1024 * 1024 * 1024)))

                let discovered = MaestroModel(
                    id: "discovered-\(repoName)",
                    displayName: repoName,
                    huggingFaceID: huggingFaceID,
                    isVision: false,
                    localPath: repoEntry.path,
                    estimatedMemoryGB: sizeGB
                )
                models.append(discovered)
                knownRepos.insert(repoName)
            }
        }
    }
}
