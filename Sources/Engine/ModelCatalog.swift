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
    let localPath: String?
    let estimatedMemoryGB: Int
    /// Whether this checkpoint can load via the in-process Apple-MLX backend.
    /// `false` routes the model to the oMLX server (e.g. the 122B, whose
    /// in-process load is broken) and prevents any in-process fallback.
    var supportsInProcess: Bool = true
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

    /// Tools are advertised only when the model is verified AND its tool-call
    /// format is known, so any emitted calls can actually be parsed. No known
    /// format ⇒ no tools, regardless of `supportsTools`.
    var advertisesTools: Bool { supportsTools && toolCallFormat != nil }

    var modelConfiguration: ModelConfiguration {
        if let localPath {
            return ModelConfiguration(
                directory: URL(fileURLWithPath: localPath)
            )
        }
        return ModelConfiguration(id: huggingFaceID)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MaestroModel, rhs: MaestroModel) -> Bool { lhs.id == rhs.id }
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

    private static let selectedModelKey = "models.selectedModelID"
    /// Launch default when no selection has been persisted yet.
    static let defaultModelID = "local-qwen3.5-122b"

    var selectedModel: MaestroModel? {
        guard let id = selectedModelID else { return models.first }
        return models.first { $0.id == id } ?? models.first
    }

    /// Look up a model by its catalog id (e.g. `local-qwen3.5-122b`).
    func model(forID id: String?) -> MaestroModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// The model an agent should run: its per-agent override if set and still
    /// known, otherwise the global selected model.
    func effectiveModel(for agent: AgentRecord) -> MaestroModel? {
        model(forID: agent.modelID) ?? selectedModel
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
        return WorkspaceStore.appSupportDir()
            .appendingPathComponent("models", isDirectory: true).path
    }

    /// Resolve a model's local directory under `modelsRoot` ONLY if it exists on
    /// disk; otherwise return nil so the model is pulled from Hugging Face Hub by
    /// its `huggingFaceID` on first use. This is what makes a fresh install work
    /// with no preinstalled models.
    nonisolated static func localIfPresent(_ subdir: String) -> String? {
        let path = (modelsRoot as NSString).appendingPathComponent(subdir)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static let builtInModels: [MaestroModel] = [
        // === Local models (already downloaded) ===
        // Served by oMLX from the swiftmaestro-models scan dir.
        MaestroModel(
            id: "local-qwen3.6-35b-a3b",
            displayName: "Qwen 3.6 35B-A3B (default)",
            huggingFaceID: "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
            // Although this checkpoint is multimodal, we load it through the
            // text MoE path (LLMModelFactory recognizes model_type `qwen3_5_moe`).
            // The VLM pipeline ran ~3x slower (12 vs ~40 tok/s on oMLX); chat is
            // text-only, so the vision tower is pure overhead.
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3.6-35B-A3B-MLX-4bit"),
            estimatedMemoryGB: 20,
            supportsTools: true,  // verified: get_current_time round-trip passed
            toolCallFormat: .xmlFunction,  // emits XML <function>/<parameter> calls
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "local-qwen3-coder-30b-a3b",
            displayName: "Qwen 3 Coder 30B-A3B (Instruct)",
            huggingFaceID: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("swiftmaestro-models/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit"),
            estimatedMemoryGB: 17,
            // Known format (XML <function>/<parameter>), but tools stay off until
            // a verified round-trip flips supportsTools on.
            toolCallFormat: .xmlFunction,
            recTemperature: 0.7, recTopP: 0.8, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "local-qwen3.5-27b",
            displayName: "Qwen 3.5 27B (Opus Distilled)",
            huggingFaceID: "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"),
            estimatedMemoryGB: 14
        ),
        MaestroModel(
            id: "local-qwen3.5-122b",
            displayName: "Qwen 3.5 122B (A10B)",
            huggingFaceID: "mlx-community/Qwen3.5-122B-A10B-4bit",
            isVision: false,
            localPath: localIfPresent("Qwen3.5-122B-A10B-4bit"),
            estimatedMemoryGB: 65,
            // In-process load works with the current mlx-swift-lm loader, which
            // quantizes a module only when the checkpoint has its `.scales`
            // (Load.swift). This checkpoint's lm_head IS quantized, so the old
            // "lm_head not found" failure (an older loader) no longer applies.
            // If an in-process load still can't proceed, `send` falls back to oMLX.
            supportsInProcess: true,
            // Confirmed: this checkpoint's chat_template uses the same XML
            // <function>/<parameter> tool format as the 3.6 default
            // (qwen3_5_moe), so the xmlFunction parser applies identically.
            supportsTools: true,
            toolCallFormat: .xmlFunction,
            recTemperature: 1.0, recTopP: 0.95, recRepetitionPenalty: 1.05
        ),
        MaestroModel(
            id: "local-hermes-70b",
            displayName: "Hermes 4 70B (6-bit)",
            huggingFaceID: "lmstudio-community/Hermes-4-70B-MLX-6bit",
            isVision: false,
            localPath: localIfPresent("Hermes-4-70B-MLX-6bit"),
            estimatedMemoryGB: 56
        ),
        MaestroModel(
            id: "local-magistral-small",
            displayName: "Magistral Small 2509",
            huggingFaceID: "lmstudio-community/Magistral-Small-2509-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("Magistral-Small-2509-MLX-4bit"),
            estimatedMemoryGB: 13
        ),
        MaestroModel(
            id: "local-deepseek-r1-8b",
            displayName: "DeepSeek R1 0528 (Qwen3 8B)",
            huggingFaceID: "lmstudio-community/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit",
            isVision: false,
            localPath: localIfPresent("DeepSeek-R1-0528-Qwen3-8B-MLX-4bit"),
            estimatedMemoryGB: 4
        ),
        MaestroModel(
            id: "local-gpt-oss-20b",
            displayName: "GPT-OSS 20B",
            huggingFaceID: "mlx-community/gpt-oss-20b-MXFP4-Q8",
            isVision: false,
            localPath: localIfPresent("gpt-oss-20b-MXFP4-Q8"),
            estimatedMemoryGB: 11
        ),
        MaestroModel(
            id: "local-deepseek-vl2-small",
            displayName: "DeepSeek VL2 Small (Vision)",
            huggingFaceID: "mlx-community/deepseek-vl2-small-4bit",
            isVision: true,
            localPath: localIfPresent("deepseek-vl2-small-4bit"),
            estimatedMemoryGB: 9
        ),
        MaestroModel(
            id: "local-nemotron-30b",
            displayName: "Nemotron Cascade 30B (A3B)",
            huggingFaceID: "JANGQ-AI/Nemotron-Cascade-2-30B-A3B-JANG_4M",
            isVision: false,
            localPath: localIfPresent("Nemotron-Cascade-2-30B-A3B-JANG_4M"),
            estimatedMemoryGB: 1
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
            estimatedMemoryGB: 3
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

    func removeModel(_ id: String) {
        models.removeAll { $0.id == id }
        if selectedModelID == id { selectedModelID = models.first?.id }
    }
}
