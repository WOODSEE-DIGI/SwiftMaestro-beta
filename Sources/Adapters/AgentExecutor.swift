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

/// One queued steer: the user's text plus any images they staged before
/// hitting send. Images ride along so a screenshot dropped mid-run reaches
/// the model on the very next round instead of being orphaned in the UI.
struct SteerPayload: Sendable {
    let text: String
    let images: [Data]
}

actor SteerInbox {
    private var pending: [SteerPayload] = []

    /// Queue a steer (no-ops when both text and images are empty).
    func append(_ text: String, images: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        pending.append(SteerPayload(text: trimmed, images: images))
    }

    /// Atomically return and clear all queued steers.
    func drainAll() -> [SteerPayload] {
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
    /// Callback when a delegation starts: (agentID, modelDisplayName).
    var onStart: ((String, String?) -> Void)?
    /// Callback to append a token: (agentID, token).
    var onToken: ((String, String) -> Void)?
    /// Callback when a delegation finishes: (agentID).
    var onFinish: ((String) -> Void)?

    func start(agentID: String, modelDisplayName: String?) {
        onStart?(agentID, modelDisplayName)
    }

    func token(agentID: String, _ text: String) {
        onToken?(agentID, text)
    }

    func finish(agentID: String) {
        onFinish?(agentID)
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
        maxToolCallsPerTool: [String: Int]? = nil,
        maxTokens: Int = 32768,
        steerInbox: SteerInbox? = nil,
        specsProvider: (@Sendable () async -> [ToolSpec])? = nil
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

                    // No iteration budget: local inference has no token cost and we
                    // are fully offline, so the agentic loop runs until the model
                    // stops requesting tools. Termination is user-driven (Stop
                    // button -> Task cancellation). `hardMaxRounds` is NOT a research
                    // limiter — it is a high runaway backstop that only fires on a
                    // pathological loop, so legitimate multi-round research/browse/
                    // crawl chains are never cut off early.
                    var round = 0
                    let hardMaxRounds = 100
                    var usedMutator = false      // a mutating tool ran this turn (verb-classified)
                    var lastRoundContent = ""    // previous round's cleaned text (anti-repeat guard)
                    var ditherRounds = 0         // CONSECUTIVE hesitation-only rounds ("Wait, I'll check…")
                    var autoNudges = 0           // CONSECUTIVE unproductive nudges
                    let maxAutoNudges = 4
                    var finalWrapUpSent = false  // bounded-run wrap-up issued
                    var fileOpCount = 0          // file ops since last auto-save
                    let autoSaveThreshold = 5    // trigger auto-save after N file ops
                    // Per-tool call budgets to stop small-model loops (e.g. web_search).
                    // Two tiers:
                    // - Content-mutation tools (plan/todo edits, file writes, note/
                    //   contact/calendar creation) get a generous cap: their
                    //   LEGITIMATE use is high-volume with varied args (checking off
                    //   a 20-step plan needs 20 edit_plan calls in one turn). True
                    //   loops are still caught by the identical-args guard and the
                    //   consecutive-failure breaker — a low count cap here only ever
                    //   punished real work.
                    // - Everything else keeps the small default, where repeated
                    //   calls with varied args are a known small-model loop pattern.
                    var effectivePerToolBudget = maxToolCallsPerTool ?? [:]
                    for name in Self.highVolumeMutationTools where effectivePerToolBudget[name] == nil {
                        effectivePerToolBudget[name] = Self.highVolumeMutationToolCap
                    }
                    let defaultPerToolCap = 5
                    for spec in toolSpecs {
                        if let name = MaestroTools.toolName(from: spec),
                           effectivePerToolBudget[name] == nil {
                            effectivePerToolBudget[name] = defaultPerToolCap
                        }
                    }
                    let perToolBudget = effectivePerToolBudget
                    var toolCallCounts: [String: Int] = [:]
                    var toolBudgetExceededNames = Set<String>()
                    // Consecutive-identical-FAILURE circuit breaker (stability only, not
                    // a work budget): stops a pathological loop where a small model keeps
                    // re-calling a tool it keeps malforming, failing the same way each
                    // time. Never fires on productive/varied/successful tool use.
                    var lastFailureSignature: String?
                    var consecutiveFailures = 0
                    // Tools hard-disabled this turn by the failure breaker. executeTool
                    // resolves against a global registry (not the per-round schema), so the
                    // only reliable stop is to intercept the call in the loop and skip it.
                    var disabledLoopTools = Set<String>()
                    // Repeated-identical-ARGS loop guard (a STUCK loop, not a failure):
                    // the failure breaker only fires on errors, but a small model can
                    // also re-call the SAME tool with the SAME arguments and get the
                    // SAME result forever — the 14:06 run re-read ONE LUNAR page NINE
                    // times (~8K context tokens per read) while the table stayed empty.
                    // Tracks (tool|args) counts: nudge+disable at 2, hard-stop at 3.
                    var repeatedArgsCounts: [String: Int] = [:]
                    var disabledArgCombos = Set<String>()
                    // BLIND-READ TRACKER: consecutive rounds where the model emits
                    // file-read tool calls with zero analysis content. Small models
                    // (Qwen 3 Coder, Gemma 4) get stuck reading the same file over
                    // and over without ever editing it. This catches the pattern
                    // BEFORE the per-args loop guard fires.
                    var blindReadCount = 0
                    // EMPTY-ARGS TRACKER: consecutive empty-args calls per tool
                    // name. Small models (Qwen 3 Coder Next) emit tool calls with
                    // {} args as context degrades — this catches the pattern and
                    // injects a nudge with required parameter names.
                    var emptyArgsCounts: [String: Int] = [:]
                    // DB-turn WRITE GUARD (research→DB rhythm): the 04:08 production
                    // run created the base/table/fields then browsed 36 rounds with
                    // ZERO db_add_rows calls — schema built, pages read, table left
                    // empty forever. Every guard on record watches failures or
                    // repeated args; none notices "N pages read, 0 rows written".
                    // Nudge after 2 unread reads, hard-block browser_open at 4+
                    // (browser_read/browser_links stay open for drilling), and
                    // re-arm everything after any successful db row write.
                    var dbWorkflowTurn = false      // any db_ tool succeeded this turn
                    var readsSinceLastDbWrite = 0   // page reads without an intervening db write
                    var dbWriteNudgeSent = false    // one-shot soft nudge (re-arms on write)
                    // Context budget: configurable via UserDefaults. This is a near-
                    // overflow backstop, not a research cut-off — the real context-
                    // window limit is handled by compaction (ChatViewModel) at the
                    // model's tunedContextLength. Default sits just under the largest
                    // supported context window (262K) so it only guards genuine runaway
                    // context growth within the loop.
                    let tokenBudget = UserDefaults.standard.object(forKey: "agent.contextTokenBudget") as? Int ?? 256_000
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
                                    if steer.images.isEmpty {
                                        convo.append(["role": "user", "content": steer.text])
                                    } else {
                                        // Multimodal steer: same content-array shape
                                        // wireMessage produces, so backend prep
                                        // (Gemma 4 last-user-image keep, generic
                                        // extraction) treats it like any image turn.
                                        var parts: [[String: Any]] = []
                                        if !steer.text.isEmpty {
                                            parts.append(["type": "text", "text": steer.text])
                                        }
                                        for data in steer.images {
                                            let uri = "data:image/png;base64,\(data.base64EncodedString())"
                                            parts.append(["type": "image_url", "image_url": ["url": uri]])
                                        }
                                        convo.append(["role": "user", "content": parts])
                                    }
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
                        // Panel-linked categories (Auto tool mode) follow the LIVE
                        // panel set — a frozen run-start snapshot went stale the
                        // moment open_panel fired, leaving the model calling app
                        // tools it had never seen schemas for (the fabricated
                        // MaestroDB import). Re-derive each round; this is an
                        // in-memory rebuild, cheap at round cadence.
                        var specsThisRound = toolSpecs
                        if let specsProvider {
                            specsThisRound = await specsProvider()
                        }
                        // Enforce per-tool call budgets: once a tool's budget is exceeded,
                        // remove it from the schemas so the model cannot call it again.
                        if !toolBudgetExceededNames.isEmpty {
                            specsThisRound = specsThisRound.filter { spec in
                                guard let name = MaestroTools.toolName(from: spec) else { return true }
                                return !toolBudgetExceededNames.contains(name)
                            }
                        }
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
                        // CONTEXT RECYCLING: elide stale tool results BEFORE generating.
                        // The agent's job is open → read → extract → move on — the
                        // database (and its own reasoning) is the memory, NOT 37 stale
                        // page dumps accumulating until MLX hits metal::malloc at ~70K
                        // tokens (the 14:39 crash). Keep only the last few results full.
                        Self.elideOldToolResults(&convo)

                        let (content, rawToolCalls) = try await backend.streamRound(
                            convo: convo,
                            toolSpecs: specsThisRound,
                            temperature: temperature,
                            topP: topP,
                            thinkingEnabled: thinkingEnabled,
                            maxTokens: maxTokens,
                            continuation: continuation
                        )
                        // Strip any thinking/channel tags that the model streamed into the
                        // text content before we use it for heuristics, nudges, or history.
                        // This keeps <channel>/</channel> markers from leaking into the
                        // conversation and from confusing the shell-command recovery path.
                        let strippedContent = ThinkingTagStripper.strip(content)
                        let cleanContent = Self.stripRawToolCallXML(strippedContent)
                        let callNames = rawToolCalls.map { $0.name }.joined(separator: ", ")
                        if rawToolCalls.isEmpty {
                            let preview = cleanContent.prefix(200).replacingOccurrences(of: "\n", with: "\\n")
                            NSLog("[AGENT] round \(round): tools=\(specsThisRound.count) content=\(cleanContent.count) chars, toolCalls=[] — content preview: \(preview)")
                        } else {
                            NSLog("[AGENT] round \(round): tools=\(specsThisRound.count) content=\(cleanContent.count) chars, toolCalls=[\(callNames)]")
                        }

                        // BLIND-READ DETECTOR: if the model emits file-read tool
                        // calls with zero content text, it's not analyzing — just
                        // mechanically re-reading. Inject a forceful nudge to break
                        // the pattern before the tools even execute.
                        if cleanContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !rawToolCalls.isEmpty {
                            let fileReadTools: Set<String> = ["read_file", "read_file_range",
                                                               "read_directory", "list_directory"]
                            let allReads = rawToolCalls.allSatisfy { fileReadTools.contains($0.name) }
                            if allReads {
                                blindReadCount += 1
                                if blindReadCount >= 2 {
                                    NSLog("[AGENT] BLIND READ: \(blindReadCount) consecutive rounds with zero-content file reads — injecting nudge")
                                    let nudgeMsg = "SYSTEM: CRITICAL — you have now made "
                                        + "\(blindReadCount) consecutive rounds of file reads with "
                                        + "ZERO analysis text. Reading without thinking is token burn. "
                                        + "You MUST now: (1) state what you learned from the file, "
                                        + "(2) identify the specific problem to fix, "
                                        + "(3) use edit_file or write_file to make the change. "
                                        + "If edit_file fails with 'old_string not found', the file "
                                        + "was already modified — re-read it ONCE, then edit the "
                                        + "CURRENT content. Do NOT call read_file more than once."
                                    convo.append([
                                        "role": "user",
                                        "content": nudgeMsg,
                                    ])
                                }
                            } else {
                                blindReadCount = 0
                            }
                        } else {
                            blindReadCount = 0
                        }

                        // EMPTY-ARGS PRE-EXECUTION DETECTOR: if every tool call
                        // in this round has empty args ({}), the model is emitting
                        // tool names but forgetting parameters — a sign of context
                        // degradation. Inject a nudge BEFORE execution to avoid
                        // wasting tokens on error responses.
                        if !rawToolCalls.isEmpty
                            && rawToolCalls.allSatisfy({
                                $0.arguments.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
                            }) {
                            let toolNames = rawToolCalls.map(\.name).joined(separator: ", ")
                            NSLog("[AGENT] EMPTY ARGS PRE-EXEC: all calls have empty args: \(toolNames)")
                            // Let the first call execute so the model sees the error,
                            // but append a nudge after the round for the remaining ones.
                        }

                        // Fallback: some backends (notably Gemma 4 with the .gemma4
                        // format) stream raw XML tool-call blocks without surfacing them
                        // as parsed `.toolCall` events. If the backend parsed nothing,
                        // extract any raw XML blocks from the assistant text and use them
                        // as the effective calls. When the backend already parsed calls,
                        // skip the fallback to avoid duplicate executions.
                        let rawXMLCalls = rawToolCalls.isEmpty
                            ? Self.extractToolCallsFromRawXML(strippedContent, toolSpecs: specsThisRound)
                            : []
                        var effectiveToolCalls = rawToolCalls + rawXMLCalls
                        // Fallback: if the model emitted an execute_command call but the
                        // XML parser returned an empty/missing `command` argument, recover
                        // the command from the assistant's text (fenced block, command-like
                        // line, or raw XML) so it actually runs.
                        effectiveToolCalls = Self.recoverShellCommands(in: effectiveToolCalls, from: strippedContent)

                        guard !Task.isCancelled else { break iterations }
                        // The forced wrap-up round IS the final answer.
                        if finalWrapUpSent { break iterations }

                        // Anti-repeat guard: a tool-free round whose content is
                        // IDENTICAL to the previous round's has nothing new to
                        // say. Ending here (instead of evaluating nudges) stops
                        // nudge loops that forced the model to re-emit the same
                        // claim over and over — each copy streamed into the
                        // chat bubble (the "Test message sent to X.X.X.X.X"
                        // duplication the user reported).
                        if effectiveToolCalls.isEmpty,
                           !cleanContent.isEmpty,
                           cleanContent == lastRoundContent {
                            NSLog("[AGENT] round \(round): identical content to previous round — ending turn without nudging")
                            break iterations
                        }
                        lastRoundContent = cleanContent

                        if effectiveToolCalls.isEmpty {
                            // DITHER BUDGET: a round with no tool call whose
                            // content is hesitation narration ("Wait, I'll
                            // check…", "Actually, let me verify…") gets ONE
                            // chance; two consecutive hesitation rounds force a
                            // tool-free final answer. Without this, a small
                            // model second-guesses itself across nudge cycles
                            // and streams multi-thousand-char walls of "Wait"
                            // (confirmed live: an 8.5K-char single bubble).
                            if !finalWrapUpSent, Self.containsHesitation(cleanContent) {
                                ditherRounds += 1
                                if ditherRounds >= 2 {
                                    NSLog("[AGENT] dither budget hit after \(ditherRounds) hesitation rounds — forcing final answer")
                                    finalWrapUpSent = true
                                    convo.append(["role": "assistant", "content": cleanContent])
                                    convo.append([
                                        "role": "user",
                                        "content":
                                            "[automated check — NOT a message from the user] Stop "
                                            + "re-checking. You already have enough information. "
                                            + "Do NOT call any more tools and do NOT narrate further "
                                            + "hesitation — give your final answer to the original "
                                            + "request now, as plain concise text.",
                                    ])
                                    continue iterations
                                }
                            } else if !Self.containsHesitation(cleanContent) {
                                ditherRounds = 0
                            }

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
                            // A message asking the USER for something (folder
                            // authorization, permission, credentials, install)
                            // is a legitimate terminal answer, not a stall —
                            // the model CANNOT proceed without the user's
                            // action, so nudging it to "emit the tool call" is
                            // pointless and just manufactures repeated text
                            // (the LaunchAgents authorization-ask loop).
                            let asksUser = Self.asksUserForAction(cleanContent)
                            if !specsThisRound.isEmpty, autoNudges < maxAutoNudges, !asksUser,
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
                        // A real tool call means the last nudge (if any) worked — reset
                        // the budget so it caps CONSECUTIVE refusals, not total nudges.
                        // Multi-step tasks (scrape -> blocked -> search -> retry) need
                        // more than 2 follow-throughs per turn; refuse-loops still
                        // terminate after 2 nudges in a row without a tool call.
                        autoNudges = 0
                        if effectiveToolCalls.contains(where: {
                            Self.agentScopedTools.contains($0.name)
                                || Self.nonInjectedMutators.contains($0.name)
                                || Self.isMutatorToolName($0.name)
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
                            // Reset empty-args counter when the model provides args.
                            if tc.arguments.trimmingCharacters(in: .whitespacesAndNewlines) != "{}" {
                                emptyArgsCounts[tc.name] = 0
                            }
                            // Failure-breaker hard stop: a tool disabled after repeated
                            // identical failures is intercepted here (executeTool resolves
                            // against a global registry, so it would still run otherwise).
                            // Return a synthetic error instead of executing so the loop ends.
                            if disabledLoopTools.contains(tc.name) {
                                NSLog("[AGENT] FAILURE BREAKER: intercepted call to disabled \(tc.name)")
                                convo.append([
                                    "role": "tool",
                                    "tool_call_id": tc.id,
                                    "content": "{\"error\":\"\(tc.name) is disabled for the rest of this turn "
                                        + "after repeated identical failures. Do NOT call it again. In your final "
                                        + "answer you MUST quote the exact error message to the user and name "
                                        + "\(tc.name) as the failing tool — do not hide the failure behind vague "
                                        + "phrases like 'technical issues'.\"}",
                                ])
                                continue
                            }
                            // Loop-guard hard stop: this exact (tool + arguments) combo
                            // already ran 4+ times this turn. Identical inputs mean
                            // identical outputs — re-executing is pure token burn (the
                            // 14:06 run re-read ONE page NINE times). Intercept with a
                            // synthetic error instead of executing.
                            // Normalized signature: escape-junk growth on retries
                            // (" → \" → \\\" → …) mutates the raw args each round,
                            // which used to RESET every loop counter — the 17-round
                            // db_add_field meltdown was invisible to this guard.
                            let argSignature = Self.normalizedGuardSignature(tc.name + "|" + tc.arguments)
                            if disabledArgCombos.contains(argSignature) {
                                NSLog("[AGENT] LOOP GUARD: intercepted repeated call \(tc.name) (these args already ran 3+ times)")
                                let isFileRead = tc.name == "read_file" || tc.name == "read_file_range"
                                    || tc.name == "read_directory" || tc.name == "list_directory"
                                let errorMsg: String
                                if isFileRead {
                                    errorMsg = "BLOCKED: You have already read this file with these EXACT "
                                        + "arguments multiple times. You have the contents — use edit_file "
                                        + "to fix the issue or write_file to replace the file. Do NOT "
                                        + "repeat this read."
                                } else {
                                    errorMsg = "BLOCKED: You have already run \(tc.name) with these EXACT "
                                        + "arguments multiple times and received the identical result. The page "
                                        + "has not changed — the data you need is NOT there. Do NOT repeat this "
                                        + "call. Use browser_links to find a different page, or enter the data "
                                        + "you already have with db_add_rows now."
                                }
                                convo.append([
                                    "role": "tool",
                                    "tool_call_id": tc.id,
                                    "content": "{\"error\":\"\(errorMsg)\"}",
                                ])
                                continue
                            }
                            // Write-guard hard stop: in a database workflow turn,
                            // opening a 4th+ page without having written a single row
                            // means the table stays empty while context burns.
                            // browser_read/browser_links remain available so the model
                            // can still drill product pages — only NEW opens are blocked
                            // until a write lands. Any successful db write re-arms this.
                            if tc.name == "browser_open", dbWorkflowTurn, readsSinceLastDbWrite >= 4 {
                                NSLog("[AGENT] WRITE GUARD: blocked browser_open after \(readsSinceLastDbWrite) reads with no db write")
                                let wgMsg = "{\"error\":\"browser_open is blocked: you have read "
                                    + "\(readsSinceLastDbWrite) pages without saving ANYTHING to your "
                                    + "table. Call db_add_rows NOW with the data you already have "
                                    + "(2-3 rows), then browsing resumes. If earlier pages had no "
                                    + "usable data, use browser_links on an open tab to drill to a "
                                    + "PRODUCT page instead of opening new URLs.\"}"
                                convo.append([
                                    "role": "tool",
                                    "tool_call_id": tc.id,
                                    "content": wgMsg,
                                ])
                                continue
                            }
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
                                    "content": Self.truncatedToolResult(result),
                                ])
                            }
                            // Write-guard bookkeeping: a successful db row write resets
                            // the unread-reads counter (and re-arms the nudge); each
                            // successful page READ increments it. The soft nudge fires
                            // once per lull at 2 unread reads; the hard block (above)
                            // fires at 4+.
                            if !result.hasPrefix("{\"error\"") {
                                if tc.name.hasPrefix("db_") { dbWorkflowTurn = true }
                                switch tc.name {
                                case "db_add_row", "db_add_rows", "db_upsert_rows",
                                     "db_update_row", "db_import_csv":
                                    readsSinceLastDbWrite = 0
                                    dbWriteNudgeSent = false
                                case "browser_read", "deep_fetch", "web_crawl", "fetch_url":
                                    readsSinceLastDbWrite += 1
                                    if dbWorkflowTurn, readsSinceLastDbWrite == 2, !dbWriteNudgeSent {
                                        dbWriteNudgeSent = true
                                        NSLog("[AGENT] WRITE GUARD: 2 unread reads in db turn — nudging db_add_rows")
                                        convo.append([
                                            "role": "user",
                                            "content": "SYSTEM: you have read 2 pages in a database task WITHOUT saving any rows — the table stays empty while you keep browsing. Call db_add_rows RIGHT NOW with whatever data you have already collected (2-3 rows is fine — saved data beats held data), THEN continue browsing. If the pages you read had no usable data, call browser_links on one of them to find PRODUCT pages instead of opening more listing pages.",
                                        ])
                                    }
                                default: break
                                }
                            }
                            // Repeated-args loop guard: count (tool|args) regardless of
                            // success — identical inputs mean identical outputs, so
                            // re-calling is pure token burn. Nudge AND disable at 2,
                            // hard-stop at 3. (The failure breaker below only sees
                            // ERRORS; this sees the "successful" stuck loop, like
                            // 9 identical page reads.)
                            repeatedArgsCounts[argSignature, default: 0] += 1
                            let argRepeats = repeatedArgsCounts[argSignature] ?? 1
                            if argRepeats == 2, !result.hasPrefix("{\"error\"") {
                                let isFileRead = tc.name == "read_file" || tc.name == "read_file_range"
                                    || tc.name == "read_directory" || tc.name == "list_directory"
                                let nudgeMessage: String
                                if isFileRead {
                                    nudgeMessage = "SYSTEM: WARNING — you have now called \(tc.name) TWICE "
                                        + "with identical arguments and received identical results. "
                                        + "You have the file contents. STOP re-reading. You MUST now "
                                        + "use edit_file or write_file to make changes. If you call "
                                        + "\(tc.name) a third time with these args it will be BLOCKED."
                                } else {
                                    nudgeMessage = "SYSTEM: WARNING — you have now called \(tc.name) TWICE "
                                        + "with identical arguments and received identical results. "
                                        + "The data has not changed. Do NOT call it again with these "
                                        + "arguments. Use a different approach or move on."
                                }
                                convo.append([
                                    "role": "user",
                                    "content": nudgeMessage,
                                ])
                                // Also disable NOW so the 3rd call is blocked even if
                                // the model ignores the nudge in this same round.
                                disabledArgCombos.insert(argSignature)
                            } else if argRepeats >= 3, !disabledArgCombos.contains(argSignature) {
                                disabledArgCombos.insert(argSignature)
                                NSLog("[AGENT] LOOP GUARD: disabled \(tc.name) with these args after \(argRepeats) identical calls")
                            }
                            // EMPTY-ARGS NUDGE: when a tool call arrives with no
                            // arguments ({}), the model emitted the tool name but
                            // forgot the parameters. Inject a one-time nudge with
                            // the required parameter names so it can self-correct
                            // instead of retrying blindly (Qwen 3 Coder Next: 30+
                            // rounds of `read_file` with empty args).
                            //
                            // SPEC-AWARE: only nudge when the tool actually has
                            // required parameters. Tools like list_background_processes
                            // take no args — {} is correct for them and nudging
                            // confuses the model into sending wrong params.
                            //
                            // FALLBACK MAP: when a tool has been budget-exhausted,
                            // it's removed from specsThisRound, so the spec lookup
                            // returns nil and the breaker never fires. A hardcoded
                            // map of known tools with required params ensures the
                            // breaker works even after budget exhaustion.
                            if tc.arguments == "{}" || tc.arguments.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
                                // Look up the tool spec to find required params.
                                // Try specsThisRound first; fall back to hardcoded map.
                                let requiredParams: [String] = {
                                    if let spec = specsThisRound.first(where: {
                                        MaestroTools.toolName(from: $0) == tc.name
                                    }),
                                    let function = spec["function"] as? [String: any Sendable],
                                    let parameters = function["parameters"] as? [String: any Sendable],
                                    let required = parameters["required"] as? [String] {
                                        return required
                                    }
                                    // Hardcoded fallback: known tools that ALWAYS require
                                    // params. This prevents the breaker from being skipped
                                    // when the tool is budget-exhausted and absent from
                                    // specsThisRound.
                                    let knownRequired: [String: [String]] = [
                                        "read_file": ["path"],
                                        "edit_file": ["path", "old_string", "new_string"],
                                        "write_file": ["path", "content"],
                                        "execute_command": ["command"],
                                        "search_replace": ["path", "old", "new"],
                                        "fetch_url": ["url"],
                                        "send_agent_message": ["to_agent", "message"],
                                        "browser_open": ["url"],
                                        "browser_type": ["ref", "text"],
                                        "browser_click": ["ref"],
                                        "browser_press_key": ["key"],
                                        "browser_select_option": ["ref", "value"],
                                        "browser_scroll": ["ref"],
                                        "browser_evaluate": ["code"],
                                        "browser_wait": [],
                                        "open_panel": ["panel"],
                                        "create_todo_list": ["todos"],
                                        "create_plan": ["plan"],
                                        "edit_plan": ["plan"],
                                        "db_create_base": ["name"],
                                        "db_create_table": ["base_id", "name"],
                                        "db_add_field": ["base_id", "table_id", "field_name"],
                                        "db_add_rows": ["base_id", "table_id", "rows"],
                                        "db_add_row": ["base_id", "table_id", "row"],
                                        "db_upsert_rows": ["base_id", "table_id", "rows"],
                                        "db_list_rows": ["base_id", "table_id"],
                                        "db_table_schema": ["base_id", "table_id"],
                                    ]
                                    return knownRequired[tc.name] ?? []
                                }()
                                // Skip nudge entirely for tools with no required params.
                                if requiredParams.isEmpty {
                                    NSLog("[AGENT] EMPTY ARGS: \(tc.name) called with {} but has no required params — skipping nudge")
                                } else {
                                    emptyArgsCounts[tc.name, default: 0] += 1
                                    if emptyArgsCounts[tc.name] == 1 {
                                        let paramList = requiredParams.joined(separator: ", ")
                                        NSLog("[AGENT] EMPTY ARGS: \(tc.name) called with {} — nudging (required: \(paramList))")
                                        convo.append([
                                            "role": "user",
                                            "content":
                                                "[automated check — NOT a message from the user] "
                                                + "You called \(tc.name) with EMPTY arguments ({}). "
                                                + "This tool REQUIRES these parameters: \(paramList). "
                                                + "Call it again with the correct arguments. "
                                                + "Do NOT call it without arguments.",
                                        ])
                                    } else if let count = emptyArgsCounts[tc.name], count >= 3, !disabledLoopTools.contains(tc.name) {
                                        disabledLoopTools.insert(tc.name)
                                        NSLog("[AGENT] EMPTY ARGS BREAKER: disabled \(tc.name) after \(count) empty-args calls")
                                        convo.append([
                                            "role": "tool",
                                            "tool_call_id": tc.id,
                                            "content": "{\"error\":\"\(tc.name) is disabled for the rest of this turn "
                                                + "after \(count) consecutive calls with empty arguments. "
                                                + "Required parameters: \(requiredParams.joined(separator: ", ")). "
                                                + "Do NOT call it again.\"}",
                                        ])
                                        continue
                                    }
                                }
                            }
                            // Consecutive-identical-failure circuit breaker. If the same
                            // tool keeps returning the same error, first nudge with a
                            // corrective message, then remove it so the agent must move on.
                            if result.hasPrefix("{\"error\"") {
                                // Normalized here too: the corrupted junk INSIDE the
                                // error message grows each retry, so the raw prefix
                                // always looked like a NEW failure to the breaker.
                                let signature = Self.normalizedGuardSignature(tc.name + "|" + String(result.prefix(80)))
                                consecutiveFailures = (signature == lastFailureSignature) ? consecutiveFailures + 1 : 1
                                lastFailureSignature = signature
                                if consecutiveFailures == 4 {
                                    convo.append([
                                        "role": "user",
                                        "content":
                                            "SYSTEM: \(tc.name) has failed \(consecutiveFailures) times in a row "
                                            + "with the SAME error. Your arguments are malformed. Do NOT keep "
                                            + "retrying the identical call — read the error, compare it against "
                                            + "the tool's parameter spec, fix the argument format, and try ONCE "
                                            + "more with DIFFERENT arguments. If you still can't fix it, skip "
                                            + "this step and quote the exact error text to the user in your "
                                            + "final answer.",
                                    ])
                                } else if consecutiveFailures >= 6, !disabledLoopTools.contains(tc.name) {
                                    disabledLoopTools.insert(tc.name)
                                    NSLog("[AGENT] FAILURE BREAKER: disabled \(tc.name) after \(consecutiveFailures) consecutive identical failures")
                                    convo.append([
                                        "role": "user",
                                        "content":
                                            "SYSTEM: \(tc.name) kept failing with the same error and has been disabled "
                                            + "for the rest of this turn. Stop calling it. REQUIRED: in your final "
                                            + "answer you must (1) quote the exact error message, (2) name \(tc.name) "
                                            + "as the tool that failed, and (3) explain what you were trying to do. "
                                            + "Do NOT gloss over this with vague phrases like 'technical issues', and "
                                            + "do NOT silently work around the failure with a different tool — the "
                                            + "user needs to know the direct path is broken so it can be fixed.",
                                    ])
                                }
                            } else {
                                consecutiveFailures = 0
                                lastFailureSignature = nil
                            }
                            // AUTO-SAVE TRIGGER: Track file operations and inject
                            // save reminder after threshold is reached.
                            if Self.isFileOpTool(tc.name) {
                                fileOpCount += 1
                                if fileOpCount >= autoSaveThreshold && !finalWrapUpSent {
                                    NSLog("[AGENT] AUTO-SAVE: \(fileOpCount) file ops reached threshold")
                                    let hasEditTools = convo.contains { ($0["content"] as? String ?? "").contains("edit_file") }
                                    let saveMsg: String
                                    if hasEditTools {
                                        saveMsg = "SYSTEM: You've performed \(fileOpCount) file operations "
                                            + "including edits. Pause and verify your changes compile — run "
                                            + "xcodebuild or the project's build command. If there are errors, "
                                            + "fix them before continuing."
                                    } else {
                                        saveMsg = "SYSTEM: You've performed \(fileOpCount) file read operations. "
                                            + "You should have enough context now — use edit_file to make the "
                                            + "needed changes, or write_file to create/replace files. Do NOT "
                                            + "keep reading without acting."
                                    }
                                    convo.append([
                                        "role": "user",
                                        "content": saveMsg,
                                    ])
                                    fileOpCount = 0
                                }
                            }
                            // Per-tool budget tracking: stop small-model loops on a single tool.
                            toolCallCounts[tc.name, default: 0] += 1
                            if let budget = perToolBudget[tc.name],
                               toolCallCounts[tc.name] == budget,
                               !toolBudgetExceededNames.contains(tc.name) {
                                toolBudgetExceededNames.insert(tc.name)
                                NSLog("[AGENT] TOOL BUDGET: \(tc.name) reached limit of \(budget)")
                                convo.append([
                                    "role": "user",
                                    "content":
                                        "SYSTEM: You have already called \(tc.name) "
                                        + "\(budget) time\(budget == 1 ? "" : "s"). "
                                        + "Do NOT call \(tc.name) again. Use the results you already "
                                        + "have and provide your final answer now.",
                                ])
                            }
                        }
                        // POST-EXECUTION EMPTY-ARGS NUDGE: if tool calls in
                        // this round had empty args and returned errors, inject a
                        // consolidated nudge with the required param names.
                        // SPEC-AWARE: only include tools that actually have required
                        // params — tools with no params (e.g. list_background_processes)
                        // are correct with {}.
                        // Uses the same hardcoded fallback map as the pre-execution
                        // nudge to handle budget-exhausted tools absent from specsThisRound.
                        let knownRequiredArgs: [String: [String]] = [
                            "read_file": ["path"],
                            "edit_file": ["path", "old_string", "new_string"],
                            "write_file": ["path", "content"],
                            "execute_command": ["command"],
                            "search_replace": ["path", "old", "new"],
                            "fetch_url": ["url"],
                            "send_agent_message": ["to_agent", "message"],
                            "browser_open": ["url"],
                            "browser_type": ["ref", "text"],
                            "browser_click": ["ref"],
                            "browser_press_key": ["key"],
                            "browser_select_option": ["ref", "value"],
                            "browser_scroll": ["ref"],
                            "browser_evaluate": ["code"],
                            "open_panel": ["panel"],
                            "create_todo_list": ["todos"],
                            "create_plan": ["plan"],
                            "edit_plan": ["plan"],
                            "db_create_base": ["name"],
                            "db_create_table": ["base_id", "name"],
                            "db_add_field": ["base_id", "table_id", "field_name"],
                            "db_add_rows": ["base_id", "table_id", "rows"],
                            "db_add_row": ["base_id", "table_id", "row"],
                            "db_upsert_rows": ["base_id", "table_id", "rows"],
                            "db_list_rows": ["base_id", "table_id"],
                            "db_table_schema": ["base_id", "table_id"],
                        ]
                        let toolsNeedingParams = effectiveToolCalls.filter { tc in
                            tc.arguments.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
                            && (
                                // Check specsThisRound first
                                specsThisRound.contains(where: {
                                    guard let name = MaestroTools.toolName(from: $0),
                                          name == tc.name,
                                          let function = $0["function"] as? [String: any Sendable],
                                          let parameters = function["parameters"] as? [String: any Sendable],
                                          let required = parameters["required"] as? [String] else { return false }
                                    return !required.isEmpty
                                })
                                // Fall back to hardcoded map for budget-exhausted tools
                                || (knownRequiredArgs[tc.name]?.isEmpty == false)
                            )
                        }
                        if !toolsNeedingParams.isEmpty {
                            let toolDetails = toolsNeedingParams.compactMap { tc -> String? in
                                // Try specsThisRound first, fall back to hardcoded map
                                let required: [String]
                                if let spec = specsThisRound.first(where: {
                                    MaestroTools.toolName(from: $0) == tc.name
                                }),
                                let function = spec["function"] as? [String: any Sendable],
                                let parameters = function["parameters"] as? [String: any Sendable],
                                let req = parameters["required"] as? [String] {
                                    required = req
                                } else if let fallback = knownRequiredArgs[tc.name] {
                                    required = fallback
                                } else {
                                    return nil
                                }
                                return "\(tc.name)(required: \(required.joined(separator: ", ")))"
                            }
                            let detailList = toolDetails.joined(separator: ", ")
                            NSLog("[AGENT] POST-EXEC EMPTY ARGS: tools needing params: \(detailList)")
                            convo.append([
                                "role": "user",
                                "content":
                                    "[automated check — NOT a message from the user] "
                                    + "Tool calls with EMPTY arguments ({}): \(detailList). "
                                    + "You MUST include the required parameters listed above. "
                                    + "Do NOT emit tool calls without parameters.",
                            ])
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
        // Question-stalls and soft-future narration MUST come before the
        // "plan"/"todo" branches below — stall text almost always mentions the
        // plan it just created, and steering it to create_plan/edit_plan again
        // would make the model redundantly RE-RUN the planning tool instead of
        // executing the plan.
        let questionStalls = [
            "shall i proceed", "shall i continue", "shall i start",
            "should i proceed", "should i continue", "should i start",
            "would you like me to", "do you want me to",
            "let me know if you'd like", "let me know when",
            "let me know if you would like",
        ]
        if questionStalls.contains(where: { t.contains($0) }) {
            return "Do NOT ask for confirmation — the user already asked for this task. "
                + "Start executing the FIRST unfinished step of your plan RIGHT NOW with "
                + "the appropriate tool call (e.g. open_panel, browser_open, db_create_base). "
                + "Only if you genuinely cannot proceed without information only the user "
                + "has, explain exactly what you need in one short sentence."
        }
        let softFutures = [
            "i will aim", "i'll aim", "i will attempt", "i'll attempt",
            "i will try", "i'll try", "i will capture", "i'll capture",
            "i will populate", "i'll populate", "i will research", "i'll research",
        ]
        if softFutures.contains(where: { t.contains($0) }) {
            return "Do not announce what you will do — do it. Emit the tool call that "
                + "performs the FIRST step of what you just described (e.g. browser_open "
                + "for research, db_add_rows for data entry) with correct arguments, now."
        }
        // Tool-invocation spirals: "Wait, I'll call db_create_base…" ×20 with no
        // call ever emitted. MUST come before the "plan" branch — spiral content
        // always mentions its plan, and steering it to edit_plan instead of the
        // tool it's circling would send it deeper into the weeds.
        let callIntents = [
            "i'll call ", "i will call ", "let me call ", "i'll run ",
            "i will run ", "let me run ", "i'll execute ", "i will execute ",
        ]
        if callIntents.contains(where: { t.contains($0) }) {
            let spiralTools = [
                "db_create_base", "db_create_table", "db_add_field", "db_add_rows",
                "db_upsert_rows", "db_add_row", "db_list_rows", "db_list_bases",
                "db_table_schema", "browser_open", "browser_read", "open_panel",
                "web_search", "fetch_url", "create_todo_list", "create_plan",
                "get_current_time",
            ]
            if let tool = spiralTools.first(where: { t.contains($0) }) {
                return "You keep saying you'll call \(tool) but you haven't. Stop "
                    + "deliberating about whether you're allowed to call it — you ARE. "
                    + "Emit the \(tool) tool call NOW with correct arguments and nothing else."
            }
            return "You keep announcing a tool call without emitting it. Emit the tool "
                + "call NOW — no more deliberation about whether you're allowed."
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
    static func claimsFutureAction(_ text: String) -> Bool {
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
            // "Proceeding" phrasing — the 03:28 stall: the model ended its
            // turn with "I am now proceeding to find the source files…" (a
            // promise of work, no tool call) and NO existing pattern matched,
            // so nothing nudged it and the run silently parked for 6 hours.
            "i am now proceeding", "i'm now proceeding", "i am proceeding to",
            "i'm proceeding to", "now proceeding to", "proceeding to find",
            "i will proceed", "i'll proceed", "proceeding with the next",
            "step 1:", "step 2:", "step 3:", "step 4:", "step 5:",
            "first, i will", "then i will", "finally, i will",
            "first, i'll", "then i'll", "finally, i'll",
            // Soft future intent — the model's favourite stall vocabulary
            // ("I will aim to capture…", "I will attempt to populate…").
            "i will aim", "i'll aim", "i will attempt", "i'll attempt",
            "i will try", "i'll try", "i will seek", "i'll seek",
            "i will capture", "i'll capture", "i will populate", "i'll populate",
            "i will research", "i'll research", "i will search", "i'll search",
            "i will browse", "i'll browse", "i will start", "i'll start",
            // Tool-invocation intent — THE most common stall phrase: "Wait,
            // I'll call db_create_base…" repeated 20 times with no call ever
            // emitted (Gemma 4 reasoning spiral, 06:18 run).
            "i'll call", "i will call", "let me call", "i'll run",
            "i will run", "let me run", "i'll execute", "i will execute",
            "i'll invoke", "i will invoke", "i'll emit", "i will emit",
            // Question-stalls — ending the turn by asking permission instead
            // of executing ("Shall I proceed?", "Would you like me to
            // continue?"). The user already asked for the task; asking again
            // is a tool-use failure. The nudge explicitly permits a genuine
            // final answer, so a real clarifying question still gets through.
            "shall i proceed", "shall i continue", "shall i start",
            "should i proceed", "should i continue", "should i start",
            "would you like me to", "do you want me to",
            "let me know if you'd like", "let me know when",
            "let me know if you would like"]
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

    /// Parameter-shape information for a tool, used by the XML fallback parser to
    /// map bare `<parameter>` values onto the correct key.
    internal struct ToolParameterInfo {
        let required: [String]
        let all: Set<String>
    }

    /// Build a map from tool name to the parameter names declared in its OpenAI
    /// function schema. The XML fallback parser uses this to pair bare
    /// `<parameter>` siblings (e.g. `<parameter>query</parameter><parameter>swift</parameter>`)
    /// and to fall back to the first required parameter when only a single bare
    /// value is provided.
    private static func parameterNamesMap(from specs: [ToolSpec]) -> [String: ToolParameterInfo] {
        var map: [String: ToolParameterInfo] = [:]
        for spec in specs {
            guard let name = MaestroTools.toolName(from: spec) else { continue }
            let function = spec["function"] as? [String: any Sendable]
            let parameters = function?["parameters"] as? [String: any Sendable]
            let properties = parameters?["properties"] as? [String: any Sendable] ?? [:]
            let required = parameters?["required"] as? [String] ?? []
            map[name] = ToolParameterInfo(required: required, all: Set(properties.keys))
        }
        return map
    }

    /// Extract all `key="value"` attributes from an XML tag fragment.
    private static func parseXMLAttributes(_ text: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let attrPattern = #"([a-zA-Z0-9_]+)=\"([^\"]*)\""#
        guard let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: []) else { return attrs }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in attrRegex.matches(in: text, options: [], range: nsRange) {
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let valRange = Range(match.range(at: 2), in: text) else { continue }
            attrs[String(text[keyRange])] = String(text[valRange])
        }
        return attrs
    }

    /// Fallback parser for raw XML tool-call blocks that the backend's native
    /// parser missed. Handles both well-formed `<tool_call><function=x>...</function></tool_call>`
    /// and the partial/bare `<function=x>...</function>` blocks that small models like
    /// Qwen 3 Coder emit when they drop the outer `<tool_call>` wrapper.
    /// `toolSpecs` provides the parameter names so bare `<parameter>` values can be
    /// paired/mapped onto the correct key (e.g. `query` for `web_search`).
    internal static func extractToolCallsFromRawXML(_ text: String, toolSpecs: [ToolSpec] = []) -> [RoundToolCall] {
        var calls: [RoundToolCall] = []
        var matchedRanges: [Range<String.Index>] = []
        let parameterInfoByName = parameterNamesMap(from: toolSpecs)

        // First pass: fully-wrapped <tool_call> blocks. The inner body is what we parse.
        let toolCallPattern = #"(?s)<tool_call>(.*?)</tool_call>"#
        if let regex = try? NSRegularExpression(pattern: toolCallPattern, options: []) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                guard let blockRange = Range(match.range, in: text),
                      let innerRange = Range(match.range(at: 1), in: text) else { continue }
                if let call = parseXMLToolCallBlock(String(text[innerRange]), parameterInfoByName: parameterInfoByName) {
                    calls.append(call)
                    matchedRanges.append(blockRange)
                }
            }
        }

        // Second pass: bare <function=NAME> ... </function> blocks that the model
        // emitted without the outer <tool_call> wrapper. We must avoid overlapping any
        // already-matched wrapped calls.
        let bareFunctionPattern = #"(?s)<function=([^>]+)>(.*?)</function>"#
        if let regex = try? NSRegularExpression(pattern: bareFunctionPattern, options: []) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                guard let blockRange = Range(match.range, in: text) else { continue }
                // Skip if this bare block overlaps an already-matched <tool_call> block.
                if matchedRanges.contains(where: { $0.overlaps(blockRange) }) { continue }
                if let call = parseXMLToolCallBlock(String(text[blockRange]), parameterInfoByName: parameterInfoByName) {
                    calls.append(call)
                }
            }
        }

        return calls
    }

    /// Parse a single XML tool-call block (either the inner body of a <tool_call> block
    /// or a bare <function=...> block) into a RoundToolCall.
    /// `parameterInfoByName` maps tool names to their declared parameters so bare
    /// `<parameter>` siblings can be paired as key/value and single bare values are
    /// assigned to the first required parameter instead of the generic `value` key.
    internal static func parseXMLToolCallBlock(_ block: String, parameterInfoByName: [String: ToolParameterInfo] = [:]) -> RoundToolCall? {
        // Extract function name: <function=NAME> or <function>NAME</function>
        let name: String? = {
            if let nameRange = block.range(of: #"<function=([^>]+)>"#, options: .regularExpression) {
                let nameWithTag = String(block[nameRange])
                return nameWithTag.dropFirst(10).dropLast(1).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let tagStart = block.range(of: "<function>"),
               let tagEnd = block.range(of: "</function>") {
                return String(block[tagStart.upperBound..<tagEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()
        guard let functionName = name, !functionName.isEmpty else { return nil }
        let info = parameterInfoByName[functionName]

        // Extract argument content. Support four forms:
        //   <parameter=name>value</parameter>
        //   <parameter name="name">value</parameter>
        //   <parameter>name</parameter><parameter>value</parameter> (bare key/value pairs)
        //   <parameter>{"key":"value"}</parameter>
        //   <parameter name="..." value="..." />  (self-closing attribute form)
        var args: [String: Any] = [:]
        let paramPattern = #"(?s)<parameter(?:=([^>\s]+))?\s*(.*?)(?:/>|>(.*?)</parameter>)"#
        if let paramRegex = try? NSRegularExpression(pattern: paramPattern, options: []) {
            let paramNSRange = NSRange(block.startIndex..., in: block)
            var rawParams: [(name: String?, value: String, attrs: [String: String])] = []
            for paramMatch in paramRegex.matches(in: block, options: [], range: paramNSRange) {
                guard let paramRange = Range(paramMatch.range, in: block) else { continue }
                var paramName = (Range(paramMatch.range(at: 1), in: block).map { String(block[$0]) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let attrBlock = String(block[paramRange])
                let attrs = parseXMLAttributes(attrBlock)
                if paramName.isEmpty, let nameAttr = attrs["name"], !nameAttr.isEmpty {
                    paramName = nameAttr
                }
                let valueRange = Range(paramMatch.range(at: 3), in: block)
                let rawValue = valueRange.map { String(block[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                let value = attrs["value"] ?? rawValue
                rawParams.append((name: paramName.isEmpty ? nil : paramName, value: value, attrs: attrs))
            }

            func assign(key: String, value: String) {
                if let data = value.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) {
                    if let obj = parsed as? [String: Any] {
                        args.merge(obj) { _, new in new }
                    } else if let str = parsed as? String {
                        args[key] = str
                    } else {
                        args[key] = value
                    }
                } else {
                    args[key] = value
                }
            }

            var i = 0
            while i < rawParams.count {
                let p = rawParams[i]
                if let key = p.name, !key.isEmpty {
                    assign(key: key, value: p.value)
                    for (attrKey, attrVal) in p.attrs where attrKey != "name" && attrKey != "value" {
                        assign(key: attrKey, value: attrVal)
                    }
                } else {
                    let value = p.value
                    // Pair consecutive bare parameters when the first one is a known
                    // parameter name for this tool: e.g. <parameter>query</parameter><parameter>swift</parameter>.
                    if let info = info,
                       info.all.contains(value),
                       i + 1 < rawParams.count,
                       rawParams[i + 1].name == nil {
                        let nextValue = rawParams[i + 1].value
                        assign(key: value, value: nextValue)
                        i += 1
                    } else {
                        // Single bare value: assign to the first required parameter if known,
                        // otherwise fall back to the generic "value" key.
                        if let firstRequired = info?.required.first {
                            assign(key: firstRequired, value: value)
                        } else {
                            assign(key: "value", value: value)
                        }
                    }
                }
                i += 1
            }
        }

        // Return tool calls even with empty args so the handler can return a
        // meaningful error (e.g. "read_file requires 'path'"). Silently dropping
        // the call leaves the model blind to why it failed, causing empty-args
        // retry loops (Qwen 3 Coder Next: 30+ rounds of `read_file` with {}).
        guard let argsData = try? JSONSerialization.data(withJSONObject: args),
              let argsJSON = String(data: argsData, encoding: .utf8)
        else { return nil }
        return RoundToolCall(id: UUID().uuidString, name: functionName, arguments: argsJSON)
    }

    /// Recover a shell command from the assistant's text when the XML parser
    /// returned an execute_command tool call with an empty or missing `command`
    /// argument. Tries, in order: a fenced code block, a command-like line in
    /// the prose, then the raw `<parameter=command>` value inside any leftover
    /// XML tool_call block.
    private static func recoverShellCommands(
        in toolCalls: [RoundToolCall], from content: String
    ) -> [RoundToolCall] {
        // Content arriving here is already tag-stripped by the caller, but strip again
        // defensively so any recovered command value is definitely clean.
        let cleanContent = ThinkingTagStripper.strip(content)
        guard let command = firstShellCommand(in: cleanContent)
                ?? firstCommandLikeLine(in: cleanContent)
                ?? firstCommandFromRawXML(in: cleanContent)
        else { return toolCalls }
        let cleanedCommand = ThinkingTagStripper.strip(command)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCommand.isEmpty else { return toolCalls }
        return toolCalls.map { tc in
            guard tc.name == "execute_command" else { return tc }
            var args = ((try? JSONSerialization.jsonObject(
                with: Data(tc.arguments.utf8)
            )) as? [String: Any]) ?? [:]
            let existing = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard existing == nil || existing?.isEmpty == true else { return tc }
            args["command"] = cleanedCommand
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
    /// Detects hesitation/second-guessing narration ("Wait, I'll check…",
    /// "Actually, let me verify…") that small models spiral into. Word-bounded
    /// so "await"/"waiting room" don't false-positive. Only meaningful in
    /// aggregate — see the dither budget in the agentic loop.
    /// Internal (not private) so tests can pin the patterns.
    static func containsHesitation(_ text: String) -> Bool {
        let t = text.lowercased()
        let patterns = [
            #"\bwait\b"#, #"\bhmm+\b"#, #"\bon second thought\b"#,
            #"\bsecond-?guess"#, #"\blet me re-?check\b"#,
            #"\blet me double-?check\b"#, #"\blet me re-?read\b"#,
            #"\blet me verify (that |once )?(again|more)\b"#,
            #"\blet me just\b"#, #"\bactually,?\b"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// Detects content that asks the USER to do something the model cannot:
    /// authorize folders, grant permissions, provide credentials, install
    /// something, sign in. Such a message is a valid final answer — nudging
    /// it as "future narration" forces the model to parrot the same request
    /// again (confirmed live: the ask repeated verbatim until the
    /// identical-round guard ended the turn).
    /// Internal (not private) so tests can pin the patterns.
    static func asksUserForAction(_ text: String) -> Bool {
        let t = text.lowercased()
        let asks = [
            "please add", "please authorize", "please authorise", "please grant",
            "please provide", "please give", "please enable", "please allow",
            "please unlock", "please install", "please sign in", "please log in",
            "please share", "please tell me", "please confirm",
            "i don't have permission", "i do not have permission",
            "i don't have access", "i do not have access",
            "access denied", "permission denied", "not authorized", "not authorised",
            "outside the authorized", "outside of the authorized",
            "you'll need to", "you will need to", "you need to add",
            "could you add", "could you provide", "could you share", "can you provide",
        ]
        return asks.contains { t.contains($0) }
    }

    private static let nonInjectedMutators: Set<String> = [
        "create_project_agent", "archive_project_agent",
        "ask_project_agent", "ask_project_agents",
    ]

    /// Verb-prefix classification for "this tool changes something" — used by
    /// the falseClaim nudge to know a claimed mutation really happened. The
    /// explicit sets above only covered plan/todo/message/workspace tools, so
    /// a successful send (e.g. send_whatsapp_message) left `usedMutator`
    /// false and the model's legitimate "Message sent!" confirmation was
    /// nudged as a FALSE claim — forcing it to repeat the claim, with every
    /// copy streaming into the chat bubble (user-reported duplication).
    /// Prefix match on the leading verb keeps this robust as tools are added;
    /// read-only verbs (get/list/read/search/fetch…) are deliberately absent.
    /// Internal (not private) so tests can pin the classification.
    static func isMutatorToolName(_ name: String) -> Bool {
        let verbs = [
            "send", "post", "like", "unlike", "repost", "unrepost",
            "create", "add", "update", "edit", "write", "delete",
            "move", "set", "start", "stop", "archive", "upload",
            "mark", "follow", "unfollow", "publish", "run",
        ]
        let lower = name.lowercased()
        return verbs.contains { lower == $0 || lower.hasPrefix("\($0)_") }
    }

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

    /// Content-mutation tools whose legitimate use is high-volume with varied
    /// arguments — e.g. checking off a 20-step plan is 20 `edit_plan` calls in
    /// one turn, and the blanket cap of 5 was cutting that off mid-plan. These
    /// get `highVolumeMutationToolCap`; pathological loops are still caught by
    /// the identical-args guard and the consecutive-failure breaker.
    private static let highVolumeMutationToolCap = 50
    private static let highVolumeMutationTools: Set<String> = [
        "create_plan", "edit_plan",
        "create_todo_list", "add_todos", "update_todo_status",
        "write_file", "edit_file",
        "write_note", "create_note",
        "memory_write",
        "create_kanban_card", "update_kanban_card",
        "write_numbers_cell",
        "create_contact", "update_contact",
        "create_calendar_event", "create_reminder",
    ]

    /// Tools whose first argument should be the calling agent's project, injected
    /// automatically when the model didn't already supply one. These are the
    /// project-scoped ai-context-bridge memory/session tools.
    private static let projectScopedTools: Set<String> = [
        "memory_write", "memory_read", "memory_search", "memory_list",
        "add_decision", "add_todo", "report_error", "update_session",
        "list_active_contexts",
        // Plan tools: a project agent's plans default to its project (shared);
        // Maestro (no project) keeps personal plans unless it passes one.
        "create_plan", "edit_plan", "read_plans", "read_plan",
    ]

    /// Tools Maestro is blocked from using (executor-level guard).
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
        if tc.name == "task" {
            return await taskDelegate(argumentsJSON: tc.arguments, mcp: mcp, workingDirectory: workingDirectory)
        }

        // Maestro guard: if project is nil (Maestro), block work tools.
        // The model sometimes ignores the tool spec and calls tools it shouldn't have.
        if project == nil && Self.navigatorBlockedTools.contains(tc.name) {
            return "{\"error\":\"\(tc.name) is not available to Maestro. "
                + "You MUST delegate this task to a project agent using ask_project_agent.\"}"
        }

        // Gemma 4 and other small models sometimes emit literal newlines/carriage
        // returns inside JSON string values instead of escaping them, and can
        // wrap the whole object in a string literal or leak JSON punctuation into
        // the keys. The injection helpers and ToolCall decoder both rely on
        // valid JSON, so repair and then sanitize the raw arguments first.
        let rawArguments = Self.sanitizeArgumentsJSON(ToolArgumentRepair.repair(tc.arguments))
        var argsJSON = Self.injectProject(
            into: rawArguments, toolName: tc.name, project: project
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
        NSLog("[executeTool] name=%@ args=%@ workingDirectory=%@", tc.name, argsJSON, workingDirectory ?? "(none)")
        let toolID = UUID().uuidString
        let toolStartTime = Date()
        AIBroadcastService.broadcastToolStarted(name: tc.name, id: toolID)
        if await MaestroTools.handles(tc.name) {
            let result = await MaestroTools.execute(call)
            NSLog("[executeTool] result for %@: %@", tc.name, String(result.prefix(300)))
            AIBroadcastService.broadcastToolCompleted(
                name: tc.name, id: toolID, duration: Date().timeIntervalSince(toolStartTime))
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
            let result = await mcp.execute(call)
            NSLog("[executeTool] MCP result for %@: %@", tc.name, String(result.prefix(300)))
            AIBroadcastService.broadcastToolCompleted(
                name: tc.name, id: toolID, duration: Date().timeIntervalSince(toolStartTime))
            return result
        }
        let result = await MaestroTools.execute(call)
        AIBroadcastService.broadcastToolCompleted(
            name: tc.name, id: toolID, duration: Date().timeIntervalSince(toolStartTime))
        return result
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

    /// Hard cap on a single tool result's size before it enters the conversation.
    /// This is a STABILITY guard, not a budget: an uncapped result (e.g. a 189 KB
    /// deep_fetch page) became a ~63K-token prefill delta that pushed the context to
    /// ~100K and made MLX throw a 1.3 TB metal::malloc allocation error, killing the
    /// round. Capping each result keeps per-round deltas small so prompt-cache reuse
    /// stays effective and total context stays within what compaction can manage.
    private static let maxToolResultChars = 20000

    /// Truncate an oversized tool result to `maxToolResultChars`, appending a clear
    /// marker so the model knows content was cut (and how much). Results within the
    /// limit are returned unchanged. VLM image payloads are handled separately and
    /// never pass through here.
    private static func truncatedToolResult(_ result: String) -> String {
        guard result.count > maxToolResultChars else { return result }
        let kept = result.prefix(maxToolResultChars)
        NSLog("[AGENT] truncated oversized tool result: \(result.count) -> \(maxToolResultChars) chars")
        return kept + "\n\n…[truncated: showing \(maxToolResultChars) of \(result.count) chars]"
    }

    /// CONTEXT RECYCLING: stub out all but the most recent tool results before
    /// each generation. Per-result truncation (maxToolResultChars) caps ONE
    /// result, but ACCUMULATION across rounds is what kills the backend — the
    /// 14:39 run carried 37 rounds of page reads (~70K tokens) until MLX threw
    /// metal::malloc. The database and the model's own running notes are the
    /// memory; the conversation is scratch space. Once a result has been
    /// processed, its full text is waste. Only the last `keepLast` results
    /// stay full-fidelity so the model can still quote its freshest reads.
    private static func elideOldToolResults(_ convo: inout [[String: Any]], keepLast: Int = 4) {
        let toolIndices = convo.indices.filter { convo[$0]["role"] as? String == "tool" }
        guard toolIndices.count > keepLast else { return }
        for idx in toolIndices.dropLast(keepLast) {
            guard let content = convo[idx]["content"] as? String, content.count > 160 else { continue }
            convo[idx]["content"] = String(content.prefix(80))
                + " …[elided: result already processed — the extracted data is in "
                + "your table or earlier reasoning]"
        }
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
        // Bus: agent_id identifies the publisher/subscriber/replier.
        "bus_publish", "bus_subscribe", "bus_read", "bus_request", "bus_reply", "bus_context_snapshot",
        // Context store: agent_id is the default scope.
        "context_update", "context_read", "fact_remember",
        // Bus worker tools are intentionally EXCLUDED from agent-scoped injection.
        // The agent_id/name they refer to is the *worker* agent, not the caller.
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
        // Resolve target + assemble its prompt on the MainActor. Include the
        // target agent's effective model so the category prompt can be tailored
        // to the model's capacity (e.g., small MoE vs large dense).
        let prep: (AgentRecord, String, [Message], String?, String?)? = await MainActor.run {
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
            let targetModel = self.catalog?.effectiveModel(for: target)
            let targetModelID = targetModel?.huggingFaceID
            let targetModelDesc = targetModel.map { "\($0.displayName) (model id \($0.huggingFaceID)), served via in-process Apple MLX" }
            var msgs = ChatHistoryStore.load(agentId: target.id)
                ?? [ChatViewModel.systemMessage(
                    for: target, projectName: proj.isEmpty ? nil : proj,
                    workingDirectory: targetWD,
                    modelDescription: targetModelDesc,
                    modelID: targetModelID)]
            msgs.append(Message(role: .user, content: trimmedTask, timestamp: Date()))
            return (target, proj, msgs, targetWD, targetModelID)
        }
        guard let (target, proj, messages, effectiveWD, _) = prep else {
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
        let subModelDisplayName = await MainActor.run {
            catalog?.model(forID: subModelID)?.displayName ?? subModelID
        }

        // Delegate tool surface: project tools only (no Maestro tools), plus
        // MCP servers the user exposes to delegated sub-agents. Per-agent enabled
        // categories override the old automatic lite-mode reduction.
        let enabledCategories = await MainActor.run {
            MaestroTools.workspace?.effectiveToolCategories(for: target.id)
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
            if let enabledCategories {
                if enabledCategories.contains(.mcp) {
                    let mcpSchemas = await mcp.currentSchemas(forCategories: enabledCategories)
                    specs += mcpSchemas
                }
            } else {
                let mcpSchemas = await mcp.currentSchemas(audience: .delegate)
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
        await delegateStreamHandler?.start(
            agentID: target.id.uuidString, modelDisplayName: subModelDisplayName)
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
                maxRounds: 100,
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
                    await delegateStreamHandler?.token(agentID: target.id.uuidString, token)
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
            await delegateStreamHandler?.finish(agentID: target.id.uuidString)
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "delegate failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            ProcessResourceSampler.shared.stopSubagent(id: target.id.uuidString)
        }
        await delegateStreamHandler?.finish(agentID: target.id.uuidString)
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
        let completedAt = Date()
        await MainActor.run {
            var msgs = messages
            // The last message is the assistant answer; stamp it with the actual
            // model and time so the sub-agent chat footer shows metadata.
            msgs.append(Message(
                role: .assistant, content: answer,
                timestamp: completedAt, modelName: subModelDisplayName))
            ChatHistoryStore.save(msgs, agentId: target.id)
            NSLog("[DELEGATE] saving \(msgs.count) messages for \(target.name) (id=\(target.id))")
            let cache = ChatViewModelCache.shared
            NSLog("[DELEGATE] cache has VM for \(target.name): \(cache.hasViewModel(for: target.id))")
            cache.reloadMessages(forAgentID: target.id, messages: msgs)
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
            MaestroTools.workspace?.effectiveToolCategories(for: target.id)
        }
        let compactMode = await MainActor.run {
            MaestroTools.workspace?.compactToolMode(for: target.id) ?? false
        }
        MaestroTools.currentEnabledCategories = enabledCategories
        MaestroTools.currentIsNavigator = false
        var specs = await MaestroTools.schemas(
            navigator: false, enabledCategories: enabledCategories, compactMode: compactMode)
        if let mcp {
            if let enabledCategories {
                if enabledCategories.contains(.mcp) {
                    let mcpSchemas = await mcp.currentSchemas(forCategories: enabledCategories)
                    specs += mcpSchemas
                }
            } else {
                let mcpSchemas = await mcp.currentSchemas(audience: .delegate)
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
        let subModelDisplayName = await MainActor.run {
            catalog?.model(forID: subModelID)?.displayName ?? subModelID
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
        await delegateStreamHandler?.start(
            agentID: target.id.uuidString, modelDisplayName: subModelDisplayName)
        do {
            for try await output in sub.run(
                messages: messages, toolSpecs: specs, mcp: mcp,
                engine: nil, catalog: nil,
                temperature: 0.3, topP: 0.95, thinkingEnabled: false,
                project: proj.isEmpty ? nil : proj,
                workingDirectory: workingDirectory,
                agentID: target.id.uuidString,
                maxRounds: 100,
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
                    await delegateStreamHandler?.token(agentID: target.id.uuidString, token)
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
            await delegateStreamHandler?.finish(agentID: target.id.uuidString)
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "delegate failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            ProcessResourceSampler.shared.stopSubagent(id: target.id.uuidString)
        }
        await delegateStreamHandler?.finish(agentID: target.id.uuidString)
        let trimmedLast = lastRoundText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAnswer = trimmedLast.isEmpty
            ? narration.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedLast
        let answer = Self.stripThinkingTags(rawAnswer)
        guard !answer.isEmpty else {
            return DelegateResult(project: proj, agent: target.name, answer: nil,
                error: "agent finished without a text answer")
        }
        let completedAt = Date()
        await MainActor.run {
            var msgs = messages
            msgs.append(Message(
                role: .assistant, content: answer,
                timestamp: completedAt, modelName: subModelDisplayName))
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
            let catalog = self.catalog
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
                let targetModel = catalog?.effectiveModel(for: target)
                let targetModelID = targetModel?.huggingFaceID
                let targetModelDesc = targetModel.map { "\($0.displayName) (model id \($0.huggingFaceID)), served via in-process Apple MLX" }
                var msgs = ChatHistoryStore.load(agentId: target.id)
                    ?? [ChatViewModel.systemMessage(
                        for: target, projectName: proj.isEmpty ? nil : proj,
                        workingDirectory: targetWD,
                        modelDescription: targetModelDesc,
                        modelID: targetModelID)]
                msgs.append(Message(role: .user, content: p.task, timestamp: Date()))
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

    /// `task` — OpenCode-style one-shot subagent. Creates a temporary project agent,
    /// delegates the task, archives the agent, and returns the answer.
    private func taskDelegate(argumentsJSON: String, mcp: MCPClientService?, workingDirectory: String? = nil) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agentName = obj["agent"] as? String,
              let taskText = obj["task"] as? String,
              !agentName.trimmingCharacters(in: .whitespaces).isEmpty,
              !taskText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return MaestroTools.errorJSON("task requires non-empty 'agent' and 'task'")
        }
        let projectName = (obj["project"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "__tasks__"
        let effectiveWD = (obj["workingDirectory"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? workingDirectory
        let modelArg = (obj["model"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let cleanAgent = agentName.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let cleanProject = projectName.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        // Create a uniquely named agent so repeated task calls don't collide.
        let uniqueAgent = "\(cleanAgent)-\(UUID().uuidString.prefix(8))"
        let created: AgentRecord? = await MainActor.run {
            guard let ws = MaestroTools.workspace else { return nil }
            let modelID = MaestroTools.resolveAgentModelID(modelArg, agentName: uniqueAgent, catalog: ModelCatalog())
            return ws.createProjectAgent(
                projectName: cleanProject, agentName: uniqueAgent,
                workingDirectory: effectiveWD, modelID: modelID)
        }
        guard let target = created else {
            return MaestroTools.errorJSON("task: workspace unavailable or agent creation failed")
        }
        let result = await delegateOne(
            projectName: cleanProject, agentName: target.name, task: taskText,
            mcp: mcp, workingDirectory: effectiveWD)
        // Archive the temporary agent and prune its project if empty.
        await MainActor.run {
            MaestroTools.workspace?.archiveAgent(id: target.id)
        }
        if let err = result.error {
            return MaestroTools.errorJSON(err)
        }
        return Self.json([
            "project": cleanProject,
            "agent": target.name,
            "answer": result.answer ?? "",
        ])
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

    /// Escape literal control characters that appear inside JSON string values.
    /// Small/local models (especially Gemma 4) emit tool-call JSON with raw
    /// newlines/carriage returns/tabs inside string values instead of the required
    /// `\\n`/`\\r`/`\\t` escapes. This breaks `JSONDecoder`, leaves the tool with
    /// empty arguments, and produces the misleading "A search query is required"
    /// style errors. The scanner is token-aware: it only touches characters inside
    /// quoted string segments and preserves already-escaped sequences.
    private static func sanitizeArgumentsJSON(_ json: String) -> String {
        var result = ""
        var insideString = false
        var escaped = false
        for char in json {
            if escaped {
                result.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                result.append(char)
                escaped = true
                continue
            }
            if char == "\"" {
                insideString.toggle()
                result.append(char)
                continue
            }
            if insideString {
                switch char {
                case "\n": result.append("\\n")
                case "\r": result.append("\\r")
                case "\t": result.append("\\t")
                default: result.append(char)
                }
            } else {
                result.append(char)
            }
        }
        return result
    }

    private static func toolCall(name: String, argumentsJSON: String) -> ToolCall {
        let sanitized = sanitizeArgumentsJSON(argumentsJSON)
        let args: [String: JSONValue]
        if let data = sanitized.data(using: .utf8),
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
        "db_import_csv", "db_export_csv",
        "glob_files", "grep_code", "edit_file",
        "git_status", "git_diff", "git_log", "git_branch",
    ]

    /// Rough token estimate: ~4 chars per token for English text.
    static func estimateTokens(_ msg: [String: Any]) -> Int {
        if let content = msg["content"] as? String {
            return content.count / 4
        }
        return 0
    }

    /// Normalize a loop-guard / failure-breaker signature so escape-junk growth
    /// can't dodge detection. Production failure family: a failed retry re-escapes
    /// the same values (" → \" → \\\" → …), mutating the raw args/error text each
    /// round — every counter keyed on the raw string kept resetting to 1, so the
    /// 17-round db_add_field meltdown was invisible to both guards. Removing the
    /// escape + wrapper characters (including stray structural braces from the
    /// meltdown) makes logically identical retries collide.
    static func normalizedGuardSignature(_ raw: String) -> String {
        String(raw.filter { !["\\", "\"", "'", "{", "}", "[", "]", "(", ")"].contains($0) })
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
