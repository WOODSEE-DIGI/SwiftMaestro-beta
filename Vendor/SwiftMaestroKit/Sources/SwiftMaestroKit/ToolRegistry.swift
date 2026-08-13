import Foundation
import MLXLMCommon

// MARK: - Tool registry
//
// Generic tool dispatch mechanism: the KIT owns this registry and knows about
// zero concrete tools. Every actual tool implementation (Kanban, Numbers,
// WhatsApp, memory, files, shell, ...) stays app-side and registers itself
// here at startup.
//
// `category` is a plain String (not an app-specific enum) specifically so
// this type has no dependency on anything app-specific — a consuming app's
// own String-backed category enum bridges via `.rawValue` at the
// registration call site with zero changes needed to that enum.

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

/// Optional permission-checking hook. Conforming types can approve/deny/ask
/// about a tool call before it executes. Return nil to allow the tool to run,
/// or a non-empty string to return that JSON error to the model instead.
public protocol ToolPermissionChecker: Sendable {
    func checkPermission(for toolName: String, call: ToolCall) async -> String?
}

/// Central registry of every tool available to the agentic loop. Thread-safe
/// via actor isolation (registration happens once at startup; dispatch
/// happens continuously from agent runs, potentially concurrently across
/// delegated sub-agents).
public actor ToolRegistry {
    public static let shared = ToolRegistry()

    private var definitions: [String: ToolDefinition] = [:]
    private var permissionChecker: ToolPermissionChecker?

    public init() {}

    public func register(_ definition: ToolDefinition) {
        definitions[definition.name] = definition
    }

    public func register(_ definitions: [ToolDefinition]) {
        for definition in definitions { register(definition) }
    }

    /// Install a permission checker that runs before every tool call.
    public func setPermissionChecker(_ checker: ToolPermissionChecker?) {
        self.permissionChecker = checker
    }

    public func handles(_ name: String) -> Bool {
        definitions[name] != nil
    }

    public func execute(_ call: ToolCall) async -> String {
        guard let definition = definitions[call.function.name] else {
            return #"{"error": "unknown tool: \#(call.function.name)"}"#
        }
        if let checker = permissionChecker,
           let denial = await checker.checkPermission(for: call.function.name, call: call) {
            return denial
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
