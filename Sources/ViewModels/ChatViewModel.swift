import Foundation
import MLXLMCommon
import SwiftMaestroKit

/// Drives one agent's chat. The Navigator is the top-level conductor; project
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
    @Published var pendingImagePaths: [String] = []
    /// Live, compact "what the agent is doing right now" line shown while
    /// streaming (e.g. "Running read_notes…"). Cleared when the turn ends.
    @Published var currentActivity: String?
    /// The agent's base directory. Injected into the system prompt and used as
    /// the default cwd for shell commands so the model resolves paths reliably.
    /// Persisted per agent in UserDefaults.
    @Published var workingDirectory: String?

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
        if let saved = ChatHistoryStore.load(agentId: agent.id), !saved.isEmpty {
            self.messages = saved
        } else {
            self.messages = [Self.systemMessage(
                for: agent, projectName: projectName, workingDirectory: wd)]
        }
    }

    private static func workingDirKey(_ id: UUID) -> String { "workingDir.\(id.uuidString)" }

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
    /// in-process via mlx-swift-lm; remote models (LM Studio) use HTTP.
    static func makeBackend(
        for model: MaestroModel, engine: MLXInferenceEngine, sessionKey: String
    ) -> GenerationBackend {
        if let remoteURL = model.remoteBaseURL {
            let config = LMStudioConfig(baseURL: remoteURL)
            return RemoteLMStudioBackend(config: config, model: model)
        }
        return InProcessMLXBackend(engine: engine, model: model, sessionKey: sessionKey)
    }

    func send(engine: MLXInferenceEngine, catalog: ModelCatalog, model: MaestroModel?) {
        guard !isStreaming else { return }
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
        isStreaming = true

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
            let modelDesc = "\(model.displayName) (model id \(model.huggingFaceID)), "
                + "served via in-process Apple MLX"
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

            let defaults = UserDefaults.standard
            let thinking = model.tunedThinkingEnabled
            // Per-model sampling: this model's own override (Settings → Tuning)
            // or its recommended values — never one global value across models.
            let temperature = model.tunedTemperature
            let topP = model.tunedTopP
            let maxTokens = model.tunedMaxTokens

        // Tool surface: project agents get the normal tools; the Navigator
        // additionally gets the workspace/delegation tools. Per-agent enabled
        // tool categories override the old automatic lite-mode reduction.
        var toolSpecs: [ToolSpec] = []
        if model.advertisesTools {
            let enabledCategories = MaestroTools.workspace?.enabledToolCategories(for: agent.id)
            let compactMode = MaestroTools.workspace?.compactToolMode(for: agent.id) ?? false
            // Set immediately before use (mirrors MaestroTools.inheritedRoots)
            // so search_tools/call_tool can see this agent's actual scope.
            MaestroTools.currentEnabledCategories = enabledCategories
            MaestroTools.currentIsNavigator = isNavigator
            toolSpecs = await MaestroTools.schemas(
                navigator: isNavigator, liteMode: model.isLiteModel,
                enabledCategories: enabledCategories, compactMode: compactMode)
            if let mcp = engine.mcpService {
                // Navigator gets NO MCP tools — it delegates everything.
                // Only project agents get MCP tools (read_note, list_dir, etc.).
                if !isNavigator {
                    let mcpSchemas = await mcp.currentSchemas()
                    if let enabledCategories {
                        let mcpCategory = ToolCategory.mcp
                        if enabledCategories.contains(mcpCategory) {
                            toolSpecs += mcpSchemas
                        }
                    } else {
                        toolSpecs += mcpSchemas
                    }
                }
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
                        m.localPath != nil
                            && !m.isLiteModel && m.advertisesTools
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

                let stream = executor.run(
                    messages: requestMessages, toolSpecs: toolSpecs, mcp: engine.mcpService,
                    engine: engine, catalog: catalog,
                    temperature: effectiveTemp, topP: topP, thinkingEnabled: thinking,
                    project: project, workingDirectory: workingDir, agentID: agentID,
                    maxTokens: maxTokens,
                    steerInbox: inbox)
                for try await output in stream {
                    guard !Task.isCancelled else { break }
                    switch output {
                    case .token(let token): consumeStreamChunk(token)
                    case .toolCall(let name): recordToolStep(name)
                    case .info(let tps): engine.reportExternalTokensPerSecond(tps)
                    case .turnBreak: beginSteeredTurn()
                    case .delegateStart(let agentID, let modelID):
                        let displayName = catalog.models.first { $0.huggingFaceID == modelID }?.displayName ?? modelID
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
                } else {
                    NSLog("[BACKEND] in-process generation FAILED for \(model.huggingFaceID): \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
            }
            finishStreamParsing()
            isStreaming = false
            currentActivity = nil
            steerInbox = nil
            saveHistory()
        }
    }

    /// Mid-generation steering: while a run is streaming, show `text` as a normal
    /// user message AND queue it for the executor to fold into the NEXT round,
    /// instead of cancelling. No-ops when not streaming (use `send` then).
    func steer(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isStreaming, !trimmed.isEmpty, let inbox = steerInbox else { return }
        inputText = ""
        messages.append(Message(role: .user, content: trimmed, timestamp: Date()))
        Task { await inbox.append(trimmed) }
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
        for (pi, pattern) in patterns.enumerated() {
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
        // Reasoning mode: close on either Qwen or Gemma 4 end-of-thinking markers.
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
        // No close tag yet: flush all but a tail that might hold a partial tag.
        let keep = max(Self.qwenCloseTag.count, Self.gemmaCloseTag.count) - 1
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
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            let narration = ThinkingTagStripper.strip(messages[idx].content)
            if !narration.isEmpty {
                let sep = (messages[idx].reasoning?.isEmpty == false) ? "\n" : ""
                messages[idx].reasoning = (messages[idx].reasoning ?? "") + sep + narration
                messages[idx].content = ""
            }
        }
        inReasoning = true
    }

    /// Flush the tail at end of stream. If no `</think>`/`</channel>` ever arrived
    /// (a model that doesn't emit thinking tags), treat the accumulated reasoning
    /// as the answer after stripping any residual markers.
    private func finishStreamParsing() {
        if !streamBuffer.isEmpty {
            let stripped = ThinkingTagStripper.strip(streamBuffer)
            if inReasoning { appendReasoning(stripped) } else { appendAnswer(stripped) }
            streamBuffer = ""
        }
        // Discard any in-progress tool call XML suppression — the model
        // produced a partial `<tool_call>` block that never got closed.
        if suppressingToolCall {
            suppressingToolCall = false
        }
        guard !sawReasoningClose,
              let idx = messages.lastIndex(where: { $0.role == .assistant }),
              messages[idx].content.isEmpty,
              let reasoning = messages[idx].reasoning, !reasoning.isEmpty else { return }
        messages[idx].content = ThinkingTagStripper.strip(reasoning)
        messages[idx].reasoning = nil
        messages[idx].reasoningSeconds = nil
    }

    /// Record a tool invocation as compact activity on the in-flight assistant
    /// message (rendered as a collapsed disclosure) and update the live status
    /// line — instead of dumping a marker into the chat transcript. A tool call
    /// also marks a round boundary, so fold this round's post-`</think>`
    /// narration into `reasoning` first.
    private func recordToolStep(_ name: String) {
        foldNarrationIntoReasoning()
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            var steps = messages[idx].toolSteps ?? []
            steps.append(name)
            messages[idx].toolSteps = steps
        }
        currentActivity = "Running \(name)…"
    }

    private func saveHistory() {
        ChatHistoryStore.save(messages, agentId: agent.id)
    }

    /// Called by ChatViewModelCache to persist messages after delegation.
    func persistHistory() {
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
        messages = [Self.systemMessage(for: agent, projectName: projectName)]
        isStreaming = false
        lastCompactionMessageCount = 0
        lastCompactionTime = nil
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
        NSLog("[STREAM] streamToDelegate agentID=\(agentID) token=\(token.prefix(30)) cache=\(cache != nil ? "exists" : "NIL")")
        if token == "[START]" {
            cache?.beginDelegation(forAgentID: UUID(uuidString: agentID) ?? UUID())
            return
        }
        if token == "[FINISH]" {
            cache?.finishDelegation(forAgentID: UUID(uuidString: agentID) ?? UUID())
            activeDelegateHandlers.removeValue(forKey: agentID)
            effectiveDelegateModelNames.removeValue(forKey: agentID)
            return
        }

        cache?.appendToken(token, toAgentID: UUID(uuidString: agentID) ?? UUID())
    }

    // MARK: - System prompt

    /// Hard rules governing tool use (anti-fabrication). Injected into every agent.
    private static let toolDiscipline = """
        TOOL USE — STRICT RULES:
        - Tools are REAL and execute on the user's system. NEVER simulate tool calls \
        as text or code blocks.
        - When the user asks you to run a command, execute it IMMEDIATELY with \
        execute_command. Do NOT show code blocks for manual execution.
        - NEVER invent, guess, or pre-write tool results. Only report what a tool \
        ACTUALLY returned after calling it.
        - BATCH file reads: call read_file on all needed files in one turn.
        - If a tool returns empty or errors, say so IMMEDIATELY. Do NOT fabricate \
        fake results, file paths, or data.
        - NEVER claim you wrote, saved, or created a file unless write_file returned \
        success. NEVER claim you read a file unless read_file returned content.
        - STOP GATHERING after 2 tool rounds. Start writing your answer NOW.
        - Do NOT narrate future tool calls ("Let me read..."). Just call the tool.
        - read_file handles ANY file type including .docx, .pdf, images, binary.
        - For large documents, use index_document/search_chunks/read_chunk.
        - Send images via ocr_image (not list_dir).
        - For creating or overwriting files, use write_file. NEVER paste the file contents \
        in chat as a code block — the tool writes the file; the chat is only for reasoning.
        - MAX 5 tool calls per message. If you need more, tell the user what you'd do next.

        CRITICAL HONESTY RULES:
        - If you lack a tool for a task, say "I don't have a tool for that" NOW.
        - If a tool errors, report it: "Tool X failed: [error]". Do NOT retry silently.
        - If results are empty, say "No results found". Do NOT invent fake data.
        - After 2 FAILED attempts on the same task, STOP and report what went wrong.
        - NEVER fill silence with "Let me think..." — either call a tool or say you can't.

        AUTO-SAVE:
        - After every 5 file reads, call write_file to save progress to disk.

        DIRECTORY INDEXING:
        - For directory exploration, use index_directory (recursive, Spotlight metadata). \
        Only use list_dir for single-directory-level checks.
        """

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
    /// calls (e.g. Qwen 3 Coder). Reinforces the schema so small models don't emit
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
        (address the conductor as agent "Navigator") and read your own inbox with \
        read_agent_messages. Use these to hand off context or coordinate work.
        - To send a message you MUST call send_agent_message. NEVER say a message \
        was sent unless you actually called the tool and got a result back.

        CALENDAR:
        - Before creating a calendar event, ALWAYS call get_current_time first to \
        get the current date and timezone. This ensures you can correctly resolve \
        relative dates like "tomorrow", "next Tuesday", or "in 2 hours" to absolute \
        ISO-8601 timestamps.
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
        """

    static func systemMessage(
        for agent: AgentRecord, projectName: String?, workingDirectory: String? = nil,
        modelDescription: String? = nil, usesXMLTools: Bool = false
    ) -> Message {
        let base: String
        if agent.kind == .navigator {
            // Inject live workspace state so the Navigator knows exact project/agent names.
            var workspaceList = "No projects or agents exist yet."
            if let ws = MaestroTools.workspace, !ws.projects.isEmpty {
                var lines: [String] = []
                for proj in ws.projects {
                    let agentNames = ws.agents
                        .filter { $0.kind == .project && $0.projectId == proj.id }
                        .map { $0.name }
                    lines.append("- Project: \"\(proj.name)\" — Agents: \(agentNames.joined(separator: ", "))")
                }
                workspaceList = lines.joined(separator: "\n")
            }
            base = """
                You are the Navigator, the conductor for SwiftMaestro. You handle general \
                chat and coordinate project work. You delegate to project agents and \
                synthesize their results for the user.

                ═══ EXISTING PROJECT AGENTS (USE THESE — DO NOT CREATE DUPLICATES) ═══
                \(workspaceList)

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
                - execute_command: Your terminal. Run ANY shell command immediately. \
                For long-running processes, use start_background: true.
                - start_server: Built-in HTTP server. start_server(path:, port:). \
                stop_server(port:) to shut down.
                - list_dir, read_file: Quick file discovery (delegate bulk work).
                - list_workspace: See all projects and agents if unsure.

                LANGUAGE RULE: Respond in English only. All tool arguments in English.

                CONTEXT COMPACTION:
                The chat history is automatically compacted when it approaches the model's \
                context limit. Older turns are summarized into a checkpoint that is injected \
                into the inference context. You do not need to compact or delete history yourself.
                """
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
                4. Stop gathering after 2 tool rounds; then write/summarize the answer.

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
                """
        }
        var content = base + "\n\n" + Self.toolDiscipline
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
        return Message(role: .system, content: content)
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
            modelDescription: modelDescription,
            usesXMLTools: model.toolCallFormat == .xmlFunction)
        var output: [Message] = [systemMessage]
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
        let budgetExceeded = totalTokens > model.tunedContextLength - max(model.tunedMaxTokens, 20_000)
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
                output = [systemMessage, compacted.checkpoint] + compacted.recentMessages
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
            "local-deepseek-r1-8b",
            "local-qwen3.5-27b",
            "local-qwen3-coder-30b-a3b",
            "local-qwen3.6-35b-a3b",
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
}
