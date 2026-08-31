import Foundation
import MLXLMCommon
import SwiftMaestroKit

/// Drives one agent's chat. Maestro is the top-level conductor; project
/// agents belong to a project and operate scoped to that project's memory.
/// Chat history persists per agent (ChatHistoryStore) separately from project
/// memory, so it can be cleared without affecting the project.
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message]
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    /// Images staged for the next message (from the attach button, drag-drop, or
    /// paste). Sent as data URIs to the vision-capable model, then cleared.
    @Published var pendingImages: [Data] = []
    /// Number of drop/paste image decodes currently in flight. Submits wait for
    /// this to drain so a fast drop→send can't orphan the image to the next turn.
    @Published var pendingImageLoads = 0
    @Published var pendingImagePaths: [String] = []
    /// A plan the user attached to this session from the Plans panel ("Attach
    /// to Session"). Injected into the regenerated system prompt every turn
    /// while attached so the agent can refer to (and edit) it; detached via
    /// the composer's plan chip or the panel's context menu.
    @Published var attachedPlan: (scope: PlanScope, plan: Plan)?

    func attach(plan: Plan, scope: PlanScope) {
        attachedPlan = (scope, plan)
        NSLog("[PLANATTACH] attached '\(plan.title)' (scope=\(scope)) to agent \(agent.name) (\(agent.id))")
    }
    func detachAttachedPlan() {
        if let attachedPlan { NSLog("[PLANATTACH] detached '\(attachedPlan.plan.title)'") }
        attachedPlan = nil
    }
    /// Live, compact "what the agent is doing right now" line shown while
    /// streaming (e.g. "Running read_notes…"). Cleared when the turn ends.
    @Published var currentActivity: String?
    /// The agent's base directory. Injected into the system prompt and used as
    /// the default cwd for shell commands so the model resolves paths reliably.
    /// Persisted per agent in UserDefaults.
    @Published var workingDirectory: String?
    /// The model (HuggingFace ID) this agent is configured to use. Used when
    /// regenerating the system prompt so the model-capacity guidance matches
    /// the actual model instead of defaulting to the small-model fallback.
    @Published var currentModelHuggingFaceID: String? = nil
    /// Context usage progress (0.0–1.0) for the compaction ring indicator.
    /// Updated after each message is added; drives the animated circle in the
    /// toolbar that fills up as the context approaches the compaction threshold.
    @Published var contextProgress: Double = 0.0

    let agent: AgentRecord
    let projectName: String?
    let visionProxyService: VisionProxyService
    private var generateTask: Task<Void, Never>?

    // Stream-time reasoning split state (reset per send). See the
    // "Stream-time reasoning split" MARK for how these drive `reasoning`/`content`.
    private var inReasoning = true
    private var reasoningStart: Date?
    private var streamBuffer = ""
    private var sawReasoningClose = false
    /// Per-ROUND close tracking: each tool-round re-arms reasoning, so a final
    /// answer round with NO thinking block (no close tag of its own) would
    /// otherwise pour the answer into `reasoning` and leave the chat empty —
    /// "thoughts didn't become chat". `sawCloseSinceFold` records whether the
    /// current (post-fold) segment ever closed; `reasoningLengthAtLastFold`
    /// marks where the final round's reasoning began.
    private var sawCloseSinceFold = false
    private var reasoningLengthAtLastFold = 0
    /// Tool call XML suppression: when the model streams `<tool_call>` tokens
    /// into the text stream alongside `.toolCall` events, suppress the raw XML
    /// so it doesn't leak into the displayed answer.
    private var suppressingToolCall = false
    /// Mid-generation steering queue for the in-flight run; held only while
    /// streaming so `steer(text:)` can hand the executor new user input without
    /// cancelling the run.
    private var steerInbox: SteerInbox?
    /// Display name of the model driving the current generation, used to tag
    /// assistant bubbles with the model that produced them.
    private var currentModelDisplayName: String?
    /// Tracks the last auto-compaction so we don't re-summarize identical
    /// history on every turn when the context is still over budget.
    private var lastCompactionMessageCount: Int = 0
    private var lastCompactionTime: Date?
    /// Last inference engine used for generation. Retained weakly so memory
    /// pressure compaction can trigger a summary without a circular reference.
    private weak var lastEngine: MLXInferenceEngine?

    init(agent: AgentRecord, projectName: String?, visionProxyService: VisionProxyService) {
        self.agent = agent
        self.projectName = projectName
        self.visionProxyService = visionProxyService
        // Prefer the working directory stored on the agent record (set at creation
        // time by create_project_agent), then fall back to the legacy UserDefaults key.
        let recordWD = agent.workingDirectory?.trimmingCharacters(in: .whitespaces)
        let legacyWD = UserDefaults.standard.string(forKey: Self.workingDirKey(agent.id))
        let wd = (recordWD?.isEmpty == false) ? recordWD : legacyWD
        self.workingDirectory = wd
        let modelID = Self.effectiveModelHuggingFaceID(for: agent)
        self.currentModelHuggingFaceID = modelID
        if let saved = ChatHistoryStore.load(agentId: agent.id), !saved.isEmpty {
            self.messages = saved
        } else {
            self.messages = [Self.systemMessage(
                for: agent, projectName: projectName, workingDirectory: wd,
                modelID: modelID)]
        }

        // SELF-HEALING: Listen for memory pressure notifications from the
        // inference engine and trigger aggressive compaction.
        NotificationCenter.default.addObserver(
            forName: .memoryPressureCompactionNeeded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let modelID = notification.userInfo?["modelID"] as? String,
                  modelID == self.agent.modelID else { return }
            Task { @MainActor in
                self.handleMemoryPressureCompaction()
            }
        }
    }

    private static func workingDirKey(_ id: UUID) -> String { "workingDir.\(id.uuidString)" }

    /// Resolve the HuggingFace ID of the model this agent is configured to use,
    /// falling back to the global default selection. Used to seed the system
    /// prompt with accurate model-capacity guidance.
    private static func effectiveModelHuggingFaceID(for agent: AgentRecord) -> String? {
        let catalog = ModelCatalog()
        let live = MaestroTools.workspace?.agent(id: agent.id) ?? agent
        return catalog.effectiveModel(for: live)?.huggingFaceID
    }

    /// Update the cached model ID when the user changes the per-agent model
    /// picker, and regenerate the system prompt so the capacity guidance matches.
    func updateModelHuggingFaceID() {
        currentModelHuggingFaceID = Self.effectiveModelHuggingFaceID(for: agent)
        // Regenerate only the leading system message; user/assistant history is
        // preserved. The model-specific prompt section will be updated on the
        // next inference anyway, but this keeps the visible/serialized prompt
        // accurate.
        if let first = messages.first, first.role == .system {
            messages[0] = Self.systemMessage(
                for: agent, projectName: projectName, workingDirectory: workingDirectory,
                modelID: currentModelHuggingFaceID)
        }
    }

    /// Set (or clear) the agent's working directory and persist it.
    func setWorkingDirectory(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespaces)
        workingDirectory = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let key = Self.workingDirKey(agent.id)
        if let wd = workingDirectory { UserDefaults.standard.set(wd, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        // Also sync to the agent record so sub-agents and the workspace see it.
        MaestroTools.workspace?.setWorkingDirectory(workingDirectory, for: agent.id)
    }

    /// Build the generation backend for a model. Local models run fully
    /// in-process via mlx-swift-lm; remote models (LM Studio, Ollama, online
    /// OpenAI-compatible endpoints like Kimi/Moonshot or Qwen/DashScope) use
    /// HTTP. API keys travel as `secret://` references and resolve from the
    /// Keychain only at the HTTP boundary.
    static func makeBackend(
        for model: MaestroModel, engine: MLXInferenceEngine, sessionKey: String
    ) -> GenerationBackend {
        if let remoteURL = model.remoteBaseURL {
            let config = LMStudioConfig(
                baseURL: remoteURL,
                apiKey: model.remoteAPIKeyRef ?? "",
                requestTimeout: model.remoteRequestTimeout ?? 120)
            return RemoteLMStudioBackend(config: config, model: model)
        }
        return InProcessMLXBackend(engine: engine, model: model, sessionKey: sessionKey)
    }

    func send(engine: MLXInferenceEngine, catalog: ModelCatalog, model: MaestroModel?) {
        guard !isStreaming else { return }
        // Retain engine reference for memory pressure compaction.
        lastEngine = engine
        // Merge typed images with any local image paths found in the text
        // (e.g. a pasted screenshot path), stripping the path from the prompt.
        let (cleanedText, pathImages, extractedPaths) = Self.extractImages(from: inputText)
        var images = pendingImages
        images.append(contentsOf: pathImages)
        var allPaths = pendingImagePaths
        allPaths.append(contentsOf: extractedPaths)
        let prompt = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !images.isEmpty else { return }
        guard let model else {
            errorMessage = "No model selected. Open Settings (⌘,) to configure."
            return
        }
        currentModelDisplayName = model.displayName

        inputText = ""
        pendingImages = []
        pendingImagePaths = []
        errorMessage = nil
        let userText = prompt.isEmpty ? " " : prompt
        let isCompactionRequest = Self.isCompactionCommand(userText)
        let now = Date()
        messages.append(Message(
            role: .user, content: userText, imageData: images.isEmpty ? nil : images,
            imagePaths: allPaths.isEmpty ? nil : allPaths, timestamp: now))
        messages.append(Message(
            role: .assistant, content: "", timestamp: now,
            modelName: currentModelDisplayName))
        // Persist dropped/added attachments into shared memory so they become
        // durable, `memory_search`-able knowledge — the same import route the
        // Settings → Context "Import Folder Into Memory" feature uses. Runs on a
        // background task so it never blocks stream start.
        Self.persistDroppedAttachments(
            imagePaths: allPaths,
            imageBytes: images,
            agentName: agent.name)
        isStreaming = true
        AIBroadcastService.broadcastGenerationStarted(modelName: currentModelDisplayName ?? "unknown")
        // Update the compaction progress ring immediately.
        updateContextProgress()

        // Manual compaction command: bypass the model and compact history immediately.
        if isCompactionRequest, !model.isRemote {
            generateTask = Task { await handleManualCompaction(engine: engine, catalog: catalog, model: model) }
            return
        }
        // Reset the stream-time reasoning split for this turn. Reasoning starts
        // open because Qwen emits a `<think>` (even an empty block) before the
        // answer regardless of the thinking toggle.
        inReasoning = true
        reasoningStart = Date()
        streamBuffer = ""
        sawReasoningClose = false
        sawCloseSinceFold = false
        reasoningLengthAtLastFold = 0
        suppressingToolCall = false
        // Fresh steer queue for this run; the executor drains it each round.
        let inbox = SteerInbox()
        steerInbox = inbox

        let isNavigator = agent.kind == .navigator
        let project = projectName
        let workingDir = workingDirectory
        let agentID = agent.id.uuidString

        generateTask = Task {
            // Tell the agent what it ACTUALLY runs on, so "which model are you?"
            // is answered truthfully instead of echoing the agent's name.
            let modelDesc: String
            if let remoteURL = model.remoteBaseURL {
                modelDesc = "\(model.displayName) (model id \(model.huggingFaceID)), "
                    + "served via OpenAI-compatible endpoint at \(remoteURL)"
            } else {
                modelDesc = "\(model.displayName) (model id \(model.huggingFaceID)), "
                    + "served via in-process Apple MLX"
            }
            let summaryModel = Self.pickSummaryModel(active: model, catalog: catalog)
            let (requestMessages, compactionSummary) = await messagesForInference(
                model: model, modelDescription: modelDesc, engine: engine,
                summaryModel: summaryModel)

            // If history was auto-compacted, surface a visible context-boundary
            // message in the chat history so the user knows older turns were
            // summarized (and where to find the saved checkpoint).
            if let compactionSummary, !compactionSummary.isEmpty {
                let notice = Message(
                    role: .assistant,
                    content: "Context compacted. Older conversation summarized and saved to AI-Context memory.\n\n" + compactionSummary,
                    isCompaction: true,
                    timestamp: Date(),
                    modelName: currentModelDisplayName)
                if let last = messages.last, last.role == .assistant, last.content.isEmpty {
                    messages.insert(notice, at: messages.count - 1)
                } else {
                    messages.append(notice)
                }
            }

            let thinking = model.tunedThinkingEnabled
            // Per-model sampling: this model's own override (Settings → Tuning)
            // or its recommended values — never one global value across models.
            let temperature = model.tunedTemperature
            let topP = model.tunedTopP
            let maxTokens = model.tunedMaxTokens

        // Tool surface: project agents get the normal tools; Maestro
        // additionally gets the workspace/delegation tools. Per-agent enabled
        // tool categories override the old automatic lite-mode reduction.
        var toolSpecs: [ToolSpec] = []
        var specsProvider: (@Sendable () async -> [ToolSpec])?
        if model.advertisesTools {
            nonisolated(unsafe) let mcpService = engine.mcpService
            let agentID = agent.id
            let isLite = model.isLiteModel
            toolSpecs = await Self.buildToolSpecs(
                agentID: agentID, isNavigator: isNavigator, isLiteModel: isLite,
                mcp: mcpService)
            // Re-derive the tool surface EVERY ROUND from the live panel set:
            // panel-linked categories (Auto tool mode) activate when open_panel
            // opens their panel and withdraw when it closes. A frozen run-start
            // snapshot went stale the moment open_panel fired — the model then
            // called app tools it had never seen schemas for, mis-called them,
            // and fabricated success (the fake MaestroDB import).
            specsProvider = { [isNavigator] in
                await Self.buildToolSpecs(
                    agentID: agentID, isNavigator: isNavigator, isLiteModel: isLite,
                    mcp: mcpService)
            }
        }
            // Low temperature when tools are active keeps function-calling faithful.
            let effectiveTemp = toolSpecs.isEmpty ? temperature : min(temperature, 0.3)

            // Delegated sub-agents resolve their OWN model/backend via this
            // resolver. Lite / known-weak tool-calling models are promoted to a
            // capable model (parent, then default) so that delegated build work
            // actually produces real file output instead of stubs.
            let delegateResolver: DelegateBackendResolver = { agentID in
                await MainActor.run { () -> (backend: GenerationBackend, modelID: String, maxTokens: Int)? in
                    guard let agent = MaestroTools.workspace?.agent(id: agentID),
                          let targetModel = catalog.effectiveModel(for: agent) else { return nil }

                    func isCapable(_ m: MaestroModel) -> Bool {
                        // Respect the user's explicit model choice for project agents.
                        // A model is "capable" if it is present locally, advertises tools,
                        // and is not Gemma 4 (whose tool-call format is currently unreliable
                        // for delegated build work). We no longer reject MoE models just because
                        // their active parameter count is small — Qwen 3.6 35B-A3B
                        // and Gemma 4 26B are the user's chosen models.
                        m.localPath != nil
                            && m.advertisesTools
                            && !m.huggingFaceID.lowercased().contains("gemma-4")
                    }

                    let effectiveModel: MaestroModel
                    if isCapable(targetModel) {
                        effectiveModel = targetModel
                    } else {
                        let defaultModel = catalog.models.first { $0.id == catalog.selectedModelID }
                        if let capable = [model, defaultModel].compactMap({ $0 }).first(where: isCapable) {
                            effectiveModel = capable
                            NSLog("[DELEGATE] promoting subagent '\(targetModel.displayName)' -> '\(capable.displayName)' for task")
                        } else if let capable = catalog.models.first(where: isCapable) {
                            effectiveModel = capable
                            NSLog("[DELEGATE] promoting subagent '\(targetModel.displayName)' -> '\(capable.displayName)' (fallback)")
                        } else {
                            effectiveModel = targetModel
                        }
                    }

                    let backend = ChatViewModel.makeBackend(
                        for: effectiveModel, engine: engine, sessionKey: agentID.uuidString)
                    return (backend, effectiveModel.huggingFaceID, effectiveModel.tunedMaxTokens)
                }
            }
            let primaryBackend = ChatViewModel.makeBackend(
                for: model, engine: engine, sessionKey: agentID)

            do {
                let executor = AgentExecutor(
                    modelID: model.huggingFaceID, backend: primaryBackend,
                    delegateBackendResolver: delegateResolver)

                // Wire up real-time sub-agent streaming so delegated agents' chat
                // windows update while the parent is still waiting for ask_project_agent.
                // Without this, all delegate tokens are queued until the sub-agent
                // finishes, so the sub-agent window stays blank until the parent stops.
                let delegateHandler = DelegateStreamHandler()
                let weakSelf = self
                delegateHandler.onStart = { [weak weakSelf] agentID, modelDisplayName in
                    guard let self = weakSelf else { return }
                    let displayName = modelDisplayName
                        ?? catalog.models.first { $0.huggingFaceID == agentID }?.displayName
                        ?? agentID
                    Self.effectiveDelegateModelNames[agentID] = displayName
                    Task { await Self.streamToDelegate(agentID: agentID, token: "[START]") }
                    self.currentActivity = "Delegating to sub-agent..."
                }
                delegateHandler.onToken = { agentID, token in
                    Task { await Self.streamToDelegate(agentID: agentID, token: token) }
                }
                delegateHandler.onFinish = { [weak weakSelf] agentID in
                    Task { await Self.streamToDelegate(agentID: agentID, token: "[FINISH]") }
                    weakSelf?.currentActivity = nil
                }
                executor.delegateStreamHandler = delegateHandler

                let stream = executor.run(
                    messages: requestMessages, toolSpecs: toolSpecs, mcp: engine.mcpService,
                    engine: engine, catalog: catalog,
                    temperature: effectiveTemp, topP: topP, thinkingEnabled: thinking,
                    project: project, workingDirectory: workingDir, agentID: agentID,
                    maxRounds: Self.maxRounds(for: agent),
                    maxToolCallsPerTool: Self.maxToolCallsPerTool(for: agent),
                    maxTokens: maxTokens,
                    steerInbox: inbox,
                    specsProvider: specsProvider)
                for try await output in stream {
                    guard !Task.isCancelled else { break }
                    switch output {
                    case .token(let token): consumeStreamChunk(token)
                    case .toolCall(let name, let args): recordToolStep(name, arguments: args)
                    case .info(let tps): engine.reportExternalTokensPerSecond(tps)
                    case .turnBreak: beginSteeredTurn()
                    case .delegateStart(let agentID, let modelID):
                        let displayName = catalog.model(forID: modelID)?.displayName ?? modelID
                        Self.effectiveDelegateModelNames[agentID] = displayName
                        await Self.streamToDelegate(agentID: agentID, token: "[START]")
                        await MainActor.run {
                            self.currentActivity = "Delegating to sub-agent..."
                        }
                    case .delegateToken(let agentID, let token):
                        await Self.streamToDelegate(agentID: agentID, token: token)
                    case .delegateFinish(let agentID):
                        await Self.streamToDelegate(agentID: agentID, token: "[FINISH]")
                        await MainActor.run {
                            self.currentActivity = nil
                        }
                    }
                }
            } catch {
                // A user cancel stops cleanly (the tail below resets state); any
                // other error surfaces in the chat UI.
                if Task.isCancelled || error is CancellationError {
                    NSLog("[BACKEND] in-process generation cancelled")
                    AIBroadcastService.broadcastGenerationCancelled(
                        modelName: currentModelDisplayName ?? "unknown")
                } else {
                    NSLog("[BACKEND] in-process generation FAILED for \(model.huggingFaceID): \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                    AIBroadcastService.broadcastGenerationFailed(
                        modelName: currentModelDisplayName ?? "unknown",
                        error: error.localizedDescription)
                }
            }
            finishStreamParsing()
            isStreaming = false
            AIBroadcastService.broadcastGenerationCompleted(
                modelName: currentModelDisplayName ?? "unknown",
                totalTokens: messages.last?.content.count ?? 0,
                tokensPerSecond: engine.tokensPerSecond
            )
            currentActivity = nil
            steerInbox = nil
            saveHistory()
            // Update the compaction progress ring after response is finalized.
            updateContextProgress()
        }
    }

    /// Mid-generation steering: while a run is streaming, show `text` as a normal
    /// user message AND queue it for the executor to fold into the NEXT round,
    /// instead of cancelling. No-ops when not streaming (use `send` then).
    /// Staged images ride along — a screenshot dropped mid-run reaches the model
    /// on the next round instead of being orphaned in the composer.
    func steer(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let paths = pendingImagePaths
        guard isStreaming, (!trimmed.isEmpty || !images.isEmpty), let inbox = steerInbox else { return }
        inputText = ""
        pendingImages = []
        pendingImagePaths = []
        messages.append(Message(
            role: .user, content: trimmed.isEmpty ? " " : trimmed,
            imageData: images.isEmpty ? nil : images,
            imagePaths: paths.isEmpty ? nil : paths,
            timestamp: Date()))
        Task {
            var payload = trimmed
            if !paths.isEmpty {
                payload += (payload.isEmpty ? "" : "\n")
                    + "(attached image path(s): \(paths.joined(separator: ", ")))"
            }
            await inbox.append(payload, images: images)
        }
    }

    /// Wait until in-flight image decodes finish (or `timeout` elapses) so a
    /// drop immediately followed by send/steer still includes the image.
    func waitForPendingImageLoads(timeout: TimeInterval = 3) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while pendingImageLoads > 0 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if pendingImageLoads > 0 {
            NSLog("[CHAT] waitForPendingImageLoads timed out with \(pendingImageLoads) load(s) still in flight")
        }
    }

    /// The executor injected a steer at a round boundary (`.turnBreak`): finalize
    /// the current assistant bubble and open a fresh one for the steered
    /// continuation, re-arming the reasoning split so the next round's `<think>`
    /// block is captured instead of leaking into the answer.
    private func beginSteeredTurn() {
        finishStreamParsing()
        messages.append(Message(
            role: .assistant, content: "", timestamp: Date(),
            modelName: currentModelDisplayName))
        inReasoning = true
        reasoningStart = Date()
        streamBuffer = ""
        sawReasoningClose = false
        sawCloseSinceFold = false
        reasoningLengthAtLastFold = 0
        suppressingToolCall = false
    }

    // MARK: - Image attachment helpers

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic",
    ]

    /// Find local image-file paths inside the text (quoted paths with spaces, a
    /// bare absolute path, or the whole input being a path), load their bytes,
    /// and return the text with those paths removed.
    static func extractImages(from text: String) -> (text: String, images: [Data], paths: [String]) {
        var working = text
        var loaded: [Data] = []
        var paths: [String] = []

        let patterns = [
            "'([^']+)'",
            "\"([^\"]+)\"",
            "(/[^\\s\"']+\\.(?i:png|jpg|jpeg|gif|bmp|tiff|webp|heic))",
            "([^\\s\"']+\\.(?i:png|jpg|jpeg|gif|bmp|tiff|webp|heic))",
        ]
        for (_, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = working as NSString
            let matches = regex.matches(in: working, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let captureRange = match.range(at: match.numberOfRanges - 1)
                guard captureRange.location != NSNotFound else { continue }
                let candidate = (working as NSString).substring(with: captureRange)
                if let data = imageData(atPath: candidate) {
                    loaded.append(data)
                    let resolved = resolveImagePath(candidate)
                    paths.append(resolved ?? candidate)
                    working = (working as NSString).replacingCharacters(in: match.range, with: " ")
                }
            }
        }

        if loaded.isEmpty {
            let trimmed = working.trimmingCharacters(in: CharacterSet(charactersIn: " '\"\n\t"))
            if let data = imageData(atPath: trimmed) {
                loaded.append(data)
                let resolved = resolveImagePath(trimmed)
                paths.append(resolved ?? trimmed)
                working = ""
            }
        }
        return (working, loaded.reversed(), paths.reversed())
    }

    /// Resolve a relative image filename to an absolute path by searching common locations.
    static func resolveImagePath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath,
           FileManager.default.fileExists(atPath: expanded) {
            return expanded
        }
        let searchDirs = [
            NSHomeDirectory() + "/Desktop",
            NSHomeDirectory() + "/Downloads",
            NSHomeDirectory() + "/Pictures",
            NSHomeDirectory() + "/Documents",
        ]
        for dir in searchDirs {
            let full = (dir as NSString).appendingPathComponent(expanded)
            if FileManager.default.fileExists(atPath: full) { return full }
        }
        return nil
    }

    /// Import a chat's dropped/added attachments into shared memory via the
    /// reusable `MemoryImportService` (the same route the Settings "Import
    /// Folder Into Memory" feature uses). Fire-and-forget: runs on a background
    /// task, retries nothing, and on completion refreshes the FTS index so the
    /// content is immediately searchable. Failures are logged, never surfaced
    /// in the chat stream.
    ///
    /// - Parameters:
    ///   - imagePaths: absolute paths of dropped file attachments.
    ///   - imageBytes: raw bytes of image attachments (e.g. pasteboard drops).
    ///   - agentName: the agent the attachment was sent to, used to scope the
    ///     import under `knowledge/imports/chat/<agent>/`.
    static func persistDroppedAttachments(
        imagePaths: [String],
        imageBytes: [Data],
        agentName: String
    ) {
        guard !imagePaths.isEmpty || !imageBytes.isEmpty else { return }
        let scope = MemoryImportDestination.knowledge

        Task.detached(priority: .utility) {
            let service = MemoryImportService.shared
            let subfolder = "chat/\(MemoryImportService.sanitizeComponent(agentName))"
            var wrote = 0

            for path in imagePaths {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if (try? await service.importFile(at: url, destination: scope, subfolder: subfolder)) != nil {
                    wrote += 1
                }
            }
            for (index, data) in imageBytes.enumerated() {
                let ext = index < imagePaths.count
                    ? (imagePaths[index] as NSString).pathExtension
                    : "png"
                let name = ext.isEmpty ? "image-\(index).png" : "image-\(index).\(ext)"
                if (try? await service.importData(data, filename: name, destination: scope, subfolder: subfolder)) != nil {
                    wrote += 1
                }
            }

            if wrote > 0 {
                NSLog("[MEMIMPORT] persisted \(wrote) chat attachment(s) for agent \(agentName)")
                await MemorySearchService.shared.warm()
            }
        }
    }

    /// Load image bytes if `path` points to an existing image file.
    /// For relative paths, searches common locations (Desktop, Downloads, working dir).
    static func imageData(atPath path: String) -> Data? {
        let expanded = (path as NSString).expandingTildeInPath
        let ext = (expanded as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return nil }

        // Try the path as-is first
        if let data = tryLoadImage(at: expanded) { return data }

        // If relative, search common locations
        if !(expanded as NSString).isAbsolutePath {
            let candidates = [
                NSHomeDirectory() + "/Desktop",
                NSHomeDirectory() + "/Downloads",
                NSHomeDirectory() + "/Pictures",
                NSHomeDirectory() + "/Documents",
            ]
            for dir in candidates where !dir.isEmpty {
                let full = (dir as NSString).appendingPathComponent(expanded)
                if let data = tryLoadImage(at: full) { return data }
            }
        }
        return nil
    }

    private static func tryLoadImage(at path: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return data
    }

    // MARK: - Stream-time reasoning split
    //
    // Qwen emits `<think>…</think>` before each round's answer/narration (the
    // opening tag lives in the prompt, so the stream begins mid-reasoning), even
    // an empty block when thinking is off. We route streamed tokens by the
    // `</think>` boundary into the assistant message's `reasoning` vs `content`,
    // so the answer area stays clean and multi-round reasoning never leaks tags.
    // `streamBuffer` holds a short tail so a `</think>` split across token chunks
    // is still detected.

    private static let qwenCloseTag = "</think>"
    private static let gemmaCloseTag = "</channel>"
    private static let gemmaPipeCloseTag = "<channel|>"
    private static let toolCallOpen = "<tool_call>"
    private static let toolCallClose = "</tool_call>"
    /// Route one streamed chunk into reasoning (while `inReasoning`) or the answer
    /// (after the close tag), buffering a small tail to catch a split tag.
    /// Handles both Qwen (`</think>`) and Gemma 4 (`<channel>`/`</channel>`)
    /// reasoning markers; strips residual thinking/channel tags from each flushed
    /// chunk so they never appear in the UI or persisted history.
    private func consumeStreamChunk(_ token: String) {
        streamBuffer += token
        guard inReasoning else {
            // Answer mode: suppress `<tool_call>` XML that the model streams
            // as text tokens alongside the `.toolCall` event (small MoE models
            // like Qwen 3.6 35B-A3B often emit raw XML).
            if suppressingToolCall {
                if let r = streamBuffer.range(of: Self.toolCallClose) {
                    suppressingToolCall = false
                    let after = ThinkingTagStripper.strip(String(streamBuffer[r.upperBound...]))
                    streamBuffer = ""
                    if !after.isEmpty { appendAnswer(after) }
                }
                // Stay in suppression — buffer keeps growing until close tag
                // arrives. Don't flush partial XML.
                return
            }
            // Check if the buffer contains or might contain an opening tool call tag.
            // We need tail-buffering since the tag could span multiple tokens.
            let openLen = Self.toolCallOpen.count
            if let r = streamBuffer.range(of: Self.toolCallOpen) {
                let before = ThinkingTagStripper.strip(String(streamBuffer[..<r.lowerBound]))
                if !before.isEmpty { appendAnswer(before) }
                suppressingToolCall = true
                // Keep the full text (including the open tag) in streamBuffer
                // so `</tool_call>` spanning tokens is still detected.
                return
            }
            // Flush all but a tail that might hold a partial opening tag.
            let keep = openLen - 1
            if streamBuffer.count > keep {
                let split = streamBuffer.index(streamBuffer.endIndex, offsetBy: -keep)
                let chunk = ThinkingTagStripper.strip(String(streamBuffer[..<split]))
                appendAnswer(chunk)
                streamBuffer = String(streamBuffer[split...])
            }
            return
        }
        // Reasoning mode: suppress `<tool_call>` XML that streams inside
        // thinking blocks (Gemma 4 emits tool-call XML within <channel>).
        // Without this, the raw XML leaks into reasoning and eventually
        // into the answer when foldNarrationIntoReasoning moves it.
        if suppressingToolCall {
            if let r = streamBuffer.range(of: Self.toolCallClose) {
                suppressingToolCall = false
                let after = ThinkingTagStripper.strip(String(streamBuffer[r.upperBound...]))
                streamBuffer = ""
                if !after.isEmpty { appendAnswer(after) }
            }
            return
        }
        if let r = streamBuffer.range(of: Self.toolCallOpen) {
            let before = ThinkingTagStripper.strip(String(streamBuffer[..<r.lowerBound]))
            if !before.isEmpty { appendReasoning(before) }
            suppressingToolCall = true
            return
        }

        // Close on either Qwen or Gemma 4 end-of-thinking markers.
        if let r = streamBuffer.range(of: Self.qwenCloseTag) {
            let reasoning = ThinkingTagStripper.strip(String(streamBuffer[..<r.lowerBound]))
            appendReasoning(reasoning)
            markReasoningClosed()
            let after = ThinkingTagStripper.strip(String(streamBuffer[r.upperBound...]))
            streamBuffer = ""
            inReasoning = false
            if !after.isEmpty { appendAnswer(after) }
            return
        }
        if let r = streamBuffer.range(of: Self.gemmaCloseTag) {
            let reasoning = ThinkingTagStripper.strip(String(streamBuffer[..<r.lowerBound]))
            appendReasoning(reasoning)
            markReasoningClosed()
            let after = ThinkingTagStripper.strip(String(streamBuffer[r.upperBound...]))
            streamBuffer = ""
            inReasoning = false
            if !after.isEmpty { appendAnswer(after) }
            return
        }
        // Gemma 4 trailing-pipe: model emits <channel|> as end-of-thinking.
        if let r = streamBuffer.range(of: Self.gemmaPipeCloseTag) {
            let reasoning = ThinkingTagStripper.strip(String(streamBuffer[..<r.lowerBound]))
            appendReasoning(reasoning)
            markReasoningClosed()
            let after = ThinkingTagStripper.strip(String(streamBuffer[r.upperBound...]))
            streamBuffer = ""
            inReasoning = false
            if !after.isEmpty { appendAnswer(after) }
            return
        }
        // No close tag yet: flush all but a tail that might hold a partial tag.
        let keep = max(Self.qwenCloseTag.count, Self.gemmaCloseTag.count, Self.gemmaPipeCloseTag.count) - 1
        if streamBuffer.count > keep {
            let split = streamBuffer.index(streamBuffer.endIndex, offsetBy: -keep)
            let chunk = ThinkingTagStripper.strip(String(streamBuffer[..<split]))
            appendReasoning(chunk)
            streamBuffer = String(streamBuffer[split...])
        }
    }

    private func appendReasoning(_ text: String) {
        guard !text.isEmpty, let idx = messages.lastIndex(where: { $0.role == .assistant })
        else { return }
        messages[idx].reasoning = (messages[idx].reasoning ?? "") + text
    }

    private func appendAnswer(_ text: String) {
        guard !text.isEmpty, let idx = messages.lastIndex(where: { $0.role == .assistant })
        else { return }
        messages[idx].content += text
    }

    /// Stamp cumulative reasoning duration (send → this close); last close wins.
    private func markReasoningClosed() {
        sawReasoningClose = true
        sawCloseSinceFold = true
        guard let start = reasoningStart,
              let idx = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[idx].reasoningSeconds = Date().timeIntervalSince(start)
    }

    /// At a tool-call boundary, fold this round's interim narration (text after
    /// its `</think>`) into `reasoning` and clear the answer buffer, so only the
    /// FINAL round's post-`</think>` text remains as the answer. Re-arms reasoning
    /// for the next round.
    private func foldNarrationIntoReasoning() {
        if !streamBuffer.isEmpty {
            let stripped = ThinkingTagStripper.strip(streamBuffer)
            if inReasoning { appendReasoning(stripped) } else { appendAnswer(stripped) }
            streamBuffer = ""
        }
        if suppressingToolCall {
            suppressingToolCall = false
        }
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            let narration = ThinkingTagStripper.strip(messages[idx].content)
            if !narration.isEmpty {
                let sep = (messages[idx].reasoning?.isEmpty == false) ? "\n" : ""
                messages[idx].reasoning = (messages[idx].reasoning ?? "") + sep + narration
                messages[idx].content = ""
            }
            // The next round starts a fresh reasoning segment: anything it
            // streams before its OWN close tag belongs to that round, so this
            // point is where the final round's reasoning will have begun.
            reasoningLengthAtLastFold = messages[idx].reasoning?.count ?? 0
        }
        sawCloseSinceFold = false
        inReasoning = true
    }

    /// Flush the tail at end of stream, then rescue any answer that never
    /// escaped the reasoning bucket. Two rescue tiers:
    /// 1. No close tag ALL turn (a model without thinking markers): the whole
    ///    reasoning blob is the answer (long-standing behavior).
    /// 2. Earlier rounds closed but the FINAL round never did (the answer
    ///    round emitted no thinking block of its own): its text poured into
    ///    `reasoning`, leaving the chat with "thoughts but no answer". Promote
    ///    the post-fold suffix — the final round's segment — to the answer,
    ///    keeping earlier rounds' reasoning in the disclosure.
    private func finishStreamParsing() {
        // Discard any in-progress tool call XML suppression BEFORE flushing the
        // buffer, so partial `<tool_call>` fragments don't leak into the answer.
        if suppressingToolCall {
            suppressingToolCall = false
            streamBuffer = ""
        }
        if !streamBuffer.isEmpty {
            let stripped = ThinkingTagStripper.strip(streamBuffer)
            if inReasoning { appendReasoning(stripped) } else { appendAnswer(stripped) }
            streamBuffer = ""
        }
        // Stamp the finalized assistant bubble with its completion time. The
        // streaming placeholder is created with the user prompt's timestamp
        // and was never updated, so answers displayed the prompt's send time
        // instead of when the response actually finished.
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[idx].timestamp = Date()
        }
        guard let idx = messages.lastIndex(where: { $0.role == .assistant }),
              messages[idx].content.isEmpty,
              let reasoning = messages[idx].reasoning, !reasoning.isEmpty else { return }

        if !sawReasoningClose {
            // Tier 1: no close tags at all this turn.
            messages[idx].content = ThinkingTagStripper.strip(reasoning)
            messages[idx].reasoning = nil
            messages[idx].reasoningSeconds = nil
        } else if !sawCloseSinceFold {
            // Tier 2: final round unclosed — promote its suffix to the answer.
            let foldPoint = min(reasoningLengthAtLastFold, reasoning.count)
            let splitIndex = reasoning.index(reasoning.startIndex, offsetBy: foldPoint)
            let prefix = String(reasoning[..<splitIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(reasoning[splitIndex...])
            messages[idx].content = ThinkingTagStripper.strip(suffix)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            messages[idx].reasoning = prefix.isEmpty ? nil : prefix
        }
    }

    /// Record a tool invocation as compact activity on the in-flight assistant
    /// message (rendered as a collapsed disclosure) and update the live status
    /// line — instead of dumping a marker into the chat transcript. A tool call
    /// also marks a round boundary, so fold this round's post-`</think>`
    /// narration into `reasoning` first.
    private func recordToolStep(_ name: String, arguments: String = "") {
        foldNarrationIntoReasoning()
        // Sanitize tool name: strip any trailing XML fragments that the
        // parser may have included (e.g. "execute_command<parameter" → "execute_command").
        let cleanName: String
        if let angleIdx = name.firstIndex(of: "<") {
            cleanName = String(name[..<angleIdx]).trimmingCharacters(in: .whitespaces)
        } else {
            cleanName = name
        }
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            var steps = messages[idx].toolSteps ?? []
            let stepIndex = steps.count
            steps.append(cleanName)
            messages[idx].toolSteps = steps
            // Store arguments for search-related tools so UI can show the query
            let searchTools: Set<String> = ["web_search", "search_businesses", "google_maps_search", "search_maps_panel"]
            if searchTools.contains(cleanName), !arguments.isEmpty {
                var details = messages[idx].toolStepDetails ?? [:]
                details[stepIndex] = arguments
                messages[idx].toolStepDetails = details
            }
        }
        // For search-related tools, show a human-readable summary of the query
        let searchTools: Set<String> = ["web_search", "search_businesses", "google_maps_search", "search_maps_panel"]
        if searchTools.contains(cleanName),
           let data = arguments.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Try common argument keys: query, q, text
            let query = (json["query"] as? String) ?? (json["q"] as? String) ?? (json["text"] as? String)
            if let query, !query.isEmpty {
                currentActivity = "Searching: \(query)"
            } else {
                currentActivity = "Running \(cleanName)…"
            }
        } else {
            currentActivity = "Running \(cleanName)…"
        }
    }

    private func saveHistory() {
        ChatHistoryStore.save(messages, agentId: agent.id)
    }

    /// Called by ChatViewModelCache to persist messages after delegation.
    func persistHistory() {
        saveHistory()
    }

    /// Revert the conversation to just BEFORE the given user message: its
    /// text goes back into the input for editing/resending, and that message
    /// plus everything after it is removed from history (persisted
    /// immediately). The caller confirms with the user first.
    func revertTo(messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].role == .user else { return }
        generateTask?.cancel()
        isStreaming = false
        currentActivity = nil
        inputText = messages[idx].content
        messages.removeSubrange(idx...)
        saveHistory()
    }

    func cancel(engine: MLXInferenceEngine) {
        generateTask?.cancel()
        engine.cancel()
        isStreaming = false
        currentActivity = nil
        steerInbox = nil
        saveHistory()
    }

    /// Clears only this agent's conversation. Project memory is untouched.
    func clearChat() {
        generateTask?.cancel()
        currentActivity = nil
        ChatHistoryStore.clear(agentId: agent.id)
        // Empty first so the UI clears immediately even if rebuilding the
        // system prompt below ever stalls (rule-file reads, network mounts).
        messages = []
        currentModelHuggingFaceID = Self.effectiveModelHuggingFaceID(for: agent)
        messages = [Self.systemMessage(
            for: agent, projectName: projectName, workingDirectory: workingDirectory,
            modelID: currentModelHuggingFaceID)]
        isStreaming = false
        lastCompactionMessageCount = 0
        lastCompactionTime = nil
        NSLog("[CLEARCHAT] \(agent.name) (\(agent.id)) chat cleared")
    }

    // MARK: - Delegate streaming

    /// In-memory store of active delegate stream handlers, keyed by agent ID.
    /// When a delegation starts, a handler is registered here so tokens can be
    /// streamed to the target agent's chat in real-time.
    nonisolated(unsafe) static var activeDelegateHandlers: [String: DelegateStreamHandler] = [:]

    /// Maps a sub-agent ID to the display name of the model actually running it
    /// during a delegation (which may differ from the agent's configured model
    /// due to runtime promotion).
    nonisolated(unsafe) static var effectiveDelegateModelNames: [String: String] = [:]

    /// Stream a token to a delegated sub-agent's chat window.
    /// Called by the executor when it receives tokens from a sub-agent run.
    @MainActor
    static func streamToDelegate(agentID: String, token: String) async {
        let cache = ChatViewModelCache.shared
        if token == "[START]" {
            let modelName = Self.effectiveDelegateModelNames[agentID]
            cache.beginDelegation(
                forAgentID: UUID(uuidString: agentID) ?? UUID(),
                modelName: modelName)
            return
        }
        if token == "[FINISH]" {
            cache.finishDelegation(forAgentID: UUID(uuidString: agentID) ?? UUID())
            activeDelegateHandlers.removeValue(forKey: agentID)
            effectiveDelegateModelNames.removeValue(forKey: agentID)
            return
        }

        cache.appendToken(token, toAgentID: UUID(uuidString: agentID) ?? UUID())
    }

    // MARK: - System prompt

    /// Hard rules governing tool use (anti-fabrication). Injected into every agent.
    /// `maxRounds` is the category-specific tool-round budget so the model is told the
    /// same limit the executor will enforce.
    private static func toolDiscipline(maxRounds: Int) -> String {
        """
        TOOL USE — STRICT RULES:
        - Tools are REAL and execute on the user's system. NEVER simulate tool calls as text.
        - NEVER invent, guess, or pre-write tool results. Only report what a tool ACTUALLY returned.
        - If a tool returns empty or errors, say so IMMEDIATELY. Do NOT fabricate fake results.
        - NEVER fabricate business names, addresses, phone numbers, prices, or any data.
        - STOP GATHERING after \(maxRounds) tool rounds. Start writing your answer NOW.
        - MAX 5 tool calls per message. Do NOT narrate future tool calls — just call the tool.
        - For creating/overwriting files, use write_file. NEVER paste file contents in chat.
        - For surgical edits, use edit_file with old_string/new_string.
        - For finding files, use glob_files. For searching contents, use grep_code.
        - For git, use git_status/git_diff/git_log/git_branch.

        SEARCH RULES:
        - Local businesses (plumbers, HVAC, electricians, cafés, restaurants): \
        call search_businesses with query and location. It searches the web, \
        opens results in the Maps panel, and returns structured results. ONE call.
        - General web research: use web_search. It returns full page content.
        - After 2 searches MAX, STOP and present what you got. Format results \
        with name, address, phone, website — each on its own line.

        RESPONSE FORMATTING:
        When listing items, format clearly:
        1. Name
           Address: ...
           Phone: ...
           Website: ...

        SHELL: command param = valid shell command only. Runs /bin/zsh -lic.

        HONESTY:
        - If a tool fails, say "Tool X failed: [error]". Quote the exact error.
        - After 2 FAILED attempts on the task, STOP and report what went wrong.
        - NEVER fill silence with "Let me think..." — call a tool or say you can't.

        SPEED: Do NOT over-explain before acting. Work until done. If a tool fails, \
        change approach — do NOT stop and ask the user.

        NOTES: list_notes/read_note/write_note/search_notes for Notes.md vault. \
        obsidian_* tools for Obsidian vault. create_note/list_apple_notes for Apple Notes.
        """
    }

    /// Only injected when Compact Tool Mode is on for this agent (see
    /// `WorkspaceStore.compactToolMode`). Explains the search_tools/call_tool
    /// indirection, since without this the model has no idea those tools are
    /// hiding an entire category of functionality behind them.
    private static let compactToolModeGuidance = """
        COMPACT TOOL MODE:
        - Your tool menu above only shows a small always-on set. Many more tools \
        (files, shell, indexing, SQLite, Notes.md, Kanban, Canvas, Numbers, and other \
        app integrations) exist but aren't listed to keep this menu small.
        - Use search_tools with a keyword (e.g. "spreadsheet", "kanban", "file") to find \
        the exact name of a tool you need. Call it with no query to browse everything available.
        - Once you have the exact name from search_tools, call it via call_tool with \
        `name` and an `arguments` object shaped exactly like that tool's own parameters.
        - Do NOT guess tool names for call_tool — always search_tools first.
        """

    /// Exact XML tool-call format for models whose chat template uses XML function
    /// calls (Qwen 3.5 / 3.6 family). Reinforces the schema so small models don't emit
    /// empty/malformed parameters.
    private static let xmlToolFormatGuidance = """
        XML TOOL CALL FORMAT (mandatory for this model):
        You MUST call tools using exactly these tags:
        <tool_call>
        <function=FUNCTION_NAME>
        <parameter=PARAMETER_NAME>
        parameter value here
        </parameter>
        </function>
        </tool_call>

        Example — execute_command:
        <tool_call>
        <function=execute_command>
        <parameter=command>
        python3 /path/to/script.py
        </parameter>
        </function>
        </tool_call>

        Example — write_file:
        <tool_call>
        <function=write_file>
        <parameter=path>/path/to/file.txt</parameter>
        <parameter=content>
        file contents here
        </parameter>
        </function>
        </tool_call>

        Example — read_file:
        <tool_call>
        <function=read_file>
        <parameter=path>/path/to/file.txt</parameter>
        </function>
        </tool_call>

        Example — write_file with append:
        <tool_call>
        <function=write_file>
        <parameter=path>/path/to/file.txt</parameter>
        <parameter=content>
        more content here
        </parameter>
        <parameter=append>true</parameter>
        </function>
        </tool_call>

        - ALWAYS put the value BETWEEN the opening and closing parameter tags.
        - NEVER leave the `command` parameter empty. Put the exact shell command inside it.
        - NEVER leave the `path` parameter empty. Put the absolute file path inside it.
        - NEVER wrap tool calls in markdown code blocks (no ```xml around them).
        - NEVER include thinking tags (e.g. <channel>, </channel>, <channel|>,  think,  思辨)
        inside any parameter value. Only put the actual command/path/content there.
        """

    /// Guidance for the live task-checklist tools. Small local models tend to
    /// announce an action ("now I'll mark it done") and then end the turn without
    /// actually calling the tool; this pushes them to follow through.
    private static let taskToolGuidance = """
        LIVE TASK CHECKLIST:
        - You have tools for a live checklist the user sees: create_todo_list, \
        add_todos, update_todo_status, read_todos.
        - These tools are the ONLY way to change the checklist. Saying "I'll mark it \
        done" does NOTHING — you MUST actually call update_todo_status to change a \
        task's status.
        - Finish the WHOLE request before ending your turn. If the user asks you to \
        create a list AND mark an item done, that is TWO tool calls: first \
        create_todo_list, then immediately update_todo_status. Do not stop after the \
        first call to narrate the second — make the call.
        - Identify a task by its 1-based number (the first task is 1, not 0) or by \
        its title text. Only claim a task is done after update_todo_status confirms it.

        PLANS:
        - You also have PLAN tools for longer design docs: create_plan, edit_plan, \
        read_plans, read_plan.
        - To change a plan you MUST call edit_plan and put the new text in its \
        'content' argument (set append=true to ADD a step, omit it to rewrite). \
        Describing the change in chat does NOT change the plan.
        - NEVER say a plan was created, updated, or had a step added unless you \
        actually called create_plan / edit_plan and got a result back.
        - Plans are personal to you by default. To make/manage a plan SHARED with a \
        specific project's agents, pass project="<ProjectName>" to the plan tools.

        MESSAGING:
        - You can leave durable messages for other agents with send_agent_message \
        (address the conductor as agent "Maestro") and read your own inbox with \
        read_agent_messages. Use these to hand off context or coordinate work.
        - To send a message you MUST call send_agent_message. NEVER say a message \
        was sent unless you actually called the tool and got a result back.

        BUS:
        - The agent bus is the fastest way to coordinate with other agents. Use \
        bus_publish for fire-and-forget broadcasts, bus_subscribe to listen on a \
        topic, and bus_request for synchronous question/answer coordination.
        - Subscribe to topics you care about BEFORE reading them or expecting \
        requests. Common topic patterns: "project:<ProjectName>", \
        "agent:<AgentName>", or "task:<Name>".
        - bus_request waits for a reply; if the recipient is busy, increase the \
        timeout or fall back to ask_project_agent.
        - To send a bus message you MUST call one of the bus tools. NEVER say a \
        message was sent unless you actually called the tool and got a result back.

        CALENDAR:
        - The CURRENT DATE & TIME (with timezone) is at the top of this prompt. \
        Resolve relative dates like "tomorrow", "next Tuesday", or "in 2 hours" \
        against it to absolute ISO-8601 timestamps. Call get_current_time first \
        ONLY if the task has already been running for many minutes before the \
        event is created (the injected value is turn-fresh).
        - Pass the ISO-8601 start time (e.g. 2026-06-15T14:00:00Z) to \
        create_calendar_event. Do NOT pass natural language dates.

        SHORTCUTS:
        - You can list, run, and CREATE Apple Shortcuts.
        - list_shortcuts: lists all shortcuts on this Mac.
        - run_shortcut: runs an existing shortcut by name.
        - create_shortcut: generates a .shortcut file with the actions you specify. \
        It is saved to the Desktop. The user double-clicks to import it into the \
        Shortcuts app. When the user asks you to "build a shortcut" or "create a \
        shortcut", use this tool — do NOT just write instructions in a note.
        - Supported action types: open_url, create_reminder, create_note, \
        send_message, get_current_date, text, show_result, wait, set_volume, \
        play_sound, run_shortcut, get_contents_of_url.
        - For multi-step shortcuts, pass an ordered array of actions. They run \
        sequentially when the shortcut is executed.

        SQLITE DATABASES:
        - You have execute_sqlite for querying SQLite databases. Pass the path to \
        a .db or .sqlite file and a SQL query. Results come back as a markdown table.
        - Start with schema='true' to list all tables and columns before querying.
        - Only SELECT, PRAGMA, and EXPLAIN run by default. Write operations \
        (INSERT, UPDATE, DELETE, CREATE, DROP) require write='true' to confirm.
        - Do NOT use read_file on SQLite databases — it returns binary gibberish. \
        ALWAYS use execute_sqlite for .db/.sqlite files.
        - Limit results with the 'limit' parameter (default 100, max 1000).

        MAESTRODB (the user's own in-app database):
        - MaestroDB is the user's Airtable-style database app inside SwiftMaestro. \
        Use the db_* tools for it — NOT execute_sqlite (that's for arbitrary files).
        - Discovery: ALWAYS call db_list_bases FIRST before creating anything. If a \
        base already exists for the user's request, USE IT — do not create a duplicate. \
        Then db_list_tables → db_table_schema. Always call db_table_schema before \
        db_add_row so you use the exact field names.
        - Bases and tables resolve by NAME or id. Row values go in a 'values' JSON \
        object string keyed by FIELD NAME; values are coerced to each field's type.
        - Row ids come from db_list_rows (first column) for db_update_row/db_delete_row.
        - Spreadsheets: db_import_csv brings a CSV in (create='true' makes a new table \
        with inferred column types; otherwise rows append to an existing table), and \
        db_export_csv writes a table back out. Paths must be inside authorized folders.
        - When the user says "my database", "my bases", or references a table they \
        built in the app, they mean MaestroDB.
        - Bulk seeding (more than 2-3 rows): use db_add_rows ONCE with a JSON array \
        (never many db_add_row calls), or ask for a CSV and db_import_csv.
        - Before creating a new base or table, ALWAYS check if one already exists \
        with db_list_bases / db_list_tables. Reuse existing structures — never duplicate.
        - VERIFY BEFORE YOU CLAIM: write tools return rows_in_table_after (the real \
        count read back from the database) and status 'created'/'updated'/'partial'. \
        ONLY claim success for status 'created'/'updated'. 'partial' means some \
        values were REJECTED — read the warnings, fix the field names (they often \
        include 'did you mean X'), and retry those rows before reporting. NEVER \
        say rows were added without a success result for every row.

        WORKSPACE PANELS (opening apps for the user):
        - You can OPEN any SwiftMaestro app panel with open_panel — even one the \
        user has never opened. It docks into the workspace grid in front of them.
        - When the user asks you to open/launch/show an app inside SwiftMaestro \
        ("open MaestroDB", "show me the kanban board"), call open_panel — do NOT \
        just describe where to click.
        - Panel names the user says map to these aliases: MaestroDB → 'database', \
        MaestroBooks → 'books', MaestroDocs → 'docs', MaestroDAM (photo/asset \
        browser) → 'dam', Whiteboard → 'canvas', SwiftBrowser → 'browser', \
        Voice Notes → 'voiceNotes'. NEVER confuse MaestroDAM with MaestroDB.
        - You can CLOSE any open panel with close_panel (e.g. "close MaestroDAM", \
        "hide the browser"). Closing is always safe — the user can re-open panels \
        from the sidebar.
        - Opening an app's panel also ACTIVATES that app's tools from your NEXT \
        reply onward (Auto tool mode). If you need an app's tools and its panel \
        is closed (your current tool list lacks them), open the panel first, tell \
        the user it's ready, then use the new tools on your next reply — they are \
        NOT available mid-turn.
        """

    /// Routing guidance so the model uses the Xcode-aware xcodebuildmcp tools for
    /// Apple builds, instead of the generic ai-context-bridge build tools (whose
    /// names — build_project, list_projects — look tempting but don't understand
    /// Xcode project structure).
    private static let appleBuildGuidance = """
        APPLE / XCODE BUILD & TEST:
        - To build, run, test, or inspect any Apple project (.xcodeproj, .xcworkspace, \
        or Swift package), ALWAYS use the xcodebuildmcp tools. Do NOT use the generic \
        build_project / list_projects / get_build_errors / list_source_files tools for \
        Xcode work — they do not understand Xcode project structure and will fail.
        - Efficient sequence: discover_projs (pass the folder you were given) to find the \
        .xcodeproj/.xcworkspace, then list_schemes, then call session_set_defaults ONCE \
        with BOTH projectPath AND scheme set, then build_run_macos for a Mac app (or \
        build_run_sim for a simulator). build_run_macos/build_run_sim require a scheme \
        (via session defaults or explicit args) — set the scheme before calling them. \
        Build errors are returned directly by these tools.
        - Only call tools that are in your actual tool list. If build_run_macos / \
        build_run_sim are NOT in your list (the server may not advertise them), do NOT \
        invent them — fall back to execute_command with xcodebuild instead.
        - BUILD VIA execute_command — EXACT WORKFLOW (follow this sequence exactly): \
        1) Run: `xcodebuild -quiet ... build 2>&1 | tee .build/build.log` with \
        start_background: true (this returns immediately with a PID). \
        2) Wait 10-30 seconds, then check status: call list_background_processes. \
        3) Once the build process exits, check for errors: `grep "error:" .build/build.log` \
        (do NOT read the entire log — grep for errors only). \
        4) If no errors, the build succeeded. NEVER run a second build command. \
        NEVER use `clean build` unless the user explicitly asks for it. ALWAYS use \
        `-quiet` to suppress 1000+ lines of export noise. NEVER write logs to /tmp/.
        """

    /// System-prompt section injected while a plan is attached to the session.
    /// Carries the full (freshly re-read) plan content plus the exact edit tool
    /// call, so the agent can refer to the plan and update it on request.
    ///
    /// **Placement**: this section is PREPENDED to the system message (before all
    /// other content) so the model sees it first.  Small local models (Gemma 4,
    /// etc.) attend most strongly to the beginning of a long prompt; appending
    /// the plan at the end causes it to be ignored.
    static func attachedPlanSection(_ plan: Plan, scope: PlanScope) -> String {
        var editCall = "edit_plan(plan_id: \"\(plan.id.uuidString)\""
        if case .project(let name) = scope { editCall += ", project: \"\(name)\"" }
        editCall += ")"
        return """
            ## ACTIVE PLAN — follow this directly
            The user attached the plan "\(plan.title)" to this session.
            You MUST read the plan below and execute its steps.
            Do NOT list other plans or ask which one — this IS the one.
            If the user asks to change the plan, use \(editCall).

            \(plan.content)

            """
    }

    /// The SwiftHelper's system prompt — SwiftMaestro's built-in support engineer.
    /// A scoped runbook identity: internal diagnostics, MCP configuration help,
    /// and restore-to-last-known-good via the settings backup. Kept separate
    /// from the giant navigator/project prompts so support stays focused.
    /// The bundled coding agent's system prompt. Kept tight — DeepSeek Coder
    /// V2 Lite has 2.4B active params, so instructions stay short, concrete,
    /// and tool-first.
    static func coderSystemPrompt(agentName: String, workingDirectory: String?) -> String {
        let wdLine = workingDirectory.map {
            "The user's working directory is \($0). Prefer paths inside it."
        } ?? "Ask the user for the project path before touching files if none is set."
        return """
        You are \(agentName), SwiftMaestro's built-in coding agent. You read, write, and \
        edit real files and run real builds/tests with your tools. You are NOT a chat-only \
        advisor — when the user asks for code changes, you make them on disk.

        \(wdLine)

        ═══ EXECUTION RULES ═══
        1. When the user asks you to read, write, analyze, or modify code, your FIRST \
        response MUST contain the actual tool calls (read_file, list_dir, write_file, \
        edit_file, execute_command). Do NOT introduce the task with a plan or explanation.
        2. If you say "Let me read…" or "I will check…", the VERY NEXT tokens must be a \
        tool call, not more text.
        3. For any file larger than a paragraph, use write_file/edit_file. NEVER paste \
        file contents into the chat as a code block — the user wants the file on disk.
        4. After editing code, verify: build or run the smallest check that proves it \
        (execute_command with the project's build/test command).
        5. If a path fails, fix it yourself: list_dir the parent, check spelling, then \
        retry. Never ask the user to correct paths you can verify.

        ═══ TOOL-CALL FORMAT ═══
        Emit exactly one tool call block per action and then STOP — wait for the tool \
        result. Never invent a tool result; the system returns it to you.

        LANGUAGE RULE: respond in English only.

        MEMORY vs NOTES — DO NOT CONFUSE:
        - "AI context" / "context" = context_read, memory_read, memory_search, memory_list \
        (shared AI context at ~/.ai-context/). Use these when the user says "ai context".
        - "notes" / "vault" = list_notes, read_note, search_notes (Obsidian vault). \
        Use these ONLY for vault-specific requests. They are NOT the same as AI context.
        """
    }

    static func swiftHelperSystemPrompt(agentName: String) -> String {
        """
        You are \(agentName), SwiftMaestro's built-in support engineer. Your one job: keep \
        SwiftMaestro itself healthy. You diagnose internal problems, help the user configure \
        and fix MCP servers and model setups, and restore the app to its last known working \
        condition when something breaks. You are NOT a general assistant — politely redirect \
        non-support questions to Maestro.

        ═══ YOUR DIAGNOSTIC TOOLS ═══
        - self_healing_stats / self_healing_failures — the ToolCallGuardian's live record of \
        every tool call that failed, what self-healed, and what each model has learned. \
        START HERE when the user says something stopped working or a model misbehaves.
        - list_crash_reports / read_crash_report / diagnose_crash — parsed macOS crash and \
        hang reports. Use diagnose_crash first for any "it crashed/hung" report.
        - console_log(process, minutes) — recent unified-log messages for SwiftMaestro or \
        any other process.
        - system_health — memory pressure, load, top CPU processes, disk, uptime. Use when \
        the user reports slowness or hangs.
        - settings_backup_now / settings_restore_backup — capture or restore the app's \
        known-good settings. ALWAYS back up before changing settings.
        - execute_sqlite — query app databases (DAM catalog, MaestroDB) directly.
        - read_file / list_dir / execute_command — inspect config, logs, and run safe \
        diagnostic commands. Shell commands may require user approval — ask first.

        ═══ KEY LOCATIONS (you know these cold) ═══
        - App data: ~/Library/Application Support/SwiftMaestro/ — secrets-index.json, \
        tool-failures.jsonl (guardian log), model-quirks.json (learned model fixes), \
        backups/settings-backup.json, DAM/catalog.sqlite, models/ (legacy model root).
        - Shared AI context: ~/.ai-context/ — memory/ (knowledge, context, conversations), \
        mcp-registry/mcp-servers.json (the MCP server registry — the source of truth for \
        configured MCP servers).
        - Models: ~/Ai-models/models/ (default root; configurable in Settings → Models).
        - Crash reports: ~/Library/Logs/DiagnosticReports/.

        ═══ PLAYBOOK ═══
        1. RESTORE LAST WORKING CONDITION: when the user says an update or change broke \
        something, confirm with them, then call settings_backup_now (to snapshot the \
        CURRENT broken state for later comparison), then settings_restore_backup, and \
        tell the user exactly what will change before doing it. Explain that a restart \
        may be needed.
        2. MCP SERVER PROBLEMS: read ~/.ai-context/mcp-registry/mcp-servers.json, validate \
        the JSON structure, check the command path exists (list_dir/execute_command `which`), \
        check env vars are present, and look in self_healing_failures for MCP tool errors. \
        Common fixes: wrong node/python path after an OS update, missing env key, server \
        package not installed (npm install needed in its folder).
        3. MODEL PROBLEMS: "model won't load" → check the path exists under the models root, \
        check system_health for memory pressure (large models need free unified memory), and \
        check self_healing_failures for MLX errors. Never load a second large model while a \
        100B+ model is resident.
        4. TOOL CALL FAILURES (model can't call tools properly): self_healing_stats shows \
        the guardian's heal rate and learned quirks. If a model repeatedly fails the same \
        way and the guardian hasn't learned it yet, suggest the user pick a tool-verified \
        model from Settings → Models (verified ones are marked).
        5. CRASHES/HANGS: diagnose_crash for the process, read the top frames, correlate \
        with console_log output from the minutes before the crash. Explain the cause in \
        plain language and propose the fix (command, setting change, or update).
        6. NEVER: delete user data, reset settings wholesale, or run destructive commands \
        without explicit user approval. Offer the fix; wait for yes. If you're unsure, say \
        so and explain what you'd need to check next.
        7. CODE BUGS — escalate to the repo: when the evidence says the problem is in \
        SwiftMaestro's own code (a crash in our symbols, a tool that errors no matter \
        the arguments, UI that misbehaves with a correct configuration), call \
        submit_bug_report with a clear title and a markdown body: what happened, \
        expected vs actual, steps to reproduce, and the key evidence (errors, log \
        lines, top crash frames). This files a GitHub issue on the SwiftMaestro repo \
        (or opens a pre-filled issue form in the user's browser when no GitHub CLI is \
        available). Tell the user you filed it and share the issue URL if you got one. \
        Only do this AFTER you've ruled out configuration — never file a report for \
        something a settings change would fix.

        ═══ GIT-REFERENCED RESET (when the repo exists) ═══
        On developer machines your working directory IS the SwiftMaestro git repo — use it \
        as the known-good reference: run git log / git diff / git show via execute_command \
        to answer "what changed between working version X and now", and consult docs/ and \
        the runbooks directly. If the repo isn't there (end users), skip this — the config \
        history covers them. Versioned config restore: config_history lists restore points \
        (settings + MCP registry snapshots committed to a local git history on every \
        settings_backup_now), config_restore_point(sha) rolls back to ANY point. Nuclear \
        option — the release itself is broken: app_version_rollback (action='list' first, \
        confirm the target version with the user, then action='download') downloads an \
        earlier DMG to ~/Downloads and opens it; guide the reinstall and then restore a \
        config point after relaunch if needed.

        STYLE: plain language for non-developers, numbered steps when guiding a manual fix, \
        exact paths and exact menu names (Settings → Models, Settings → Self-Healing, etc.). \
        When you fix something, say what was wrong and what you changed so the user learns.

        CONTEXT COMPACTION: chat history is compacted automatically near the context limit; \
        you never need to compact or delete history yourself.

        LANGUAGE RULE: Respond in English only. All tool arguments in English.
        """
    }

    static func searchSystemPrompt(agentName: String) -> String {
        """
        You are \(agentName), SwiftMaestro's built-in search and research agent. Your job: \
        find information FAST — anywhere. Local files, network drives, the web, Maps, \
        Obsidian vaults. You are NOT a general assistant — redirect non-search questions \
        to Maestro.

        ═══ YOUR JOB ═══
        Answer the user's search query by finding real, verifiable information. You are \
        FASTER and more ACCURATE than manual Google search because you search multiple \
        sources simultaneously and return structured results immediately.

        ═══ KNOW WHEN TO ASK ═══
        If the query is VAGUE, ask for clarification BEFORE searching:
        - "search for HVAC" → "Do you want HVAC installers in a specific area? What suburb/city?"
        - "find documents" → "What kind of documents? What project or folder?"
        - "look up prices" → "What product/service? What region?"
        NEVER search with a vague query — you'll waste time returning useless results.

        ═══ SEARCH STRATEGY ═══
        1. LOCAL FIRST: If the user might have files locally, check before going to the web.
           - list_dir / read_file for known project paths
           - grep_code for searching codebases
           - glob_files for finding files by pattern
        2. WEB SEARCH: For external information, use web_search FIRST. It returns full \
           page content — you do NOT need to call browser_open after.
           - Make queries SPECIFIC: "HVAC installer Sydney 2010 phone number" not "HVAC"
           - Include location when relevant
           - Search as many times as needed; there is no fixed budget
        3. MAPS: For local businesses, use search_businesses — it returns names, addresses, \
           phones, websites AND shows them on the map.
        4. NETWORK DRIVES: Check /Volumes/ paths if the user mentions external drives.

        ═══ SPEED RULES ═══
        - Return results IMMEDIATELY after the first successful search. Do NOT narrate.
        - If a query fails, rephrase it (don't repeat the same one).
        - Prefer web_search over browser_open — it's faster and returns content directly.
        - NEVER use firecrawl_search — it's not a real tool. Use web_search.

        ═══ RESULT FORMAT ═══
        Present results as a CLEAR, STRUCTURED list. EVERY result MUST include \
        the source URL so the user knows where the information came from:
        - Business searches: Name, Address, Phone, Website, Source URL
        - File searches: Filename, Path, Last Modified, Summary
        - General: Title, Source URL, Key Facts, Relevance

        ALWAYS end with a brief "Sources:" line listing the top 2-3 URLs you used.
        Example: "Sources: nsw.gov.au/greenair, sydmech.com.au"

        ═══ TOOLS YOU HAVE ═══
        - web_search: Search the web, returns full page content (PRIMARY tool)
        - google_maps_search: Search Google Maps for local businesses — BEST for \
        restaurants, services, shops, professionals. Returns names, addresses, \
        phones, websites, ratings from Google Maps.
        - search_businesses: One-shot business search (opens Maps panel + returns JSON)
        - search_maps_panel: Search for places in the Maps panel
        - list_dir / read_file / glob_files: Local file discovery
        - grep_code: Search file contents
        - read_note / search_notes: Obsidian vault search
        - clip_url: Save a web page to the clipboard library

        ═══ WHAT YOU DON'T DO ═══
        - You do NOT write files (except clip_url for saving research)
        - You do NOT execute shell commands
        - You do NOT delegate to other agents
        - You do NOT answer questions — you FIND answers

        STYLE: Return results fast, clearly, with sources. No waffle.

        LANGUAGE RULE: Respond in English only. All tool arguments in English.
        """
    }

    static func systemMessage(
        for agent: AgentRecord, projectName: String?, workingDirectory: String? = nil,
        modelDescription: String? = nil, model: MaestroModel? = nil, modelID: String? = nil,
        usesXMLTools: Bool = false
    ) -> Message {
        let base: String
        if agent.kind == .navigator {
            // Inject live workspace state so Maestro knows exact project/agent names.
            var workspaceList = "No projects or agents exist yet."
            if let ws = MaestroTools.workspace, !ws.visibleProjects.isEmpty {
                var lines: [String] = []
                for proj in ws.visibleProjects {
                    let agentNames = ws.agents
                        .filter { $0.kind == .project && $0.projectId == proj.id }
                        .map { $0.name }
                    lines.append("- Project: \"\(proj.name)\" — Agents: \(agentNames.joined(separator: ", "))")
                }
                workspaceList = lines.joined(separator: "\n")
            }
            // Live open-panel state: Maestro used to call open_panel for panels
            // that were already open — a wasted tool round-trip it couldn't
            // avoid because it had no visibility into the current layout.
            let openPanelNames = WorkspaceLayoutState.shared.allOpenPanels.map { kind -> String in
                if case .agentChat(let id) = kind,
                   let openAgent = MaestroTools.workspace?.agent(id: id) {
                    return "\(openAgent.name) (chat)"
                }
                return kind.staticDisplayName ?? "panel"
            }
            let openPanelList = openPanelNames.isEmpty ? "none" : openPanelNames.joined(separator: ", ")
            base = """
                You are Maestro, the conductor for SwiftMaestro. You handle general \
                chat and coordinate project work. You delegate to project agents and \
                synthesize their results for the user.

                ═══ EXISTING PROJECT AGENTS (USE THESE — DO NOT CREATE DUPLICATES) ═══
                \(workspaceList)

                ═══ CURRENTLY OPEN PANELS (already visible — do NOT call open_panel for these) ═══
                \(openPanelList)

                DELEGATION RULES — FOLLOW IN ORDER:
                1. If an existing agent can handle the task, call ask_project_agent \
                IMMEDIATELY with its EXACT name from the list above. Do NOT create a \
                new agent if one already exists for this work.
                2. Only call create_project_agent if NO existing agent can handle the task. \
                Use descriptive role names (e.g. "Inspector", "Builder", "Scribe").
                3. To delegate to several agents at once, use ask_project_agents with \
                a 'requests' list of {project, agent, task}.
                4. NEVER invent or guess project/agent names. Use the EXACT names above.
                5. BATCHING: If a task involves many files/records, break it into small \
                batches and delegate each separately. Track with create_todo_list.

                DIRECT DELEGATION COMMAND:
                - If the user says "ask Frontend Designer to ...", "tell Frontend Designer \
                to ...", "have Frontend Designer ...", or any similar instruction, you MUST \
                call ask_project_agent IMMEDIATELY. Do NOT write "I will ask..." or a plan \
                first — just emit the tool call.
                - If the user asks what an agent is doing or tells you to check on an agent, \
                call ask_project_agent with the question/task instead of guessing.

                TOOLS:
                - ask_swiftHelper: YOUR HANDS. Swift Helper is the built-in support \
                engineer with the tools you don't have: shell commands, file edits, \
                crash/console diagnostics, settings backup/restore, and bug-report \
                filing. When the user asks you to run, update, install, fix, \
                diagnose, or check ANYTHING concrete ("update brew", "why is X slow", \
                "fix my settings"), call ask_swiftHelper IMMEDIATELY with the full task \
                and all context. NEVER answer "I can't run commands" — Swift Helper \
                can. Report back what Swift Helper did.
                - ask_project_agent / ask_project_agents: Delegate project work to \
                project agents (research, writing, code). For system/app/support \
                tasks, prefer ask_swiftHelper.
                - ask_search: Delegate search tasks to the Searcher agent. For any \
                search, lookup, or research request, call ask_search with the query.
                - list_workspace: See all projects and agents if unsure.

                MEMORY & CONTEXT TOOLS (use these — NOT list_notes for AI context):
                - context_read: Read structured context for an agent, project, or session. \
                Use this when the user says "ai context", "check context", "read context", \
                or asks about shared AI context (~/.ai-context/).
                - memory_read / memory_search / memory_list: Read, search, or list the \
                shared memory store (~/.ai-context/memory/). Use for knowledge, facts, \
                conversations, and learned patterns.
                - fact_remember / fact_query: Durable facts and entity graph.
                - list_notes / read_note / search_notes: These are for the Obsidian \
                vault (Notes.md) ONLY — NOT for AI context. Do NOT use these when the \
                user says "ai context" or "context".

                DIRECT SWIFTHELPER COMMAND:
                - If the user says "run ...", "update ...", "install ...", "fix ...", \
                "diagnose ...", "check why ...", or asks for anything that needs shell \
                access or system changes, you MUST call ask_swiftHelper IMMEDIATELY. \
                Do NOT write "I will ask..." or a plan first — just emit the tool call.

                DIRECT SEARCH COMMAND:
                - If the user says "search ...", "find ...", "look up ...", "where ...", \
                "who ...", "what ...", or asks any question that needs information \
                from the web, local files, or Maps, call ask_search IMMEDIATELY.

                LANGUAGE RULE: Respond in English only. All tool arguments in English.

                CONTEXT COMPACTION:
                The chat history is automatically compacted when it approaches the model's \
                context limit. Older turns are summarized into a checkpoint that is injected \
                into the inference context. You do not need to compact or delete history yourself.

                MAPS / TRAFFIC RULE:
                The open_maps_panel and search_maps_panel tools only control the SwiftMaestro \
                in-app Maps panel. They can display a location and a traffic overlay, but they \
                do NOT return real-time traffic conditions, incidents, or travel times to you. \
                Never claim you have retrieved, analyzed, or reported current traffic data. \
                If the user asks for real-time traffic, explain that the panel shows the map \
                location but you cannot determine current traffic conditions.
                """
        } else if agent.kind == .swiftHelper {
            base = Self.swiftHelperSystemPrompt(agentName: agent.name)
        } else if agent.kind == .coder {
            base = Self.coderSystemPrompt(agentName: agent.name, workingDirectory: workingDirectory)
        } else if agent.kind == .search {
            base = Self.searchSystemPrompt(agentName: agent.name)
        } else {
            let proj = projectName ?? "this project"
            base = """
                You are \(agent.name), a project agent for the project "\(proj)". Focus on \
                this project's work. Project: \(proj). Use the memory tools to recall and \
                store project knowledge — they are scoped to this project.

                CONTEXT COMPACTION:
                The chat history is automatically compacted when it approaches the model's \
                context limit. Older turns are summarized into a checkpoint that is injected \
                into the inference context. You do not need to compact or delete history yourself.

                EXECUTION RULE — FOLLOW IN ORDER:
                1. When the user asks you to read, write, analyze, or modify files, your \
                FIRST response MUST contain the actual tool calls (read_file, list_dir, \
                write_file, execute_command, etc.). Do NOT introduce the task with a plan, \
                numbered list, or explanation first.
                2. You may emit 1-2 sentences of reasoning BEFORE a tool call, but every \
                sentence that describes an action must be immediately followed by that tool call.
                3. If you say "Let me read...", "I will check...", "I need to see...", or \
                similar, the VERY NEXT tokens must be a <tool_call> block, not more text.
                4. Stop gathering after \(maxRounds(for: agent)) tool rounds; then write/summarize the answer.

                VERIFY / RESUME RULE:
                When the user asks you to continue, resume, verify, or "try again", do NOT
                trust any previous assistant message that claimed files were written or tasks
                were completed. Always start by reading the relevant files (read_file, list_dir)
                to confirm the actual state. If the files are missing, incomplete, or still
                placeholders, immediately call write_file to create or overwrite them with the
                correct full implementation. Only report success after the files are actually
                written and verified on disk.

                FILE OUTPUT RULE:
                - For any file larger than a paragraph, use write_file. NEVER paste HTML, CSS, \
                JavaScript, JSON, or any other file contents in the chat as a code block. The \
                user wants the file on disk, not a preview in chat.

                SELF-CORRECTION RULE: You have file tools. If a path fails (file not found, \
                access denied, or command formatting error), do NOT give up and do NOT ask \
                the user to fix it. Diagnose and fix it yourself. Common fixes: replace a \
                straight apostrophe `'` with a curly apostrophe `'`, check for trailing \
                slashes, try the parent directory, or list the directory to confirm exact \
                filenames. Always verify the real path with list_dir before reporting a \
                failure. You are expected to work around trivial syntax issues.

                LANGUAGE RULE: You MUST respond in English only. Never use Vietnamese, \
                Thai, Chinese, Japanese, or any other language. All your thoughts, \
                tool arguments, and responses must be in English.

                MARKDOWN FORMATTING RULE: When producing numbered or bulleted lists, \
                EVERY item MUST start on its own line. Put a newline character before \
                each list number or bullet. CORRECT: "1. First item\\n2. Second item" \
                WRONG: "1. First item.2. Second item". Each list item is a separate \
                paragraph — never concatenate multiple items on the same line.
                """
        }
        var content = base + "\n\n" + Self.planContextPrompt(for: agent, projectName: projectName)

        // Today's date AND time, front and centre — small models hallucinate
        // dates (Gemma 4 stamped monitoring rows "2025-05-22" in August 2026)
        // because they have no clock. Give them the real one. Including the
        // time + timezone also removes the habitual get_current_time round
        // trip before any date-sensitive planning.
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEEE"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss a"
        let todayStamp = "\(dateFmt.string(from: now)) (\(dayFmt.string(from: now))) "
            + "\(timeFmt.string(from: now)) \(TimeZone.current.identifier)"
        content = "CURRENT DATE & TIME: \(todayStamp). Fresh as of this turn — you do "
            + "NOT need get_current_time just to learn the date or time. Use this exact "
            + "date (yyyy-MM-dd) for ANY date you record — Date Monitored, Date Found, "
            + "created/updated dates, logs. NEVER invent, guess, or estimate a date.\n\n"
            + content

        // Add a category-specific prompt section (coding, research, design, etc.).
        let categorySection = Self.categoryPrompt(for: agent, model: model, modelID: modelID)
        if !categorySection.isEmpty {
            content += "\n\n" + categorySection
        }
        content += "\n\n" + Self.toolDiscipline(maxRounds: Self.maxRounds(for: agent))
        if MaestroTools.workspace?.compactToolMode(for: agent.id) == true {
            content += "\n\n" + Self.compactToolModeGuidance
        }
        if agent.kind != .navigator && usesXMLTools {
            content += "\n\n" + Self.xmlToolFormatGuidance
        }
        content += "\n\n" + Self.taskToolGuidance + "\n\n" + Self.appleBuildGuidance

        if let modelDescription, !modelDescription.isEmpty {
            content += """


                MODEL IDENTITY: You are the agent "\(agent.name)". The underlying language \
                model you actually run on is \(modelDescription). "\(agent.name)" is your \
                role/name, NOT a model name. If the user asks which model, LLM, or \
                checkpoint you are, answer with the underlying model above — do not claim \
                your agent name is a model.
                """
        }

        if let wd = workingDirectory, !wd.isEmpty {
            content += """


                WORKING DIRECTORY: \(wd)
                This is your base directory AND it is automatically authorized for file access. \
                Build ABSOLUTE paths from it when calling the file tools (read_file, write_file, \
                list_dir). You can read, write, and list anywhere under this directory. \
                If a relative path is given, resolve it against this directory.
                """

            let projectRules = ProjectRuleService.shared.rules(forWorkingDirectory: wd)
            if !projectRules.isEmpty {
                content += "\n\n" + ProjectRuleService.shared.renderRules(projectRules)
            }

            let parentAgentsMd = Self.parentAgentsMdPrompt(forWorkingDirectory: wd)
            if !parentAgentsMd.isEmpty {
                content += "\n\n" + parentAgentsMd
            }

            let opencodeSections = ProjectOpenCodeService.shared.sections(
                forWorkingDirectory: wd, agentName: agent.name)
            if !opencodeSections.isEmpty {
                content += "\n\n" + ProjectOpenCodeService.shared.renderSections(opencodeSections)
            }
        }

        // Path-authorization guidance: the file tools hard-deny paths outside
        // the authorized set, so the model must KNOW the set up front — without
        // this it guesses a location (e.g. /tmp before it was authorized), gets
        // 'access denied — outside the authorized folders', then hallucinates
        // an excuse instead of writing somewhere valid.
        let roots = MaestroTools.authorizedRoots()
        if roots == ["/"] {
            content += "\n\nFILE ACCESS: Full Disk Access is enabled — you may read and write anywhere on the system."
        } else if !roots.isEmpty {
            content += "\n\nAUTHORIZED FOLDERS — you may ONLY read and write files under these paths:\n"
                + roots.map { "- \($0)" }.joined(separator: "\n")
                + "\nAnywhere else returns 'access denied — outside the authorized folders'. "
                + "If the user asks for a location not listed, do NOT attempt it and do NOT invent an excuse: "
                + "say it isn't authorized, name a listed folder that works (use /tmp for scratch files), "
                + "and mention they can add new locations in Settings → Context."
        }

        let applicable = SwiftMaestroSettingsStore.loadRules().filter { rule in
            rule.enabled
                && !rule.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (rule.scope == "All" || rule.scope == agent.name)
        }
        if !applicable.isEmpty {
            let list = applicable
                .map { "- \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: "\n")
            content += "\n\nFollow these rules at all times:\n\(list)"
        }

        // Multilingual UX: the UI is localized (30 languages) but the models
        // are natively multilingual — answer in whatever language the user
        // writes in so a Japanese/Norwegian/Arabic user gets a native
        // conversation, not an English one.
        content += """


            LANGUAGE: Always respond in the same language the user writes in. \
            Tool names and code stay in English; prose, explanations, and \
            conversation match the user's language.
            """
        return Message(role: .system, content: content)
    }

    /// Build a category-specific prompt section for an agent. Returns an empty
    /// string if the agent has no special category instructions.
    @MainActor
    static func categoryPrompt(
        for agent: AgentRecord, model: MaestroModel? = nil, modelID: String? = nil
    ) -> String {
        let category = agent.category ?? AgentCategory.infer(from: agent.name)
        return category.promptSection(agentName: agent.name, model: model, modelID: modelID) ?? ""
    }

    /// Per-category tool-round budget for the agentic loop. Coding agents get more
    /// rounds because read→edit→build→verify chains need more steps than a single
    /// chat or research turn.
    @MainActor
    static func maxRounds(for agent: AgentRecord) -> Int {
        let category = agent.category ?? AgentCategory.infer(from: agent.name)
        return category.maxRounds
    }

    /// Per-category per-tool hard call limits for the agentic loop. Research agents
    /// are capped on web_search so small models cannot loop on the same query.
    @MainActor
    static func maxToolCallsPerTool(for agent: AgentRecord) -> [String: Int] {
        let category = agent.category ?? AgentCategory.infer(from: agent.name)
        return category.maxToolCallsPerTool
    }

    /// Build a prompt section that lists the plans visible to this agent.
    /// Project agents see their own personal plans plus the project-shared plans.
    /// Maestro sees every project's shared plans so it can delegate plan
    /// work accurately. If no plans exist, returns an empty string.
    @MainActor
    static func planContextPrompt(for agent: AgentRecord, projectName: String?) -> String {
        guard let planStore = MaestroTools.planStore else { return "" }

        var plans: [(scope: String, plan: Plan)] = []
        var seenIDs = Set<UUID>()

        // 1. Personal plans for this agent.
        let personalScope = PlanScope.agent(agent.id)
        for plan in planStore.plans(in: personalScope) {
            plans.append(("personal", plan))
            seenIDs.insert(plan.id)
        }

        // 2. Project-scoped plans for the agent's project.
        if let projectName = projectName, !projectName.isEmpty {
            let projectScope = PlanScope.project(projectName)
            for plan in planStore.plans(in: projectScope) {
                guard !seenIDs.contains(plan.id) else { continue }
                plans.append(("project \"\(projectName)\"", plan))
                seenIDs.insert(plan.id)
            }
        }

        // 3. For Maestro, expose all project plans so delegation requests
        //    like "continue the Spotlight plan" can be routed with full context.
        if agent.kind == .navigator, let workspace = MaestroTools.workspace {
            for project in workspace.visibleProjects {
                let projectScope = PlanScope.project(project.name)
                for plan in planStore.plans(in: projectScope) {
                    guard !seenIDs.contains(plan.id) else { continue }
                    plans.append(("project \"\(project.name)\"", plan))
                    seenIDs.insert(plan.id)
                }
            }
        }

        guard !plans.isEmpty else { return "" }

        var lines: [String] = [
            "═══ EXISTING PLANS — USE THESE WHEN THE USER MENTIONS A PLAN ═══"
        ]
        for (scope, plan) in plans {
            lines.append("")
            lines.append("# \(plan.title) [\(scope)]")
            lines.append(plan.content)
        }
        lines.append("")
        lines.append(
            "When the user asks you to continue, resume, or work on a plan, "
            + "use the plan content above as context. If the plan references "
            + "files, read them to verify the current state before continuing."
        )
        return lines.joined(separator: "\n")
    }

    /// Build a prompt section by reading AGENTS.md files discovered in parent
    /// directories of the working directory. Closer AGENTS.md files are listed
    /// first; all are advisory and supplement the system prompt. The root-level
    /// AGENTS.md is already loaded by ProjectRuleService, so this method only
    /// walks upward to capture repo/org-wide conventions.
    static func parentAgentsMdPrompt(forWorkingDirectory wd: String) -> String {
        let fileManager = FileManager.default
        var current = URL(fileURLWithPath: wd).deletingLastPathComponent()
        var files: [URL] = []
        while current.path != "/" {
            let candidate = current.appendingPathComponent("AGENTS.md")
            if fileManager.fileExists(atPath: candidate.path) {
                files.append(candidate)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        guard !files.isEmpty else { return "" }
        var sections: [String] = []
        for file in files {
            if let data = fileManager.contents(atPath: file.path),
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                sections.append("AGENTS.md — \(file.path)\n\n\(text)")
            }
        }
        guard !sections.isEmpty else { return "" }
        return "═══ PROJECT CONTEXT FROM AGENTS.md ═══\n\n"
            + sections.joined(separator: "\n\n")
            + "\n\nThese instructions apply in addition to the rules above."
    }

    /// Build the agent's tool schema list from the CURRENT workspace state.
    /// Extracted so the executor can re-derive the list every round —
    /// panel-linked categories (Auto tool mode) follow the live panel set.
    static func buildToolSpecs(
        agentID: UUID, isNavigator: Bool, isLiteModel: Bool, mcp: MCPClientService?
    ) async -> [ToolSpec] {
        let (enabledCategories, compactMode) = await MainActor.run {
            (MaestroTools.workspace?.effectiveToolCategories(for: agentID),
             MaestroTools.workspace?.compactToolMode(for: agentID) ?? false)
        }
        // Gate Apple app tools by the launcher toggles: disabled apps
        // lose their agent tools, not just their launcher rows.
        let blockedByLauncher = await MainActor.run {
            AppEnablementStore.shared.blockedToolCategories()
        }
        let filteredCategories: Set<ToolCategory>? = {
            guard let enabledCategories else { return nil }
            return enabledCategories.subtracting(blockedByLauncher)
        }()
        // Set immediately before use (mirrors MaestroTools.inheritedRoots)
        // so search_tools/call_tool can see this agent's actual scope.
        await MainActor.run {
            MaestroTools.currentEnabledCategories = filteredCategories
            MaestroTools.currentIsNavigator = isNavigator
        }
        var specs = await MaestroTools.schemas(
            navigator: isNavigator, liteMode: isLiteModel,
            enabledCategories: filteredCategories, compactMode: compactMode)
        if let mcp {
            // Maestro gets NO MCP tools — it delegates everything.
            // Only project agents get MCP tools (read_note, list_dir, etc.).
            if !isNavigator {
                if let filteredCategories {
                    if filteredCategories.contains(ToolCategory.mcp) {
                        specs += await mcp.currentSchemas(forCategories: filteredCategories)
                    }
                } else {
                    specs += await mcp.currentSchemas()
                }
            }
        }
        return specs
    }

    private func messagesForInference(
        model: MaestroModel,
        modelDescription: String? = nil,
        engine: MLXInferenceEngine,
        summaryModel: MaestroModel?
    ) async -> (messages: [Message], compactionSummary: String?) {
        // Always regenerate the system prompt so prompt/rule changes (and tool
        // routing guidance) apply to existing chats without needing a clear.
        // The stored leading system message is display-only and is dropped here.
        let systemMessage = Self.systemMessage(
            for: agent, projectName: projectName, workingDirectory: workingDirectory,
            modelDescription: modelDescription, model: model, modelID: model.huggingFaceID,
            usesXMLTools: model.toolCallFormat == .xmlFunction || model.toolCallFormat == .gemma4)
        var inferenceSystemMessage = systemMessage
        if let attachedPlan {
            // Refresh from disk so the agent's mid-session plan edits are
            // reflected; fall back to the attach-time copy if the plan (or
            // its scope) was deleted while attached.
            let fresh = PlanStore.load(attachedPlan.scope).first { $0.id == attachedPlan.plan.id }
            let planForPrompt = fresh ?? attachedPlan.plan
            // PREPEND so the model sees the attached plan first — small local
            // models (Gemma 4 26B-A4B etc.) attend strongly to prompt head;
            // content appended after thousands of tokens of tool definitions
            // is effectively invisible.
            inferenceSystemMessage.content = Self.attachedPlanSection(
                planForPrompt, scope: attachedPlan.scope)
                + inferenceSystemMessage.content
            NSLog("[PLANATTACH] injecting '\(planForPrompt.title)' (\(planForPrompt.content.count) chars) at system-prompt head")
        }
        // Keep the visible/serialized system prompt in sync with the regenerated
        // inference prompt so the user sees the correct model-capacity guidance.
        // (The DISPLAY copy stays free of the attached-plan section — the chip
        // in the composer already shows it; the model-facing copy carries it.)
        if let first = messages.first, first.role == .system {
            messages[0] = systemMessage
        }
        var output: [Message] = [inferenceSystemMessage]
        for message in messages where message.role != .system {
            // Strip the display-only "🔧 called `name`" markers so the model can't
            // replay/imitate them and fabricate tool calls.
            guard message.role == .assistant else {
                output.append(message)
                continue
            }
            let cleaned = Self.stripToolMarkers(message.content)
            let final = Self.stripOldToolResults(cleaned)
            if final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if message.content.isEmpty { output.append(message) }
                continue
            }
            var copy = message
            copy.content = final
            output.append(copy)
        }
        if let last = output.last, last.role == .assistant, last.content.isEmpty {
            output.removeLast()
        }
        // Recency reinforcement for an attached plan: small models can blow past
        // a directive at the head of a 15K-token system prompt, so also tag the
        // outgoing user turn with a one-line pointer back to the plan. This
        // edits only the inference copy — the displayed message is untouched.
        if let attachedPlan,
           let lastUserIdx = output.lastIndex(where: { $0.role == .user }) {
            output[lastUserIdx].content =
                "[Active plan attached: \"\(attachedPlan.plan.title)\" — full content is in the system prompt; continue with it]\n\n"
                + output[lastUserIdx].content
        }
        // When the last user message has images and the model does NOT have
        // vision, inject a hint to use ocr_image. Vision models (like Gemma 4)
        // can see images directly and don't need the tool — injecting the hint
        // would cause double image injection.
        if !model.isVision,
           let lastIdx = output.indices.last,
           output[lastIdx].role == .user,
           let imgs = output[lastIdx].imageData, !imgs.isEmpty,
           !output[lastIdx].content.contains("ocr_image") {
            var copy = output[lastIdx]

            if visionProxyService.config.isEnabled {
                // Route the images through the vision proxy and describe them in
                // text so the non-vision model can still "see" them.
                var descriptions: [String] = []
                for (index, data) in imgs.enumerated() {
                    do {
                        if let caption = try await visionProxyService.caption(imageData: data) {
                            descriptions.append("[Image \(index + 1): \(caption)]")
                        }
                    } catch {
                        NSLog("[VISION PROXY] caption failed for image \(index + 1): \(error)")
                        descriptions.append("[Image \(index + 1): <vision proxy unavailable>]")
                    }
                }
                if !descriptions.isEmpty {
                    copy.content = descriptions.joined(separator: "\n") + "\n" + copy.content
                }
                // The non-vision model cannot consume raw pixels; strip the image
                // data so the backend only receives text.
                copy.imageData = nil
                copy.imagePaths = nil
            } else {
                // Fallback to the OCR-path hint when the proxy is disabled.
                let paths = copy.imagePaths ?? []
                let pathList = paths.isEmpty ? "the attached image" :
                    paths.map { "`\($0)`" }.joined(separator: ", ")
                copy.content = "[The user attached \(imgs.count) image(s): \(pathList). Use the ocr_image tool with the image path to extract text from it.]\n" + copy.content
                // Keep the original image data so the ocr_image tool can read the
                // path later; the LLM backend still ignores it.
            }
            output[lastIdx] = copy
        }

        // Compact older history if the regenerated context is approaching the
        // model's context window. The checkpoint is a synthetic user message;
        // the visible chat history is left intact. The summary is autosaved
        // to the shared AI-Context memory.
        var compactionSummary: String?
        let nonSystemOutput = Array(output.dropFirst())
        let totalTokens = ChatCompaction.estimateTokens(
            for: nonSystemOutput.map { ChatCompaction.serialize($0) })
        let budgetExceeded = totalTokens > model.effectiveCompactionThreshold
        let hasNewActivitySinceCompaction = nonSystemOutput.count != lastCompactionMessageCount
        // Re-compact at most once per minute even when budget is exceeded, and
        // only when the message count actually changed (no new activity = skip).
        let canAutoCompact: Bool = {
            guard budgetExceeded else { return false }
            guard hasNewActivitySinceCompaction else { return false }
            if let last = lastCompactionTime {
                return Date().timeIntervalSince(last) >= 60
            }
            return true
        }()
        if canAutoCompact {
            currentActivity = "Compacting chat history…"
            if let compacted = await ChatCompaction.compactIfNeeded(
                messages: nonSystemOutput,
                model: model,
                engine: engine,
                contextLength: model.tunedContextLength,
                outputTokens: model.tunedMaxTokens,
                agentID: agent.id.uuidString,
                agentName: agent.name,
                summaryModel: summaryModel) {
                output = [inferenceSystemMessage, compacted.checkpoint] + compacted.recentMessages
                compactionSummary = compacted.summary
                lastCompactionMessageCount = nonSystemOutput.count
                lastCompactionTime = Date()
            }
            currentActivity = nil
        }

        return (output, compactionSummary)
    }

    /// Choose a small, verified local model to summarize history for compaction.
    /// Falls back to the active model if nothing faster is available.
    private static func pickSummaryModel(
        active model: MaestroModel, catalog: ModelCatalog
    ) -> MaestroModel? {
        // If the active model is already small, just use it.
        if model.estimatedMemoryGB <= 16 { return nil }
        let preferredIDs = [
            "local-qwen3.6-35b-a3b",   // 20 GB MoE — fast compaction
            "local-gemma4-26b",        // 26 GB — vision model doubles as summarizer
        ]
        if let fast = preferredIDs.lazy.compactMap({ catalog.model(forID: $0) })
            .first(where: { $0.supportsTools && !$0.isRemote }) {
            return fast
        }
        return catalog.models
            .filter { $0.supportsTools && !$0.isRemote && $0.estimatedMemoryGB <= 16 }
            .min(by: { $0.estimatedMemoryGB < $1.estimatedMemoryGB })
    }

    /// Detect a manual compaction request (e.g. "can you compact this chat?").
    private static func isCompactionCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = [
            "compact this chat", "compact the chat", "compact chat",
            "compact conversation", "compact this conversation", "compact history",
            "/compact",
        ]
        return commands.contains { lower.contains($0) }
    }

    /// SELF-HEALING: Triggered by the inference engine when system memory is
    /// critically low. Forces an immediate compaction regardless of the normal
    /// token-budget threshold, freeing KV cache memory before generation can
    /// overflow Metal's ~80GB single-buffer limit.
    private func handleMemoryPressureCompaction() {
        // Don't compact if already compacting, if the conversation is too short,
        // or if we don't have a reference to the engine.
        guard !isStreaming, messages.count > 10, let engine = lastEngine else { return }
        // Respect the one-compaction-per-minute guard.
        if let last = lastCompactionTime, Date().timeIntervalSince(last) < 60 { return }

        let catalog = ModelCatalog()
        guard let model = catalog.effectiveModel(for: agent) else { return }
        guard !model.isRemote else { return }

        NSLog("[ChatViewModel] memory pressure compaction triggered for model=%@", model.id)
        currentActivity = "Compacting history to free memory…"
        generateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let summaryModel = Self.pickSummaryModel(active: model, catalog: catalog)
            let nonSystemMessages = self.messages.filter { $0.role != .system }
            if let compacted = await ChatCompaction.compactIfNeeded(
                messages: nonSystemMessages,
                model: model,
                engine: engine,
                contextLength: model.tunedContextLength,
                outputTokens: model.tunedMaxTokens,
                agentID: self.agent.id.uuidString,
                agentName: self.agent.name,
                summaryModel: summaryModel) {
                let systemMsg = self.messages.first { $0.role == .system }
                var newMessages: [Message] = []
                if let systemMsg { newMessages.append(systemMsg) }
                newMessages.append(compacted.checkpoint)
                newMessages.append(contentsOf: compacted.recentMessages)
                self.messages = newMessages
                self.lastCompactionMessageCount = nonSystemMessages.count
                self.lastCompactionTime = Date()
                NSLog("[ChatViewModel] memory pressure compaction complete: freed %d messages", nonSystemMessages.count - compacted.recentMessages.count)
                // Reset the progress ring — compaction freed context.
                self.updateContextProgress()
            }
            self.currentActivity = nil
        }
    }

    /// Handle a manual compaction request by summarizing the head and saving the
    /// checkpoint to AI-Context memory. The visible chat history is left intact.
    private func handleManualCompaction(
        engine: MLXInferenceEngine, catalog: ModelCatalog, model: MaestroModel
    ) async {
        let summaryModel = Self.pickSummaryModel(active: model, catalog: catalog)
        currentActivity = "Compacting chat history…"
        let nonSystemMessages = messages.filter { $0.role != .system }
        let compacted = await ChatCompaction.compactIfNeeded(
            messages: nonSystemMessages,
            model: model,
            engine: engine,
            contextLength: model.tunedContextLength,
            outputTokens: model.tunedMaxTokens,
            agentID: agent.id.uuidString,
            agentName: agent.name,
            summaryModel: summaryModel,
            force: true)
        currentActivity = nil

        // Replace the empty assistant placeholder with a confirmation or error.
        if let last = messages.last, last.role == .assistant {
            messages.removeLast()
        }
        if let compacted {
            let summaryText = compacted.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = summaryText.isEmpty
                ? "Chat history compacted. Older turns are summarized into the inference context and saved to AI-Context memory."
                : "Context compacted. Older conversation summarized and saved to AI-Context memory.\n\n" + summaryText
            messages.append(Message(
                role: .assistant,
                content: body,
                isCompaction: true,
                timestamp: Date()))
        } else {
            messages.append(Message(
                role: .assistant,
                content: "I couldn't compact the chat history (the conversation may be too short to summarize, or no local summary model is available).",
                timestamp: Date()))
        }
        saveHistory()
        isStreaming = false
    }

    private static func stripToolMarkers(_ content: String) -> String {
        // Strip both "🔧 called" display markers AND raw XML tool call text
        // that the model emits when the parser didn't consume it (e.g. the
        // model puts tool_call XML in the content instead of as a separate
        // tool-call event). This keeps the chat clean while the actual tool
        // still gets executed by the parser.
        var result = content
        // Remove <tool_call>...</tool_call> blocks (may span multiple lines)
        let xmlPattern = "(?s)<tool_call>.*?</tool_call>"
        result = result.replacingOccurrences(of: xmlPattern, with: "",
            options: .regularExpression)
        // Remove single-line "🔧 called" markers
        result = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("🔧 called") }
            .joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip old tool-result content from assistant messages to prevent the model
    /// from seeing past tool outputs and fabricating them as new. Keeps only the
    /// final user-facing answer if it looks like a tool-result dump.
    private static func stripOldToolResults(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Substring] = []
        for line in lines {
            let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
            // Skip lines that look like tool-result summaries
            if lower.hasPrefix("done!") || lower.hasPrefix("here are the results")
                || lower.contains("completed:") || lower.contains("all three tasks")
                || lower.contains("all four") || lower.contains("both operations") {
                continue
            }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Update the context usage progress (0.0–1.0) based on current messages
    /// and the active model's compaction threshold. Called after messages change
    /// and after compaction completes.
    func updateContextProgress() {
        let catalog = ModelCatalog()
        guard let model = catalog.effectiveModel(for: agent) else {
            contextProgress = 0.0
            return
        }
        let nonSystemMessages = messages.filter { $0.role != .system }
        let totalTokens = ChatCompaction.estimateTokens(
            for: nonSystemMessages.map { ChatCompaction.serialize($0) })
        let threshold = model.effectiveCompactionThreshold
        guard threshold > 0 else {
            contextProgress = 0.0
            return
        }
        contextProgress = min(1.0, Double(totalTokens) / Double(threshold))
    }
}
