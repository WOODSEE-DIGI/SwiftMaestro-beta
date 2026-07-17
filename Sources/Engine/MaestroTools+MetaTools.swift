import Foundation
import MLXLMCommon

// MARK: - Compact Tool Mode meta-tools: search_tools / call_tool
//
// When an agent has Compact Tool Mode enabled, `MaestroTools.schemas(...)`
// (see MaestroTools.swift) hides every tool belonging to a deferrable
// category (`ToolCategory.isDeferrable`) and advertises just these two
// meta-tools instead. The agent calls `search_tools` to discover a deferred
// tool's exact name, then `call_tool` to invoke it — trading one extra
// round-trip for a much smaller prompt on every turn, which matters once the
// native tool surface gets large (file/shell/server/index/sqlite/notes/
// kanban/canvas/numbers/system, and growing).
//
// This is purely additive: with Compact Tool Mode off (the default for every
// existing agent), none of this is advertised and behavior is unchanged.
extension MaestroTools {

    static let metaToolNames: Set<String> = ["search_tools", "call_tool"]

    static var metaToolSpecs: [ToolSpec] {
        [
            rawSpec("search_tools",
                "Search for additional tools not already listed in your tool menu — file, shell, "
                + "server, indexing, SQLite, Notes.md, Kanban, Canvas, Numbers, and other "
                + "app-integration tools are available this way to keep your default tool menu "
                + "small. Call this first, then use call_tool with the exact name you find. "
                + "Omit 'query' to browse everything available, grouped by category.",
                properties: [
                    "query": ["type": "string", "description": "Keywords to match against tool names/descriptions, e.g. 'spreadsheet' or 'kanban'."],
                ], required: []),
            rawSpec("call_tool",
                "Invoke a tool found via search_tools, by its exact name, passing its own arguments "
                + "as an object matching that tool's normal parameter schema.",
                properties: [
                    "name": ["type": "string", "description": "Exact tool name returned by search_tools."],
                    "arguments": [
                        "type": "object",
                        "description": "Arguments object for that tool, shaped exactly like its own parameter schema. Omit for tools that take no arguments.",
                    ] as [String: any Sendable],
                ], required: ["name"]),
        ]
    }

    // MARK: - search_tools

    private struct SearchToolsArgs: Codable { let query: String? }

    /// The full candidate list of deferrable-category tools reachable by the
    /// agent currently dispatching (per `currentIsNavigator`/
    /// `currentEnabledCategories`), built from the SAME `schemas(...)` source
    /// of truth `compactMode` uses to decide what to hide — so search results
    /// and what `call_tool` will actually accept never drift apart.
    private static func deferredCandidates() -> [(name: String, description: String, category: ToolCategory)] {
        schemas(
            navigator: currentIsNavigator,
            enabledCategories: currentEnabledCategories,
            compactMode: false
        ).compactMap { spec in
            guard let name = toolName(from: spec),
                  let category = ToolCategory.category(for: name),
                  category.isDeferrable
            else { return nil }
            let function = spec["function"] as? [String: any Sendable]
            let description = function?["description"] as? String ?? ""
            return (name, description, category)
        }
    }

    static func searchToolsMeta(_ call: ToolCall) async -> String {
        let query = decodeArgs(call, as: SearchToolsArgs.self)?.query?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = deferredCandidates()

        guard !query.isEmpty else {
            guard !candidates.isEmpty else { return "No additional tools available right now." }
            let grouped = Dictionary(grouping: candidates, by: \.category)
            let lines = grouped
                .sorted { $0.key.displayName.localizedCompare($1.key.displayName) == .orderedAscending }
                .map { category, items in
                    "\(category.displayName): " + items.map(\.name).sorted().joined(separator: ", ")
                }
            return "Available tools by category (call_tool by exact name):\n" + lines.joined(separator: "\n")
        }

        let lowerQuery = query.lowercased()
        let scored: [(score: Int, item: (name: String, description: String, category: ToolCategory))] = candidates.compactMap { item in
            if item.name.lowercased().contains(lowerQuery) { return (2, item) }
            if item.description.lowercased().contains(lowerQuery) { return (1, item) }
            return nil
        }
        let top = scored.sorted { $0.score > $1.score }.prefix(8)

        guard !top.isEmpty else {
            return "No tools match \"\(query)\". Try an empty query to browse everything available, or different keywords."
        }
        let matches: [[String: Any]] = top.map {
            ["name": $0.item.name, "description": $0.item.description, "category": $0.item.category.displayName]
        }
        return jsonString(["matches": matches])
    }

    // MARK: - call_tool

    static func callToolMeta(_ call: ToolCall) async -> String {
        guard case .string(let name)? = call.function.arguments["name"], !name.isEmpty else {
            return errorJSON("call_tool requires 'name' (get it from search_tools).")
        }
        guard let category = ToolCategory.category(for: name), category.isDeferrable else {
            return errorJSON("\"\(name)\" isn't a tool call_tool can reach. Use search_tools to find an exact name.")
        }
        if let scope = currentEnabledCategories, !scope.contains(category) {
            return errorJSON("\"\(name)\" isn't enabled for this agent. Use search_tools to see what's available.")
        }
        guard MaestroTools.handles(name) else {
            return errorJSON("\"\(name)\" is not implemented.")
        }

        let innerArguments: [String: JSONValue]
        if case .object(let object)? = call.function.arguments["arguments"] {
            innerArguments = object
        } else {
            innerArguments = [:]
        }
        let synthetic = ToolCall(function: .init(name: name, arguments: innerArguments))
        return await MaestroTools.execute(synthetic)
    }
}
