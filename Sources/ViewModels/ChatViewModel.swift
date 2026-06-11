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

    /// MLX-first backend choice: in-process unless the model can't load
    /// in-process (e.g. the 122B) or the user forced oMLX globally.
    static func usesInProcess(_ model: MaestroModel) -> Bool {
        let forceOMLX = (UserDefaults.standard.string(forKey: "models.backend") ?? "inprocess") == "omlx"
        return model.supportsInProcess && !forceOMLX
    }

    /// Build the generation backend for a model per the MLX-first policy.
    static func makeBackend(
        for model: MaestroModel, engine: MLXInferenceEngine, endpoint: String, sessionKey: String
    ) -> GenerationBackend {
        usesInProcess(model)
            ? InProcessMLXBackend(engine: engine, model: model, sessionKey: sessionKey)
            : OMLXBackend(endpointURL: endpoint, modelID: model.huggingFaceID)
    }

    func send(engine: MLXInferenceEngine, catalog: ModelCatalog, model: MaestroModel?) {
        guard !isStreaming else { return }
        // Merge typed images with any local image paths found in the text
        // (e.g. a pasted screenshot path), stripping the path from the prompt.
        let (cleanedText, pathImages) = Self.extractImages(from: inputText)
        var images = pendingImages
        images.append(contentsOf: pathImages)
        let prompt = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !images.isEmpty else { return }
        guard let model else {
            errorMessage = "No model selected. Open Settings (⌘,) to configure."
            return
        }

        inputText = ""
        pendingImages = []
        errorMessage = nil
        let userText = prompt.isEmpty ? "Describe this image." : prompt
        messages.append(Message(
            role: .user, content: userText, imageData: images.isEmpty ? nil : images))
        messages.append(Message(role: .assistant, content: ""))
        isStreaming = true

        let isNavigator = agent.kind == .navigator
        let project = projectName
        let workingDir = workingDirectory
        let agentID = agent.id.uuidString

        generateTask = Task {
            // Tell the agent what it ACTUALLY runs on, so "which model are you?"
            // is answered truthfully instead of echoing the agent's name.
            let modelDesc = "\(model.displayName) (model id \(model.huggingFaceID)), served via "
                + (ChatViewModel.usesInProcess(model) ? "in-process Apple MLX" : "the local oMLX server")
            let requestMessages = messagesForInference(modelDescription: modelDesc)
            let defaults = UserDefaults.standard
            let endpoint = defaults.string(forKey: "models.endpointURL") ?? "http://localhost:8012"
            let thinking = (defaults.object(forKey: "tuning.enableThinking") as? Bool) ?? false
            let temperature = (defaults.object(forKey: "tuning.temperature") as? Double)
                ?? model.recTemperature ?? 1.0
            let topP = (defaults.object(forKey: "tuning.topP") as? Double)
                ?? model.recTopP ?? 0.95

            // Tool surface: project agents get the normal tools; the Navigator
            // additionally gets the workspace/delegation tools.
            var toolSpecs: [ToolSpec] = []
            if model.advertisesTools {
                toolSpecs = MaestroTools.schemas(navigator: isNavigator)
                if let mcp = engine.mcpService {
                    toolSpecs += await mcp.currentSchemas()
                }
            }
            // Low temperature when tools are active keeps function-calling faithful.
            let effectiveTemp = toolSpecs.isEmpty ? temperature : min(temperature, 0.3)

            // Backend selection (MLX-first): in-process unless the model can't
            // load in-process (e.g. the 122B) or the user forced oMLX globally.
            // Delegated sub-agents resolve their OWN model/backend via the
            // resolver below (per-agent models).
            let delegateResolver: DelegateBackendResolver = { agentID in
                await MainActor.run { () -> (backend: GenerationBackend, modelID: String)? in
                    guard let agent = MaestroTools.workspace?.agent(id: agentID),
                          let m = catalog.effectiveModel(for: agent) else { return nil }
                    let backend = ChatViewModel.makeBackend(
                        for: m, engine: engine, endpoint: endpoint, sessionKey: agentID.uuidString)
                    return (backend, m.huggingFaceID)
                }
            }
            let useInProcess = ChatViewModel.usesInProcess(model)
            let primaryBackend = ChatViewModel.makeBackend(
                for: model, engine: engine, endpoint: endpoint, sessionKey: agentID)
            // Fallback only switches to in-process for models that support it;
            // a !supportsInProcess model (e.g. 122B) never attempts in-process.
            let fallbackBackend: GenerationBackend? =
                useInProcess
                ? OMLXBackend(endpointURL: endpoint, modelID: model.huggingFaceID)
                : (model.supportsInProcess
                    ? InProcessMLXBackend(engine: engine, model: model, sessionKey: agentID)
                    : nil)

            do {
                let executor = OMLXAgentExecutor(
                    endpointURL: endpoint, modelID: model.huggingFaceID, backend: primaryBackend,
                    delegateBackendResolver: delegateResolver)
                let stream = executor.run(
                    messages: requestMessages, toolSpecs: toolSpecs, mcp: engine.mcpService,
                    temperature: effectiveTemp, topP: topP, thinkingEnabled: thinking,
                    project: project, workingDirectory: workingDir, agentID: agentID)
                for try await output in stream {
                    guard !Task.isCancelled else { break }
                    switch output {
                    case .token(let token): appendToAssistant(token)
                    case .toolCall(let name): recordToolStep(name)
                    case .info(let tps): engine.reportExternalTokensPerSecond(tps)
                    }
                }
            } catch {
                // A user cancel must NOT silently switch backends; stop cleanly
                // (the tail below resets streaming state).
                if Task.isCancelled || error is CancellationError {
                    NSLog("[BACKEND] primary (\(useInProcess ? "in-process" : "oMLX")) cancelled — no fallback")
                } else if let fallbackBackend {
                    NSLog("[BACKEND] primary (\(useInProcess ? "in-process" : "oMLX")) FAILED for \(model.huggingFaceID): \(error.localizedDescription) — falling back")
                    do {
                        let executor = OMLXAgentExecutor(
                            endpointURL: endpoint, modelID: model.huggingFaceID, backend: fallbackBackend,
                            delegateBackendResolver: delegateResolver)
                        let stream = executor.run(
                            messages: requestMessages, toolSpecs: toolSpecs, mcp: engine.mcpService,
                            temperature: effectiveTemp, topP: topP, thinkingEnabled: thinking,
                            project: project, workingDirectory: workingDir, agentID: agentID)
                        for try await output in stream {
                            guard !Task.isCancelled else { break }
                            switch output {
                            case .token(let token): appendToAssistant(token)
                            case .toolCall(let name): recordToolStep(name)
                            case .info(let tps): engine.reportExternalTokensPerSecond(tps)
                            }
                        }
                    } catch {
                        NSLog("[BACKEND] fallback also FAILED: \(error.localizedDescription)")
                        errorMessage = error.localizedDescription
                    }
                } else {
                    NSLog("[BACKEND] primary (oMLX) FAILED for \(model.huggingFaceID), no in-process fallback: \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
            }
            isStreaming = false
            currentActivity = nil
            saveHistory()
        }
    }

    // MARK: - Image attachment helpers

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic",
    ]

    /// Find local image-file paths inside the text (quoted paths with spaces, a
    /// bare absolute path, or the whole input being a path), load their bytes,
    /// and return the text with those paths removed.
    static func extractImages(from text: String) -> (text: String, images: [Data]) {
        var working = text
        var loaded: [Data] = []

        let patterns = [
            "'([^']+)'",
            "\"([^\"]+)\"",
            "(/[^\\s\"']+\\.(?i:png|jpg|jpeg|gif|bmp|tiff|webp|heic))",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = working as NSString
            let matches = regex.matches(in: working, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let captureRange = match.range(at: match.numberOfRanges - 1)
                guard captureRange.location != NSNotFound else { continue }
                let candidate = (working as NSString).substring(with: captureRange)
                if let data = imageData(atPath: candidate) {
                    loaded.append(data)
                    working = (working as NSString).replacingCharacters(in: match.range, with: " ")
                }
            }
        }

        if loaded.isEmpty {
            let trimmed = working.trimmingCharacters(in: CharacterSet(charactersIn: " '\"\n\t"))
            if let data = imageData(atPath: trimmed) {
                loaded.append(data)
                working = ""
            }
        }
        return (working, loaded.reversed())
    }

    /// Load image bytes if `path` points to an existing image file.
    static func imageData(atPath path: String) -> Data? {
        let expanded = (path as NSString).expandingTildeInPath
        let ext = (expanded as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext),
              FileManager.default.fileExists(atPath: expanded),
              let data = try? Data(contentsOf: URL(fileURLWithPath: expanded))
        else { return nil }
        return data
    }

    private func appendToAssistant(_ text: String) {
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[idx].content += text
        }
    }

    /// Record a tool invocation as compact activity on the in-flight assistant
    /// message (rendered as a collapsed disclosure) and update the live status
    /// line — instead of dumping a marker into the chat transcript.
    private func recordToolStep(_ name: String) {
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

    func cancel(engine: MLXInferenceEngine) {
        generateTask?.cancel()
        engine.cancel()
        isStreaming = false
        currentActivity = nil
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
        - Make ONE tool call at a time, then wait for its real result before deciding \
        the next step. Do not narrate a sequence of imaginary calls.
        - If a tool returns empty or no output, say exactly that — do not fabricate a \
        plausible-looking result (e.g. fake file listings, paths, or timestamps).
        - If you cannot or did not call a tool, say so plainly. Never claim an action \
        happened unless a real tool result confirms it.
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
            base = """
                You are the Navigator, the conductor for SwiftMaestro. You handle general \
                chat and coordinate project work. You can create projects and long-lived \
                project agents (create_project_agent), list the workspace (list_workspace), \
                remove agents that are no longer needed (archive_project_agent), and \
                delegate a task to a project agent (ask_project_agent) then synthesize \
                their result for the user. To delegate to SEVERAL agents at once, use \
                ask_project_agents with a 'requests' list of {project, agent, task}. \
                Create a project agent when the user wants ongoing work focused on a \
                specific project.
                """
        } else {
            let proj = projectName ?? "this project"
            base = """
                You are \(agent.name), a project agent for the project "\(proj)". Focus on \
                this project's work. Project: \(proj). Use the memory tools to recall and \
                store project knowledge — they are scoped to this project.
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
                This is your base directory. Build ABSOLUTE paths from it when calling file \
                and search tools (read_file, write_file, edit_file, list_dir, grep_code, \
                glob_files) instead of guessing or searching for the project, and it is the \
                default working directory for execute_command. If a relative path is given, \
                resolve it against this directory.
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

    private func messagesForInference(modelDescription: String? = nil) -> [Message] {
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
            if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if message.content.isEmpty { output.append(message) }
                continue
            }
            var copy = message
            copy.content = cleaned
            output.append(copy)
        }
        if let last = output.last, last.role == .assistant, last.content.isEmpty {
            output.removeLast()
        }
        return output
    }

    private static func stripToolMarkers(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("🔧 called") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
