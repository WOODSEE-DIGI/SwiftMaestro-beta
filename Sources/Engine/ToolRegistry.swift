import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - App-side tool registration glue
//
// The generic `ToolDefinition`/`ToolRegistry` dispatch mechanism itself lives
// in SwiftMaestroKit (extracted 2026-07-18) — it has zero knowledge of any
// concrete tool. This file is the app-side wiring: it registers every
// SwiftMaestro-specific tool group into the kit's shared `ToolRegistry` at
// startup, before any agent can possibly dispatch a tool call.

extension MaestroTools {
    /// Registers every tool group that's been migrated to `ToolRegistry` so
    /// far. Called once at app startup (see `SwiftMaestroApp.swift`'s
    /// `.task`). Add one line here per file as each group migrates off the
    /// legacy switch.
    static func registerAllMigratedTools() async {
        await registerSQLiteTools()
        await registerServerTools()
        await registerShellTools()
        await registerReleaseTools()
        await registerMemoryTools()
        await registerFileTools()
        await registerDocumentTools()
        await registerBooksTools()
        await registerCodingTools()
        await registerIndexTools()
        await registerSystemTools()
        await registerWhatsAppTools()
        await registerAppsTools()
        await registerAppleAppsTools()
        await registerMessagingTools()
        await registerBusTools()
        await registerTodoTools()
        await registerPlanTools()
        await registerWorkspaceTools()
        await registerMetaTools()
        await registerTimeTools()
        await registerWebTools()
        await registerDeepWebTools()
        await registerBrowserTools()
        await registerBlueskyTools()

        // Tool providers — plugins that register their own tools.
        await registerToolProvider(ObsidianToolProvider())
    }

    // MARK: - Tool Provider Registration

    /// Registers a `ToolProvider`'s tools with the shared `ToolRegistry`.
    /// Each tool is wrapped in a `ToolDefinition` and dispatched through the
    /// standard registry path. Invalidates the schema cache so the new tools
    /// are visible to the next agent run.
    static func registerToolProvider(_ provider: ToolProvider) async {
        let tools = await provider.provideTools()
        let definitions = tools.map { tool in
            ToolDefinition(
                name: tool.name,
                spec: tool.spec,
                category: tool.category.rawValue,
                handler: tool.handler
            )
        }
        await ToolRegistry.shared.register(definitions)
        await invalidateToolSchemaCache()
    }
}
