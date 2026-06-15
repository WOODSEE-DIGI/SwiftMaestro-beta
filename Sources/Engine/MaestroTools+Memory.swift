import Foundation
import MLXLMCommon

// MARK: - Native memory tools
//
// In-process durable memory backed by `SimpleMemoryStore` (~/.ai-context/memory),
// the SAME shared store other AI tools read. These replace the ai-context-bridge
// `memory_*` tools so a self-contained build (no MCP servers) still has working,
// recallable memory out of the box.
extension MaestroTools {

    static let memoryToolNames: Set<String> = [
        "memory_write", "memory_read", "memory_search", "memory_list",
    ]

    private static let memoryKindDesc =
        "Namespace: 'knowledge' (durable facts/decisions), 'memory' (conversation "
        + "notes), 'context' (session state), or 'skill'. Defaults to 'knowledge'."

    static var memoryToolSpecs: [ToolSpec] {
        [
            rawSpec("memory_write",
                "Save durable text to the shared local memory store so it persists "
                + "across chats and can be recalled later. Use for facts, decisions, "
                + "and notes worth remembering.",
                properties: [
                    "path": ["type": "string", "description": "Slash path identifying the entry, e.g. 'projects/swiftmaestro/notes'."],
                    "content": ["type": "string", "description": "The text to store."],
                    "kind": ["type": "string", "description": memoryKindDesc],
                ], required: ["path", "content"]),
            rawSpec("memory_read",
                "Read back a memory entry previously saved with memory_write.",
                properties: [
                    "path": ["type": "string", "description": "The entry's slash path."],
                    "kind": ["type": "string", "description": memoryKindDesc],
                ], required: ["path"]),
            rawSpec("memory_search",
                "Full-text search across the whole local memory store. Returns matching "
                + "entry paths with a snippet.",
                properties: [
                    "query": ["type": "string", "description": "Text to search for."],
                ], required: ["query"]),
            rawSpec("memory_list",
                "List stored memory entry paths, optionally limited to one kind.",
                properties: [
                    "kind": ["type": "string", "description": memoryKindDesc],
                ], required: []),
        ]
    }

    private struct MemoryWriteArgs: Codable { let path: String?; let content: String?; let kind: String? }
    private struct MemoryReadArgs: Codable { let path: String?; let kind: String? }
    private struct MemorySearchArgs: Codable { let query: String? }
    private struct MemoryListArgs: Codable { let kind: String? }

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
        let kindRaw = args?.kind?.trimmingCharacters(in: .whitespaces) ?? ""
        let kinds: [MaestroURI.Kind] = kindRaw.isEmpty
            ? MaestroURI.Kind.allCases
            : [memoryKind(kindRaw)]
        var lines: [String] = []
        for kind in kinds {
            for entry in store.entries(kind: kind) {
                lines.append("- [\(kind.rawValue)] \(entry)")
            }
        }
        guard !lines.isEmpty else { return "Memory store is empty." }
        return "Memory entries (\(lines.count)):\n" + lines.joined(separator: "\n")
    }
}
