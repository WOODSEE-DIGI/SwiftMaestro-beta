# AGENTS.md — SwiftMaestro

This file provides context for AI agents (Amy/Oz in Warp, Qwen Code CLI, or any MCP-connected agent) working in this repository.

---

## Project Identity

- **App:** SwiftMaestro — native macOS SwiftUI AI assistant powered by local Qwen models via oMLX
- **Bundle ID:** `com.woodseedigi.swiftmaestro`
- **Repo path:** `~/GitHub/AI-ML-Agents/SwiftMaestro`
- **Distribution:** GitHub + .dmg (no App Store — no sandbox restrictions)

---

## Unified Memory System

SwiftMaestro reads and writes to the shared memory store at `~/.ai-context/memory/`:
- **conversations/swiftmaestro/** — SwiftMaestro's chat history (via `SimpleMemoryStore`)
- **knowledge/** — persistent facts, decisions, project knowledge (shared with all tools)
- **context/** — active session state
- **skills/** — learned patterns

**MaestroURI mapping** (in `SimpleMemoryStore.kindDirectoryMap`):
- `maestro://memory/*` → `~/.ai-context/memory/conversations/swiftmaestro/*`
- `maestro://knowledge/*` → `~/.ai-context/memory/knowledge/*`
- `maestro://context/*` → `~/.ai-context/memory/context/*`
- `maestro://skill/*` → `~/.ai-context/memory/skills/*`

**Other tools using the same store:** Warp (Oz), Qwen Code CLI, LM Studio, Claude Code — all via the `ai-context-bridge` MCP server.

---

## MCP Server Registry

All MCP servers defined in `~/.ai-context/mcp-registry/mcp-servers.json`.
Run `~/.ai-context/scripts/sync-mcp.sh` to push config to all tools.

**Future:** SwiftMaestro will connect to `ai-context-bridge` as an MCP client (Layer B) using the Swift MCP SDK for full tool access.

---

## Architecture

| Component | Path | Purpose |
|---|---|---|
| **ChatView** | `Sources/Views/ChatView.swift` | Main chat UI with fixed auto-scroll |
| **MessageBubble** | `Sources/Views/MessageBubble.swift` | Markdown/code block rendering |
| **ChatViewModel** | `Sources/ViewModels/ChatViewModel.swift` | Chat logic (streaming, file attachments) |
| **LocalLLMExecutor** | `Sources/Adapters/LocalLLMExecutor.swift` | HTTP client for oMLX |
| **SimpleMemoryStore** | `Sources/Memory/SimpleMemoryStore.swift` | File-based shared memory (→ `~/.ai-context/memory/`) |
| **MaestroURI** | `Sources/MaestroURI.swift` | Memory URI scheme |
| **ModelRouter** | `Sources/Services/ModelRouter.swift` | Model selection (35B/122B) |

---

## Models

- **Qwen 35B** (`Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit`) — fast, general use
- **Qwen 122B** (`Qwen3.5-122B-A10B-4bit`) — deep reasoning, complex tasks

Models stored at: `~/Ai-models/`

---

## Build & Run

```bash
# Start oMLX with model
omlx serve "~/Ai-models/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit" --port 8000

# Generate Xcode project
xcodegen generate

# Build and run
open SwiftMaestro.xcodeproj
# Cmd+R in Xcode
```

---

## Code Conventions

- **Language:** Swift 6.3, SwiftUI, macOS 14.0+
- **Project gen:** xcodegen (`project.yml`)
- **No App Store sandbox** — full system access for macOS integration
- **No external Swift package dependencies** (oMLX provides ML inference)
- **Secrets:** Keychain only

---

## Security Policy

- Deep scrub before any public push — remove all PII except 'woodsee'
- No telemetry, no analytics, no data collection
- All model inference happens locally on Apple Silicon
