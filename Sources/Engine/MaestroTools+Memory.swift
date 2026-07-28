import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native memory tools
//
// In-process durable memory backed by `SimpleMemoryStore` (~/.ai-context/memory),
// the SAME shared store other AI tools read. These replace the ai-context-bridge
// `memory_*` tools so a self-contained build (no MCP servers) still has working,
// recallable memory out of the box.
//
// Phase 4 additions: context store, fact graph, and knowledge promotion.

extension MaestroTools {

    static func registerMemoryTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "memory_write", spec: memoryToolSpecs[0],
                category: ToolCategory.memory.rawValue,
                handler: { call in await memoryWrite(call) }),
            ToolDefinition(
                name: "memory_read", spec: memoryToolSpecs[1],
                category: ToolCategory.memory.rawValue,
                handler: { call in await memoryRead(call) }),
            ToolDefinition(
                name: "memory_search", spec: memoryToolSpecs[2],
                category: ToolCategory.memory.rawValue,
                handler: { call in await memorySearch(call) }),
            ToolDefinition(
                name: "memory_list", spec: memoryToolSpecs[3],
                category: ToolCategory.memory.rawValue,
                handler: { call in await memoryList(call) }),
            ToolDefinition(
                name: "context_update", spec: memoryToolSpecs[4],
                category: ToolCategory.memory.rawValue,
                handler: { call in await contextUpdate(call) }),
            ToolDefinition(
                name: "context_read", spec: memoryToolSpecs[5],
                category: ToolCategory.memory.rawValue,
                handler: { call in await contextRead(call) }),
            ToolDefinition(
                name: "fact_remember", spec: memoryToolSpecs[6],
                category: ToolCategory.memory.rawValue,
                handler: { call in await factRemember(call) }),
            ToolDefinition(
                name: "fact_query", spec: memoryToolSpecs[7],
                category: ToolCategory.memory.rawValue,
                handler: { call in await factQuery(call) }),
            ToolDefinition(
                name: "memory_promote", spec: memoryToolSpecs[8],
                category: ToolCategory.memory.rawValue,
                handler: { call in await memoryPromote(call) }),
            ToolDefinition(
                name: "memory_learn", spec: memoryToolSpecs[9],
                category: ToolCategory.memory.rawValue,
                handler: { call in await memoryLearn(call) }),
        ])
    }

    private static let memoryKindDesc =
        "Namespace: 'knowledge' (durable facts/decisions), 'memory' (conversation "
        + "notes), 'context' (session state), or 'skill'. Defaults to 'knowledge'."

    static var memoryToolSpecs: [ToolSpec] {
        let scopeKindSchema: [String: any Sendable] = [
            "type": "string",
            "description": "agent | project | session",
        ]
        let decisionItemSchema: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Decision title."] as [String: any Sendable],
                "rationale": ["type": "string", "description": "Why this decision was made."] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["title"],
        ] as [String: any Sendable]
        let todoItemSchema: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "task": ["type": "string", "description": "Task description."] as [String: any Sendable],
                "priority": ["type": "string", "description": "low | medium | high"] as [String: any Sendable],
                "status": ["type": "string", "description": "open | done | cancelled"] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["task"],
        ] as [String: any Sendable]
        let relationItemSchema: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "relation": ["type": "string", "description": "Relationship type, e.g. 'uses' or 'depends_on'."] as [String: any Sendable],
                "target_id": ["type": "string", "description": "Existing fact node ID to link to."] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["relation", "target_id"],
        ] as [String: any Sendable]
        let learnFactItemSchema: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "Short human-readable label for the learned fact."] as [String: any Sendable],
                "kind": ["type": "string", "description": "fact | entity | preference | decision | project | task | relationship"] as [String: any Sendable],
                "payload": ["type": "string", "description": "Detailed fact content."] as [String: any Sendable],
                "confidence": ["type": "number", "description": "Confidence 0.0-1.0."] as [String: any Sendable],
                "relations": ["type": "array", "items": relationItemSchema, "description": "Related facts: [{relation, target_id}]."] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["label", "kind", "payload"],
        ] as [String: any Sendable]
        return [
            rawSpec("memory_write",
                "Save durable text to the shared local memory store so it persists "
                + "across chats and can be recalled later. Use for facts, decisions, "
                + "and notes worth remembering.",
                properties: [
                    "path": ["type": "string", "description": "Slash path identifying the entry, e.g. 'projects/swiftmaestro/notes'."] as [String: any Sendable],
                    "content": ["type": "string", "description": "The text to store."] as [String: any Sendable],
                    "kind": ["type": "string", "description": memoryKindDesc] as [String: any Sendable],
                ] as [String: any Sendable], required: ["path", "content"]),
            rawSpec("memory_read",
                "Read back a memory entry previously saved with memory_write.",
                properties: [
                    "path": ["type": "string", "description": "The entry's slash path."] as [String: any Sendable],
                    "kind": ["type": "string", "description": memoryKindDesc] as [String: any Sendable],
                ] as [String: any Sendable], required: ["path"]),
            rawSpec("memory_search",
                "Full-text search across the whole local memory store. Returns matching "
                + "entry paths with a snippet.",
                properties: [
                    "query": ["type": "string", "description": "Text to search for."] as [String: any Sendable],
                ] as [String: any Sendable], required: ["query"]),
            rawSpec("memory_list",
                "List a small page of stored memory entry paths (metadata only). Prefer memory_search for finding specific content. Default limit is 50; use offset to paginate.",
                properties: [
                    "kind": ["type": "string", "description": memoryKindDesc] as [String: any Sendable],
                    "path": ["type": "string", "description": "Optional path prefix to narrow results (e.g. 'projects/SwiftMaestro')."] as [String: any Sendable],
                    "limit": ["type": "integer", "description": "Max entries to return (default 50, max 200)."] as [String: any Sendable],
                    "offset": ["type": "integer", "description": "Skip this many entries for pagination."] as [String: any Sendable],
                ] as [String: any Sendable], required: []),
            rawSpec("context_update",
                "Update the structured context profile for an agent, project, or session. "
                + "Use this to keep the model's working memory current: goals, open todos, "
                + "recent decisions, attached files, and notes.",
                properties: [
                    "scope_kind": scopeKindSchema,
                    "scope_id": ["type": "string", "description": "Agent UUID, project name, or session ID."] as [String: any Sendable],
                    "title": ["type": "string", "description": "Short display title for this context."] as [String: any Sendable],
                    "working_directory": ["type": "string", "description": "Current working directory."] as [String: any Sendable],
                    "active_project": ["type": "string", "description": "Name of the active project."] as [String: any Sendable],
                    "current_goals": ["type": "array", "items": ["type": "string"] as [String: any Sendable], "description": "Current goals."] as [String: any Sendable],
                    "key_facts": ["type": "array", "items": ["type": "string"] as [String: any Sendable], "description": "Fact graph node IDs relevant to this context."] as [String: any Sendable],
                    "recent_decisions": ["type": "array", "items": decisionItemSchema, "description": "Recent decisions to record."] as [String: any Sendable],
                    "recent_todos": ["type": "array", "items": todoItemSchema, "description": "Current todos to record."] as [String: any Sendable],
                    "attached_files": ["type": "array", "items": ["type": "string"] as [String: any Sendable], "description": "Files attached to this context."] as [String: any Sendable],
                    "notes": ["type": "string", "description": "Freeform notes."] as [String: any Sendable],
                    "replace_notes": ["type": "boolean", "description": "If true, replace existing notes instead of appending."] as [String: any Sendable],
                ] as [String: any Sendable], required: []),
            rawSpec("context_read",
                "Read the structured context profile for an agent, project, or session.",
                properties: [
                    "scope_kind": scopeKindSchema,
                    "scope_id": ["type": "string", "description": "Agent UUID, project name, or session ID."] as [String: any Sendable],
                ] as [String: any Sendable], required: []),
            rawSpec("fact_remember",
                "Add a durable fact or entity to the shared fact graph. Optionally link it "
                + "to related facts with typed edges (e.g. 'uses', 'depends_on', 'prefers').",
                properties: [
                    "label": ["type": "string", "description": "Short human-readable label, e.g. 'Swift 6.3' or 'User prefers dark mode'."] as [String: any Sendable],
                    "kind": ["type": "string", "description": "fact | entity | preference | decision | project | task | relationship"] as [String: any Sendable],
                    "payload": ["type": "string", "description": "Detailed fact content."] as [String: any Sendable],
                    "source_uri": ["type": "string", "description": "Optional source memory URI."] as [String: any Sendable],
                    "confidence": ["type": "number", "description": "Confidence 0.0-1.0."] as [String: any Sendable],
                    "relations": ["type": "array", "items": relationItemSchema, "description": "Related facts: [{relation, target_id}]."] as [String: any Sendable],
                ] as [String: any Sendable], required: ["label", "kind", "payload"]),
            rawSpec("fact_query",
                "Search the shared fact graph by label/payload text, optionally filtered by kind "
                + "or by relationships from a known fact ID.",
                properties: [
                    "query": ["type": "string", "description": "Text to search for."] as [String: any Sendable],
                    "kind": ["type": "string", "description": "Optional fact kind filter."] as [String: any Sendable],
                    "relation": ["type": "string", "description": "Optional relation filter when source_id is set."] as [String: any Sendable],
                    "source_id": ["type": "string", "description": "Optional fact ID to find related facts."] as [String: any Sendable],
                    "limit": ["type": "integer", "description": "Max results."] as [String: any Sendable],
                ] as [String: any Sendable], required: []),
            rawSpec("memory_promote",
                "Promote a memory entry from the ephemeral 'memory' namespace to durable "
                + "'knowledge' so it survives long-term.",
                properties: [
                    "path": ["type": "string", "description": "Slash path of the memory entry to promote."] as [String: any Sendable],
                    "kind": ["type": "string", "description": "Source kind: 'memory' (default), 'context', or 'skill'."] as [String: any Sendable],
                ] as [String: any Sendable], required: ["path"]),
            rawSpec("memory_learn",
                "Extract and store durable facts from a memory entry, conversation, or other "
                + "source. Each learned fact is added to the shared fact graph and linked to the "
                + "source URI so it can be recalled later.",
                properties: [
                    "source_uri": ["type": "string", "description": "URI or slash path of the source memory entry (e.g. 'memory://projects/swiftmaestro/notes')."] as [String: any Sendable],
                    "facts": ["type": "array", "items": learnFactItemSchema, "description": "Facts to learn."] as [String: any Sendable],
                ] as [String: any Sendable], required: ["facts"]),
        ]
    }

    // MARK: - Existing handlers

    private struct MemoryWriteArgs: Codable { let path: String?; let content: String?; let kind: String? }
    private struct MemoryReadArgs: Codable { let path: String?; let kind: String? }
    private struct MemorySearchArgs: Codable { let query: String? }
    private struct MemoryListArgs: Codable { let kind: String?; let path: String?; let limit: Int?; let offset: Int? }

    private static func memoryKind(_ raw: String?) -> MaestroURI.Kind {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty,
              let kind = MaestroURI.Kind(rawValue: raw) else { return .knowledge }
        return kind
    }

    private static func memoryPath(_ raw: String) -> [String] {
        raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func memoryWrite(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MemoryWriteArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty,
              let content = args.content else {
            return errorJSON("memory_write requires 'path' and 'content'")
        }
        let uri = MaestroURI(kind: memoryKind(args.kind), path: memoryPath(path))
        do {
            try SimpleMemoryStore().save(content, at: uri)
            return jsonString(["status": "saved", "uri": uri.description])
        } catch {
            return errorJSON("failed to save memory: \(error.localizedDescription)")
        }
    }

    static func memoryRead(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MemoryReadArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return errorJSON("memory_read requires 'path'")
        }
        let uri = MaestroURI(kind: memoryKind(args.kind), path: memoryPath(path))
        do {
            guard let content = try SimpleMemoryStore().load(uri) else {
                return jsonString(["status": "not_found", "uri": uri.description])
            }
            return content
        } catch {
            return errorJSON("failed to read memory: \(error.localizedDescription)")
        }
    }

    static func memorySearch(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MemorySearchArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return errorJSON("memory_search requires 'query'")
        }
        let hits = SimpleMemoryStore().search(query, limit: 20)
        guard !hits.isEmpty else { return "No memory entries match \"\(query)\"." }
        let lines = hits.map { "- \($0.path)\n    \($0.snippet)" }
        return "Found \(hits.count) match(es) for \"\(query)\":\n" + lines.joined(separator: "\n")
    }

    static func memoryList(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: MemoryListArgs.self)
        let store = SimpleMemoryStore()
        let kind = memoryKind(args?.kind)
        let pathPrefix = args?.path?.trimmingCharacters(in: .whitespaces)
        let limit = max(1, min(args?.limit ?? 50, 200))
        let offset = max(0, args?.offset ?? 0)
        let total = store.countEntries(kind: kind, pathPrefix: pathPrefix)
        let entries = store.entries(kind: kind, pathPrefix: pathPrefix, limit: limit, offset: offset)
        guard !entries.isEmpty else { return "No memory entries in \(kind.rawValue)\(pathPrefix.map { " under \($0)" } ?? "")." }
        let lines = entries.map { "- [\(kind.rawValue)] \($0)" }
        if total == entries.count && offset == 0 {
            return "Memory entries (\(total)):\n" + lines.joined(separator: "\n")
        }
        return "Showing \(entries.count) of \(total) memory entries in \(kind.rawValue) (offset \(offset), limit \(limit)):\n" + lines.joined(separator: "\n") + "\n\nUse memory_search to find specific content, or increase offset to paginate."
    }

    // MARK: - Context store handlers

    private struct ContextUpdateArgs: Codable {
        let agent_id: String?
        let scope_kind: String?
        let scope_id: String?
        let title: String?
        let working_directory: String?
        let active_project: String?
        let current_goals: [String]?
        let key_facts: [String]?
        let recent_decisions: [ContextDecisionDTO]?
        let recent_todos: [ContextTodoDTO]?
        let attached_files: [String]?
        let notes: String?
        let replace_notes: Bool?
    }

    private struct ContextReadArgs: Codable {
        let agent_id: String?
        let scope_kind: String?
        let scope_id: String?
    }

    private struct ContextDecisionDTO: Codable {
        let title: String
        let rationale: String?
    }

    private struct ContextTodoDTO: Codable {
        let task: String
        let priority: String?
        let status: String?
    }

    private static func resolveScope(
        kind: String?, id: String?, fallbackAgentID: String?
    ) -> ContextScope? {
        let normalizedKind = kind?.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedID = id?.trimmingCharacters(in: .whitespaces)
        let fallback = fallbackAgentID?.trimmingCharacters(in: .whitespaces)

        if let normalizedKind, let kind = ContextScope.Kind(rawValue: normalizedKind), let normalizedID, !normalizedID.isEmpty {
            return ContextScope(kind: kind, identifier: normalizedID)
        }
        if let fallback, !fallback.isEmpty {
            return ContextScope(kind: .agent, identifier: fallback)
        }
        return nil
    }

    private static func contextUpdate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ContextUpdateArgs.self),
              let scope = resolveScope(kind: args.scope_kind, id: args.scope_id, fallbackAgentID: args.agent_id)
        else {
            return errorJSON("context_update requires 'scope_kind' + 'scope_id', or an agent_id")
        }
        let decisions = args.recent_decisions?.map {
            ContextDecision(title: $0.title, rationale: $0.rationale)
        }
        let todos = args.recent_todos?.map {
            ContextTodo(
                task: $0.task,
                priority: $0.priority?.trimmingCharacters(in: .whitespaces) ?? "medium",
                status: $0.status?.trimmingCharacters(in: .whitespaces) ?? "open")
        }
        let profile = await MaestroMemoryEngine.shared.updateProfile(
            for: scope,
            title: args.title,
            workingDirectory: args.working_directory,
            activeProject: args.active_project,
            currentGoals: args.current_goals,
            keyFacts: args.key_facts,
            recentDecisions: decisions,
            recentTodos: todos,
            attachedFiles: args.attached_files,
            notes: args.notes,
            replaceNotes: args.replace_notes ?? false)
        return jsonString([
            "updated": true,
            "scope": profile.scope.description,
            "title": profile.title,
            "updated_at": ISO8601DateFormatter().string(from: profile.updatedAt),
        ])
    }

    private static func contextRead(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ContextReadArgs.self),
              let scope = resolveScope(kind: args.scope_kind, id: args.scope_id, fallbackAgentID: args.agent_id)
        else {
            return errorJSON("context_read requires 'scope_kind' + 'scope_id', or an agent_id")
        }
        let profile = await MaestroMemoryEngine.shared.loadProfile(for: scope)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profile),
              let json = String(data: data, encoding: .utf8) else {
            return errorJSON("failed to encode context profile")
        }
        return json
    }

    // MARK: - Fact graph handlers

    private struct FactRememberArgs: Codable {
        let label: String?
        let kind: String?
        let payload: String?
        let source_uri: String?
        let confidence: Double?
        let relations: [FactRelationDTO]?
    }

    private struct FactRelationDTO: Codable {
        let relation: String
        let target_id: String
    }

    private struct FactQueryArgs: Codable {
        let query: String?
        let kind: String?
        let relation: String?
        let source_id: String?
        let limit: Int?
    }

    private static func factKind(_ raw: String?) -> FactKind {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty,
              let kind = FactKind(rawValue: raw) else { return .fact }
        return kind
    }

    private static func optionalFactKind(_ raw: String?) -> FactKind? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty,
              let kind = FactKind(rawValue: raw) else { return nil }
        return kind
    }

    private static func factRemember(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: FactRememberArgs.self),
              let label = args.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
              let payload = args.payload?.trimmingCharacters(in: .whitespacesAndNewlines),
              let kind = args.kind?.trimmingCharacters(in: .whitespaces).lowercased(), !kind.isEmpty
        else {
            return errorJSON("fact_remember requires 'label', 'kind', and 'payload'")
        }
        let kindValue = factKind(kind)
        let relations = args.relations?.map { FactRelationInput(relation: $0.relation, targetID: $0.target_id) } ?? []
        let id = await MaestroMemoryEngine.shared.remember(
            label: label,
            kind: kindValue,
            payload: payload,
            sourceURI: args.source_uri,
            confidence: args.confidence ?? 1.0,
            relations: relations)
        return jsonString([
            "remembered": true,
            "fact_id": id,
            "label": label,
            "kind": kindValue.rawValue,
        ])
    }

    private static func factQuery(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: FactQueryArgs.self) else {
            return errorJSON("fact_query: invalid arguments")
        }
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind = optionalFactKind(args.kind)
        let limit = max(1, min(args.limit ?? 20, 100))
        let nodes = await MaestroMemoryEngine.shared.queryFacts(
            query: query,
            kind: kind,
            relation: args.relation,
            sourceID: args.source_id,
            limit: limit)
        let items: [[String: any Sendable]] = nodes.map { node in
            [
                "id": node.id,
                "label": node.label,
                "kind": node.kind.rawValue,
                "payload": node.payload,
                "confidence": node.confidence,
                "source_uri": node.sourceURI ?? "",
                "created_at": ISO8601DateFormatter().string(from: node.createdAt),
            ]
        }
        return jsonString(["count": items.count, "facts": items])
    }

    // MARK: - Knowledge promotion

    private struct MemoryPromoteArgs: Codable {
        let path: String?
        let kind: String?
    }

    private static func memoryPromote(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MemoryPromoteArgs.self),
              let path = args.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return errorJSON("memory_promote requires 'path'")
        }
        let sourceKind: MaestroURI.Kind = {
            let raw = args.kind?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return MaestroURI.Kind(rawValue: raw) ?? .memory
        }()
        do {
            try await MaestroMemoryEngine.shared.promoteMemory(path: path, fromKind: sourceKind)
            return jsonString(["promoted": true, "path": path, "to": "knowledge"])
        } catch {
            return errorJSON("memory_promote failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Learning engine

    private struct MemoryLearnArgs: Codable {
        let source_uri: String?
        let facts: [MemoryLearnFactDTO]?
    }

    private struct MemoryLearnFactDTO: Codable {
        let label: String
        let kind: String
        let payload: String
        let confidence: Double?
        let relations: [MemoryLearnRelationDTO]?
    }

    private struct MemoryLearnRelationDTO: Codable {
        let relation: String
        let target_id: String
    }

    private static func memoryLearn(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MemoryLearnArgs.self),
              let facts = args.facts, !facts.isEmpty else {
            return errorJSON("memory_learn requires at least one fact")
        }
        let sourceURI = args.source_uri?.trimmingCharacters(in: .whitespacesAndNewlines)
        var learnedIDs: [String] = []
        for fact in facts {
            let label = fact.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let relations = fact.relations?.map {
                FactRelationInput(relation: $0.relation, targetID: $0.target_id)
            } ?? []
            let id = await MaestroMemoryEngine.shared.remember(
                label: label,
                kind: factKind(fact.kind),
                payload: fact.payload.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceURI: sourceURI,
                confidence: fact.confidence ?? 1.0,
                relations: relations)
            learnedIDs.append(id)
        }
        return jsonString([
            "learned": true,
            "count": learnedIDs.count,
            "fact_ids": learnedIDs,
            "source_uri": sourceURI ?? "",
        ])
    }
}
