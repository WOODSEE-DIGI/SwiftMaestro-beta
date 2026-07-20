import Foundation

/// A typed message on the SwiftMaestro internal agent bus.
/// Used for reactive, low-latency agent-to-agent and agent-to-core communication
/// without going through the slower polling `send_agent_message` / `read_agent_messages`
/// inbox path. Messages are durable, topic-addressed, and support request/reply.
public struct AgentBusMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let topic: String
    public let sender: UUID
    public let senderName: String
    public let kind: AgentBusMessageKind
    public let payload: String
    public let timestamp: Date
    public let inReplyTo: UUID?

    public init(
        id: UUID = UUID(),
        topic: String,
        sender: UUID,
        senderName: String,
        kind: AgentBusMessageKind,
        payload: String,
        timestamp: Date = Date(),
        inReplyTo: UUID? = nil
    ) {
        self.id = id
        self.topic = topic
        self.sender = sender
        self.senderName = senderName
        self.kind = kind
        self.payload = payload
        self.timestamp = timestamp
        self.inReplyTo = inReplyTo
    }

    /// Human-readable summary for tool results and UI logging.
    public var summary: String {
        "[\(topic)] \(senderName) \(kind.rawValue): \(payload.prefix(120))"
    }
}

public enum AgentBusMessageKind: String, Codable, Sendable, CaseIterable {
    /// Fire-and-forget broadcast on a topic.
    case event
    /// A request expecting a reply on the same topic (or `inReplyTo`).
    case request
    /// A reply to a previous request.
    case reply
    /// A task hand-off that a sub-agent should pick up.
    case task
    /// Progress / heartbeat update.
    case status
}

/// A pending request waiting for a matching reply on the bus.
internal struct PendingBusRequest: Identifiable, Sendable {
    let id: UUID
    let topic: String
    let continuation: CheckedContinuation<AgentBusMessage, Error>
    let timeoutTask: Task<Void, Never>?
}

/// Errors the agent bus can surface.
public enum AgentBusError: Error, CustomStringConvertible {
    case timeout(topic: String, requestID: UUID)
    case noSubscribers(topic: String)
    case invalidTopic
    case unknownRequest(UUID)

    public var description: String {
        switch self {
        case .timeout(let topic, let id):
            return "Bus request \(id) on '\(topic)' timed out"
        case .noSubscribers(let topic):
            return "No subscribers on topic '\(topic)'"
        case .invalidTopic:
            return "Invalid bus topic"
        case .unknownRequest(let id):
            return "Unknown bus request \(id)"
        }
    }
}
