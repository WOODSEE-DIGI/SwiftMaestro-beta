import Foundation
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Hub
import Tokenizers

// MARK: - Engine State

enum EngineState: Equatable {
    case idle
    case loading(String)
    case ready(String)
    case generating
    case error(String)
}

// MARK: - Generation Output

enum GenerationOutput: Sendable {
    case token(String)
    case info(tokensPerSecond: Double)
}

// MARK: - Tokenizer Loader

/// Loads tokenizers from local model directories using swift-transformers.
struct MaestroTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return tokenizer as! any MLXLMCommon.Tokenizer
    }
}

// MARK: - Hub Downloader

/// Downloads models from HuggingFace Hub using swift-transformers HubApi.
struct HFHubDownloader: MLXLMCommon.Downloader {
    let hubApi: HubApi

    init(token: String? = nil) {
        self.hubApi = HubApi(hfToken: token)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let repo = Hub.Repo(id: id)
        return try await hubApi.snapshot(
            from: repo,
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

// MARK: - MLXInferenceEngine

/// Native MLX inference engine for Apple Silicon.
/// Loads models from local paths or HuggingFace Hub, runs inference on GPU.
@Observable
@MainActor
final class MLXInferenceEngine {

    // MARK: - Published state

    private(set) var state: EngineState = .idle
    private(set) var downloadProgress: Progress?
    private(set) var tokensPerSecond: Double = 0

    // MARK: - Private

    private let modelCache = NSCache<NSString, ModelContainer>()
    private let tokenizerLoader = MaestroTokenizerLoader()
    private let hubDownloader = HFHubDownloader()
    private var generateTask: Task<Void, any Error>?

    init() {
        // Limit GPU cache to avoid OOM on large models
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
    }

    // MARK: - Model Loading

    /// Load a model from a ``MaestroModel`` descriptor.
    /// Returns the cached container if already loaded.
    func loadModel(_ model: MaestroModel) async throws -> ModelContainer {
        let cacheKey = model.id as NSString

        if let cached = modelCache.object(forKey: cacheKey) {
            state = .ready(model.displayName)
            return cached
        }

        state = .loading(model.displayName)

        let container: ModelContainer
        if let localPath = model.localPath {
            // Load from local directory
            let url = URL(fileURLWithPath: localPath)
            if model.isVision {
                container = try await VLMModelFactory.shared.loadContainer(
                    from: url, using: tokenizerLoader
                )
            } else {
                container = try await LLMModelFactory.shared.loadContainer(
                    from: url, using: tokenizerLoader
                )
            }
        } else {
            // Download from Hub
            let configuration = ModelConfiguration(id: model.huggingFaceID)
            let factory: any ModelFactory = model.isVision
                ? VLMModelFactory.shared
                : LLMModelFactory.shared
            container = try await factory.loadContainer(
                from: hubDownloader,
                using: tokenizerLoader,
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }
        }

        modelCache.setObject(container, forKey: cacheKey)
        state = .ready(model.displayName)
        downloadProgress = nil
        return container
    }

    // MARK: - Generation

    /// Stream tokens from the model for a given chat history.
    func generate(
        messages: [Message],
        model: MaestroModel,
        temperature: Float = 0.7,
        maxTokens: Int = 4096
    ) async throws -> AsyncStream<GenerationOutput> {
        cancel()
        state = .generating

        let container = try await loadModel(model)

        // Map SwiftMaestro messages to MLX Chat.Message
        let chat: [Chat.Message] = messages.map { msg in
            let role: Chat.Message.Role = switch msg.role {
            case .user: .user
            case .assistant: .assistant
            case .system: .system
            }
            return Chat.Message(role: role, content: msg.content)
        }

        let userInput = UserInput(chat: chat)
        let parameters = GenerateParameters(
            temperature: temperature,
            topP: 0.9,
            repetitionPenalty: 1.05
        )

        return AsyncStream<GenerationOutput> { continuation in
            self.generateTask = Task {
                do {
                    nonisolated(unsafe) let capturedInput = userInput
                    let stream = try await container.perform { context in
                        let lmInput = try await context.processor.prepare(input: capturedInput)
                        return try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                    }
                    for await generation in stream {
                        guard !Task.isCancelled else { break }
                        switch generation {
                        case .chunk(let chunk):
                            continuation.yield(.token(chunk))
                        case .info(let info):
                            await MainActor.run {
                                self.tokensPerSecond = info.tokensPerSecond
                            }
                            continuation.yield(.info(tokensPerSecond: info.tokensPerSecond))
                        case .toolCall:
                            break
                        }
                    }
                } catch {
                    // Propagate via the stream — caller handles errors
                }
                continuation.finish()
                await MainActor.run {
                    self.state = .ready(model.displayName)
                }
            }
        }
    }

    // MARK: - Control

    func cancel() {
        generateTask?.cancel()
        generateTask = nil
        if case .generating = state {
            state = .idle
        }
    }

    func unloadModel(_ modelID: String) {
        modelCache.removeObject(forKey: modelID as NSString)
        if case .ready(let name) = state, name == modelID {
            state = .idle
        }
    }

    func unloadAll() {
        modelCache.removeAllObjects()
        state = .idle
    }
}
