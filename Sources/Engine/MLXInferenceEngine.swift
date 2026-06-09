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
    case toolCall(name: String)
}

// MARK: - Tokenizer Loader
/// Adapter from swift-transformers tokenizer protocol to MLXLMCommon.Tokenizer.
struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads tokenizers from local model directories using swift-transformers.
struct MaestroTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return HuggingFaceTokenizerBridge(tokenizer)
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

    /// Client-side MCP tool source. Set during app launch. When present (and the
    /// model supports tools), discovered MCP tools join the same agentic loop as
    /// the native tools.
    var mcpService: MCPClientService?

    /// Persistent prompt KV cache for cross-turn prefix reuse. The big, fixed
    /// `[system + tools]` block (~3k tokens) dominates prefill; keeping its KV
    /// across turns and re-prefilling only the changed suffix turns a ~40s wait
    /// into a one-time cost. Single slot: it "follows" the active conversation
    /// via common-prefix matching (switching chats just pays one full prefill).
    private let promptCache = PromptCache()

    init() {
        // Baseline GPU buffer cache. (A larger RAM-scaled cache was tried and
        // regressed throughput on this machine, so we keep the conservative
        // value while we diagnose the real bottleneck.)
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
        temperature: Float? = nil,
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

        // Thinking mode + sampling come from SwiftMaestro's own settings
        // (self-hosted — independent of any oMLX/server-side config).
        // Thinking defaults OFF for a clean, fast chat experience; reasoning can
        // be re-enabled via the `tuning.enableThinking` setting. `enable_thinking`
        // is passed to the model's chat template via additionalContext.
        let defaults = UserDefaults.standard
        let thinkingEnabled = (defaults.object(forKey: "tuning.enableThinking") as? Bool) ?? false
        // Precedence: explicit arg > user's global Tuning override (only if set) >
        // per-model recommended > hard default. Keeps each model on its own
        // sampling instead of one global temperature.
        let resolvedTemp = temperature
            ?? (defaults.object(forKey: "tuning.temperature") as? Double).map { Float($0) }
            ?? model.recTemperature.map { Float($0) }
            ?? 1.0
        let resolvedTopP = (defaults.object(forKey: "tuning.topP") as? Double).map { Float($0) }
            ?? model.recTopP.map { Float($0) }
            ?? 0.95
        let resolvedRepPenalty = (defaults.object(forKey: "tuning.repetitionPenalty") as? Double).map { Float($0) }
            ?? model.recRepetitionPenalty.map { Float($0) }
            ?? 1.05
        let parameters = GenerateParameters(
            temperature: resolvedTemp,
            topP: resolvedTopP,
            repetitionPenalty: resolvedRepPenalty
        )

        // Verify-per-model: only advertise tools to models whose tool round-trip
        // has been confirmed. Unverified models (e.g. Qwen3-Coder, pending its
        // tool-call format support) run as plain chat — no broken tool path.
        //
        // Tool sources are merged here: native (in-process) tools plus any tools
        // discovered from user-enabled MCP servers. The loop below is
        // source-agnostic and routes each call to whichever source owns it.
        let mcp = mcpService
        let toolSchemas: [ToolSpec]?
        if model.supportsTools {
            var specs = MaestroTools.schemas
            if let mcp { specs += await mcp.currentSchemas() }
            toolSchemas = specs.isEmpty ? nil : specs
        } else {
            toolSchemas = nil
        }

        return AsyncStream<GenerationOutput> { continuation in
            self.generateTask = Task {
                // Agentic loop: generate -> if the model calls tools, execute them,
                // feed results back as tool messages, and re-generate until the
                // model produces a final answer. No iteration budget (local
                // inference has no token cost); termination is the model finishing
                // or the user cancelling. The loop is tool-source-agnostic: calls
                // route to native tools or MCP.
                var conversation = chat
                do {
                    iterations: while !Task.isCancelled {
                        let input = UserInput(
                            chat: conversation,
                            tools: toolSchemas,
                            additionalContext: ["enable_thinking": thinkingEnabled]
                        )
                        nonisolated(unsafe) let capturedInput = input
                        nonisolated(unsafe) let pc = self.promptCache
                        let modelID = model.id
                        var pendingCalls: [ToolCall] = []
                        let stream = try await container.perform { context in
                            let lmInput = try await context.processor.prepare(input: capturedInput)
                            let fullTokens = lmInput.text.tokens.asArray(Int.self)

                            // Reuse the persistent prompt cache when it belongs to
                            // the same model and is trimmable. Common-prefix match
                            // against the previously-fed tokens, trim the cache to
                            // that prefix, and prefill only the changed suffix.
                            let canReuse = pc.isReady
                                && pc.modelID == modelID
                                && !pc.caches.isEmpty
                                && pc.caches.allSatisfy { $0.isTrimmable }
                            var prefix = 0
                            if canReuse {
                                let minOffset = pc.caches.map { $0.offset }.min() ?? 0
                                prefix = MLXInferenceEngine.commonPrefixLength(pc.tokens, fullTokens)
                                // Clamp: keep ≥1 token to prefill, never exceed what
                                // the cache actually holds (e.g. after a cancel).
                                prefix = min(prefix, minOffset, fullTokens.count - 1)
                                if prefix < 0 { prefix = 0 }
                            }

                            let inputForGen: LMInput
                            let cacheForGen: [KVCache]
                            if canReuse && prefix > 0 {
                                for c in pc.caches { c.trim(c.offset - prefix) }
                                let deltaInts = Array(fullTokens[prefix...]).map { Int32($0) }
                                let deltaArray = MLXArray(deltaInts).reshaped([1, deltaInts.count])
                                inputForGen = LMInput(text: .init(tokens: deltaArray))
                                cacheForGen = pc.caches
                                NSLog("[PERF] cache reuse: prefix=\(prefix)/\(fullTokens.count), prefill delta=\(deltaInts.count) tok")
                            } else {
                                let fresh = context.model.newCache(parameters: parameters)
                                pc.caches = fresh
                                inputForGen = lmInput
                                cacheForGen = fresh
                                NSLog("[PERF] cache fresh: prefill full=\(fullTokens.count) tok")
                            }
                            pc.tokens = fullTokens
                            pc.modelID = modelID
                            pc.isReady = true

                            return try MLXLMCommon.generate(
                                input: inputForGen,
                                cache: cacheForGen,
                                parameters: parameters,
                                context: context
                            )
                        }
                        for await generation in stream {
                            guard !Task.isCancelled else { break iterations }
                            switch generation {
                            case .chunk(let chunk):
                                continuation.yield(.token(chunk))
                            case .info(let info):
                                NSLog("[PERF] prompt=\(info.promptTokenCount) tok in \(String(format: "%.2f", info.promptTime))s (\(String(format: "%.0f", info.promptTokensPerSecond)) tok/s prefill); gen=\(info.generationTokenCount) tok in \(String(format: "%.2f", info.generateTime))s (\(String(format: "%.1f", info.tokensPerSecond)) tok/s)")
                                await MainActor.run {
                                    self.tokensPerSecond = info.tokensPerSecond
                                }
                                continuation.yield(.info(tokensPerSecond: info.tokensPerSecond))
                            case .toolCall(let call):
                                pendingCalls.append(call)
                            }
                        }
                        // No tool calls -> the model produced its final answer.
                        if pendingCalls.isEmpty { break iterations }
                        // Execute each tool call and feed the result back for the next round.
                        // Native tools take precedence; otherwise route to MCP.
                        for call in pendingCalls {
                            let name = call.function.name
                            continuation.yield(.toolCall(name: name))
                            let result: String
                            if MaestroTools.handles(name) {
                                result = await MaestroTools.execute(call)
                            } else if let mcp, await mcp.handles(name) {
                                result = await mcp.execute(call)
                            } else {
                                result = await MaestroTools.execute(call)
                            }
                            conversation.append(.tool(result))
                        }
                    }
                } catch {
                    // Propagate via the stream — caller handles errors / fallback
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

    /// Report generation throughput from an external backend (e.g. the oMLX
    /// path) so the status bar reflects it.
    func reportExternalTokensPerSecond(_ tps: Double) {
        tokensPerSecond = tps
    }

    func unloadModel(_ modelID: String) {
        modelCache.removeObject(forKey: modelID as NSString)
        promptCache.reset()
        if case .ready(let name) = state, name == modelID {
            state = .idle
        }
    }

    func unloadAll() {
        modelCache.removeAllObjects()
        promptCache.reset()
        state = .idle
    }

    /// Length of the shared leading run of two token sequences.
    fileprivate nonisolated static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }
}

// MARK: - Prompt KV cache holder

/// Reference-type holder for the persistent prompt KV cache and the exact token
/// sequence it represents. A class (not a struct) so it can be shared by
/// reference into the model container's isolated `perform` closure; access is
/// safe because generations are strictly serialized (see `cancel()` in
/// `generate`).
private final class PromptCache {
    var caches: [KVCache] = []
    /// The full prompt token sequence most recently fed (prefix of what the
    /// cache holds, modulo trailing generated tokens).
    var tokens: [Int] = []
    var modelID: String = ""
    var isReady = false

    func reset() {
        caches = []
        tokens = []
        modelID = ""
        isReady = false
    }
}
