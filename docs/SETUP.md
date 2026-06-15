# SwiftMaestro Setup Guide

SwiftMaestro is a fully on-device macOS AI assistant. Everything below reflects the in-process Apple MLX build — there is no separate model server to run.

## Install

### Option 1 — Download the notarized `.dmg` (recommended)
1. Download the latest `SwiftMaestro-<version>.dmg` from [Releases](https://github.com/WOODSEE-DIGI/SwiftMaestro/releases).
2. Open the `.dmg` and drag **SwiftMaestro.app** to **Applications**.
3. Launch it. It's Developer ID signed and Apple-notarized, so it opens without Gatekeeper prompts.

### Option 2 — Build from source
```bash
brew install xcodegen
git clone https://github.com/WOODSEE-DIGI/SwiftMaestro.git
cd SwiftMaestro
UNSIGNED=1 ./scripts/build.sh     # ad-hoc local build → build/Release/SwiftMaestro.app
```

## System requirements
- macOS 14 (Sonoma) or later.
- Apple Silicon (M1/M2/M3/M4 …). Intel Macs are not supported.
- RAM and disk scale with the chosen model:

| Model | On-disk / RAM | Notes |
| --- | --- | --- |
| Qwen 3.6 35B-A3B (default) | ~20 GB | Good balance of speed and quality |
| Qwen 3.5 122B (A10B) | ~65 GB | Needs a 64 GB+ Mac |
| Qwen 3 4B / other small Hub models | ~3–6 GB | Fastest first run, lowest footprint |

## First run
- A welcome sheet appears on a fresh install and explains model-download behavior.
- **No model is bundled.** Your first message downloads the selected model from Hugging Face — a one-time download per model.
- SwiftMaestro creates its data directory at `~/.ai-context` automatically if it doesn't exist.

## Models
Choose and manage models in **Settings → Models**:
- The selected model downloads on first use and is cached.
- Default model storage: `~/Library/Application Support/SwiftMaestro/models`.
- To reuse an existing model collection (e.g. on an external drive), set a custom **Models folder** path, then relaunch.
- Add any MLX model from Hugging Face by its Hub ID (e.g. `mlx-community/Qwen3-8B-4bit`).

## Permissions
SwiftMaestro is not sandboxed and asks for access only when a feature needs it:

| Permission | Requested when | Used by |
| --- | --- | --- |
| Reminders | First time the assistant creates/lists a reminder | `create_reminder`, `list_reminders` |
| Calendar | First time it creates an event | `create_calendar_event` |
| Automation (Notes) | First time it creates a note | `create_note` |
| Files | Only within folders you add in **Settings → Context** | `read_file`, `write_file`, `list_dir` |

Manage these in **System Settings → Privacy & Security**.

## Built-in tools
These run in-process — no setup:
- Durable memory (`memory_write` / `memory_read` / `memory_search` / `memory_list`) backed by `~/.ai-context/memory`.
- File access (`read_file` / `write_file` / `list_dir`) limited to your authorized folders.
- macOS: Reminders, Calendar, Notes, open URL.
- Plans, live task checklists, inter-agent messaging, current time.

Optional: add MCP servers in **Settings → MCP** for extra tools (web, shell, etc.).

## Secrets
API tokens are stored in the macOS Keychain — never in chat history, logs, or the memory store. Add them in **Settings → Secrets** and reference them anywhere as `secret://<name>`.

## Building a release (maintainers)
```bash
# One-time: store notarization credentials
xcrun notarytool store-credentials "SwiftMaestroNotary" \
  --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>

./scripts/build.sh        # Developer ID signed, hardened-runtime, arm64 Release
./scripts/package.sh      # DMG → notarize → staple → verify
./scripts/smoke-test.sh   # signature / arch / hardening / Gatekeeper checks
```

## Troubleshooting

### "SwiftMaestro is damaged / can't be opened"
You're likely running an unsigned local build. Use a notarized release `.dmg`, or for a local build remove the quarantine attribute:
```bash
xattr -dr com.apple.quarantine /Applications/SwiftMaestro.app
```

### First message is slow or appears to hang
The model is downloading on first use. Watch progress in the app; later runs load from the local cache. Pick a smaller model in **Settings → Models** for a faster first run.

### Out of memory / very slow generation
The model is too large for available RAM. Switch to a smaller model (the 35B default, or a 4B/8B Hub model).

### A file tool says "access denied"
Add the folder in **Settings → Context** — the agent can only read/write inside authorized folders.

### Build errors after pulling
Regenerate the Xcode project:
```bash
xcodegen generate
```

## Uninstall
```bash
rm -rf /Applications/SwiftMaestro.app
rm -rf ~/Library/Application\ Support/SwiftMaestro   # app data (models, chats, plans)
# ~/.ai-context is a shared store; remove it only if no other tools use it.
```

## Credits
- Models: Qwen (Alibaba) and the MLX community.
- Inference: Apple MLX (`mlx-swift-lm`) and `swift-transformers`.

## License
MIT License — see [LICENSE](LICENSE).
