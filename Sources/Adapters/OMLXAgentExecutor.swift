import Foundation
import MLXLMCommon

// MARK: - Agentic executor
//
// Owns the backend-agnostic agentic loop: it manages the conversation, executes
// tools (with project/working-dir injection + delegation), and streams activity.
// Per-round generation is delegated to a pluggable `GenerationBackend` (oMLX HTTP
// or in-process MLX). Tool execution reuses the same native (MaestroTools) and
// MCP sources regardless of backend.

final class OMLXAgentExecutor: Sendable {

    private let endpointURL: String
    private let modelID: String
    private let backend: GenerationBackend
    /// When set, delegated sub-agents resolve their OWN backend/model via this
    /// (per-agent models). When nil, sub-agents reuse the parent's backend.
    private let delegateBackendResolver: DelegateBackendResolver?

    /// Designated init with an explicit backend. `endpointURL`/`modelID` are kept
    /// for delegation (sub-agents spin up their own oMLX executor).
    init(endpointURL: String, modelID: String, backend: GenerationBackend,
         delegateBackendResolver: DelegateBackendResolver? = nil) {
        self.endpointURL = endpointURL
        self.modelID = modelID
        self.backend = backend
        self.delegateBackendResolver = delegateBackendResolver
    }

    // MARK: - Entry point

    /// Run the agentic loop. `toolSpecs` are OpenAI function schemas (empty to
    /// disable tools). `mcp` handles MCP-sourced tool execution. `project`, when
    /// set, scopes project-aware tools (memory_*, decisions/todos, etc.) and is
    /// the project the calling agent belongs to.
    func run(
        messages: [Message],
        toolSpecs: [ToolSpec],
        mcp: MCPClientService?,
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        project: String? = nil,
        workingDirectory: String? = nil,
        agentID: String? = nil,
        maxRounds: Int? = nil
    ) -> AsyncThrowingStream<OMLXOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Conversation in OpenAI wire format; we append assistant
                    // tool_calls and tool results across rounds. Messages with
                    // attached images use the multimodal content-array form.
                    var convo: [[String: Any]] = messages.map { Self.wireMessage($0) }

