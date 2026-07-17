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
        await registerMemoryTools()
        await registerFileTools()
        await registerIndexTools()
        await registerSystemTools()
        await registerWhatsAppTools()
        await registerAppsTools()
        await registerMessagingTools()
        await registerTodoTools()
        await registerPlanTools()
        await registerWorkspaceTools()
        await registerMetaTools()
        await registerTimeTools()
    }
}
