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
    var selectedModelID: String?

    var selectedModel: MaestroModel? {
        guard let id = selectedModelID else { return models.first }
        return models.first { $0.id == id } ?? models.first
    }

    init() {
        models = Self.builtInModels
        selectedModelID = models.first?.id
    }

    // MARK: - Local models (on ~/Ai-models)

    static let localModelPath = "~/Ai-models"

    static let builtInModels: [MaestroModel] = [
        // === Local models (already downloaded) ===
        // Served by oMLX from the swiftmaestro-models scan dir.
        MaestroModel(
            id: "local-qwen3.6-35b-a3b",
            displayName: "Qwen 3.6 35B-A3B (default)",
            huggingFaceID: "Qwen3.6-35B-A3B-MLX-4bit",
            isVision: true,
            localPath: "\(localModelPath)/swiftmaestro-models/Qwen3.6-35B-A3B-MLX-4bit",
            estimatedMemoryGB: 20
        ),
        MaestroModel(
            id: "local-qwen3-coder-30b-a3b",
            displayName: "Qwen 3 Coder 30B-A3B (Instruct)",
            huggingFaceID: "Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
            isVision: false,
            localPath: "\(localModelPath)/swiftmaestro-models/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
            estimatedMemoryGB: 17
        ),
        MaestroModel(
            id: "local-qwen3.5-27b",
            displayName: "Qwen 3.5 27B (Opus Distilled)",
            huggingFaceID: "Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
            isVision: false,
            localPath: "\(localModelPath)/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
            estimatedMemoryGB: 14
        ),
        MaestroModel(
            id: "local-qwen3.5-122b",
            displayName: "Qwen 3.5 122B (A10B)",
            huggingFaceID: "Qwen3.5-122B-A10B-4bit",
            isVision: false,
            localPath: "\(localModelPath)/Qwen3.5-122B-A10B-4bit",
            estimatedMemoryGB: 65
        ),
        MaestroModel(
            id: "local-hermes-70b",
            displayName: "Hermes 4 70B",
            huggingFaceID: "Hermes-4-70B-MLX-4bit",
            isVision: false,
            localPath: "\(localModelPath)/Hermes-4-70B-MLX-4bit",
            estimatedMemoryGB: 37
        ),
        MaestroModel(
            id: "local-magistral-small",
            displayName: "Magistral Small 2509",
            huggingFaceID: "Magistral-Small-2509-MLX-4bit",
            isVision: false,
            localPath: "\(localModelPath)/Magistral-Small-2509-MLX-4bit",
            estimatedMemoryGB: 13
        ),
        MaestroModel(
            id: "local-deepseek-r1-8b",
            displayName: "DeepSeek R1 0528 (Qwen3 8B)",
            huggingFaceID: "DeepSeek-R1-0528-Qwen3-8B-MLX-4bit",
            isVision: false,
            localPath: "\(localModelPath)/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit",
            estimatedMemoryGB: 4
        ),
        MaestroModel(
            id: "local-gpt-oss-20b",
            displayName: "GPT-OSS 20B",
            huggingFaceID: "gpt-oss-20b-MXFP4-Q8",
            isVision: false,
            localPath: "\(localModelPath)/gpt-oss-20b-MXFP4-Q8",
            estimatedMemoryGB: 11
        ),
        MaestroModel(
            id: "local-deepseek-vl2-small",
            displayName: "DeepSeek VL2 Small (Vision)",
            huggingFaceID: "deepseek-vl2-small-4bit",
            isVision: true,
            localPath: "\(localModelPath)/deepseek-vl2-small-4bit",
            estimatedMemoryGB: 9
        ),
        MaestroModel(
            id: "local-nemotron-30b",
            displayName: "Nemotron Cascade 30B (A3B)",
            huggingFaceID: "Nemotron-Cascade-2-30B-A3B-JANG_4M",
            isVision: false,
            localPath: "\(localModelPath)/Nemotron-Cascade-2-30B-A3B-JANG_4M",
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
