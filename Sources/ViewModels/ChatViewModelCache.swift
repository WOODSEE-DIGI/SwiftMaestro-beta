import SwiftUI

// MARK: - Chat view-model cache

/// Keeps one `ChatViewModel` per agent alive for the session so switching
/// agents preserves each conversation. Plain reference type (not observable):
/// mutating its cache during a view body does not trigger SwiftUI updates.
@MainActor
final class ChatViewModelCache {
    private var byID: [UUID: ChatViewModel] = [:]
    private var visionProxyService: VisionProxyService?

    /// The single shared cache for the whole process.
    ///
    /// This MUST be a non-optional lazily-initialized singleton. The previous
    /// design (`static var shared: ChatViewModelCache?` assigned from `init`)
    /// had two failure modes:
    ///  1. `shared == nil` during the first body evaluation (the original race
    ///     this type's init-self-registration was added to fix), and
    ///  2. worse: EVERY `ChatViewModelCache()` construction silently replaced
    ///     `shared`. ContentView's `@State` constructs one per main window, so
    ///     with multiple windows (or window-state restoration) `shared` flipped
    ///     to the newest window's EMPTY cache. Chat views kept their existing
    ///     VMs alive via `@StateObject`, but anything reaching for
    ///     `shared.viewModel(for:)` afterwards (Clear Chat, delegate streaming,
    ///     reloadMessages) minted a FRESH empty VM and mutated that phantom —
    ///     the on-screen conversation never changed. That is exactly the
    ///     "Clear Chat button does nothing" bug.
    /// A `static let` can never be nil, can never be replaced, and initializes
    /// synchronously on first access — all three problems gone.
    nonisolated static let shared = ChatViewModelCache()
    /// Called on the main actor when a delegation to `agentID` begins, so the UI
    /// can open or front a floating chat window for that sub-agent.
    var onOpenAgentWindow: ((UUID) -> Void)?

    /// Non-isolated so `static let shared` can initialize without hopping to the
    /// main actor. All stored properties have defaults; nothing actor-isolated
    /// is touched here.
    nonisolated init() {}

    func setVisionProxyService(_ service: VisionProxyService) {
        self.visionProxyService = service
    }

    func viewModel(for agent: AgentRecord, projectName: String?) -> ChatViewModel {
        if let existing = byID[agent.id] { return existing }
        let vm = ChatViewModel(
            agent: agent,
            projectName: projectName,
            visionProxyService: visionProxyService ?? VisionProxyService())
        byID[agent.id] = vm
        return vm
    }

    /// Drop a cached view-model (e.g. after archiving its agent).
    func drop(_ id: UUID) { byID[id] = nil }

    /// Append a token to an agent's current assistant message (for delegate streaming).
    /// Strips XML thinking/channel tags so the chat shows clean content.
    /// Tokens are buffered and flushed in small batches to avoid one SwiftUI
    /// update per token, which is the dominant source of "laggy" streaming.
    func appendToken(_ token: String, toAgentID agentID: UUID) {
        guard byID[agentID] != nil else { return }
        var buffer = tokenBuffers[agentID] ?? ""
        buffer += token
        tokenBuffers[agentID] = buffer

        let now = ContinuousClock.now
        let last = lastFlushTimes[agentID] ?? now
        let threshold = 50  // characters
        let interval: Duration = .milliseconds(50)
        let elapsed = last.duration(to: now)
        if buffer.count >= threshold || elapsed >= interval {
            flushTokens(for: agentID)
        }
    }

    /// Buffers of streaming tokens per agent, waiting to be flushed to the UI.
    private var tokenBuffers: [UUID: String] = [:]
    /// Last UI flush time per agent, so we can time-cap token buffering.
    private var lastFlushTimes: [UUID: ContinuousClock.Instant] = [:]

    /// Flush the buffered tokens for an agent into its last assistant message.
    /// This is the only place we mutate the UI and re-strip the accumulated
    /// content, so expensive tag stripping and SwiftUI re-renders happen once
    /// per batch instead of once per token.
    func flushTokens(for agentID: UUID) {
        guard let vm = byID[agentID],
              let buffer = tokenBuffers[agentID],
              !buffer.isEmpty else { return }
        tokenBuffers[agentID] = ""
        lastFlushTimes[agentID] = ContinuousClock.now

        vm.objectWillChange.send()
        if vm.messages.last?.role == .assistant {
            let idx = vm.messages.count - 1
            // Re-strip the entire accumulated content each flush so tags that span
            // token boundaries or appear in different forms still get removed.
            let accumulated = vm.messages[idx].content + buffer
            let cleaned = Self.stripThinkingTags(accumulated)
            vm.messages[idx].content = cleaned
            // Ensure the live streaming message carries metadata even if it was
            // created before the model name was resolved.
            if vm.messages[idx].modelName == nil || vm.messages[idx].modelName?.isEmpty == true {
                vm.messages[idx].modelName = ChatViewModel.effectiveDelegateModelNames[agentID.uuidString]
            }
        }
    }

    /// Strip XML thinking/channel tags from a string.
    /// Delegates to the shared stripper so all layers use the same patterns.
    private static func stripThinkingTags(_ text: String) -> String {
        ThinkingTagStripper.strip(text)
    }

    /// Notify an agent that delegation started (append empty assistant message).
    /// `modelName` is the resolved model running the sub-agent, shown in the footer.
    func beginDelegation(forAgentID agentID: UUID, modelName: String? = nil) {
        guard let vm = byID[agentID] else { return }
        vm.objectWillChange.send()
        vm.messages.append(Message(
            role: .assistant, content: "",
            timestamp: Date(), modelName: modelName))
        onOpenAgentWindow?(agentID)
    }

    /// Reload an agent's messages from the persisted exchange after delegation.
    @MainActor
    func reloadMessages(forAgentID agentID: UUID, messages: [Message]) {
        flushTokens(for: agentID)
        if let vm = byID[agentID] {
            vm.objectWillChange.send()
            vm.messages = messages
        } else {
            NSLog("[CACHE] reloadMessages: no VM for \(agentID) — creating fresh one")
            guard let agent = MaestroTools.workspace?.agent(id: agentID) else {
                NSLog("[CACHE] reloadMessages: can't find agent record for \(agentID)")
                return
            }
            let vm = ChatViewModel(
                agent: agent,
                projectName: MaestroTools.workspace?.projectName(for: agent),
                visionProxyService: visionProxyService ?? VisionProxyService())
            vm.messages = messages
            byID[agentID] = vm
        }
    }

    /// Check if a VM exists for an agent.
    func hasViewModel(for agentID: UUID) -> Bool {
        byID[agentID] != nil
    }

    /// Notify an agent that delegation finished (save history).
    func finishDelegation(forAgentID agentID: UUID) {
        flushTokens(for: agentID)
        guard let vm = byID[agentID] else { return }
        vm.persistHistory()
    }
}
