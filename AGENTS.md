# AGENTS.md — SwiftMaestro

This file provides context for AI agents (Amy/Oz in Warp, Qwen Code CLI, or any MCP-connected agent) working in this repository.

---
## Agent Operating Rules (read first)

These are mandatory working agreements for this repo. Follow them every session.

1. **Never launch the app.** Do not `open`, launch, relaunch, kill (`pkill`/`killall`), screenshot, or UI-drive SwiftMaestro (any copy — Debug, Release, `/Applications`, DMG). Do not touch its processes, windows, or TCC prompts. Verification ends at `xcodebuild ... build` → `** BUILD SUCCEEDED **`; the user launches and tests the app themselves and reports what they see. The only sanctioned shipping step is the package pipeline producing a DMG — never a launch.
2. **Orient before acting.** Before changing code, read this file and `~/.ai-context/README.md`, and query the `ai-context-bridge` MCP memory for relevant prior context. Confirm where the project stands before editing.
3. **Verify every build.** After code changes, run `xcodegen generate` if files were added/removed, then run `xcodebuild ... build` and confirm `** BUILD SUCCEEDED **` before claiming a task is done. Do not commit generated `SwiftMaestro.xcodeproj/` or `.derivedData/` output.
4. **Protect the Mac with large models.** Never trigger a second large in-process model load (the 122B is ~65GB resident). Confirm no other large model is loaded before loading another.
5. **Scan downloads.** Any downloaded file gets a two-stage malware scan: quick scan, then deep scan, before use.
6. **Before any public push.** Deep-scrub for PII that could be used maliciously. The name `woodsee` may remain.
7. **Git discipline.** Commit only when explicitly asked.
8. **Conventions.** Use 24-hour time `HH:mm:ss` with an AM/PM indicator. Name plans for Warp rules and AI-context rules as `YY.MM.DD-Plan name`.
9. **Backup before destructive operations.** Never delete, overwrite, or reset user data, preferences, keychain items, model files, or project configuration without first making a recoverable backup (e.g., copy the file/directory, export the plist, snapshot the keychain item) and confirming the backup succeeded. This applies to `~/Library/Preferences/`, `~/Library/Application Support/SwiftMaestro/`, `~/.ai-context/`, and any user-created files.

---

## Project Identity

- **App:** SwiftMaestro — native macOS SwiftUI AI assistant powered by local models running fully in-process on Apple MLX (mlx-swift-lm)
- **Bundle ID:** `com.woodseedigi.swiftmaestro`
- **Repo path:** `~/GitHub/FUSV/SwiftMaestro`
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

**Other tools using the same store:** Warp, Qwen Code CLI, Claude Code — all via the `ai-context-bridge` MCP server.

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
| **AgentExecutor** | `Sources/Adapters/AgentExecutor.swift` | Backend-agnostic agentic loop (formerly OMLXAgentExecutor; renamed) |
| **SettingsView** | `Sources/Views/SettingsView.swift` | Settings tabs: Models, Tuning, Vision Proxy, Appearance, Rules, Context, MCP, Storage, Secrets, Whisper, Shell |
| **WindowSizeConfigurator** | `Sources/Views/WindowSizeConfigurator.swift` | AppKit bridge enforcing min/default window sizes |
| **SimpleMemoryStore** | `Sources/Memory/SimpleMemoryStore.swift` | File-based shared memory (→ `~/.ai-context/memory/`) |
| **MaestroURI** | `Sources/MaestroURI.swift` | Memory URI scheme |
| **KeychainService** | `Sources/Services/KeychainService.swift` | macOS Keychain wrapper (legacy login keychain; iCloud-sync aware) |
| **SecretsStore** | `Sources/Services/SecretsStore.swift` | Secret metadata index, `secret://` resolution, redaction |
| **PluginBridge** | `Sources/Services/PluginBridge.swift` | JS↔Swift bridge for WKWebView plugins; capabilities: `network`, `secrets`, `tools`, `oauth` |
| **OAuthLoopbackServer** | `Sources/Services/OAuthLoopbackServer.swift` | Generic loopback-only OAuth callback server (plugin `startOAuth`) |
| **Bundled plugins** | `Sources/Resources/Plugins/{mastodon,bluesky,patreon}/` | WKWebView panel plugins (folder reference; excluded from Sources glob in project.yml) |

---

## Models

Verified core models:
- **Gemma 4 26B-A4B 8-bit** (default) — vision + text, general navigator
- **Qwen 3.5 122B (A10B)** — deep reasoning, complex tasks
- **Qwen 3.5 27B (Opus Distilled)** — balanced performance
- **Qwen 3 Coder Next** — coding tasks, sub-agents

Experimental models (tool support may be limited): Qwen 3.6, DeepSeek R1, Hermes 4, Magistral, Nemotron, Hub models.

Models stored at: `~/Ai-models/models` by default; configurable in **Settings → Models**.

---

## Build & Run

```bash
# Generate Xcode project (xcodeproj is gitignored — regenerate after pulling)
xcodegen generate

# Build and run
open SwiftMaestro.xcodeproj
# Cmd+R in Xcode

# Headless build check (signed — do NOT pass CODE_SIGNING_REQUIRED=NO: an
# unsigned build gets a per-build ad-hoc cdhash identity, which makes the
# login Keychain treat every rebuild as a different app and re-prompt for
# the keychain password on every launch)
xcodebuild -project SwiftMaestro.xcodeproj -scheme SwiftMaestro -configuration Debug \
  -destination "platform=macOS" build
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
- **Reference, never inline:** anywhere a token is needed, use `secret://<name>`. It is resolved from the Keychain only at the HTTP boundary; the raw value never enters the prompt, chat history, or memory store.
- **Redaction:** `SecretRedactor` strips any known secret value from content before it is written to the shared memory store.
- **Storage detail:** values live in the Keychain; non-secret descriptors live in machine-local `~/Library/Application Support/SwiftMaestro/secrets-index.json` (only Keychain values sync via iCloud). We stay on the legacy login keychain so the `security` CLI can read the same items.
- **Cross-agent (ai-context-bridge):** `list_secrets` (names + scope only), `use_secret` (injects the secret into a request header server-side and returns only the response — never the raw value), and `set_secret` (creates a machine-local secret; use the app for iCloud-synced ones). A raw `get_secret` is intentionally omitted.

## Security Policy

- Deep scrub before any public push — remove all PII except 'woodsee'
- No telemetry, no analytics, no data collection
- All model inference happens locally on Apple Silicon
