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
        workingDirectory: String? = nil
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
                            break iterations  // final answer already streamed
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
                                tc, mcp: mcp, project: project, workingDirectory: workingDirectory)
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
    ]

    private func executeTool(
        _ tc: RoundToolCall, mcp: MCPClientService?, project: String?,
        workingDirectory: String? = nil
    ) async -> String {
        NSLog("[OMLX] executeTool name=\(tc.name) args=\(tc.arguments.prefix(300))")
        // Delegation is handled here (not in MaestroTools) because it needs the
        // live endpoint/model/MCP to run the target agent's own loop.
        if tc.name == "ask_project_agent" {
            return await Self.delegate(
                argumentsJSON: tc.arguments,
                endpoint: endpointURL, modelID: modelID, mcp: mcp
            )
        }

        var argsJSON = Self.injectProject(
            into: tc.arguments, toolName: tc.name, project: project
        )
        // Default execute_command's cwd to the agent's working directory.
        argsJSON = Self.injectCwd(
            into: argsJSON, toolName: tc.name, workingDirectory: workingDirectory
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

    /// Run a project agent's loop for a delegated task, persist the exchange to
    /// its history, and return its answer. The delegate gets project tools but
    /// not the Navigator tools, so delegation cannot recurse.
    private static func delegate(
        argumentsJSON: String, endpoint: String, modelID: String, mcp: MCPClientService?
    ) async -> String {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projectName = obj["project"] as? String,
            let agentName = obj["agent"] as? String,
            let task = obj["task"] as? String,
            !task.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            NSLog("[DELEGATE] bad args: \(argumentsJSON.prefix(300))")
            return MaestroTools.errorJSON(
                "ask_project_agent requires non-empty 'project', 'agent', and 'task'")
        }
        NSLog("[DELEGATE] -> project='\(projectName)' agent='\(agentName)' task='\(task.prefix(120))'")

        // Resolve target + assemble its prompt on the MainActor.
        let prep: (AgentRecord, [Message])? = await MainActor.run {
            guard let ws = MaestroTools.workspace,
                  let target = ws.findAgent(projectName: projectName, agentName: agentName)
            else { return nil }
            var msgs = ChatHistoryStore.load(agentId: target.id)
                ?? [ChatViewModel.systemMessage(for: target, projectName: projectName)]
            msgs.append(Message(role: .user, content: task))
            return (target, msgs)
        }
        guard let (target, messages) = prep else {
            NSLog("[DELEGATE] target not found for project='\(projectName)' agent='\(agentName)'")
            return MaestroTools.errorJSON(
                "no agent named '\(agentName)' in project '\(projectName)'")
        }

        // Delegate tool surface: project tools only (no Navigator tools).
        var specs = MaestroTools.schemas(navigator: false)
        if let mcp { specs += await mcp.currentSchemas() }
        NSLog("[DELEGATE] running sub-agent '\(target.name)' with \(specs.count) tools")

        let sub = OMLXAgentExecutor(endpointURL: endpoint, modelID: modelID)
        var answer = ""
        do {
            for try await output in sub.run(
                messages: messages, toolSpecs: specs, mcp: mcp,
                temperature: 0.3, topP: 0.95, thinkingEnabled: false,
                project: projectName
            ) {
                if case .token(let token) = output { answer += token }
            }
        } catch {
            NSLog("[DELEGATE] sub-run threw: \(error.localizedDescription)")
            return MaestroTools.errorJSON("delegate failed: \(error.localizedDescription)")
        }
        NSLog("[DELEGATE] <- answer=\(answer.count) chars")

        // Persist the delegated exchange to the target agent's own history.
        await MainActor.run {
            var msgs = messages
            msgs.append(Message(role: .assistant, content: answer))
            ChatHistoryStore.save(msgs, agentId: target.id)
        }

        let payload: [String: Any] = [
            "project": projectName, "agent": agentName, "answer": answer,
        ]
        if let out = try? JSONSerialization.data(withJSONObject: payload),
           let string = String(data: out, encoding: .utf8) {
            return string
        }
        return answer
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
