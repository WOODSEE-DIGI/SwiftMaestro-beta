# AGENTS.md — SwiftMaestro

This file provides context for AI agents (Amy/Oz in Warp, Qwen Code CLI, or any MCP-connected agent) working in this repository.

---
## Agent Operating Rules (read first)

These are mandatory working agreements for this repo. Follow them every session.

1. **Orient before acting.** Before changing code, read this file and `~/.ai-context/README.md`, and query the `ai-context-bridge` MCP memory for relevant prior context. Confirm where the project stands before editing.
2. **Verify every build.** After code changes, run `xcodegen generate` if files were added/removed, then run `xcodebuild ... build` and confirm `** BUILD SUCCEEDED **` before claiming a task is done. Do not commit generated `SwiftMaestro.xcodeproj/` or `.derivedData/` output.
3. **Protect the Mac with large models.** Never trigger a second large in-process model load (the 122B is ~65GB resident). Confirm no other large model is loaded before loading another.
4. **Scan downloads.** Any downloaded file gets a two-stage malware scan: quick scan, then deep scan, before use.
5. **Before any public push.** Deep-scrub for PII that could be used maliciously. The name `woodsee` may remain.
6. **Git discipline.** Commit only when explicitly asked. Every commit message must include `Co-Authored-By: Oz <oz-agent@warp.dev>`.
7. **Conventions.** Use 24-hour time `HH:mm:ss` with an AM/PM indicator. Name plans for Warp rules and AI-context rules as `YY.MM.DD-Plan name`.

---

## Project Identity

- **App:** SwiftMaestro — native macOS SwiftUI AI assistant powered by local Qwen models running fully in-process on Apple MLX (mlx-swift-lm)
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
| **MLXInferenceEngine** | `Sources/Engine/MLXInferenceEngine.swift` | Primary native MLX inference path |
| **InProcessMLXBackend** | `Sources/Adapters/InProcessMLXBackend.swift` | The sole generation backend (in-process MLX) |
| **OMLXAgentExecutor** | `Sources/Adapters/OMLXAgentExecutor.swift` | Backend-agnostic agentic loop (name retained; not oMLX) |
| **SettingsView** | `Sources/Views/SettingsView.swift` | Settings tabs: Models, Tuning, Rules, Context, MCP, Secrets |
| **WindowSizeConfigurator** | `Sources/Views/WindowSizeConfigurator.swift` | AppKit bridge enforcing min/default window sizes |
| **SimpleMemoryStore** | `Sources/Memory/SimpleMemoryStore.swift` | File-based shared memory (→ `~/.ai-context/memory/`) |
| **MaestroURI** | `Sources/MaestroURI.swift` | Memory URI scheme |
| **ModelRouter** | `Sources/Services/ModelRouter.swift` | Model selection (35B/122B) |
| **KeychainService** | `Sources/Services/KeychainService.swift` | macOS Keychain wrapper (legacy login keychain; iCloud-sync aware) |
| **SecretsStore** | `Sources/Services/SecretsStore.swift` | Secret metadata index, `secret://` resolution, redaction |

---

## Models

- **Qwen 35B** (`Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit`) — fast, general use
- **Qwen 122B** (`Qwen3.5-122B-A10B-4bit`) — deep reasoning, complex tasks

Models stored at: `~/Ai-models/`

---

## Build & Run

```bash
# Generate Xcode project (xcodeproj is gitignored — regenerate after pulling)
xcodegen generate

# Build and run
open SwiftMaestro.xcodeproj
# Cmd+R in Xcode

# Headless build check
xcodebuild -project SwiftMaestro.xcodeproj -scheme SwiftMaestro -configuration Debug \
  -destination "platform=macOS" CODE_SIGNING_REQUIRED=NO build
```

---

## Code Conventions

- **Language:** Swift 6.3, SwiftUI, macOS 14.0+
- **Project gen:** xcodegen (`project.yml`)
- **No App Store sandbox** — full system access for macOS integration
- **Swift package dependencies** (see `project.yml`): `mlx-swift-lm` (MLXLLM/MLXVLM/MLXLMCommon) and `swift-transformers` (Tokenizers/Hub) power the native `MLXInferenceEngine` — the sole inference backend (in-process, no server)
- **Secrets:** macOS Keychain only via `KeychainService` / `SecretsStore` (see Secrets Management). Never hard-code secrets in source.

---

## Secrets Management

Auth tokens / API keys are stored in the macOS **Keychain** (service `com.woodseedigi.SwiftMaestro`), never in source, JSON config, UserDefaults, logs, or `~/.ai-context/memory/`.

- **Add/manage:** Settings → **Secrets** tab. Each secret has a scope — **Permanent** (`secret.global.<name>`) or **This project only** (`secret.project.<projectId>.<name>`, persists until purged) — and an optional **iCloud Keychain sync** toggle (on by default for Permanent) so the same token works across all signed-in Macs (end-to-end encrypted).
- **Reference, never inline:** anywhere a token is needed, use `secret://<name>`. It is resolved from the Keychain only at the HTTP boundary (`RemoteLMStudioClient`); the raw value never enters the prompt, chat history, or memory store.
- **Redaction:** `SecretRedactor` strips any known secret value from content before it is written to the shared memory store.
- **Storage detail:** values live in the Keychain; non-secret descriptors live in machine-local `~/Library/Application Support/SwiftMaestro/secrets-index.json` (only Keychain values sync via iCloud). We stay on the legacy login keychain so the `security` CLI can read the same items.
- **Cross-agent (ai-context-bridge):** `list_secrets` (names + scope only), `use_secret` (injects the secret into a request header server-side and returns only the response — never the raw value), and `set_secret` (creates a machine-local secret; use the app for iCloud-synced ones). A raw `get_secret` is intentionally omitted.

## Security Policy

- Deep scrub before any public push — remove all PII except 'woodsee'
- No telemetry, no analytics, no data collection
- All model inference happens locally on Apple Silicon
