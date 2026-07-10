import Foundation
import MLXLMCommon

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

    init(agent: AgentRecord, projectName: String?) {
        self.agent = agent
        self.projectName = projectName
        let wd = UserDefaults.standard.string(forKey: Self.workingDirKey(agent.id))
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

        inputText = ""
        pendingImages = []
        pendingImagePaths = []
        errorMessage = nil
        let userText = prompt.isEmpty ? " " : prompt
        messages.append(Message(
            role: .user, content: userText, imageData: images.isEmpty ? nil : images,
            imagePaths: allPaths.isEmpty ? nil : allPaths))
        messages.append(Message(role: .assistant, content: ""))
        isStreaming = true
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
            let requestMessages = messagesForInference(
                modelDescription: modelDesc, isVisionModel: model.isVision)
            let defaults = UserDefaults.standard
            let thinking = model.tunedThinkingEnabled
            // Per-model sampling: this model's own override (Settings → Tuning)
            // or its recommended values — never one global value across models.
            let temperature = model.tunedTemperature
            let topP = model.tunedTopP
            let maxTokens = model.tunedMaxTokens

            // Tool surface: project agents get the normal tools; the Navigator
            // additionally gets the workspace/delegation tools. Lite mode
            // (small MoE models with <10B active params) gets a reduced set.
            var toolSpecs: [ToolSpec] = []
            if model.advertisesTools {
                toolSpecs = MaestroTools.schemas(
                    navigator: isNavigator, liteMode: model.isLiteModel)
                if let mcp = engine.mcpService {
                    // Navigator gets NO MCP tools — it delegates everything.
                    // Only project agents get MCP tools (read_note, list_dir, etc.).
                    if !isNavigator {
                        toolSpecs += await mcp.currentSchemas()
                    }
                }
            }
            // Low temperature when tools are active keeps function-calling faithful.
            let effectiveTemp = toolSpecs.isEmpty ? temperature : min(temperature, 0.3)

            // Delegated sub-agents resolve their OWN model/backend via this
            // resolver (per-agent models; local or remote depending on model).
            let delegateResolver: DelegateBackendResolver = { agentID in
                await MainActor.run { () -> (backend: GenerationBackend, modelID: String)? in
                    guard let agent = MaestroTools.workspace?.agent(id: agentID),
                          let m = catalog.effectiveModel(for: agent) else { return nil }
                    let backend = ChatViewModel.makeBackend(
                        for: m, engine: engine, sessionKey: agentID.uuidString)
                    return (backend, m.huggingFaceID)
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
                    case .delegateStart(let agentID):
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
        messages.append(Message(role: .user, content: trimmed))
        Task { await inbox.append(trimmed) }
    }

    /// The executor injected a steer at a round boundary (`.turnBreak`): finalize
    /// the current assistant bubble and open a fresh one for the steered
    /// continuation, re-arming the reasoning split so the next round's `<think>`
    /// block is captured instead of leaking into the answer.
    private func beginSteeredTurn() {
        finishStreamParsing()
        messages.append(Message(role: .assistant, content: ""))
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

    private static let closeTag = "</think>"
    private static let toolCallOpen = "<tool_call>"
    private static let toolCallClose = "</tool_call>"
    /// Route one streamed chunk into reasoning (while `inReasoning`) or the answer
    /// (after the close tag), buffering a small tail to catch a split tag.
    private func consumeStreamChunk(_ token: String) {
        streamBuffer += token
        guard inReasoning else {
            // Answer mode: suppress `<tool_call>` XML that the model streams
            // as text tokens alongside the `.toolCall` event (small MoE models
            // like Qwen 3.6 35B-A3B often emit raw XML).
            if suppressingToolCall {
                if let r = streamBuffer.range(of: Self.toolCallClose) {
                    suppressingToolCall = false
                    let after = String(streamBuffer[r.upperBound...])
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
                let before = String(streamBuffer[..<r.lowerBound])
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
                appendAnswer(String(streamBuffer[..<split]))
                streamBuffer = String(streamBuffer[split...])
            }
            return
        }
        if let r = streamBuffer.range(of: Self.closeTag) {
            appendReasoning(String(streamBuffer[..<r.lowerBound]))
            markReasoningClosed()
            let after = String(streamBuffer[r.upperBound...])
            streamBuffer = ""
            inReasoning = false
            if !after.isEmpty { appendAnswer(after) }
            return
        }
        // No close tag yet: flush all but a tail that might hold a partial tag.
        let keep = Self.closeTag.count - 1
        if streamBuffer.count > keep {
            let split = streamBuffer.index(streamBuffer.endIndex, offsetBy: -keep)
            appendReasoning(String(streamBuffer[..<split]))
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
            if inReasoning { appendReasoning(streamBuffer) } else { appendAnswer(streamBuffer) }
            streamBuffer = ""
        }
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            let narration = messages[idx].content
            if !narration.isEmpty {
                let sep = (messages[idx].reasoning?.isEmpty == false) ? "\n" : ""
                messages[idx].reasoning = (messages[idx].reasoning ?? "") + sep + narration
                messages[idx].content = ""
            }
        }
        inReasoning = true
    }

    /// Flush the tail at end of stream. If no `</think>` ever arrived (a model that
    /// doesn't emit think tags), treat the accumulated reasoning as the answer.
    private func finishStreamParsing() {
        if !streamBuffer.isEmpty {
            if inReasoning { appendReasoning(streamBuffer) } else { appendAnswer(streamBuffer) }
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
        messages[idx].content = reasoning
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
    }

    // MARK: - Delegate streaming

    /// In-memory store of active delegate stream handlers, keyed by agent ID.
    /// When a delegation starts, a handler is registered here so tokens can be
    /// streamed to the target agent's chat in real-time.
    nonisolated(unsafe) static var activeDelegateHandlers: [String: DelegateStreamHandler] = [:]

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
            return
        }

        cache?.appendToken(token, toAgentID: UUID(uuidString: agentID) ?? UUID())
    }

    // MARK: - System prompt

    /// Hard rules governing tool use (anti-fabrication). Injected into every agent.
    private static let toolDiscipline = """
        TOOL USE — STRICT RULES:
        - Your tools are REAL and execute on the user's actual system. Use them by \
        making a real tool call. NEVER write a tool call, shell command, JSON, or a \
        tool's output as plain text or inside a code block to simulate it.
        - When a request can be answered by a tool you have, CALL IT rather than \
        declining or telling the user to do it themselves.
        - NEVER invent, guess, paraphrase, or pre-write tool results. Only state what \
        a tool ACTUALLY returned to you after you called it.
        - When you need to read multiple files, BATCH them: call read_file on all \
        needed files in a single turn. The results come back together so you can \
        work faster. Do NOT read files one at a time in sequence.
        - Make ONE tool call at a time for UNRELATED tasks, but batch related reads \
        (e.g. reading several source files to understand a project). Do not narrate \
        a sequence of imaginary calls.
        - If a tool returns empty or no output, say exactly that — do not fabricate a \
        plausible-looking result (e.g. fake file listings, paths, or timestamps).
        - If you cannot or did not call a tool, say so plainly. Never claim an action \
        happened unless a real tool result confirms it.
        - NEVER claim you saved, wrote, or created a file unless you actually called \
        write_file and got a success response. Running create_todo_list, create_plan, \
        or any other tool does NOT write files — only write_file writes files.
        - NEVER claim you read a file unless you actually called read_file and got \
        its content back.
        - STOP GATHERING after 2 tool rounds. You have enough context. Start writing \
        your answer or output NOW. Do NOT do read → list → read → list → read loops. \
        Work with what you have. The user is waiting.
        - NEVER narrate future tool calls. Do NOT say "Let me read...", "Now I'll \
        list...", "I'll check..." — just CALL the tool. Narration without action \
        wastes a full round and frustrates the user. If you need a file, call \
        read_file NOW. If you need a directory, call list_dir NOW. No preamble.
        - If you have already read files and listed directories, you have enough. \
        STOP calling tools and WRITE YOUR RESPONSE. One more tool call is NOT \
        the answer — outputting text IS.
        - read_file handles ANY file type: text files, documents (.docx, .pdf, \
        .rtf, .odt, .pages, .html), images, and binary files. Documents are \
        extracted to text; binary files return base64 with MIME type.
        - write_file writes UTF-8 text by default. To write a binary file, set \
        encoding='base64' and pass base64-encoded content.
        - For large documents that exceed the context window, use index_document \
        to split files into exact-text chunks, search_chunks to find relevant \
        chunks with loose keyword/fuzzy matching, and read_chunk to retrieve the \
        verbatim original text. NEVER summarize when the user wants exact quotes.
        - When the user sends an image or image path, call ocr_image with the \
        absolute path. Do NOT call list_dir on an image — that lists the parent \
        directory. ocr_image sends the image to the vision model for text extraction.

        CRITICAL HONESTY RULES — VIOLATION IS A HARD FAILURE:
        - If you DO NOT HAVE a tool for a task (e.g. no SQL tool, no search tool, \
        no browser tool), say "I don't have a tool for that" IMMEDIATELY. Do NOT \
        wait, do NOT fill time with narration, do NOT pretend to be working. The \
        user is watching your output in real time — silence and stalling waste their \
        time.
        - If a tool returns an ERROR, report the error IMMEDIATELY. Do NOT retry \
        silently, do NOT fabricate a success, do NOT pretend the error didn't happen. \
        Say: "Tool X failed: [error message]".
        - If a tool returns EMPTY results (no files found, no search hits, no rows), \
        say "No results found" IMMEDIATELY. Do NOT invent fake file paths, fake \
        search results, or fake data to fill the silence. Empty is a valid answer.
        - If a file path does not exist, say "File not found at [path]" IMMEDIATELY. \
        Do NOT guess what the file might contain. Do NOT make up directory listings \
        or file contents.
        - If you CANNOT complete a task because a tool is missing, a path is \
        unauthorized, or a dependency is unavailable, say so in ONE sentence and \
        suggest what the user can do. Do NOT loop, do NOT retry the same failing \
        call, do NOT fabricate a workaround.
        - NEVER pad your response with filler text like "Let me think about this..." \
        or "I'm working on it..." — if you're not actively calling a tool, you're \
        not working. Either call the tool NOW or say you can't.
        - After 2 FAILED tool attempts on the same task, STOP and report what went \
        wrong. Do NOT attempt a 3rd, 4th, or 5th variation. The user needs to know \
        the task is blocked, not watch you keep trying.
        - When searching (files, web, memory, vault), if the search completes with \
        zero results, the correct response is "No results found for [query]". Do NOT \
        fabricate results you think the user wanted to see. Do NOT make up file \
        names, document titles, or search snippets.
        - You have a MAXIMUM of 5 tool calls per user message. After 5, you MUST \
        stop and give your best answer with what you have. The user cannot wait \
        forever. If you need more, tell the user what you'd do next and ask them \
        to continue.

        AUTO-SAVE TRIGGER:
        - After every 5 file read operations (read_file, ocr_image, list_dir), \
        you MUST call write_file to save your accumulated progress to disk. \
        This is automatic and does not require user approval.
        - Save to your designated output path (provided in your task prompt). \
        Each save should include: timestamp, files processed so far, key findings, \
        and files remaining.
        - If you crash or are interrupted, your last save preserves your work. \
        This is critical for long-running analysis tasks.
        - Do NOT wait for the user to ask you to save. Save proactively.

        DIRECTORY INDEXING:
        - When the user shares a directory or asks you to explore one, ALWAYS start \
        with index_directory (NOT list_dir). It recursively scans the ENTIRE tree, \
        uses macOS Spotlight for rich metadata (file types, sizes, dates, dimensions), \
        and returns a structured summary. This is the FASTEST way to understand a \
        directory's contents.
        - index_directory is comprehensive by default — it returns ALL files and \
        subdirectories. Do NOT filter or skip entries you think are unimportant. \
        The user needs the COMPLETE picture.
        - After indexing, call save_index to persist the results to shared memory \
        so they're available in future sessions.
        - Only use list_dir for quick checks of a SINGLE directory level. For any \
        multi-level exploration, index_directory is the right tool.
        - When listing a directory (list_dir), report EVERY entry — do NOT filter, \
        prioritize, or skip files. The user asked to see the contents, not your \
        opinion of what's important.
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
        modelDescription: String? = nil
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
                chat and coordinate project work. You can create projects and long-lived \
                project agents (create_project_agent), list the workspace (list_workspace), \
                remove agents that are no longer needed (archive_project_agent), and \
                delegate a task to a project agent (ask_project_agent) then synthesize \
                their result for the user. To delegate to SEVERAL agents at once, use \
                ask_project_agents with a 'requests' list of {project, agent, task}. \
                You can also perform basic file discovery (list_dir, read_file) to help \
                the user and investigate the workspace. Create a project agent when the \
                user wants ongoing work focused on a specific project. When creating agents, \
                use descriptive names that reflect their role (e.g. "Inspector", "Builder", "Scribe") — never \
                use placeholder names like "NewName" or "Agent1".

                CURRENT WORKSPACE:
                \(workspaceList)

                WHEN DELEGATING: Use the EXACT project and agent names listed above. \
                Do NOT invent or guess project/agent names. If you're unsure, call \
                list_workspace first.

                YOU HAVE the execute_command tool — this IS your terminal. Use it \
                to run ANY shell command (ls, cd, python, docker, cat, grep, etc.) \
                and show the user the results. NEVER say "I cannot open a terminal" \
                or "I don't have terminal access" — execute_command IS your terminal. \
                When showing deployment steps or multi-step shell scripts, execute \
                each step with execute_command and report the results. Only ask the \
                user to run something manually if it requires interactive input or sudo. \
                \
                For LONG-RUNNING processes (HTTP servers, watchers, daemons), use \
                start_background: true in execute_command. This spawns the process in \
                the background and returns a process ID. Use list_background_processes \
                to check status and stop_background_process to kill them. \
                \
                You also have start_server — a built-in HTTP server that serves local \
                files over HTTP. Use start_server to let the user browse HTML/JSON/images \
                in their browser. Example: start_server(path: "/path/to/site", port: 8080). \
                Use stop_server(port:) to shut it down, list_servers to see what's running. \
                \
                When the user asks you to do ANY work beyond coordination (read \
                files, analyse data, write reports, edit documents, search vault, \
                or any multi-step task), you MUST delegate to a project agent \
                using ask_project_agent.

                BATCHING RULE — MANDATORY: If a delegated task involves scanning, \
                reading, or analyzing more than a few files, a large folder, or a \
                database spread across many records, you MUST break it into small \
                batches and delegate each batch separately. Use create_todo_list or \
                add_todos to track batches. Examples: by month, by week, by sender, \
                by file type, or by directory subfolder. Never ask a sub-agent to \
                process an entire folder, database, or multi-file archive in a single \
                call. After each batch returns, save progress to disk with write_file \
                before starting the next batch.

                LANGUAGE RULE: You MUST respond in English only. Never use Vietnamese, \
                Thai, Chinese, Japanese, or any other language. All your thoughts, \
                tool arguments, and responses must be in English.
                """
        } else {
            let proj = projectName ?? "this project"
            base = """
                You are \(agent.name), a project agent for the project "\(proj)". Focus on \
                this project's work. Project: \(proj). Use the memory tools to recall and \
                store project knowledge — they are scoped to this project.

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
            + "\n\n" + Self.taskToolGuidance + "\n\n" + Self.appleBuildGuidance

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

    private func messagesForInference(modelDescription: String? = nil, isVisionModel: Bool = false) -> [Message] {
        // Always regenerate the system prompt so prompt/rule changes (and tool
        // routing guidance) apply to existing chats without needing a clear.
        // The stored leading system message is display-only and is dropped here.
        var output: [Message] = [Self.systemMessage(
            for: agent, projectName: projectName, workingDirectory: workingDirectory,
            modelDescription: modelDescription)]
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
        if !isVisionModel,
           let lastIdx = output.indices.last,
           output[lastIdx].role == .user,
           let imgs = output[lastIdx].imageData, !imgs.isEmpty,
           !output[lastIdx].content.contains("ocr_image") {
            var copy = output[lastIdx]
            let paths = copy.imagePaths ?? []
            let pathList = paths.isEmpty ? "the attached image" :
                paths.map { "`\($0)`" }.joined(separator: ", ")
            copy.content = "[The user attached \(imgs.count) image(s): \(pathList). Use the ocr_image tool with the image path to extract text from it.]\n" + copy.content
            output[lastIdx] = copy
        }
        return output
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
