import Foundation

// MARK: - Maestro Memory Engine
//
// Phase 4 advanced memory service. Manages:
//   - Context profiles (per agent/project/session)
//   - A typed fact graph
//   - Memory promotion from ephemeral memory to durable knowledge
//
// All state is persisted through `SimpleMemoryStore` under `~/.ai-context/memory`
// so it is shared with the rest of the local AI tooling ecosystem.

actor MaestroMemoryEngine {

    /// Shared singleton used by the native memory tools.
    static let shared = MaestroMemoryEngine()

    private let store = SimpleMemoryStore()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Context Profiles

    /// URI for a context profile: `maestro://context/<scopeKind>/<scopeID>/profile.json`
    private func profileURI(for scope: ContextScope) -> MaestroURI {
        MaestroURI(kind: .context, path: [scope.kind.rawValue, scope.identifier, "profile.json"])
    }

    /// Load or create a context profile for the given scope.
    func loadProfile(for scope: ContextScope, defaultTitle: String? = nil) async -> MemoryContextProfile {
        let uri = profileURI(for: scope)
        do {
            if let data = try store.load(uri)?.data(using: .utf8),
               let profile = try? decoder.decode(MemoryContextProfile.self, from: data) {
                return profile
            }
        } catch {
            NSLog("[MaestroMemoryEngine] failed to load profile for \(scope): \(error.localizedDescription)")
        }
        return MemoryContextProfile(
            scope: scope,
            title: defaultTitle ?? "\(scope.kind.rawValue.capitalized) context"
        )
    }

    /// Persist a context profile.
    func saveProfile(_ profile: MemoryContextProfile) async {
        var copy = profile
        copy.touch()
        let uri = profileURI(for: copy.scope)
        do {
            let data = try encoder.encode(copy)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try store.save(json, at: uri)
        } catch {
            NSLog("[MaestroMemoryEngine] failed to save profile for \(copy.scope): \(error.localizedDescription)")
        }
    }

    /// Merge a partial update into an existing profile. Nil values leave the
    /// existing field untouched.
    func updateProfile(
        for scope: ContextScope,
        title: String? = nil,
        workingDirectory: String? = nil,
        activeProject: String? = nil,
        currentGoals: [String]? = nil,
        keyFacts: [String]? = nil,
        recentDecisions: [ContextDecision]? = nil,
        recentTodos: [ContextTodo]? = nil,
        recentBusMessages: [ContextBusMessage]? = nil,
        attachedFiles: [String]? = nil,
        notes: String? = nil,
        replaceNotes: Bool = false
    ) async -> MemoryContextProfile {
        var profile = await loadProfile(for: scope)
        if let title { profile.title = title }
        if let workingDirectory { profile.workingDirectory = workingDirectory }
        if let activeProject { profile.activeProject = activeProject }
        if let currentGoals { profile.currentGoals = currentGoals }
        if let keyFacts { profile.keyFacts = keyFacts }
        if let recentDecisions { profile.recentDecisions = recentDecisions }
        if let recentTodos { profile.recentTodos = recentTodos }
        if let recentBusMessages { profile.recentBusMessages = recentBusMessages }
        if let attachedFiles { profile.attachedFiles = attachedFiles }
        if let notes {
            if replaceNotes || profile.notes.isEmpty {
                profile.notes = notes
            } else {
                profile.notes += "\n\n" + notes
            }
        }
        await saveProfile(profile)
        return profile
    }

    // MARK: - Fact Graph

    private let factGraphURI = MaestroURI(kind: .knowledge, path: ["facts", "graph.json"])

    /// Load the shared fact graph, creating an empty one if missing.
    func loadFactGraph() async -> FactGraph {
        do {
            if let data = try store.load(factGraphURI)?.data(using: .utf8),
               let graph = try? decoder.decode(FactGraph.self, from: data) {
                return graph
            }
        } catch {
            NSLog("[MaestroMemoryEngine] failed to load fact graph: \(error.localizedDescription)")
        }
        return FactGraph()
    }

    /// Persist the fact graph.
    func saveFactGraph(_ graph: FactGraph) async {
        var copy = graph
        copy.touch()
        do {
            let data = try encoder.encode(copy)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try store.save(json, at: factGraphURI)
        } catch {
            NSLog("[MaestroMemoryEngine] failed to save fact graph: \(error.localizedDescription)")
        }
    }

    /// Remember a fact by upserting a node and adding any supplied edges.
    /// Returns the fact's ID.
    func remember(
        label: String,
        kind: FactKind,
        payload: String,
        sourceURI: String? = nil,
        confidence: Double = 1.0,
        relations: [FactRelationInput] = []
    ) async -> String {
        var graph = await loadFactGraph()
        let id = graph.upsert(
            label: label,
            kind: kind,
            payload: payload,
            sourceURI: sourceURI,
            confidence: confidence)
        for relation in relations {
            graph.relate(source: id, relation: relation.relation, target: relation.targetID)
        }
        await saveFactGraph(graph)
        return id
    }

    /// Query facts by text and optional kind.
    func queryFacts(
        query: String,
        kind: FactKind? = nil,
        relation: String? = nil,
        sourceID: String? = nil,
        limit: Int = 20
    ) async -> [FactNode] {
        let graph = await loadFactGraph()
        if let sourceID {
            return graph.related(to: sourceID, relation: relation, limit: limit)
        }
        return graph.nodes(matching: query, kind: kind, limit: limit)
    }

    // MARK: - Knowledge Promotion

    /// Copy a memory entry (or directory) from the ephemeral `memory` namespace
    /// into the durable `knowledge` namespace.
    func promoteMemory(path: String, fromKind: MaestroURI.Kind = .memory) async throws {
        let source = MaestroURI(kind: fromKind, path: memoryPath(path))
        guard let content = try store.load(source) else {
            throw MaestroMemoryError.notFound(path)
        }
        let target = MaestroURI(kind: .knowledge, path: memoryPath(path))
        try store.save(content, at: target)
    }

    // MARK: - Prompt Helpers

    /// Render a profile as a compact, LLM-friendly context block.
    func contextPrompt(for scope: ContextScope) async -> String {
        let profile = await loadProfile(for: scope)
        var lines: [String] = []
        lines.append("## Context: \(profile.title)")
        lines.append("Scope: \(profile.scope)")
        if let wd = profile.workingDirectory, !wd.isEmpty { lines.append("Working directory: \(wd)") }
        if let project = profile.activeProject, !project.isEmpty { lines.append("Active project: \(project)") }
        if !profile.currentGoals.isEmpty {
            lines.append("Goals:")
            profile.currentGoals.forEach { lines.append("- \($0)") }
        }
        if !profile.recentDecisions.isEmpty {
            lines.append("Recent decisions:")
            profile.recentDecisions.forEach { lines.append("- \($0.title)") }
        }
        if !profile.recentTodos.isEmpty {
            lines.append("Open todos:")
            profile.recentTodos.filter { $0.status != "done" }.forEach { lines.append("- [\($0.priority)] \($0.task)") }
        }
        if !profile.keyFacts.isEmpty {
            lines.append("Key facts: \(profile.keyFacts.joined(separator: ", "))")
        }
        if !profile.notes.isEmpty {
            lines.append("Notes:\n\(profile.notes)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func memoryPath(_ raw: String) -> [String] {
        raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

struct FactRelationInput: Sendable, Codable {
    let relation: String
    let targetID: String
}

enum MaestroMemoryError: Error, CustomStringConvertible {
    case notFound(String)
    case invalidScope(String)

    var description: String {
        switch self {
        case .notFound(let path): return "Memory entry not found: \(path)"
        case .invalidScope(let msg): return "Invalid context scope: \(msg)"
        }
    }
}
