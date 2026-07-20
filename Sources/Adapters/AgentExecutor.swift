import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Steer inbox
//
// Thread-safe queue of mid-generation "steer" messages the user sends while a
// run is streaming. The executor drains it at each round boundary and injects
// the steers as user turns, so the next generation incorporates them WITHOUT
// cancelling the run. An actor keeps producer (UI) and consumer (executor task)
// race-free.

actor SteerInbox {
    private var pending: [String] = []

    /// Queue a steer (no-ops on blank input).
    func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending.append(trimmed)
    }

    /// Atomically return and clear all queued steers.
    func drainAll() -> [String] {
        let out = pending
        pending.removeAll()
        return out
    }

    var hasPending: Bool { !pending.isEmpty }
}

// MARK: - Delegate stream handler
//
// Thread-safe handler that receives tokens from delegated sub-agent runs
// and forwards them to the UI. When a delegation starts, the handler
// appends an empty assistant message to the target agent's chat, then
// streams tokens into it in real-time.

@MainActor
final class DelegateStreamHandler: ObservableObject {
    /// The target agent's ID receiving streamed tokens.
    let targetAgentID: String
    /// Callback to append a token to the target agent's messages.
    var onToken: ((String) -> Void)?
    /// Callback when delegation starts (append empty assistant message).
    var onStart: (() -> Void)?
    /// Callback when delegation finishes (save history).
    var onFinish: (() -> Void)?

    init(targetAgentID: String) {
        self.targetAgentID = targetAgentID
    }

    func token(_ text: String) {
        onToken?(text)
    }

    func start() {
        onStart?()
    }

    func finish() {
        onFinish?()
    }
}

// MARK: - Agentic executor
//
// Owns the backend-agnostic agentic loop: it manages the conversation, executes
// tools (with project/working-dir injection + delegation), and streams activity.
// Per-round generation is delegated to a pluggable `GenerationBackend` (the
// in-process MLX backend). Tool execution reuses the same native (MaestroTools)
// and MCP sources.

final class AgentExecutor: Sendable {

    private let modelID: String
    private let backend: GenerationBackend
    /// When set, delegated sub-agents resolve their OWN backend/model via this
    /// (per-agent models). When nil, sub-agents reuse the parent's backend.
    private let delegateBackendResolver: DelegateBackendResolver?
    /// Stream handler for delegated sub-agent tokens. When set, tokens from
    /// delegated runs are forwarded to this handler so the UI can show
    /// real-time activity in the target agent's chat window.
    nonisolated(unsafe) var delegateStreamHandler: DelegateStreamHandler?
    /// Callback for delegation streaming events. Set by the main run() loop
    /// to yield delegate events to the parent's continuation.
    nonisolated(unsafe) var onDelegateEvent: ((AgentOutput) -> Void)?
    /// Pending delegation streaming events, collected during tool execution
    /// and drained by the main loop after each tool call.
    nonisolated(unsafe) var pendingDelegateEvents: [AgentOutput] = []
    /// Catalog reference captured at run() start so delegation can look up the
    /// target model's size and choose a reduced tool surface for small MoE models.
    nonisolated(unsafe) var catalog: ModelCatalog? = nil
    /// Per-run token budget for this executor. Delegated sub-agents inherit this
    /// unless the backend resolver supplies a model-specific value.
    nonisolated(unsafe) var maxTokens: Int = 32768