                    // No iteration budget: local inference has no token cost, so
                    // the agentic loop runs until the model stops requesting tools.
                    // Termination is user-driven (Stop button -> Task cancellation).
                    var round = 0
                    var didUseTool = false       // any tool ran this turn
                    var usedMutator = false      // a todo/plan/message/workspace/delegation tool ran
                    var autoNudges = 0           // CONSECUTIVE unproductive nudges
                    let maxAutoNudges = 2
                    var finalWrapUpSent = false  // bounded-run wrap-up issued
                    iterations: while !Task.isCancelled {
                        // Bounded runs (delegated sub-agents): once the tool budget
                        // is spent, force ONE last tool-free round so the model must
                        // produce a final text answer instead of ping-ponging tools
                        // forever (which would hang the parent's delegation call).
                        var specsThisRound = toolSpecs
                        if let maxRounds, round >= maxRounds {
                            if finalWrapUpSent { break iterations }
                            finalWrapUpSent = true
                            specsThisRound = []
                            convo.append([
                                "role": "user",
                                "content":
                                    "Tool budget exhausted — do NOT call any more tools. "
                                    + "Using what you learned above, give your FINAL answer "
                                    + "to the original request now, as plain text.",
                            ])
                        }
                        let (content, toolCalls) = try await backend.streamRound(
                            convo: convo,
                            toolSpecs: specsThisRound,
                            temperature: temperature,
                            topP: topP,
                            thinkingEnabled: thinkingEnabled,
                            continuation: continuation
                        )
                        NSLog("[OMLX] round \(round): tools=\(specsThisRound.count) content=\(content.count) chars, toolCalls=[\(toolCalls.map { $0.name }.joined(separator: ", "))]")

                        guard !Task.isCancelled else { break iterations }
                        // The forced wrap-up round IS the final answer.
                        if finalWrapUpSent { break iterations }

                        if toolCalls.isEmpty {
                            // Small models end a turn either (a) NARRATING a future
                            // action ("I'll mark it done now") after using a tool, or
                            // (b) CLAIMING in past tense that they changed a plan/
                            // checklist while never calling the tool. Both are caught
                            // here; a bounded nudge makes the call actually happen.
                            // Only nudge on a FALSE CLAIM: the model asserts (past
                            // tense) that it changed a plan/checklist/etc. or
                            // delegated, yet NO such tool ran this turn. We no longer
                            // nudge on "unfinished intent" narration: capable
                            // reasoning models (e.g. 122B) interleave <think> and
                            // narration across many tool rounds, and nudging that
                            // made them redundantly RE-RUN already-completed tools
                            // (re-create the same todo list, re-list the directory)
                            // and misread the automated nudge as a message from the
                            // user. If the model pauses with narration, just end the
                            // turn rather than fabricating a correction message.
                            let falseClaim = !usedMutator
                                && (Self.claimsToolBackedMutation(content)
                                    || Self.claimsDelegation(content))
                            if !specsThisRound.isEmpty, autoNudges < maxAutoNudges, falseClaim {
                                autoNudges += 1
                                NSLog("[OMLX] auto-nudge \(autoNudges): falseClaim")
                                convo.append(["role": "assistant", "content": content])
                                // The correction is a USER-role message: a mid-conversation
                                // SYSTEM message breaks the Qwen Jinja chat template
                                // (Jinja.TemplateException — it only accepts a system message
                                // at position 0). To stop the model mistaking this for the
                                // human ("the user is pointing out that I claimed..."), the
                                // content explicitly labels itself as an automated check that
                                // is NOT from the user.
                                convo.append([
                                    "role": "user",
                                    "content":
                                        "[automated check — NOT a message from the user] Your previous "
                                        + "message described an action but did not include the tool call "
                                        + "that performs it. "
                                        + Self.nudgeInstruction(for: content)
                                        + " Emit ONLY that tool call now, with correct arguments and no "
                                        + "unrelated tools. If the action was already completed in an "
                                        + "earlier step, or no tool is needed, just give your final answer.",
                                ])
                                continue iterations
                            }
                            break iterations  // final answer already streamed
                        }
                        didUseTool = true
                        // A real tool call means the last nudge (if any) worked — reset
                        // the budget so it caps CONSECUTIVE refusals, not total nudges.
                        // Multi-step tasks (scrape -> blocked -> search -> retry) need
                        // more than 2 follow-throughs per turn; refuse-loops still
                        // terminate after 2 nudges in a row without a tool call.
                        autoNudges = 0
                        if toolCalls.contains(where: {
                            Self.agentScopedTools.contains($0.name)
                                || Self.nonInjectedMutators.contains($0.name)
                        }) {
                            usedMutator = true
                        }

                        // Record the assistant turn that requested the tools.
                        convo.append([
                            "role": "assistant",
                            "content": content,
                            "tool_calls": toolCalls.map { $0.wire },
                        ])

                        // Execute each tool and feed the result back.
                        for tc in toolCalls {
                            continuation.yield(.toolCall(name: tc.name))
                            let result = await executeTool(
                                tc, mcp: mcp, project: project,
                                workingDirectory: workingDirectory, agentID: agentID)
                            convo.append([
                                "role": "tool",
                                "tool_call_id": tc.id,
                                "content": result,
                            ])
                        }
                        round += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pick a SPECIFIC instruction naming just the one tool that matches what the
    /// model claimed/intended, so a nudged small model doesn't grab unrelated
    /// tools from a menu (e.g. creating a todo list when asked to send a message).
    private static func nudgeInstruction(for content: String) -> String {
        let t = content.lowercased()
        let messageish = ["message", "inbox", "sent", "messaged", "notified", "deliver"]
        if messageish.contains(where: { t.contains($0) }) {
            return "Call send_agent_message with to_agent, subject, and message."
        }
        if claimsDelegation(content) {
            return "Call ask_project_agents with a 'requests' list of {project, agent, task} "
                + "(or ask_project_agent for a single one) to ACTUALLY delegate. Do not invent "
                + "the agents' answers — only report what the tool returns."
        }
        if t.contains("agent") {
            return "Call create_project_agent with 'project' and 'agent' (or ask_project_agent "
                + "to delegate a task)."
        }
        if t.contains("plan") {
            return "Call edit_plan (or create_plan) and put the new text in its 'content' argument "
                + "(set append=true to add to an existing plan)."
        }
        if t.contains("todo") || t.contains("task") || t.contains("checklist") {
            return "Call update_todo_status (or create_todo_list) to change the task checklist."
        }
        return "Make the tool call that actually performs the action you just described."
    }

    /// Heuristic: does this text CLAIM (often in past tense) that a tool-backed
    /// action happened — a plan/task/checklist change OR a message send? Used to
    /// catch the model asserting e.g. "plan updated" or "message sent" without
    /// having actually called the corresponding tool.
    private static func claimsToolBackedMutation(_ text: String) -> Bool {
        let t = text.lowercased()
        guard !t.isEmpty else { return false }
        let nouns = ["plan", "task", "todo", "to-do", "checklist", "message", "inbox", "agent"]
        let verbs = ["updated", "created", "added", "marked", "edited", "appended",
                     "deleted", "renamed", "removed", "completed", "archived",
                     "sent", "messaged", "notified", "delivered"]
        return nouns.contains { t.contains($0) } && verbs.contains { t.contains($0) }
    }

    /// Heuristic: does this text CLAIM the model delegated to / consulted project
    /// agents (and is likely reporting fabricated answers) without calling the
    /// delegation tool? Requires the word "agent" plus a PAST-TENSE completed-
    /// action cue. Present-tense capability descriptions ("I delegate tasks to
    /// specialists when needed") must NOT match — flagging those nudges the model
    /// into delegating spuriously (e.g. on "what's your role?").
    private static func claimsDelegation(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.contains("agent") else { return false }
        let cues = ["i asked", "i've asked", "i have asked", "asked both",
                    "delegated", "consulted", "queried", "their response",
                    "their suggestion", "suggested", "responded", "replied",
                    "both agents"]
        return cues.contains { t.contains($0) }
    }

    /// Mutating tools that are NOT agent-scoped (no agent_id injection) but still
    /// count as "real work this turn" so a legitimate result isn't re-nudged.
    private static let nonInjectedMutators: Set<String> = [
        "create_project_agent", "archive_project_agent",
        "ask_project_agent", "ask_project_agents",
    ]

    /// Encode a Message into an OpenAI chat message. Plain text uses string
    /// content; when images are attached, content becomes an array of text +
    /// image_url (base64 data URI) parts, which oMLX accepts for vision models.
    private static func wireMessage(_ message: Message) -> [String: Any] {
        guard let images = message.imageData, !images.isEmpty else {
            return ["role": message.role.rawValue, "content": message.content]
        }
        var parts: [[String: Any]] = []
        if !message.content.isEmpty {
            parts.append(["type": "text", "text": message.content])
        }
        for data in images {
            let uri = "data:image/png;base64,\(data.base64EncodedString())"
            parts.append(["type": "image_url", "image_url": ["url": uri]])
        }
        return ["role": message.role.rawValue, "content": parts]
    }

    // MARK: - Tool execution (shared across backends)

    /// Tools whose first argument should be the calling agent's project, injected
    /// automatically when the model didn't already supply one. These are the
    /// project-scoped ai-context-bridge memory/session tools.
    private static let projectScopedTools: Set<String> = [
        "memory_write", "memory_read", "memory_search", "memory_list",
        "add_decision", "add_todo", "report_error", "update_session",
        "list_active_contexts",
        // Plan tools: a project agent's plans default to its project (shared);
        // the Navigator (no project) keeps personal plans unless it passes one.
        "create_plan", "edit_plan", "read_plans", "read_plan",
    ]

    private func executeTool(
        _ tc: RoundToolCall, mcp: MCPClientService?, project: String?,
        workingDirectory: String? = nil, agentID: String? = nil
    ) async -> String {
        NSLog("[OMLX] executeTool name=\(tc.name) args=\(tc.arguments.prefix(300))")
        // Delegation is handled here (not in MaestroTools) because it needs the
        // live endpoint/model/MCP to run the target agent's own loop.
        if tc.name == "ask_project_agent" {
            return await delegate(argumentsJSON: tc.arguments, mcp: mcp)
        }
        if tc.name == "ask_project_agents" {
            return await delegateMany(argumentsJSON: tc.arguments, mcp: mcp)
        }

        var argsJSON = Self.injectProject(
            into: tc.arguments, toolName: tc.name, project: project
        )
        // Default execute_command's cwd to the agent's working directory.
        argsJSON = Self.injectCwd(
            into: argsJSON, toolName: tc.name, workingDirectory: workingDirectory
        )
        // Stamp the calling agent's id onto live-todo tools (the model can't know
        // its own id; the live checklist is keyed by agent).
        argsJSON = Self.injectAgentID(
            into: argsJSON, toolName: tc.name, agentID: agentID
        )
        let call = Self.toolCall(name: tc.name, argumentsJSON: argsJSON)
        if MaestroTools.handles(tc.name) {
            return await MaestroTools.execute(call)
        }
        if let mcp, await mcp.handles(tc.name) {
            return await mcp.execute(call)
        }
        return await MaestroTools.execute(call)
    }

    /// Inject the agent's working directory as `cwd` for execute_command when the
    /// model didn't supply one, so shell commands run in the right place.
    private static func injectCwd(
        into argumentsJSON: String, toolName: String, workingDirectory: String?
    ) -> String {
        guard let wd = workingDirectory, !wd.isEmpty, toolName == "execute_command" else {
            return argumentsJSON
        }
        var obj = ((try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any]) ?? [:]
        let existing = obj["cwd"] as? String
        if existing == nil || existing?.isEmpty == true { obj["cwd"] = wd }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8)
        else { return argumentsJSON }
        return string
    }

