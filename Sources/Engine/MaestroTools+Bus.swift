import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Agent Bus tools
//
// Reactive, low-latency agent-to-agent communication. These bypass the slower
// polling inbox (`send_agent_message` / `read_agent_messages`) and the JSON-RPC
// overhead of MCP. Messages are typed, topic-addressed, and durable in memory.

extension MaestroTools {

    static func registerBusTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "bus_publish", spec: busToolSpecs[0],
                category: ToolCategory.bus.rawValue,
                handler: { call in await busPublish(call) }),
            ToolDefinition(
                name: "bus_subscribe", spec: busToolSpecs[1],
                category: ToolCategory.bus.rawValue,
                handler: { call in await busSubscribe(call) }),
            ToolDefinition(
                name: "bus_read", spec: busToolSpecs[2],
                category: ToolCategory.bus.rawValue,
                handler: { call in await busRead(call) }),
            ToolDefinition(
                name: "bus_request", spec: busToolSpecs[3],
                category: ToolCategory.bus.rawValue,
                handler: { call in await busRequest(call) }),
            ToolDefinition(
                name: "bus_reply", spec: busToolSpecs[4],
                category: ToolCategory.bus.rawValue,
                handler: { call in await busReply(call) }),
            ToolDefinition(
                name: "bus_context_snapshot", spec: busToolSpecs[5],
                category: ToolCategory.bus.rawValue,
                handler: { call in await busContextSnapshot(call) }),
        ])
    }

    private static var busToolSpecs: [ToolSpec] {
        let publishProps: [String: any Sendable] = [
            "topic": ["type": "string", "description": "Bus topic, e.g. 'project:Spotlight' or 'agent:Frontend Designer'."] as [String: any Sendable],
            "kind": ["type": "string", "description": "event | request | task | status"] as [String: any Sendable],
            "payload": ["type": "string", "description": "Message body."] as [String: any Sendable],
        ]
        let subscribeProps: [String: any Sendable] = [
            "topic": ["type": "string", "description": "Topic to subscribe to."] as [String: any Sendable],
        ]
        let kindsSchema: [String: any Sendable] = [
            "type": "array",
            "items": ["type": "string"] as [String: any Sendable],
            "description": "Optional filter: [\"event\", \"request\", \"task\", \"status\"].",
        ]
        let readProps: [String: any Sendable] = [
            "topic": ["type": "string", "description": "Topic to read."] as [String: any Sendable],
            "kinds": kindsSchema,
            "limit": ["type": "integer", "description": "Max messages to return (default 20)."] as [String: any Sendable],
            "unread_only": ["type": "boolean", "description": "Only messages newer than this agent's last read."] as [String: any Sendable],
        ]
        let requestProps: [String: any Sendable] = [
            "topic": ["type": "string", "description": "Topic to send the request to."] as [String: any Sendable],
            "payload": ["type": "string", "description": "Request body."] as [String: any Sendable],
            "timeout_seconds": ["type": "integer", "description": "Optional wait timeout."] as [String: any Sendable],
        ]
        let snapshotProps: [String: any Sendable] = [
            "agent_id": ["type": "string", "description": "Optional agent ID to scope the snapshot to."] as [String: any Sendable],
            "topics": ["type": "array", "items": ["type": "string"] as [String: any Sendable], "description": "Optional bus topics to include recent messages from."] as [String: any Sendable],
            "message_limit": ["type": "integer", "description": "Max recent bus messages per topic (default 10)."] as [String: any Sendable],
        ]
        let replyProps: [String: any Sendable] = [
            "request_id": ["type": "string", "description": "UUID of the request this message is replying to."] as [String: any Sendable],
            "topic": ["type": "string", "description": "Bus topic the original request was sent to."] as [String: any Sendable],
            "payload": ["type": "string", "description": "Reply body."] as [String: any Sendable],
        ]
        return [
            rawSpec("bus_publish",
                "Publish a message to an internal agent bus topic. Fast, typed, fire-and-forget. "
                + "Use for progress updates, task hand-offs, and broadcasts."
                + " topic format: 'project:<ProjectName>' or 'agent:<AgentName>' or 'task:<Name>'.",
                properties: publishProps, required: ["topic", "kind", "payload"]),
            rawSpec("bus_subscribe",
                "Subscribe this agent to a bus topic so it receives messages published there.",
                properties: subscribeProps, required: ["topic"]),
            rawSpec("bus_read",
                "Read messages from a bus topic. Optionally filter by kind or unread only.",
                properties: readProps, required: ["topic"]),
            rawSpec("bus_request",
                "Publish a request to a bus topic and wait for the first reply. "
                + "Use for synchronous coordination between agents. Timeout defaults to 30s.",
                properties: requestProps, required: ["topic", "payload"]),
            rawSpec("bus_reply",
                "Publish a reply to a specific pending bus request. Resolves the requester's wait. "
                + "Use only when you have read a request and need to respond to it.",
                properties: replyProps, required: ["request_id", "topic", "payload"]),
            rawSpec("bus_context_snapshot",
                "Return a shared context snapshot for an agent: working directory, visible plans, "
                + "applicable rules, and recent bus messages. Use to bring a new agent or a sub-agent "
                + "up to speed without re-reading the same files and plans independently.",
                properties: snapshotProps, required: []),
        ]
    }

    // MARK: - Handlers

    private static func busPublish(_ call: ToolCall) async -> String {
        struct Args: Decodable {
            let agent_id: String?
            let topic: String
            let kind: String
            let payload: String
        }
        guard let args = decodeArgs(call, as: Args.self),
              let kind = AgentBusMessageKind(rawValue: args.kind.lowercased())
        else {
            return errorJSON("bus_publish requires 'topic', 'kind' (event|request|task|status), and 'payload'")
        }
        let senderID = UUID(uuidString: args.agent_id ?? "")
        let senderName = await busSenderName(for: senderID)
        let message = AgentBusMessage(
            topic: args.topic,
            sender: senderID ?? UUID(),
            senderName: senderName,
            kind: kind,
            payload: args.payload)
        let hadSubscribers = await AgentBus.shared.publish(message)
        return jsonString([
            "published": true,
            "topic": args.topic,
            "had_subscribers": hadSubscribers,
            "message_id": message.id.uuidString,
        ])
    }

    private static func busSubscribe(_ call: ToolCall) async -> String {
        struct Args: Decodable {
            let agent_id: String?
            let topic: String
        }
        guard let args = decodeArgs(call, as: Args.self)
        else { return errorJSON("bus_subscribe requires 'topic'") }
        let agentID = UUID(uuidString: args.agent_id ?? "") ?? UUID()
        await AgentBus.shared.subscribe(agentID: agentID, topic: args.topic)
        return jsonString(["subscribed": true, "topic": args.topic])
    }

    private static func busRead(_ call: ToolCall) async -> String {
        struct Args: Decodable {
            let agent_id: String?
            let topic: String
            let kinds: [String]?
            let limit: Int?
            let unread_only: Bool?
        }
        guard let args = decodeArgs(call, as: Args.self)
        else { return errorJSON("bus_read requires 'topic'") }
        let agentID = UUID(uuidString: args.agent_id ?? "") ?? UUID()
        let parsedKinds = args.kinds?.compactMap { AgentBusMessageKind(rawValue: $0.lowercased()) }
        let messages = await AgentBus.shared.read(
            topic: args.topic,
            agentID: agentID,
            kinds: parsedKinds,
            limit: args.limit ?? 20,
            unreadOnly: args.unread_only ?? false)
        await AgentBus.shared.markRead(topic: args.topic, agentID: agentID)
        let items: [[String: any Sendable]] = messages.map { m in
            [
                "id": m.id.uuidString,
                "sender": m.senderName,
                "kind": m.kind.rawValue,
                "payload": m.payload,
                "timestamp": ISO8601DateFormatter().string(from: m.timestamp),
            ]
        }
        return jsonString(["topic": args.topic, "messages": items, "count": items.count])
    }

    private static func busRequest(_ call: ToolCall) async -> String {
        struct Args: Decodable {
            let agent_id: String?
            let topic: String
            let payload: String
            let timeout_seconds: Int?
        }
        guard let args = decodeArgs(call, as: Args.self)
        else { return errorJSON("bus_request requires 'topic' and 'payload'") }
        let senderID = UUID(uuidString: args.agent_id ?? "")
        let senderName = await busSenderName(for: senderID)
        let message = AgentBusMessage(
            topic: args.topic,
            sender: senderID ?? UUID(),
            senderName: senderName,
            kind: .request,
            payload: args.payload)
        let timeout: Duration? = args.timeout_seconds.map { .seconds($0) }
        do {
            let reply = try await AgentBus.shared.request(message: message, timeout: timeout)
            return jsonString([
                "status": "replied",
                "reply": reply.payload,
                "sender": reply.senderName,
                "reply_id": reply.id.uuidString,
            ])
        } catch let error as AgentBusError {
            return errorJSON(error.description)
        } catch {
            return errorJSON("bus_request failed: \(error.localizedDescription)")
        }
    }

    private static func busReply(_ call: ToolCall) async -> String {
        struct Args: Decodable {
            let agent_id: String?
            let request_id: String
            let topic: String
            let payload: String
        }
        guard let args = decodeArgs(call, as: Args.self),
              let requestID = UUID(uuidString: args.request_id)
        else {
            return errorJSON("bus_reply requires 'request_id' (UUID), 'topic', and 'payload'")
        }
        let senderID = UUID(uuidString: args.agent_id ?? "")
        let senderName = await busSenderName(for: senderID)
        let message = AgentBusMessage(
            topic: args.topic,
            sender: senderID ?? UUID(),
            senderName: senderName,
            kind: .reply,
            payload: args.payload,
            inReplyTo: requestID)
        let resolved = await AgentBus.shared.reply(message, to: requestID)
        return jsonString([
            "replied": resolved,
            "request_id": requestID.uuidString,
            "topic": args.topic,
            "message_id": message.id.uuidString,
        ])
    }

    private static func busContextSnapshot(_ call: ToolCall) async -> String {
        struct Args: Decodable {
            let agent_id: String?
            let topics: [String]?
            let message_limit: Int?
        }
        guard let args = decodeArgs(call, as: Args.self)
        else { return errorJSON("bus_context_snapshot: invalid arguments") }

        let monitorID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let agentID = args.agent_id.flatMap { UUID(uuidString: $0) }
        let agent = await MainActor.run { agentID.flatMap { workspace?.agent(id: $0) } }
        let projectName = await MainActor.run { agent.flatMap { workspace?.projectName(for: $0) } }
        let workingDirectory = agent?.workingDirectory

        // Recent bus messages: either requested topics or all known topics.
        let limit = min(max(args.message_limit ?? 10, 1), 50)
        let busTopics = await {
            if let requested = args.topics, !requested.isEmpty {
                return requested
            }
            return await AgentBus.shared.topics()
        }()
        var busMessages: [[String: any Sendable]] = []
        for topic in busTopics {
            let messages = await AgentBus.shared.read(
                topic: topic,
                agentID: monitorID,
                limit: limit)
            for m in messages {
                busMessages.append([
                    "topic": topic,
                    "id": m.id.uuidString,
                    "sender": m.senderName,
                    "kind": m.kind.rawValue,
                    "payload": m.payload,
                    "timestamp": ISO8601DateFormatter().string(from: m.timestamp),
                ])
            }
        }

        // Visible plans for the agent.
        let planPrompt: String = await MainActor.run {
            if let agent = agent {
                return ChatViewModel.planContextPrompt(for: agent, projectName: projectName)
            }
            return ""
        }

        // Applicable rules for the agent.
        let rules: [String] = await MainActor.run {
            guard let agent = agent else { return [] }
            return SwiftMaestroSettingsStore.loadRules().filter {
                $0.enabled
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ($0.scope == "All" || $0.scope == agent.name)
            }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        // Project rules from the working directory.
        let projectRules: [String] = await MainActor.run {
            guard let wd = workingDirectory, !wd.isEmpty else { return [] }
            return ProjectRuleService.shared.rules(forWorkingDirectory: wd).map { rule in
                "[\(rule.source.displayName)] \(rule.path)\n\(rule.content)"
            }
        }

        return jsonString([
            "agent_id": agentID?.uuidString ?? "",
            "agent_name": agent?.name ?? "",
            "project": projectName ?? "",
            "working_directory": workingDirectory ?? "",
            "plan_context": planPrompt,
            "rules": rules,
            "project_rules": projectRules,
            "bus_messages": busMessages,
            "bus_topics": busTopics,
        ])
    }

    // MARK: - Helpers

    private static func busSenderName(for agentID: UUID?) async -> String {
        guard let agentID = agentID else { return "Unknown" }
        if let agent = await MainActor.run(body: { workspace?.agent(id: agentID) }) {
            return agent.name
        }
        return agentID.uuidString
    }
}