    /// Designated init with an explicit backend. `modelID` identifies the model
    /// for delegation (sub-agents spin up their own executor).
    init(modelID: String, backend: GenerationBackend,
         delegateBackendResolver: DelegateBackendResolver? = nil) {
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
        engine: MLXInferenceEngine?,
        catalog: ModelCatalog?,
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        project: String? = nil,
        workingDirectory: String? = nil,
        agentID: String? = nil,
        maxRounds: Int? = nil,
        maxTokens: Int = 32768,
        steerInbox: SteerInbox? = nil
    ) -> AsyncThrowingStream<AgentOutput, Error> {
        AsyncThrowingStream { continuation in
            // Keep catalog reachable during this run so delegated sub-agents can
            // adapt their tool surface to the target model's capacity.
            self.catalog = catalog
            self.maxTokens = maxTokens
            // Reset per-run delegation state so stale sub-agent roots don't leak.
            MaestroTools.delegatedAgentWorkingDirectories = []
            let task = Task {
                do {
                    // Conversation in OpenAI wire format; we append assistant
                    // tool_calls and tool results across rounds. Messages with
                    // attached images use the multimodal content-array form.
                    var convo: [[String: Any]] = messages.map { Self.wireMessage($0) }

                    // No iteration budget: local inference has no token cost, so
                    // the agentic loop runs until the model stops requesting tools.
                    // Termination is user-driven (Stop button -> Task cancellation).
                    // HARD CAP: even the main agent gets max 8 rounds to prevent
                    // infinite narration/gather loops on small models.
                    var round = 0
                    let hardMaxRounds = 8
                    var didUseTool = false       // any tool ran this turn
                    var usedMutator = false      // a todo/plan/message/workspace/delegation tool ran
                    var autoNudges = 0           // CONSECUTIVE unproductive nudges
                    let maxAutoNudges = 4
                    var finalWrapUpSent = false  // bounded-run wrap-up issued
                    var fileOpCount = 0          // file ops since last auto-save
                    let autoSaveThreshold = 5    // trigger auto-save after N file ops
                    // Context budget: configurable via UserDefaults; default raised from
                    // 80K to 200K so large indexing/file ops don't trip prematurely.
                    let tokenBudget = UserDefaults.standard.object(forKey: "agent.contextTokenBudget") as? Int ?? 200_000
                    iterations: while !Task.isCancelled {
                        // Mid-generation steering: pull any user messages queued
                        // while the previous round was streaming or executing
                        // tools, and inject them as user turns so THIS round
                        // incorporates them (no cancel; KV-cache prefix reuse keeps
                        // the continuation fast).
                        if let steerInbox {
                            let steers = await steerInbox.drainAll()
                            if !steers.isEmpty {
                                for steer in steers {
                                    convo.append(["role": "user", "content": steer])
                                }
                                // Open a fresh assistant bubble for the steered
                                // continuation and re-arm the UI's reasoning split.
                                continuation.yield(.turnBreak)
                            }
                        }
                        // Bounded runs (delegated sub-agents): once the tool budget
                        // is spent, force ONE last tool-free round so the model must
                        // produce a final text answer instead of ping-ponging tools
                        // forever (which would hang the parent's delegation call).
                        // Also enforces a hard cap on the main agent to prevent
                        // infinite gather loops on small models.
                        var specsThisRound = toolSpecs
                        let effectiveMax = maxRounds ?? hardMaxRounds

                        // MEMORY GUARD: Check system memory pressure before generation.
                        // If memory is critically low, force the model to wrap up and save.
                        if Self.checkMemoryPressure() {
                            NSLog("[AGENT] MEMORY GUARD: System memory pressure detected (<15%% free)")
                            if !finalWrapUpSent {
                                finalWrapUpSent = true
                                specsThisRound = []
                                convo.append([
                                    "role": "user",
                                    "content":
                                        "SYSTEM WARNING: Memory pressure detected. "
                                        + "You MUST save your progress immediately using write_file. "
                                        + "Do NOT read any more files or call ocr_image. "
                                        + "Summarize what you've processed so far and save it. "
                                        + "Then provide your final answer.",
                                ])
                            }
                        }

                        // CONTEXT LIMIT: Force save if conversation exceeds token budget.
                        let currentTokens = Self.conversationTokenCount(convo)
                        if currentTokens > tokenBudget && !finalWrapUpSent {
                            NSLog("[AGENT] CONTEXT LIMIT: \(currentTokens) tokens exceeds budget of \(tokenBudget)")
                            finalWrapUpSent = true
                            specsThisRound = []
                            convo.append([
                                "role": "user",
                                "content":
                                    "SYSTEM: Context limit reached (\(currentTokens) tokens). "
                                    + "You MUST save all progress to disk immediately using write_file. "
                                    + "Do NOT read any more files. Provide a summary of what's been "
                                    + "done and what remains.",
                            ])
                        }

                        if round >= effectiveMax {
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
                        let (content, rawToolCalls) = try await backend.streamRound(
                            convo: convo,
                            toolSpecs: specsThisRound,
                            temperature: temperature,
                            topP: topP,
                            thinkingEnabled: thinkingEnabled,
                            maxTokens: maxTokens,
                            continuation: continuation
                        )
                        let cleanContent = Self.stripRawToolCallXML(content)
                        let callNames = rawToolCalls.map { $0.name }.joined(separator: ", ")
                        if rawToolCalls.isEmpty {
                            let preview = cleanContent.prefix(200).replacingOccurrences(of: "\n", with: "\\n")
                            NSLog("[AGENT] round \(round): tools=\(specsThisRound.count) content=\(cleanContent.count) chars, toolCalls=[] — content preview: \(preview)")
                        } else {
                            NSLog("[AGENT] round \(round): tools=\(specsThisRound.count) content=\(cleanContent.count) chars, toolCalls=[\(callNames)]")
                        }

                        // Fallback: if the model emitted an execute_command call but the
                        // XML parser returned an empty/missing `command` argument, recover
                        // the command from the assistant's text (fenced block, command-like
                        // line, or raw XML) so it actually runs.
                        var effectiveToolCalls = Self.recoverShellCommands(in: rawToolCalls, from: content)

                        guard !Task.isCancelled else { break iterations }
                        // The forced wrap-up round IS the final answer.
                        if finalWrapUpSent { break iterations }

                        if effectiveToolCalls.isEmpty {
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
                                && (Self.claimsToolBackedMutation(cleanContent)
                                    || Self.claimsDelegation(cleanContent))
                            // Future-tense narration ("I'll delegate", "Now I'll mark it",
                            // "I will now:", "Step 1: ...") should ALWAYS trigger a nudge —
                            // the model is announcing intent it never followed through on.
                            let futureNarration = !specsThisRound.isEmpty
                                && Self.claimsFutureAction(cleanContent)
                            // A displayed shell command the user is expected to run manually
                            // is a tool-use failure — the model should execute it itself.
                            let unexecutedShell = !specsThisRound.isEmpty
                                && Self.containsUnexecutedShellCommand(cleanContent)
                            // A displayed HTML/CSS/JS/JSON code block that the model is
                            // writing is a tool-use failure — it should use write_file.
                            let unexecutedFileWrite = !specsThisRound.isEmpty
                                && Self.containsUnexecutedFileWrite(cleanContent)
                            if !specsThisRound.isEmpty, autoNudges < maxAutoNudges,
                                falseClaim || futureNarration || unexecutedShell || unexecutedFileWrite {
                                autoNudges += 1
                                let reason: String
                                if unexecutedShell { reason = "unexecutedShell" }
                                else if unexecutedFileWrite { reason = "unexecutedFileWrite" }
                                else { reason = falseClaim ? "falseClaim" : "futureNarration" }
                                NSLog("[AGENT] auto-nudge \(autoNudges): \(reason)")
                                convo.append(["role": "assistant", "content": cleanContent])
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
                                        + Self.nudgeInstruction(for: cleanContent)
                                        + " Emit ONLY that tool call now, with correct arguments and no "
                                        + "unrelated tools. If the action was already completed in an "
                                        + "earlier step, or no tool is needed, just give your final answer.",
                                ])
                                continue iterations
                            }
                            // If the user steered during this (otherwise final)
                            // round, don't end: record the answer and loop so the
                            // top-of-loop drain injects the steer and the model
                            // responds to it (instead of dropping it).
                            if let steerInbox, await steerInbox.hasPending {
                                convo.append(["role": "assistant", "content": cleanContent])
                                round += 1
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
                        if effectiveToolCalls.contains(where: {
                            Self.agentScopedTools.contains($0.name)
                                || Self.nonInjectedMutators.contains($0.name)
                        }) {
                            usedMutator = true
                        }

                        // Record the assistant turn that requested the tools.
                        convo.append([
                            "role": "assistant",
                            "content": cleanContent,
                            "tool_calls": effectiveToolCalls.map { $0.wire },
                        ])

                        // Execute each tool and feed the result back.
                        for tc in effectiveToolCalls {
                            continuation.yield(.toolCall(name: tc.name))
                            let result = await executeTool(
                                tc, mcp: mcp, project: project,
                                workingDirectory: workingDirectory, agentID: agentID)
                            // VLM tools return image data that must be injected as a
                            // user message with the image attached, not as text.
                            if let vlmPayload = Self.parseVLMResult(result) {
                                convo.append([
                                    "role": "tool",
                                    "tool_call_id": tc.id,
                                    "content": vlmPayload.text,
                                ])
                            } else {
                                convo.append([
                                    "role": "tool",
                                    "tool_call_id": tc.id,
                                    "content": result,
                                ])
                            }
                            // AUTO-SAVE TRIGGER: Track file operations and inject
                            // save reminder after threshold is reached.
                            if Self.isFileOpTool(tc.name) {
                                fileOpCount += 1
                                if fileOpCount >= autoSaveThreshold && !finalWrapUpSent {
                                    NSLog("[AGENT] AUTO-SAVE: \(fileOpCount) file ops reached threshold")
                                    convo.append([
                                        "role": "user",
                                        "content":
                                            "SYSTEM: Auto-save trigger. You've performed "
                                            + "\(fileOpCount) file read operations. "
                                            + "Call write_file to save your current progress to disk "
                                            + "before continuing. Include: files processed so far, "
                                            + "key findings, and files remaining.",
                                    ])
                                    fileOpCount = 0
                                }
                            }
                        }
                        // Drain any delegation streaming events and yield them
                        // so the UI can show real-time sub-agent activity.
                        while !pendingDelegateEvents.isEmpty {
                            let event = pendingDelegateEvents.removeFirst()
                            continuation.yield(event)
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
        // Shell / server / command execution takes priority — this is the main failure
        // mode the user is asking about.
        if containsUnexecutedShellCommand(content) || t.contains("nohup") || t.contains("http.server")
            || t.contains("python3 -m") || t.contains("curl") || t.contains("lsof") || t.contains("kill")
            || t.contains("server") || t.contains("port") {
            return "Call execute_command with the EXACT shell command you just displayed. "
                + "Use this XML format:\n"
                + "<tool_call>\n<function=execute_command>\n<parameter=command>\n"
                + "YOUR_COMMAND_HERE\n</parameter>\n</function>\n</tool_call>\n"
                + "Do NOT output the command again as a code block or numbered step. "
                + "Use start_background: true for long-running servers. Run it now."
        }
        // File write dumps: the model pasted HTML/CSS/JS/JSON in chat instead of
        // calling write_file — redirect it to the tool.
        if containsUnexecutedFileWrite(content) {
            return "You just displayed a file's contents as a code block. You MUST use write_file "
                + "to actually create or overwrite the file. Use this XML format:\n"
                + "<tool_call>\n<function=write_file>\n"
                + "<parameter=path>/absolute/path/to/file.html</parameter>\n"
                + "<parameter=content>\nPASTE THE ENTIRE FILE CONTENTS HERE\n</parameter>\n"
                + "</function>\n</tool_call>\n"
                + "Do NOT output the file contents again as a code block. Write the file now."
        }
        let messageish = ["message", "inbox", "sent", "messaged", "notified", "deliver"]
        if messageish.contains(where: { t.contains($0) }) {
            return "Call send_agent_message with to_agent, subject, and message."
        }
        if claimsDelegation(content) {
            return "Call ask_project_agents with a 'requests' list of {project, agent, task} "
                + "(or ask_project_agent for a single one) to ACTUALLY delegate. Use this XML format:\n"
                + "<tool_call>\n<function=ask_project_agent>\n"
                + "<parameter=project>PROJECT_NAME</parameter>\n"
                + "<parameter=agent>AGENT_NAME</parameter>\n"
                + "<parameter=task>THE TASK TO HAND OFF</parameter>\n"
                + "</function>\n</tool_call>\n"
                + "Do not invent the agents' answers — only report what the tool returns."
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
        if t.contains("index") || t.contains("scan") || t.contains("directory") {
            return "Call index_directory with 'paths' (JSON array of directory paths) to ACTUALLY scan the directory. "
                + "Do not claim you have already indexed something — emit the tool call now."
        }
        if t.contains("read") || t.contains("file") || t.contains("content") || t.contains("config")
            || t.contains("guide") || t.contains("json") || t.contains("md") {
            return "Call read_file with the absolute 'path' of the file you just mentioned. "
                + "Use this XML format:\n"
                + "<tool_call>\n<function=read_file>\n<parameter=path>\n"
                + "/absolute/path/to/file.txt\n</parameter>\n</function>\n</tool_call>\n"
                + "If you are unsure of the exact path, call list_dir first. Emit the tool call now."
        }
        if t.contains("list") || t.contains("files") || t.contains("folder") {
            return "Call list_dir with the absolute 'path' of the directory you just mentioned. "
                + "Use this XML format:\n"
                + "<tool_call>\n<function=list_dir>\n<parameter=path>\n"
                + "/absolute/path/to/directory\n</parameter>\n</function>\n</tool_call>\n"
                + "Emit the tool call now, do not just describe what you would list."
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
        let nouns = ["plan", "task", "todo", "to-do", "checklist", "message", "inbox", "agent", "index"]
        let verbs = ["updated", "created", "added", "marked", "edited", "appended",
                     "deleted", "renamed", "removed", "completed", "archived",
                     "sent", "messaged", "notified", "delivered", "indexed", "scanned", "run"]
        return nouns.contains { t.contains($0) } && verbs.contains { t.contains($0) }
    }

    /// Heuristic: does this text CLAIM the model delegated to / consulted project
    /// agents (and is likely reporting fabricated answers) without calling the
    /// delegation tool? Requires the word "agent" plus a completed-action or
    /// present-progress cue. Present-tense capability descriptions ("I delegate
    /// tasks to specialists when needed") must NOT match.
    private static func claimsDelegation(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.contains("agent") else { return false }
        let cues = [
            "i asked", "i've asked", "i have asked", "asked both",
            "delegated", "consulted", "queried", "their response",
            "their suggestion", "suggested", "responded", "replied",
            "both agents",
            // Model claiming an agent is doing / has done work without actually
            // delegating via ask_project_agent.
            "agent has confirmed", "agent has verified", "agent has completed",
            "agent has checked", "agent has created", "agent has updated",
            "agent is now", "agent is working", "agent is checking",
            "agent is taking", "agent is processing", "agent will",
        ]
        return cues.contains { t.contains($0) }
    }

    /// Heuristic: does this text NARRATE a future action the model intends to
    /// take ("I'll delegate now", "Now I'll mark it done", "I will now:") but the
    /// turn ends without the tool call actually firing? Catches the model's pattern
    /// of announcing intent and then stopping.
    private static func claimsFutureAction(_ text: String) -> Bool {
        let t = text.lowercased()
        guard !t.isEmpty else { return false }
        let intents = [
            // Delegation / asking agents
            "i'll delegate", "i'll ask", "i'll task", "i'll instruct", "i'll have",
            "i'll get", "i'll make", "i'll tell", "i will delegate", "i will ask",
            "i will task", "i will instruct", "i will have", "i will get", "i will make",
            "i will tell", "i'm going to ask", "i'm going to task", "i'm going to instruct",
            "i am going to ask", "i am going to task", "i am going to instruct",
            // General future actions
            "i'll create", "i'll mark", "i'll send",
            "i'll add", "i'll update", "i'll set", "i'll remove",
            "i'll read", "i'll list", "i'll check", "i'll look",
            "i'll explore", "i'll gather", "i'll collect", "i'll help",
            "i will now", "i will:", "i will first", "i will then",
            "i will help", "i will read", "i will check", "i will explore",
            "i need to", "i need read", "i need check", "i need explore",
            "i am going to", "i'm going to",
            "now i'll", "let me delegate", "let me create",
            "let me mark", "let me send", "let me add",
            "let me read", "let me list", "let me check",
            "let me explore", "let me gather", "let me collect",
            "let me now", "let me start", "let me help",
            "next, i'll", "next i'll", "next, let me", "next let me",
            "now let me", "good, i'll", "i have the",
            "step 1:", "step 2:", "step 3:", "step 4:", "step 5:",
            "first, i will", "then i will", "finally, i will",
            "first, i'll", "then i'll", "finally, i'll"]
        return intents.contains { t.contains($0) }
    }

    /// Heuristic: does the text contain a bash/shell code block that the model
    /// displayed but never executed? Catches the pattern where the model prints a
    /// command for the user to run instead of calling execute_command.
    private static func containsUnexecutedShellCommand(_ text: String) -> Bool {
        let t = text.lowercased()
        guard !t.isEmpty else { return false }
        // Detect a fenced bash/zsh/shell code block.
        let patterns = [
            "```bash", "```sh", "```zsh", "```shell",
            "<code class=\"language-bash\"", "<code class=\"language-sh\""
        ]
        return patterns.contains { t.contains($0) }
    }

    /// Heuristic: does the text contain a fenced code block that looks like a
    /// file the model is writing (HTML/CSS/JS/JSON) but the model never called
    /// write_file? Catches the pattern where small models dump file contents in
    /// chat instead of using the tool.
    private static func containsUnexecutedFileWrite(_ text: String) -> Bool {
        let t = text.lowercased()
        guard !t.isEmpty else { return false }
        let tags = [
            "```html", "```css", "```js", "```javascript", "```json",
            "```xml", "```swift", "```python", "```md", "```markdown",
            "<code class=\"language-html\"", "<code class=\"language-css\"",
            "<code class=\"language-js\"", "<code class=\"language-javascript\"",
            "<code class=\"language-json\"",
        ]
        return tags.contains { t.contains($0) }
    }

    /// Strip raw XML tool-call blocks that the parser consumed as `.toolCall`
    /// events. Keeping them in the assistant content fed back to the model adds
    /// noise and can confuse small XML-format models into echoing malformed tags.
    private static func stripRawToolCallXML(_ text: String) -> String {
        var result = text
        let patterns = [
            "(?s)<tool_call>.*?</tool_call>",
            "(?s)<function=[^>]+>.*?</function>",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recover a shell command from the assistant's text when the XML parser
    /// returned an execute_command tool call with an empty or missing `command`
    /// argument. Tries, in order: a fenced code block, a command-like line in
    /// the prose, then the raw `<parameter=command>` value inside any leftover
    /// XML tool_call block.
    private static func recoverShellCommands(
        in toolCalls: [RoundToolCall], from content: String
    ) -> [RoundToolCall] {
        guard let command = firstShellCommand(in: content)
                ?? firstCommandLikeLine(in: content)
                ?? firstCommandFromRawXML(in: content)
        else { return toolCalls }
        return toolCalls.map { tc in
            guard tc.name == "execute_command" else { return tc }
            var args = ((try? JSONSerialization.jsonObject(
                with: Data(tc.arguments.utf8)
            )) as? [String: Any]) ?? [:]
            let existing = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard existing == nil || existing?.isEmpty == true else { return tc }
            args["command"] = command
            guard let data = try? JSONSerialization.data(withJSONObject: args),
                  let json = String(data: data, encoding: .utf8)
            else { return tc }
            NSLog("[AGENT] recovered execute_command args: \(json)")
            return RoundToolCall(id: tc.id, name: tc.name, arguments: json)
        }
    }

    /// Extract the first shell command from a fenced code block.
    private static func firstShellCommand(in text: String) -> String? {
        let tags = ["```bash", "```sh", "```zsh", "```shell"]
        var candidates: [String] = []
        for tag in tags {
            var search = text
            while let startRange = search.range(of: tag, options: .caseInsensitive) {
                let afterStart = search[startRange.upperBound...]
                guard let endRange = afterStart.range(of: "```") else { break }
                let block = String(afterStart[..<endRange.lowerBound])
                let cmd = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cmd.isEmpty { candidates.append(cmd) }
                search = String(afterStart[endRange.upperBound...])
            }
        }
        return candidates.first
    }

    /// Heuristic: find a line that looks like an executable command.
    private static func firstCommandLikeLine(in text: String) -> String? {
        let commandStarters = [
            "python3 ", "python ", "node ", "npm ", "yarn ", "swift ", "xcodegen ",
            "xcodebuild ", "cd ", "ls ", "cat ", "mkdir ", "cp ", "mv ", "rm ",
            "touch ", "echo ", "grep ", "find ", "awk ", "sed ", "curl ", "git ",
            "make ", "docker ", "kill ", "lsof ", "nohup ", "open ", "defaults ",
            "plutil ", "security "
        ]
        let operators = ["&&", "||", "|", ";", ">", ">>", " 2>&1"]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            if commandStarters.contains(where: { lower.hasPrefix($0) }) { return trimmed }
            if operators.contains(where: { trimmed.contains($0) })
                && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("*") {
                return trimmed
            }
        }
        return nil
    }

    /// Last resort: parse any raw `<function=execute_command>` XML block in the
    /// text and return the value of its `<parameter=command>` tag.
    private static func firstCommandFromRawXML(in text: String) -> String? {
        guard let funcMatch = text.range(
            of: #"<function=execute_command>([\s\S]*?)</function>"#,
            options: .regularExpression)
        else { return nil }
        let funcContent = String(text[funcMatch])
        guard let paramStart = funcContent.range(of: "<parameter=command>") else { return nil }
        let afterStart = funcContent[paramStart.upperBound...]
        guard let paramEnd = afterStart.range(of: "</parameter>") else { return nil }
        let value = String(afterStart[..<paramEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Mutating tools that are NOT agent-scoped (no agent_id injection) but still
    /// count as "real work this turn" so a legitimate result isn't re-nudged.
    private static let nonInjectedMutators: Set<String> = [
        "create_project_agent", "archive_project_agent",
        "ask_project_agent", "ask_project_agents",
    ]

    /// Encode a Message into an OpenAI chat message. Plain text uses string
    /// content; when images are attached, content becomes an array of text +
    /// image_url (base64 data URI) parts, which vision-capable models accept.
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

    /// Tools the Navigator is blocked from using (executor-level guard).
    /// The model sometimes ignores the tool spec and calls these anyway.
    /// Memory tools are ALLOWED (for coordination context); file/system/MCP tools are blocked.
    private static let navigatorBlockedTools: Set<String> = [
        "whisperkit_transcribe_control", "whisperkit_transcribe_snapshot",
        "execute_sqlite",
    ]

    private func executeTool(
        _ tc: RoundToolCall, mcp: MCPClientService?, project: String?,
        workingDirectory: String? = nil, agentID: String? = nil
    ) async -> String {
        // Delegation is handled here (not in MaestroTools) because it needs the
        // live endpoint/model/MCP to run the target agent's own loop.
        if tc.name == "ask_project_agent" {
            return await delegate(argumentsJSON: tc.arguments, mcp: mcp, workingDirectory: workingDirectory)
        }
        if tc.name == "ask_project_agents" {
            return await delegateMany(argumentsJSON: tc.arguments, mcp: mcp, workingDirectory: workingDirectory)
        }

        // Navigator guard: if project is nil (Navigator), block work tools.
        // The model sometimes ignores the tool spec and calls tools it shouldn't have.
        if project == nil && Self.navigatorBlockedTools.contains(tc.name) {
            return "{\"error\":\"\(tc.name) is not available to the Navigator. "
                + "You MUST delegate this task to a project agent using ask_project_agent.\"}"
        }

        var argsJSON = Self.injectProject(
            into: tc.arguments, toolName: tc.name, project: project
        )
        // Default execute_command's cwd to the agent's working directory.
        argsJSON = Self.injectCwd(
            into: argsJSON, toolName: tc.name, workingDirectory: workingDirectory
        )
        // Default create_project_agent's working directory to the creating agent's
        // working directory so sub-agents inherit a sensible base path.
        argsJSON = Self.injectCreateAgentCwd(
            into: argsJSON, toolName: tc.name, workingDirectory: workingDirectory
        )
        // Stamp the calling agent's id onto live-todo tools (the model can't know
        // its own id; the live checklist is keyed by agent).
        argsJSON = Self.injectAgentID(
            into: argsJSON, toolName: tc.name, agentID: agentID
        )
        let call = Self.toolCall(name: tc.name, argumentsJSON: argsJSON)
        // Expose the working directory to file tools so they treat it as an
        // implicit authorized root (agents can create/edit under their cwd
        // without requiring manual Settings → Context entries).
        MaestroTools.workingDirectory = workingDirectory
        if await MaestroTools.handles(tc.name) {
            let result = await MaestroTools.execute(call)
            // If create_project_agent returned "already_exists", rewrite the
            // result into a hard error so the model is forced to use
            // ask_project_agent instead of looping on create.
            if tc.name == "create_project_agent" && result.contains("already_exists") {
                return "{\"error\":\"AGENT ALREADY EXISTS. Do NOT call create_project_agent again. "
                    + "You MUST use ask_project_agent with the same project and agent name to delegate work.\"}"
            }
            return result
        }
        if let mcp, await mcp.handles(tc.name) {
            return await mcp.execute(call)
        }
        return await MaestroTools.execute(call)
    }

    // MARK: - VLM tool result support

    struct VLMResult {
        let text: String
    }

    /// If a tool result is a VLM image payload (from ocr_image), parse it into
    /// a VLMResult. The image is NOT re-injected — it's already visible in the
    /// user message. The tool just provides the extracted text.
    private static func parseVLMResult(_ result: String) -> VLMResult? {
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["__vlm_image__"] as? Bool == true,
              let path = obj["path"] as? String else { return nil }
        return VLMResult(
            text: "[Image loaded from \(path)]"
        )
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

    /// Default create_project_agent's working directory to the parent agent's
    /// working directory when the model didn't supply one.
    private static func injectCreateAgentCwd(
        into argumentsJSON: String, toolName: String, workingDirectory: String?
    ) -> String {
        guard let wd = workingDirectory, !wd.isEmpty, toolName == "create_project_agent" else {
            return argumentsJSON
        }
        var obj = ((try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any]) ?? [:]
        let existing = obj["workingDirectory"] as? String
        if existing == nil || existing?.isEmpty == true { obj["workingDirectory"] = wd }
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
        projectName: String?, agentName: String, task: String, mcp: MCPClientService?,
        workingDirectory: String? = nil
    ) async -> DelegateResult {
        let trimmedTask = task.trimmingCharacters(in: .whitespaces)
        guard !agentName.trimmingCharacters(in: .whitespaces).isEmpty, !trimmedTask.isEmpty else {
            return DelegateResult(project: projectName ?? "", agent: agentName, answer: nil,
                error: "each request needs a non-empty 'agent' and 'task'")
        }
        // Resolve target + assemble its prompt on the MainActor.
        let prep: (AgentRecord, String, [Message], String?)? = await MainActor.run {
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
            // Prefer the target agent's own working directory from its record,
            // then legacy UserDefaults, then the parent agent's working directory.
            let targetWD = target.workingDirectory
                ?? UserDefaults.standard.string(forKey: "workingDir.\(target.id.uuidString)")
                ?? workingDirectory
            if let targetWD, !targetWD.isEmpty,
               !MaestroTools.delegatedAgentWorkingDirectories.contains(targetWD) {
                MaestroTools.delegatedAgentWorkingDirectories.append(targetWD)
            }
            var msgs = ChatHistoryStore.load(agentId: target.id)
                ?? [ChatViewModel.systemMessage(
                    for: target, projectName: proj.isEmpty ? nil : proj,
                    workingDirectory: targetWD)]
            msgs.append(Message(role: .user, content: trimmedTask))
            return (target, proj, msgs, targetWD)
        }
        guard let (target, proj, messages, effectiveWD) = prep else {
            // List available agents so the model can correct itself.
            let available = await MainActor.run {
                guard let ws = MaestroTools.workspace else { return "none" }
                return ws.agents.filter { $0.kind == .project }.map { agent in
                    let p = ws.projectName(for: agent) ?? "unknown"
                    return "\(agent.name) (project: \(p))"
                }.joined(separator: ", ")
            }
            return DelegateResult(project: projectName ?? "", agent: agentName, answer: nil,
                error: "no agent named '\(agentName)' in project '\(projectName ?? "")'. "
                    + "Available agents: \(available). Use EXACT names from list_workspace.")
        }

        // Per-agent model: when a resolver is wired, the sub-agent runs on ITS
        // own assigned in-process model/backend; otherwise it reuses the
        // parent's. Bounded tool budget: a delegated run must terminate and
        // answer (the wrap-up round in `run` forces a final tool-free reply).
        var subModelID = modelID
        var subBackend = backend
        var subMaxTokens = maxTokens
        var subIsLite = false
        if let delegateBackendResolver, let resolved = await delegateBackendResolver(target.id) {
            subModelID = resolved.modelID
            subBackend = resolved.backend
            subMaxTokens = resolved.maxTokens
            // Small MoE models (<10B active params) are easily overwhelmed by the
            // full tool menu; give them the reduced essential+file set.
            if let catalog = self.catalog {
                subIsLite = await MainActor.run {
                    catalog.models.first { $0.huggingFaceID == resolved.modelID }?.isLiteModel ?? false
                }
            }
        }

        // Delegate tool surface: project tools only (no Navigator tools), plus
        // MCP servers the user exposes to delegated sub-agents. Per-agent enabled
        // categories override the old automatic lite-mode reduction.
        let enabledCategories = await MainActor.run {
            MaestroTools.workspace?.enabledToolCategories(for: target.id)
        }
        let compactMode = await MainActor.run {
            MaestroTools.workspace?.compactToolMode(for: target.id) ?? false
        }
        MaestroTools.currentEnabledCategories = enabledCategories
        MaestroTools.currentIsNavigator = false
        var specs = await MaestroTools.schemas(
            navigator: false, liteMode: subIsLite,
            enabledCategories: enabledCategories, compactMode: compactMode)
        if let mcp {
            let mcpSchemas = await mcp.currentSchemas(audience: .delegate)
            if let enabledCategories {
                if enabledCategories.contains(.mcp) {
                    specs += mcpSchemas
                }
            } else {
                specs += mcpSchemas
            }
        }
        NSLog("[DELEGATE] -> '\(target.name)' (project='\(proj)', lite=\(subIsLite), maxTokens=\(subMaxTokens)) with \(specs.count) tools")
        let sub = AgentExecutor(
            modelID: subModelID, backend: subBackend,
            delegateBackendResolver: delegateBackendResolver)
        // Wire up live streaming so the target agent's UI shows activity.
        if let handler = delegateStreamHandler {
            sub.delegateStreamHandler = handler
        }
        var narration = ""      // every streamed token (fallback)
        var lastRoundText = ""  // text after the most recent tool call
        // Notify handler and global sampler that delegation is starting.
        await MainActor.run {
            ProcessResourceSampler.shared.startSubagent(id: target.id.uuidString, name: target.name)
        }
        await delegateStreamHandler?.start()
        pendingDelegateEvents.append(.delegateStart(agentID: target.id.uuidString, modelID: subModelID))
        // Pass the parent's authorized roots to the child so it can access
        // the same folders (e.g. the vault) without re-authorizing.
        MaestroTools.inheritedRoots = MaestroTools.authorizedRootsForParent()
        defer { MaestroTools.inheritedRoots = [] }
        do {
            for try await output in sub.run(
                messages: messages, toolSpecs: specs, mcp: mcp,
                engine: nil, catalog: nil,
                temperature: 0.3, topP: 0.95, thinkingEnabled: false,
                project: proj.isEmpty ? nil : proj,
                workingDirectory: effectiveWD,
                agentID: target.id.uuidString,
                maxRounds: 6,
                maxTokens: subMaxTokens
            ) {
                switch output {
                case .token(let token):
                    narration += token
                    lastRoundText += token
                    // Forward token to live streaming handler and collect event.
                    await MainActor.run {
                        ProcessResourceSampler.shared.recordSubagentToken(id: target.id.uuidString)
                    }
                    await delegateStreamHandler?.token(token)
                    pendingDelegateEvents.append(.delegateToken(agentID: target.id.uuidString, token: token))
                case .toolCall:
                    // Rounds that end in tool calls are narration, not the answer.
                    lastRoundText = ""
                case .info, .turnBreak:
                    // Sub-agents have no steer inbox, so .turnBreak never fires;
                    // handled for switch exhaustiveness.
                    break
                case .delegateToken, .delegateStart(_, _), .delegateFinish:
                    // Sub-agents don't nest delegations, so these shouldn't appear.
                    break
                }
            }
        } catch {
            await MainActor.run {
                ProcessResourceSampler.shared.stopSubagent(id: target.id.uuidString)
            }
            await delegateStreamHandler?.finish()
            pendingDelegateEvents.append(.delegateFinish(agentID: target.id.uuidString))
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "delegate failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            ProcessResourceSampler.shared.stopSubagent(id: target.id.uuidString)
        }
        await delegateStreamHandler?.finish()
        pendingDelegateEvents.append(.delegateFinish(agentID: target.id.uuidString))
        let trimmedLast = lastRoundText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAnswer = trimmedLast.isEmpty
            ? narration.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedLast
        let answer = Self.stripThinkingTags(rawAnswer)
        guard !answer.isEmpty else {
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "agent finished without a text answer")
        }

        // Persist the delegated exchange to the target agent's own history
        // and update the in-memory ChatViewModel so the UI reflects it.
        await MainActor.run {
            var msgs = messages
            msgs.append(Message(role: .assistant, content: answer))
            ChatHistoryStore.save(msgs, agentId: target.id)
            NSLog("[DELEGATE] saving \(msgs.count) messages for \(target.name) (id=\(target.id))")
            if let cache = ChatViewModelCache.shared {
                NSLog("[DELEGATE] cache has VM for \(target.name): \(cache.hasViewModel(for: target.id))")
                cache.reloadMessages(forAgentID: target.id, messages: msgs)
            } else {
                NSLog("[DELEGATE] ChatViewModelCache.shared is NIL — UI won't update")
            }
        }
        return DelegateResult(project: proj, agent: target.name, answer: answer, error: nil)
    }

    /// Like `delegateOne` but takes pre-resolved targets to avoid MainActor.run
    /// inside concurrent task groups (prevents deadlock when UI is busy).
    private func delegateOneResolved(
        target: AgentRecord, proj: String, messages: [Message], task: String,
        mcp: MCPClientService?, workingDirectory: String?
    ) async -> DelegateResult {
        let enabledCategories = await MainActor.run {
            MaestroTools.workspace?.enabledToolCategories(for: target.id)
        }
        let compactMode = await MainActor.run {
            MaestroTools.workspace?.compactToolMode(for: target.id) ?? false
        }
        MaestroTools.currentEnabledCategories = enabledCategories
        MaestroTools.currentIsNavigator = false
        var specs = await MaestroTools.schemas(
            navigator: false, enabledCategories: enabledCategories, compactMode: compactMode)
        if let mcp {
            let mcpSchemas = await mcp.currentSchemas(audience: .delegate)
            if let enabledCategories {
                if enabledCategories.contains(.mcp) {
                    specs += mcpSchemas
                }
            } else {
                specs += mcpSchemas
            }
        }
        NSLog("[DELEGATE] -> '\(target.name)' (project='\(proj)') with \(specs.count) tools [resolved]")

        var subModelID = modelID
        var subBackend = backend
        var subMaxTokens = maxTokens
        if let delegateBackendResolver, let resolved = await delegateBackendResolver(target.id) {
            subModelID = resolved.modelID
            subBackend = resolved.backend
            subMaxTokens = resolved.maxTokens
        }
        let sub = AgentExecutor(
            modelID: subModelID, backend: subBackend,
            delegateBackendResolver: delegateBackendResolver)
        // Wire up live streaming so the target agent's UI shows activity.
        if let handler = delegateStreamHandler {
            sub.delegateStreamHandler = handler
        }
        var narration = ""
        var lastRoundText = ""
        // Notify handler and global sampler that delegation is starting.
        await MainActor.run {
            ProcessResourceSampler.shared.startSubagent(id: target.id.uuidString, name: target.name)
        }
        await delegateStreamHandler?.start()
        pendingDelegateEvents.append(.delegateStart(agentID: target.id.uuidString, modelID: subModelID))
        do {
            for try await output in sub.run(
                messages: messages, toolSpecs: specs, mcp: mcp,
                engine: nil, catalog: nil,
                temperature: 0.3, topP: 0.95, thinkingEnabled: false,
                project: proj.isEmpty ? nil : proj,
                workingDirectory: workingDirectory,
                agentID: target.id.uuidString,
                maxRounds: 6,
                maxTokens: subMaxTokens
            ) {
                switch output {
                case .token(let token):
                    narration += token
                    lastRoundText += token
                    // Forward token to live streaming handler and collect event.
                    await MainActor.run {
                        ProcessResourceSampler.shared.recordSubagentToken(id: target.id.uuidString)
                    }
                    await delegateStreamHandler?.token(token)
                    pendingDelegateEvents.append(.delegateToken(agentID: target.id.uuidString, token: token))
                case .toolCall:
                    lastRoundText = ""
                case .info, .turnBreak:
                    break
                case .delegateToken, .delegateStart, .delegateFinish:
                    break
                }
            }
        } catch {
            await MainActor.run {
                ProcessResourceSampler.shared.stopSubagent(id: target.id.uuidString)
            }
            await delegateStreamHandler?.finish()
            pendingDelegateEvents.append(.delegateFinish(agentID: target.id.uuidString))
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "delegate failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            ProcessResourceSampler.shared.stopSubagent(id: target.id.uuidString)
        }
        await delegateStreamHandler?.finish()
        pendingDelegateEvents.append(.delegateFinish(agentID: target.id.uuidString))
        let trimmedLast = lastRoundText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAnswer = trimmedLast.isEmpty
            ? narration.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedLast
        let answer = Self.stripThinkingTags(rawAnswer)
        guard !answer.isEmpty else {
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "agent finished without a text answer")
        }
        await MainActor.run {
            var msgs = messages
            msgs.append(Message(role: .assistant, content: answer))
            ChatHistoryStore.save(msgs, agentId: target.id)
        }
        return DelegateResult(project: proj, agent: target.name, answer: answer, error: nil)
    }

    /// `ask_project_agent` — delegate a single task and return its answer.
    private func delegate(argumentsJSON: String, mcp: MCPClientService?, workingDirectory: String? = nil) async -> String {
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
            projectName: req["project"] as? String, agentName: agentName, task: task, mcp: mcp,
            workingDirectory: workingDirectory)
        if let err = r.error { return MaestroTools.errorJSON(err) }
        return Self.json(["project": r.project, "agent": r.agent, "answer": r.answer ?? ""])
    }

    /// `ask_project_agents` — delegate to several agents and aggregate the answers.
    /// Runs the sub-agents SEQUENTIALLY: in-process MLX can only run one
    /// generation at a time, so concurrent task groups deadlock when two
    /// sub-agents fight for the same model.
    private func delegateMany(argumentsJSON: String, mcp: MCPClientService?, workingDirectory: String? = nil) async -> String {
        guard let requests = Self.parseDelegationRequests(argumentsJSON), !requests.isEmpty else {
            return MaestroTools.errorJSON(
                "ask_project_agents requires 'requests': a non-empty JSON array of "
                + "{project, agent, task} objects. Example: {\"requests\": "
                + "[{\"project\": \"Tests\", \"agent\": \"Agent1-test1\", "
                + "\"task\": \"Suggest one improvement to the auth plan.\"}]}")
        }
        NSLog("[DELEGATE] fan-out to \(requests.count) agent(s) — sequential")
        let parsed: [(project: String?, agent: String, task: String)] = requests.map {
            ($0["project"] as? String, ($0["agent"] as? String) ?? "", ($0["task"] as? String) ?? "")
        }
        // Pre-resolve ALL targets on MainActor before running any sub-agents.
        struct ResolvedTarget: Sendable {
            let project: String
            let target: AgentRecord
            let messages: [Message]
            let workingDirectory: String?
        }
        let resolved: [ResolvedTarget?] = await MainActor.run {
            guard let ws = MaestroTools.workspace else { return parsed.map { _ in nil } }
            return parsed.map { p in
                let target: AgentRecord?
                if let proj = p.project, !proj.trimmingCharacters(in: .whitespaces).isEmpty {
                    target = ws.findAgent(projectName: proj, agentName: p.agent)
                } else {
                    target = ws.agents.first {
                        $0.kind == .project && $0.name.caseInsensitiveCompare(p.agent) == .orderedSame
                    }
                }
                guard let target else { return nil }
                let proj = ws.projectName(for: target) ?? (p.project ?? "")
                let targetWD = target.workingDirectory
                    ?? UserDefaults.standard.string(forKey: "workingDir.\(target.id.uuidString)")
                    ?? workingDirectory
                if let targetWD, !targetWD.isEmpty,
                   !MaestroTools.delegatedAgentWorkingDirectories.contains(targetWD) {
                    MaestroTools.delegatedAgentWorkingDirectories.append(targetWD)
                }
                var msgs = ChatHistoryStore.load(agentId: target.id)
                    ?? [ChatViewModel.systemMessage(
                        for: target, projectName: proj.isEmpty ? nil : proj,
                        workingDirectory: targetWD)]
                msgs.append(Message(role: .user, content: p.task))
                return ResolvedTarget(
                    project: proj, target: target, messages: msgs,
                    workingDirectory: targetWD)
            }
        }
        // Run sequentially — MLX can only handle one generation at a time.
        var results: [[String: Any]] = []
        for (i, (p, res)) in zip(parsed, resolved).enumerated() {
            let r: DelegateResult
            if let resolved = res {
                r = await delegateOneResolved(
                    target: resolved.target, proj: resolved.project,
                    messages: resolved.messages, task: p.task, mcp: mcp,
                    workingDirectory: resolved.workingDirectory)
            } else {
                r = DelegateResult(project: p.project ?? "", agent: p.agent, answer: nil,
                    error: "no project agent named '\(p.agent)'")
            }
            if let err = r.error {
                results.append(["project": r.project, "agent": r.agent, "error": err])
            } else {
                results.append(["project": r.project, "agent": r.agent, "answer": r.answer ?? ""])
            }
            NSLog("[DELEGATE] \(i+1)/\(parsed.count) done: '\(r.agent)'")
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
    /// Strip XML thinking/channel tags from a string.
    /// Delegates to the shared stripper so all layers use the same patterns.
    private static func stripThinkingTags(_ text: String) -> String {
        ThinkingTagStripper.strip(text)
    }

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

    // MARK: - Memory safety & auto-save

    /// Tools that read file content or scan directories (count toward auto-save threshold).
    static let fileOpToolNames: Set<String> = [
        "read_file", "ocr_image", "list_dir",
        "index_directory", "spotlight_search",
        "index_document", "search_chunks", "read_chunk",
        "execute_sqlite",
    ]

    /// Rough token estimate: ~4 chars per token for English text.
    static func estimateTokens(_ msg: [String: Any]) -> Int {
        if let content = msg["content"] as? String {
            return content.count / 4
        }
        return 0
    }

    /// Check if system memory usage exceeds safe threshold.
    /// Uses a simple heuristic based on process memory and total RAM.
    static func checkMemoryPressure() -> Bool {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        // Get process memory usage via task_info
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return false }

        // If our process is using more than 40% of total RAM, trigger safety stop
        // (this leaves room for the OS, other apps, and model loading)
        let processBytes = info.resident_size
        let threshold = totalRAM * 4 / 10  // 40%
        return processBytes > threshold
    }

    /// Approximate token count of the full conversation.
    static func conversationTokenCount(_ convo: [[String: Any]]) -> Int {
        convo.reduce(0) { $0 + estimateTokens($1) }
    }

    /// File operation tools that count toward the auto-save threshold.
    static func isFileOpTool(_ name: String) -> Bool {
        fileOpToolNames.contains(name)
    }
}
