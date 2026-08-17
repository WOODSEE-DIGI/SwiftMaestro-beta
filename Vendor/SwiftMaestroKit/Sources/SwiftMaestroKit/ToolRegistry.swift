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
        // Small local models drift on parameter names (Gemma 4 was observed
        // calling read_file with `filepath`, three rounds in a row). Remap
        // known aliases to the tool's declared parameters BEFORE permission
        // checks and the handler, so everyone sees the same repaired call.
        let call = Self.remappingParameterAliases(call, definition: definition)
        if let checker = permissionChecker,
           let denial = await checker.checkPermission(for: call.function.name, call: call) {
            return denial
        }
        return await definition.handler(call)
    }

    // MARK: - Parameter alias repair

    /// Known parameter-name synonyms, keyed by the canonical (declared) name.
    /// Kept deliberately small — each alias exists because a small local model
    /// was observed emitting it in production.
    private static let parameterAliases: [String: [String]] = [
        "path": ["filepath", "file_path", "file", "filename", "file_name", "folder", "directory", "dir"],
        "query": ["q", "search", "search_query", "searchquery", "term"],
        "content": ["text", "body", "contents"],
        "old_string": ["oldstring", "old_str", "oldtext", "old"],
        "new_string": ["newstring", "new_str", "newtext", "new"],
    ]

    /// Remap alias parameter names to the tool's declared names. Conservative:
    /// only applies when the canonical key is missing from the arguments AND
    /// the alias key is not itself a declared parameter of this tool — real
    /// input is never overwritten.
    static func remappingParameterAliases(_ call: ToolCall, definition: ToolDefinition) -> ToolCall {
        let args = call.function.arguments
        guard !args.isEmpty else { return call }

        guard let function = definition.spec["function"] as? [String: any Sendable],
              let parameters = function["parameters"] as? [String: any Sendable],
              let properties = parameters["properties"] as? [String: any Sendable]
        else { return call }
        let declared = Set(properties.keys)

        var remapped = args
        var didRemap = false
        for (canonical, aliases) in parameterAliases {
            guard declared.contains(canonical), remapped[canonical] == nil else { continue }
            for alias in aliases {
                if let value = remapped[alias], !declared.contains(alias) {
                    remapped[canonical] = value
                    remapped.removeValue(forKey: alias)
                    didRemap = true
                    NSLog("[TOOLARGS] %@: remapped parameter '%@' → '%@'", definition.name, alias, canonical)
                    break
                }
            }
        }
        guard didRemap else { return call }
        return ToolCall(function: .init(name: call.function.name, arguments: remapped))
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
