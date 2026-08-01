import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Bus worker
//
// A persistent, Swift-side polling worker that lets an agent listen to a bus
// topic and reply to requests without requiring the model to loop forever. The
// model-based agent loop is bounded (8 rounds), so a worker cannot reliably wait
// for a request by calling bus_read repeatedly. Instead, BusWorker subscribes
// to the topic, polls for unread requests, and runs each request through a
// single-shot agent executor. The resulting final text is published as a bus
// reply.

/// A long-lived worker for one agent + one topic.
///
/// Isolated to its own actor so polling and per-request generation never block
/// the main thread. Callers hop to MainActor only when reading shared UI state
/// (workspace / catalog).
actor BusWorker {
    /// Published handle returned when a worker is started.
    struct Handle: Identifiable, Sendable {
        let id: UUID
        let agentID: UUID
        let topic: String
    }

    private struct WorkerConfig: Sendable {
        let id: UUID
        let agentID: UUID
        let topic: String
        let taskPrompt: String
        let model: MaestroModel
        let backend: GenerationBackend
        let projectName: String?
        let workingDirectory: String?
    }

    private weak var engine: MLXInferenceEngine?
    private weak var mcpService: MCPClientService?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var configs: [UUID: WorkerConfig] = [:]

    init(engine: MLXInferenceEngine, mcpService: MCPClientService?) {
        self.engine = engine
        self.mcpService = mcpService
    }

    /// Start a worker that listens on `topic` using the model/project settings of `agentID`.
    /// `taskPrompt` is injected into the system prompt so the worker knows its role.
    func start(agentID: UUID, topic: String, taskPrompt: String) async -> Handle? {
        guard !topic.isEmpty else { return nil }
        guard let engine else { return nil }

        // Gather UI-bound state on the main actor, then start the background task.
        let config = await MainActor.run {
            guard let agent = MaestroTools.workspace?.agent(id: agentID),
                  let model = MaestroTools.catalog?.effectiveModel(for: agent)
                    ?? MaestroTools.catalog?.selectedModel
            else { return nil as WorkerConfig? }
            let backend = ChatViewModel.makeBackend(
                for: model, engine: engine, sessionKey: agentID.uuidString)
            let id = UUID()
            return WorkerConfig(
                id: id,
                agentID: agentID,
                topic: topic,
                taskPrompt: taskPrompt,
                model: model,
                backend: backend,
                projectName: MaestroTools.workspace?.projectName(for: agent),
                workingDirectory: agent.workingDirectory)
        }

        guard let config else { return nil }
        configs[config.id] = config
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(config: config)
        }
        tasks[config.id] = task
        return Handle(id: config.id, agentID: agentID, topic: topic)
    }

    /// Stop a specific worker by its handle id.
    func stop(id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        configs.removeValue(forKey: id)
    }

    /// Stop every worker for a given agent, or all workers if `agentID` is nil.
    func stopAll(agentID: UUID? = nil) {
        for (id, config) in configs {
            if let agentID, config.agentID != agentID { continue }
            tasks[id]?.cancel()
            tasks.removeValue(forKey: id)
        }
        configs = configs.filter { _, config in
            agentID == nil || config.agentID == agentID
        }
    }

    /// Read-only snapshot of active workers for UI/monitoring.
    var activeHandles: [Handle] {
        configs.values.map { Handle(id: $0.id, agentID: $0.agentID, topic: $0.topic) }
    }

    // MARK: - Private

    private func run(config: WorkerConfig) async {
        await AgentBus.shared.subscribe(agentID: config.agentID, topic: config.topic)
        defer { Task { await AgentBus.shared.unsubscribe(agentID: config.agentID, topic: config.topic) } }

        while !Task.isCancelled {
            let messages = await AgentBus.shared.read(
                topic: config.topic,
                agentID: config.agentID,
                kinds: [.request],
                limit: 10,
                unreadOnly: true)

            for request in messages {
                await handleRequest(request, config: config)
            }

            // Mark the topic read only after processing so a hanging request
            // generation doesn’t permanently drop the message.
            await AgentBus.shared.markRead(topic: config.topic, agentID: config.agentID)

            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s poll interval
        }
    }

    private func handleRequest(_ request: AgentBusMessage, config: WorkerConfig) async {
        let systemPrompt = """
        You are a SwiftMaestro agent bus worker.
        Topic: \(config.topic)
        Task: \(config.taskPrompt)
        A request has been published on this topic. Respond with a concise, accurate answer.
        Do not narrate your plan. Do not call any tools. If the request is trivial, just answer.
        """
        let userPrompt = "Request: \(request.payload)\n\nReply as plain text."
        let messages = [
            Message(role: .system, content: systemPrompt),
            Message(role: .user, content: userPrompt)
        ]

        // Resolve the catalog and sender name on the main actor; everything else
        // runs on this background actor so the UI stays responsive.
        let catalog = await MainActor.run { MaestroTools.catalog }
        let senderName = await MainActor.run {
            MaestroTools.workspace?.agent(id: config.agentID)?.name
            ?? config.agentID.uuidString
        }

        let executor = AgentExecutor(
            modelID: config.model.huggingFaceID,
            backend: config.backend)
        let stream = executor.run(
            messages: messages,
            toolSpecs: [],
            mcp: mcpService,
            engine: engine,
            catalog: catalog,
            temperature: min(config.model.tunedTemperature, 0.3),
            topP: config.model.tunedTopP,
            thinkingEnabled: config.model.tunedThinkingEnabled,
            project: config.projectName,
            workingDirectory: config.workingDirectory,
            agentID: config.agentID.uuidString,
            maxRounds: 1,
            maxTokens: 1024)

        var payload = ""
        do {
            for try await output in stream {
                if case .token(let token) = output {
                    payload += token
                }
            }
        } catch {
            payload = "Worker error: \(error.localizedDescription)"
        }

        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty { payload = "(empty worker response)" }

        let reply = AgentBusMessage(
            topic: config.topic,
            sender: config.agentID,
            senderName: senderName,
            kind: .reply,
            payload: payload,
            inReplyTo: request.id)
        _ = await AgentBus.shared.reply(reply, to: request.id)
    }
}