    /// Per-agent tools (live todo checklist + plan docs) keyed by the calling
    /// agent. The id is always injected (overwriting any model-supplied value)
    /// since the model can't know it.
    private static let agentScopedTools: Set<String> = [
        "create_todo_list", "add_todos", "update_todo_status", "read_todos",
        "create_plan", "edit_plan", "read_plans", "read_plan",
        // Messaging: agent_id identifies the sender / the inbox owner.
        "send_agent_message", "read_agent_messages",
    ]

    /// Always stamp `agent_id` onto live-todo tool calls.
    private static func injectAgentID(
        into argumentsJSON: String, toolName: String, agentID: String?
    ) -> String {
        guard let agentID, agentScopedTools.contains(toolName) else { return argumentsJSON }
        var obj = ((try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any]) ?? [:]
        obj["agent_id"] = agentID
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8)
        else { return argumentsJSON }
        return string
    }

    /// Inject `project` into a project-scoped tool's JSON arguments when absent.
    private static func injectProject(
        into argumentsJSON: String, toolName: String, project: String?
    ) -> String {
        guard let project, projectScopedTools.contains(toolName) else { return argumentsJSON }
        var obj = ((try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any]) ?? [:]
        let existing = obj["project"] as? String
        if existing == nil || existing?.isEmpty == true {
            obj["project"] = project
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8)
        else { return argumentsJSON }
        return string
    }

    // MARK: - Delegation (true multi-agent)

    private struct DelegateResult: Sendable {
        let project: String
        let agent: String
        let answer: String?
        let error: String?
    }

    /// Delegate ONE task to a project agent: resolve the target, run its own loop
    /// (project tools only, so it can't recurse), persist the exchange, and return
    /// the result. The sub-agent gets its own agentID so its todo/plan/messaging
    /// tools work.
    private func delegateOne(
        projectName: String?, agentName: String, task: String, mcp: MCPClientService?
    ) async -> DelegateResult {
        let trimmedTask = task.trimmingCharacters(in: .whitespaces)
        guard !agentName.trimmingCharacters(in: .whitespaces).isEmpty, !trimmedTask.isEmpty else {
            return DelegateResult(project: projectName ?? "", agent: agentName, answer: nil,
                error: "each request needs a non-empty 'agent' and 'task'")
        }
        // Resolve target + assemble its prompt on the MainActor.
        let prep: (AgentRecord, String, [Message])? = await MainActor.run {
            guard let ws = MaestroTools.workspace else { return nil }
            let target: AgentRecord?
            if let p = projectName, !p.trimmingCharacters(in: .whitespaces).isEmpty {
                target = ws.findAgent(projectName: p, agentName: agentName)
            } else {
                target = ws.agents.first {
                    $0.kind == .project && $0.name.caseInsensitiveCompare(agentName) == .orderedSame
                }
            }
            guard let target else { return nil }
            let proj = ws.projectName(for: target) ?? (projectName ?? "")
            var msgs = ChatHistoryStore.load(agentId: target.id)
                ?? [ChatViewModel.systemMessage(
                    for: target, projectName: proj.isEmpty ? nil : proj)]
            msgs.append(Message(role: .user, content: trimmedTask))
            return (target, proj, msgs)
        }
        guard let (target, proj, messages) = prep else {
            return DelegateResult(project: projectName ?? "", agent: agentName, answer: nil,
                error: "no project agent named '\(agentName)'")
        }

        // Delegate tool surface: project tools only (no Navigator tools), plus
        // MCP servers the user exposes to delegated sub-agents.
        var specs = MaestroTools.schemas(navigator: false)
        if let mcp { specs += await mcp.currentSchemas(audience: .delegate) }
        NSLog("[DELEGATE] -> '\(target.name)' (project='\(proj)') with \(specs.count) tools")

        // Per-agent model: when a resolver is wired, the sub-agent runs on ITS
        // own assigned model/backend (in-process or oMLX); otherwise it reuses
        // the parent's. Bounded tool budget: a delegated run must terminate and
        // answer (the wrap-up round in `run` forces a final tool-free reply).
        var subModelID = modelID
        var subBackend = backend
        if let delegateBackendResolver, let resolved = await delegateBackendResolver(target.id) {
            subModelID = resolved.modelID
            subBackend = resolved.backend
        }
        let sub = OMLXAgentExecutor(
            endpointURL: endpointURL, modelID: subModelID, backend: subBackend,
            delegateBackendResolver: delegateBackendResolver)
        var narration = ""      // every streamed token (fallback)
        var lastRoundText = ""  // text after the most recent tool call
        do {
            for try await output in sub.run(
                messages: messages, toolSpecs: specs, mcp: mcp,
                temperature: 0.3, topP: 0.95, thinkingEnabled: false,
                project: proj.isEmpty ? nil : proj, agentID: target.id.uuidString,
                maxRounds: 6
            ) {
                switch output {
                case .token(let token):
                    narration += token
                    lastRoundText += token
                case .toolCall:
                    // Rounds that end in tool calls are narration, not the answer.
                    lastRoundText = ""
                case .info:
                    break
                }
            }
        } catch {
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "delegate failed: \(error.localizedDescription)")
        }
        let trimmedLast = lastRoundText.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = trimmedLast.isEmpty
            ? narration.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedLast
        guard !answer.isEmpty else {
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "agent finished without a text answer")
        }

        // Persist the delegated exchange to the target agent's own history.
        await MainActor.run {
            var msgs = messages
            msgs.append(Message(role: .assistant, content: answer))
            ChatHistoryStore.save(msgs, agentId: target.id)
        }
        return DelegateResult(project: proj, agent: target.name, answer: answer, error: nil)
    }

    /// `ask_project_agent` — delegate a single task and return its answer.
    private func delegate(argumentsJSON: String, mcp: MCPClientService?) async -> String {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let req = Self.normalizeRequestItem(raw),
            let agentName = req["agent"] as? String,
            let task = req["task"] as? String
        else {
            return MaestroTools.errorJSON("ask_project_agent requires 'project', 'agent', and 'task'")
        }
        let r = await delegateOne(
            projectName: req["project"] as? String, agentName: agentName, task: task, mcp: mcp)
        if let err = r.error { return MaestroTools.errorJSON(err) }
        return Self.json(["project": r.project, "agent": r.agent, "answer": r.answer ?? ""])
    }

    /// `ask_project_agents` — delegate to several agents and aggregate the answers.
    /// Runs the sub-agents CONCURRENTLY: each `delegateOne` builds its own
    /// backend (per-agent model), uses its own per-agent KV cache, and wraps
    /// generation in task-local random state, so interleaved on-device runs are
    /// safe. Output order matches the request order.
    private func delegateMany(argumentsJSON: String, mcp: MCPClientService?) async -> String {
        guard let requests = Self.parseDelegationRequests(argumentsJSON), !requests.isEmpty else {
            return MaestroTools.errorJSON(
                "ask_project_agents requires 'requests': a non-empty JSON array of "
                + "{project, agent, task} objects. Example: {\"requests\": "
                + "[{\"project\": \"Tests\", \"agent\": \"Agent1-test1\", "
                + "\"task\": \"Suggest one improvement to the auth plan.\"}]}")
        }
        NSLog("[DELEGATE] fan-out to \(requests.count) agent(s) — concurrent")
        // Extract Sendable primitives before the task group (a [String: Any]
        // dictionary is not Sendable and can't cross the task boundary).
        let parsed: [(project: String?, agent: String, task: String)] = requests.map {
            ($0["project"] as? String, ($0["agent"] as? String) ?? "", ($0["task"] as? String) ?? "")
        }
        let collected = await withTaskGroup(
            of: (Int, String, String, String?, String?).self
        ) { group in
            for (i, p) in parsed.enumerated() {
                group.addTask { [self] in
                    let r = await delegateOne(
                        projectName: p.project, agentName: p.agent, task: p.task, mcp: mcp)
                    return (i, r.project, r.agent, r.answer, r.error)
                }
            }
            var acc: [(Int, String, String, String?, String?)] = []
            for await t in group { acc.append(t) }
            return acc
        }
        let results: [[String: Any]] = collected.sorted { $0.0 < $1.0 }.map { t in
            if let err = t.4 { return ["project": t.1, "agent": t.2, "error": err] }
            return ["project": t.1, "agent": t.2, "answer": t.3 ?? ""]
        }
        return Self.json(["results": results])
    }

    // MARK: - Lenient delegation-argument parsing

    /// Normalize `ask_project_agents` arguments into a list of {project, agent,
    /// task} dictionaries. Small local models emit the 'requests' payload in many
    /// shapes — a proper array, a double-encoded JSON string, a single object, a
    /// flat {agent, task} at the top level, or {agents: [names], task: "..."} —
    /// so this accepts all of them instead of bouncing the call (mirrors the
    /// lenient todo/plan arg decoding).
    static func parseDelegationRequests(_ argumentsJSON: String) -> [[String: Any]]? {
        guard let data = argumentsJSON.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // Top-level array: treat it as the requests list itself.
        if let arr = top as? [Any] { return normalizeRequestList(arr, sharedTask: nil) }
        guard let obj = top as? [String: Any] else { return nil }

        let sharedTask = firstString(in: obj, keys: ["task", "question", "prompt", "message"])

        if let raw = obj["requests"] {
            // Proper array (of objects or strings).
            if let arr = raw as? [Any] { return normalizeRequestList(arr, sharedTask: sharedTask) }
            // Single object instead of an array.
            if let one = raw as? [String: Any] {
                return normalizeRequestItem(one).map { [$0] }
            }
            // Double-encoded JSON string: decode and recurse.
            if let s = raw as? String, let d = s.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: d) {
                if let arr = inner as? [Any] {
                    return normalizeRequestList(arr, sharedTask: sharedTask)
                }
                if let one = inner as? [String: Any] {
                    return normalizeRequestItem(one).map { [$0] }
                }
            }
            return nil
        }

        // {agents: [names], task: "..."} — fan the shared task out by name.
        if let names = obj["agents"] as? [Any], let task = sharedTask {
            let reqs: [[String: Any]] = names.compactMap { n in
                guard let name = n as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty
                else { return nil }
                var req: [String: Any] = ["agent": name, "task": task]
                if let p = firstString(in: obj, keys: ["project", "project_name"]) {
                    req["project"] = p
                }
                return req
            }
            return reqs.isEmpty ? nil : reqs
        }

        // Flat single request at the top level.
        return normalizeRequestItem(obj).map { [$0] }
    }

    /// Normalize one requests-list element (object, or a bare agent-name string
    /// when a shared task is available).
    private static func normalizeRequestList(
        _ arr: [Any], sharedTask: String?
    ) -> [[String: Any]]? {
        let reqs: [[String: Any]] = arr.compactMap { el in
            if let obj = el as? [String: Any] {
                var item = normalizeRequestItem(obj)
                if item?["task"] == nil, let t = sharedTask {
                    item?["task"] = t
                }
                return item
            }
            if let name = el as? String, let task = sharedTask,
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return ["agent": name, "task": task]
            }
            return nil
        }
        return reqs.isEmpty ? nil : reqs
    }

    /// Map alternate key spellings onto {project, agent, task}. Returns nil when
    /// no agent name (or no task) can be recovered.
    private static func normalizeRequestItem(_ obj: [String: Any]) -> [String: Any]? {
        guard let agent = firstString(in: obj, keys: ["agent", "agent_name", "name"]),
              !agent.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        guard let task = firstString(
            in: obj, keys: ["task", "question", "prompt", "message", "request"])
        else { return nil }
        var req: [String: Any] = ["agent": agent, "task": task]
        if let p = firstString(in: obj, keys: ["project", "project_name"]) {
            req["project"] = p
        }
        return req
    }

    private static func firstString(in obj: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = obj[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// Build an mlx `ToolCall` from an OpenAI tool call so we can reuse the
    /// existing native/MCP execution paths.
    private static func toolCall(name: String, argumentsJSON: String) -> ToolCall {
        let args: [String: JSONValue]
        if let data = argumentsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            args = decoded
        } else {
            args = [:]
        }
        return ToolCall(function: .init(name: name, arguments: args))
    }
}
