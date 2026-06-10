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

    /// Convenience init using the oMLX HTTP backend.
    init(endpointURL: String, modelID: String) {
        self.endpointURL = endpointURL
        self.modelID = modelID
        self.backend = OMLXBackend(endpointURL: endpointURL, modelID: modelID)
    }

    /// Designated init with an explicit backend. `endpointURL`/`modelID` are kept
    /// for delegation (sub-agents spin up their own oMLX executor).
    init(endpointURL: String, modelID: String, backend: GenerationBackend) {
        self.endpointURL = endpointURL
        self.modelID = modelID
        self.backend = backend
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
        agentID: String? = nil
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
                    var didUseTool = false           // any tool ran this turn
                    var usedAgentScopedTool = false  // a todo/plan tool ran this turn
                    var autoNudges = 0               // bounded self-continuations
                    let maxAutoNudges = 2
                    iterations: while !Task.isCancelled {
                        let (content, toolCalls) = try await backend.streamRound(
                            convo: convo,
                            toolSpecs: toolSpecs,
                            temperature: temperature,
                            topP: topP,
                            thinkingEnabled: thinkingEnabled,
                            continuation: continuation
                        )
                        NSLog("[OMLX] round \(round): tools=\(toolSpecs.count) content=\(content.count) chars, toolCalls=[\(toolCalls.map { $0.name }.joined(separator: ", "))]")

                        guard !Task.isCancelled else { break iterations }

                        if toolCalls.isEmpty {
                            // Small models end a turn either (a) NARRATING a future
                            // action ("I'll mark it done now") after using a tool, or
                            // (b) CLAIMING in past tense that they changed a plan/
                            // checklist while never calling the tool. Both are caught
                            // here; a bounded nudge makes the call actually happen.
                            let unfinished = didUseTool && Self.looksUnfinishedIntent(content)
                            let falseClaim = !usedAgentScopedTool
                                && Self.claimsToolBackedMutation(content)
                            if !toolSpecs.isEmpty, autoNudges < maxAutoNudges,
                               unfinished || falseClaim {
                                autoNudges += 1
                                NSLog("[OMLX] auto-nudge \(autoNudges): unfinished=\(unfinished) falseClaim=\(falseClaim)")
                                convo.append(["role": "assistant", "content": content])
                                convo.append([
                                    "role": "user",
                                    "content":
                                        "You have not actually called the tool needed to complete my request. "
                                        + Self.nudgeInstruction(for: content)
                                        + " Call ONLY that tool now, with the correct arguments. Do not call "
                                        + "unrelated tools. NEVER claim something was done unless you actually called the tool.",
                                ])
                                continue iterations
                            }
                            break iterations  // final answer already streamed
                        }
                        didUseTool = true
                        if toolCalls.contains(where: { Self.agentScopedTools.contains($0.name) }) {
                            usedAgentScopedTool = true
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

    /// Heuristic: does this assistant text read like the model is ABOUT to take
    /// an action (but hasn't actually called a tool)? Used to auto-continue the
    /// loop so small models follow through on a promised tool call.
    private static func looksUnfinishedIntent(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        if t.hasSuffix(":") { return true }
        let futureCues = ["i'll ", "i will ", "i am going to ", "i'm going to ",
                          "let me ", "now i", "next, i", "next i", "i can now ", "i need to "]
        let actionVerbs = ["mark", "update", "set ", "call ", "create", "add ",
                           "remove", "delete", "run ", "fix", "make ", "check "]
        let hasCue = futureCues.contains { t.contains($0) }
        let hasVerb = actionVerbs.contains { t.contains($0) }
        return hasCue && hasVerb
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
        if t.contains("agent") {
            return "Call create_project_agent with 'project' and 'agent' (or ask_project_agent "
                + "to delegate a task)."
        }
        if t.contains("plan") {
            return "Call edit_plan (or create_plan) and put the new text in its 'content' argument "
                + "(set append=true to add to an existing plan)."
        }
        return "Call update_todo_status (or create_todo_list) to change the task checklist."
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

        // Delegate tool surface: project tools only (no Navigator tools).
        var specs = MaestroTools.schemas(navigator: false)
        if let mcp { specs += await mcp.currentSchemas() }
        NSLog("[DELEGATE] -> '\(target.name)' (project='\(proj)') with \(specs.count) tools")

        // Sub-agent uses the SAME backend as the parent (in-process or oMLX).
        let sub = OMLXAgentExecutor(endpointURL: endpointURL, modelID: modelID, backend: backend)
        var answer = ""
        do {
            for try await output in sub.run(
                messages: messages, toolSpecs: specs, mcp: mcp,
                temperature: 0.3, topP: 0.95, thinkingEnabled: false,
                project: proj.isEmpty ? nil : proj, agentID: target.id.uuidString
            ) {
                if case .token(let token) = output { answer += token }
            }
        } catch {
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "delegate failed: \(error.localizedDescription)")
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
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let agentName = obj["agent"] as? String,
            let task = obj["task"] as? String
        else {
            return MaestroTools.errorJSON("ask_project_agent requires 'project', 'agent', and 'task'")
        }
        let r = await delegateOne(
            projectName: obj["project"] as? String, agentName: agentName, task: task, mcp: mcp)
        if let err = r.error { return MaestroTools.errorJSON(err) }
        return Self.json(["project": r.project, "agent": r.agent, "answer": r.answer ?? ""])
    }

    /// `ask_project_agents` — delegate to several agents and aggregate the answers.
    /// Runs sequentially: the on-device model is shared (a single KV-prefix cache),
    /// so generations must be serialized for correctness; the value here is
    /// one-shot multi-agent delegation + aggregation. A concurrency-safe server
    /// backend could run these in parallel.
    private func delegateMany(argumentsJSON: String, mcp: MCPClientService?) async -> String {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let requests = obj["requests"] as? [[String: Any]], !requests.isEmpty
        else {
            return MaestroTools.errorJSON(
                "ask_project_agents requires 'requests': a non-empty list of {project, agent, task}")
        }
        NSLog("[DELEGATE] fan-out to \(requests.count) agent(s)")
        var results: [[String: Any]] = []
        for req in requests {
            let r = await delegateOne(
                projectName: req["project"] as? String,
                agentName: (req["agent"] as? String) ?? "",
                task: (req["task"] as? String) ?? "", mcp: mcp)
            if let err = r.error {
                results.append(["project": r.project, "agent": r.agent, "error": err])
            } else {
                results.append(["project": r.project, "agent": r.agent, "answer": r.answer ?? ""])
            }
        }
        return Self.json(["results": results])
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
