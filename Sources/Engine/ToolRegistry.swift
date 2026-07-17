import Foundation
import MLXLMCommon

// MARK: - Tool registry
//
// Replaces MaestroTools' old monolithic switch-based dispatch
// (schemas()/handles()/execute() manually concatenating and switching over
// every tool name across every file) with a registry apps register their own
// tools into. This is the seed of what moves into SwiftMaestroKit: the KIT
// owns this dispatch mechanism and knows about zero concrete tools; every
// actual tool implementation (Kanban, Numbers, WhatsApp, memory, files,
// shell, ...) stays app-side and registers itself here at startup.
//
// `category` is a plain String (not SwiftMaestro's `ToolCategory` enum)
// specifically so this type has no dependency on anything app-specific —
// `ToolCategory` is already String-backed (`enum ToolCategory: String`), so
// bridging is just `category.rawValue` at the registration call site with
// zero changes needed to that enum.
//
// Migration status: incremental, file-by-file (see MIGRATION_NOTES.md-style
// comments at each call site) — `MaestroTools.execute()`/`handles()`/
// `schemas()` check this registry FIRST, falling back to the legacy
// switch-based path for any tool group not yet migrated. Once every group is
// migrated the legacy path gets deleted entirely.

/// A single registered tool: its schema, category (for per-agent
/// enable/disable filtering), and the closure that actually executes it.
public struct ToolDefinition: Sendable {
    public let name: String
    public let spec: ToolSpec
    /// Nil = always-on / uncategorized (never hidden by category filtering).
    public let category: String?
    public let handler: @Sendable (ToolCall) async -> String

    public init(
        name: String, spec: ToolSpec, category: String?,
        handler: @escaping @Sendable (ToolCall) async -> String
    ) {
        self.name = name
        self.spec = spec
        self.category = category
        self.handler = handler
    }
}

/// Central registry of every tool available to the agentic loop. Thread-safe
/// via actor isolation (registration happens once at startup; dispatch
/// happens continuously from agent runs, potentially concurrently across
/// delegated sub-agents).
public actor ToolRegistry {
    public static let shared = ToolRegistry()

    private var definitions: [String: ToolDefinition] = [:]

    public func register(_ definition: ToolDefinition) {
        definitions[definition.name] = definition
    }

    public func register(_ definitions: [ToolDefinition]) {
        for definition in definitions { register(definition) }
    }

    public func handles(_ name: String) -> Bool {
        definitions[name] != nil
    }

    public func execute(_ call: ToolCall) async -> String {
        guard let definition = definitions[call.function.name] else {
            return #"{"error": "unknown tool: \#(call.function.name)"}"#
        }
        return await definition.handler(call)
    }

    /// - Parameter enabledCategories: if provided, only definitions whose
    ///   category is in this set (or which have no category at all — always-on)
    ///   are returned. Nil means unrestricted (everything registered).
    public func schemas(enabledCategories: Set<String>?) -> [ToolSpec] {
        definitions.values.filter { definition in
            guard let enabledCategories else { return true }
            guard let category = definition.category else { return true }
            return enabledCategories.contains(category)
        }.map(\.spec)
    }

    /// All registered tool names, regardless of category filtering — used by
    /// Compact Tool Mode's `search_tools` to build its candidate list.
    public func allDefinitions() -> [ToolDefinition] {
        Array(definitions.values)
    }
}

extension MaestroTools {
    /// Registers every tool group that's been migrated to `ToolRegistry` so
    /// far. Called once at app startup (before any agent can possibly
    /// dispatch a tool call) — see `SwiftMaestroApp.swift`'s `.task`. Add one
    /// line here per file as each group migrates off the legacy switch.
    static func registerAllMigratedTools() async {
        await registerSQLiteTools()
    }
}
