import Foundation

// MARK: - Context Store
//
// A structured, queryable snapshot of the current operational context for an
// agent, project, or session. The context store is the first pillar of Phase 4
// advanced memory: it gives the model a durable, scannable "working memory" of
// goals, recent decisions, open todos, key facts, and attached files without
// having to re-read the entire chat history every turn.

/// The scope a context profile is attached to. `kind` disambiguates the
/// identifier so one store can serve agents, projects, and sessions.
struct ContextScope: Codable, Sendable, Hashable, Identifiable, CustomStringConvertible {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case agent, project, session
    }

    var kind: Kind
    var identifier: String

    var id: String { "\(kind.rawValue):\(identifier)" }
    var description: String { id }

    static func agent(_ id: String) -> ContextScope { ContextScope(kind: .agent, identifier: id) }
    static func project(_ name: String) -> ContextScope { ContextScope(kind: .project, identifier: name) }
    static func session(_ id: String) -> ContextScope { ContextScope(kind: .session, identifier: id) }
}

/// A durable context profile. Keep it small enough to be injected into the
/// system prompt every turn, but rich enough to capture what matters now.
struct MemoryContextProfile: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var scope: ContextScope
    var title: String
    var updatedAt: Date

    var workingDirectory: String?
    var activeProject: String?
    var currentGoals: [String]
    var keyFacts: [String]
    var recentDecisions: [ContextDecision]
    var recentTodos: [ContextTodo]
    var recentBusMessages: [ContextBusMessage]
    var attachedFiles: [String]
    var notes: String

    init(
        id: UUID = UUID(),
        scope: ContextScope,
        title: String,
        workingDirectory: String? = nil,
        activeProject: String? = nil,
        currentGoals: [String] = [],
        keyFacts: [String] = [],
        recentDecisions: [ContextDecision] = [],
        recentTodos: [ContextTodo] = [],
        recentBusMessages: [ContextBusMessage] = [],
        attachedFiles: [String] = [],
        notes: String = ""
    ) {
        self.id = id
        self.scope = scope
        self.title = title
        self.updatedAt = Date()
        self.workingDirectory = workingDirectory
        self.activeProject = activeProject
        self.currentGoals = currentGoals
        self.keyFacts = keyFacts
        self.recentDecisions = recentDecisions
        self.recentTodos = recentTodos
        self.recentBusMessages = recentBusMessages
        self.attachedFiles = attachedFiles
        self.notes = notes
    }

    mutating func touch() {
        updatedAt = Date()
    }
}

struct ContextDecision: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var rationale: String?
    var timestamp: Date

    init(id: UUID = UUID(), title: String, rationale: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.timestamp = timestamp
    }
}

struct ContextTodo: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var task: String
    var priority: String
    var status: String
    var timestamp: Date

    init(
        id: UUID = UUID(),
        task: String,
        priority: String = "medium",
        status: String = "open",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.task = task
        self.priority = priority
        self.status = status
        self.timestamp = timestamp
    }
}

struct ContextBusMessage: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var topic: String
    var kind: String
    var payload: String
    var senderName: String
    var timestamp: Date

    init(
        id: String,
        topic: String,
        kind: String,
        payload: String,
        senderName: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.topic = topic
        self.kind = kind
        self.payload = payload
        self.senderName = senderName
        self.timestamp = timestamp
    }
}
