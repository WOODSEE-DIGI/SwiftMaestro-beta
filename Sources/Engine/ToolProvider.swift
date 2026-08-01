import Foundation
import MLXLMCommon

// MARK: - Tool Provider Protocol
//
// Plugins (or bundled modules) that want to register tools with the agent
// conform to this protocol. Each provider declares its tools at startup,
// and `ToolRegistry` routes calls to the provider's handler.
//
// This is the reverse of the existing `.tools` PluginCapability (which lets
// WKWebView plugins CALL native tools). ToolProviders let Swift code
// REGISTER tools that the agent can call.

/// A type that provides tools to the agent's tool registry.
///
/// Conform to this protocol, implement `provideTools()` to return your tool
/// specs and handlers, then register via `ToolRegistry.shared.registerProvider()`.
///
/// Example:
/// ```swift
/// struct MyToolProvider: ToolProvider {
///     let id = "my-tools"
///     func provideTools() async -> [ToolProviderTool] { ... }
/// }
/// ```
protocol ToolProvider: Sendable {
    /// Unique identifier for this provider (e.g. "obsidian", "github").
    var id: String { get }

    /// Called once at startup to discover and register this provider's tools.
    func provideTools() async -> [ToolProviderTool]
}

/// A tool provided by a `ToolProvider`.
struct ToolProviderTool: Sendable {
    /// Tool name (must be unique across all providers and native tools).
    let name: String
    /// OpenAI function-spec schema.
    let spec: ToolSpec
    /// Category for the tool picker toggle.
    let category: ToolCategory
    /// The actual handler — receives the ToolCall, returns a JSON string result.
    let handler: @Sendable (ToolCall) async -> String
}
