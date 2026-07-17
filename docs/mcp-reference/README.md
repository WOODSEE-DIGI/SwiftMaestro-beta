# ⚠️ Historical — superseded

Everything in this folder (`swift-client/`, `docs/`) documents an early,
**abandoned** prototype MCP client (`MCPSession`/`MCPClientManager`/
`MCPToolRegistry` under a planned `Sources/MCP/` tree) from May 2025. That
implementation was never shipped — it doesn't exist anywhere in the current
`Sources/` tree.

SwiftMaestro's actual, shipping MCP integration is a single file:
**`Sources/Engine/MCPClientService.swift`**, built on the official
[Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) (the
`mcp-swift-sdk` package dependency in `project.yml`). It works completely
differently from what's described here:

- No external JSON config file — servers are configured one at a time in
  **Settings → MCP**, persisted via `UserDefaults`/`SwiftMaestroSettingsStore`.
- No custom `MCPSession`/JSON-RPC-by-hand code — the official SDK handles the
  protocol; `MCPClientService` just spawns the subprocess, wires up stdio, and
  bridges discovered tools into the same agentic loop `MaestroTools` uses.

For accurate, current documentation, see **[`docs/MCP-SERVERS.md`](../MCP-SERVERS.md)**
and the runnable example server at **[`docs/mcp-template/`](../mcp-template/)**.

This folder is kept only as a historical record (and because some of the
*server names* referenced here — `ai-context-bridge`, `xcodebuildmcp`,
`swift-terminals`, `firecrawl-mcp`, etc. — are still genuinely useful,
actively-maintained servers; just ignore the config format and file paths,
which are specific to an old machine setup and don't apply generally).
