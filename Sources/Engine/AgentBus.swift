import Foundation
import os.log

/// The SwiftMaestro internal agent bus.
///
/// A typed, topic-based, in-memory message broker that lets agents communicate
/// without the latency of the polling `send_agent_message` / `read_agent_messages`
/// inbox or the JSON-RPC overhead of MCP. It supports:
///   - pub/sub via `subscribe` / `publish`
///   - synchronous request/reply via `request` / `reply`
///   - durable history per topic (in-memory + persisted to `~/.ai-context/memory/context/bus/`)
///
/// The bus is an actor so it is safe to call from any isolation context.
actor AgentBus {

    /// Message history per topic (oldest first). Pruned to a fixed size.
    private var history: [String: [AgentBusMessage]] = [:] {
        didSet { pruneHistory() }
    }

    /// Last-read timestamp per agent per topic, for unread-only reads.
    private var lastReadTimestamps: [UUID: [String: Date]] = [:]

    /// Subscribers per topic: agent IDs that should see messages on that topic.
    private var subscriptions: [String: Set<UUID>] = [:]

    /// Pending synchronous requests keyed by request ID.
    private var pendingRequests: [UUID: PendingBusRequest] = [:]

    /// Default timeout for `request` if none is provided.
    private let defaultRequestTimeout: Duration = .seconds(30)

    /// Maximum number of messages retained per topic.
    private let maxMessagesPerTopic = 200

    /// Where the bus history is persisted on disk.
    private let historyURI = MaestroURI(kind: .context, path: ["bus", "history.json"])

    /// In-memory store for saving/loading the bus history.
    private let store = SimpleMemoryStore()

    /// Whether persistence is enabled. Disable for tests or ephemeral sessions.
    private var persistenceEnabled: Bool = true

    /// Track an in-flight save so we don't stack multiple redundant writes.
    private var pendingSaveTask: Task<Void, Never>?

    /// Load persisted history on first creation.
    init(persistenceEnabled: Bool = true) {
        self.persistenceEnabled = persistenceEnabled
        if persistenceEnabled {
            Task { await loadHistory() }
        }
    }

    // MARK: - Subscription

    /// Subscribe an agent to a topic. Idempotent.
    func subscribe(agentID: UUID, topic: String) {
        var subs = subscriptions[topic] ?? Set()
        subs.insert(agentID)
        subscriptions[topic] = subs
        scheduleSaveHistory()
    }

    /// Unsubscribe an agent from a topic.
    func unsubscribe(agentID: UUID, topic: String) {
        guard var subs = subscriptions[topic] else { return }
        subs.remove(agentID)
        subscriptions[topic] = subs.isEmpty ? nil : subs
        scheduleSaveHistory()
    }

    /// Remove all subscriptions for a given agent.
    func unsubscribeAll(agentID: UUID) {
        for topic in subscriptions.keys {
            unsubscribe(agentID: agentID, topic: topic)
        }
        scheduleSaveHistory()
    }

    /// List topics an agent is subscribed to.
    func subscriptions(for agentID: UUID) -> [String] {
        subscriptions.compactMap { topic, subs in
            subs.contains(agentID) ? topic : nil
        }.sorted()
    }

    // MARK: - Publication

    /// Publish a fire-and-forget event to a topic. Returns true if the topic
    /// had at least one subscriber, false otherwise.
    @discardableResult
    func publish(_ message: AgentBusMessage) -> Bool {
        guard validateTopic(message.topic) else { return false }
        append(message)
        scheduleSaveHistory()
        let hasSubscribers = subscriptions[message.topic]?.isEmpty == false
        return hasSubscribers
    }

    /// Publish a request and await the first reply. Returns the reply message.
    /// If no subscriber is present, the request still sits on the topic so a
    /// late subscriber can pick it up.
    func request(
        message: AgentBusMessage,
        timeout: Duration? = nil
    ) async throws -> AgentBusMessage {
        guard validateTopic(message.topic) else {
            throw AgentBusError.invalidTopic
        }
        append(message)
        scheduleSaveHistory()

        let requestID = message.id
        let effectiveTimeout = timeout ?? defaultRequestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task {
                try? await Task.sleep(for: effectiveTimeout)
                if let pending = self.pendingRequests.removeValue(forKey: requestID) {
                    pending.continuation.resume(
                        throwing: AgentBusError.timeout(topic: message.topic, requestID: requestID))
                }
            }
            pendingRequests[requestID] = PendingBusRequest(
                id: requestID,
                topic: message.topic,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
        }
    }

    /// Publish a reply to a specific request. Resolves the caller's continuation.
    func reply(_ message: AgentBusMessage, to requestID: UUID) -> Bool {
        guard validateTopic(message.topic) else { return false }
        append(message)
        scheduleSaveHistory()
        guard let pending = pendingRequests.removeValue(forKey: requestID) else {
            return false
        }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(returning: message)
        return true
    }

    // MARK: - Reading

    /// Read messages on a topic, optionally filtering by kind and unread state.
    /// `unread` is computed against the agent's last read timestamp.
    func read(
        topic: String,
        agentID: UUID,
        kinds: [AgentBusMessageKind]? = nil,
        limit: Int = 50,
        unreadOnly: Bool = false
    ) -> [AgentBusMessage] {
        guard validateTopic(topic) else { return [] }
        var messages = history[topic] ?? []
        if let kinds = kinds, !kinds.isEmpty {
            messages = messages.filter { kinds.contains($0.kind) }
        }
        if unreadOnly {
            let lastRead = lastReadTimestamps[agentID]?[topic] ?? .distantPast
            messages = messages.filter { $0.timestamp > lastRead }
        }
        messages = Array(messages.suffix(limit))
        return messages
    }

    /// Mark a topic as read for an agent.
    func markRead(topic: String, agentID: UUID) {
        var perAgent = lastReadTimestamps[agentID] ?? [:]
        perAgent[topic] = Date()
        lastReadTimestamps[agentID] = perAgent
        // read receipts are not persisted; only message history is.
    }

    /// List all topics that have history.
    func topics() -> [String] {
        history.keys.sorted()
    }

    /// Summary of a topic for tool responses.
    func topicSummary(topic: String, limit: Int = 20) -> String {
        let messages = (history[topic] ?? []).suffix(limit)
        return messages.map { "\($0.timestamp) \($0.senderName) [\($0.kind.rawValue)]: \($0.payload)" }
            .joined(separator: "\n")
    }

    // MARK: - Private

    private func append(_ message: AgentBusMessage) {
        var messages = history[message.topic] ?? []
        messages.append(message)
        history[message.topic] = messages
    }

    private func pruneHistory() {
        for (topic, messages) in history where messages.count > maxMessagesPerTopic {
            history[topic] = Array(messages.suffix(maxMessagesPerTopic))
        }
    }

    private func validateTopic(_ topic: String) -> Bool {
        let trimmed = topic.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Disallow path traversal or obvious injection in topic names.
        let invalid = CharacterSet(charactersIn: "../\\")
        return trimmed.rangeOfCharacter(from: invalid) == nil
    }

    // MARK: - Persistence

    /// Schedule an async save of the current history. Coalesces rapid mutations.
    private func scheduleSaveHistory() {
        guard persistenceEnabled else { return }
        // Cancel any pending save and schedule a new one. This coalesces bursts
        // of bus activity into a single write.
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms coalescing window
            guard !Task.isCancelled else { return }
            await saveHistory()
        }
    }

    /// Encode and persist the current bus history to `~/.ai-context/memory/context/bus/history.json`.
    private func saveHistory() {
        guard persistenceEnabled else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(history)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try store.save(json, at: historyURI)
        } catch {
            logBusError("Failed to persist bus history: \(error.localizedDescription)")
        }
    }

    /// Load persisted bus history from disk, if any.
    private func loadHistory() async {
        guard persistenceEnabled else { return }
        do {
            guard let json = try store.load(historyURI) else { return }
            let data = Data(json.utf8)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([String: [AgentBusMessage]].self, from: data)
            history.merge(loaded) { existing, incoming in
                // Deduplicate by id, keep chronological order.
                let merged = (existing + incoming).sorted { $0.timestamp < $1.timestamp }
                var seen = Set<UUID>()
                return merged.filter { seen.insert($0.id).inserted }
            }
        } catch {
            logBusError("Failed to load bus history: \(error.localizedDescription)")
        }
    }

    private func logBusError(_ message: String) {
        // Use unified logging so bus persistence issues show up alongside other errors.
        Logger.bus.error("\(message)")
    }
}

extension Logger {
    fileprivate static let bus = Logger(subsystem: "com.woodseedigi.swiftmaestro", category: "AgentBus")
}

extension AgentBus {
    /// Default shared instance. Tools and the UI access the same bus.
    static let shared = AgentBus()
}