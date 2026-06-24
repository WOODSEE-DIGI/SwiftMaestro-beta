# SwiftMaestro

A native macOS AI assistant that runs large language models **fully on-device** on Apple Silicon via Apple [MLX](https://github.com/ml-explore/mlx) (`mlx-swift-lm`). No server, no account, no cloud — your conversations and files never leave your Mac.

## Highlights
- **100% local inference** — models run in-process on the GPU through MLX. There is no external runtime or server to start or manage.
- **Self-contained** — on first launch a guided onboarding walks you through picking, downloading, and loading a model. Nothing is hard-wired to a specific machine.
- **Speech-to-text** — built-in WhisperKit integration lets you dictate messages via the microphone button. The speech model downloads on first use with a progress dialog.
- **Built-in tools, no setup** — the assistant can use durable memory, read/write files in folders you authorize, manage Reminders/Calendar/Notes, and open URLs — all in-process. MCP servers are an optional power-user extension.
- **Multi-model agents** — assign different models to the Navigator and each sub-agent. Use a fast model for chat and a coding-focused model for project work. Six models ship with tool support enabled.
- **Mid-generation steering** — send a follow-up message while the agent is still generating to redirect it without cancelling the current run.
- **Thinking display** — stream-split reasoning chain (collapsible) so you can see the model's thought process without cluttering the answer.
- **Multi-model residency** — keep multiple models loaded in memory for instant switching between agents.
- **Appearance settings** — themeable accent colors, light/dark mode, and per-panel background colors.
- **Plans & task checklists** — docked panels, resizable plan windows, and Markdown export.
- **Behavioral rules** — add custom rules that guide the agent's behavior, scoped globally or per-agent.
- **Private by design** — no telemetry, no analytics. Secrets live in the macOS Keychain and are never written to chat history or the memory store.
- **Distributed as a notarized `.dmg`** — Developer ID signed and Apple-notarized, so it opens cleanly on any Apple Silicon Mac.

## Requirements
- Apple Silicon Mac (M1 or later). Intel is not supported — MLX is Apple-Silicon-only.
- macOS 14 (Sonoma) or later.
- Disk space and RAM scale with the model you choose (see [Models](#models)).

## Install (beta)
1. Download the latest `SwiftMaestro-<version>.dmg` from the [Releases page](https://github.com/WOODSEE-DIGI/SwiftMaestro/releases).
2. Open the `.dmg` and drag **SwiftMaestro** to **Applications**.
3. Launch it. Because it's notarized, it opens without Gatekeeper warnings.

On first launch a guided onboarding walks you through picking and downloading a language model. A separate one-time setup dialog installs the speech recognition model (~3 GB) when you first use the microphone.

## Models
Models download on first use from Hugging Face and are cached locally. Pick one in **Settings → Models**.

### Tool-enabled models
These models support SwiftMaestro's native tools (memory, files, reminders, etc.):

| Model | Approx. size / RAM | Best for | Tools |
| --- | --- | --- | --- |
| Qwen 3.6 35B-A3B (default) | ~20 GB | Fast, general use | ✅ verified |
| Qwen 3 Coder 30B-A3B | ~17 GB | Coding tasks, sub-agents | ✅ |
| Qwen 3.5 122B (A10B) | ~65 GB | Deepest reasoning | ✅ verified |
| Qwen 3.5 27B (Opus Distilled) | ~14 GB | Balanced performance | ✅ |
| DeepSeek R1 8B (Qwen3) | ~4 GB | Lightweight reasoning | ✅ |
| Gemma 3n E4B | ~3 GB | Low memory, quick first run | ✅ |

### Additional models
These models work for chat but tools are not yet enabled:

| Model | Approx. size / RAM | Best for |
| --- | --- | --- |
| Hermes 4 70B | ~56 GB | General purpose |
| Magistral Small | ~13 GB | Fast inference |
| Nemotron Cascade 30B | ~1 GB | Ultra-low memory |
| Hub models (Qwen 3 8B/4B, Llama 3.2 1B) | ~1–6 GB | Quick experiments |

### Per-agent model overrides
Assign different models to different agents via the **"This agent"** picker in the chat toolbar. For example:
- **Navigator** → Qwen 3.6 35B (fast chat)
- **Coder sub-agent** → Qwen 3 Coder 30B (coding focus)
- **Reasoning sub-agent** → DeepSeek R1 8B (chain-of-thought)

Each agent runs its own model independently — no conflicts, no shared state.

By default models are stored under `~/Library/Application Support/SwiftMaestro/models`. To reuse an existing collection (for example on an external drive), set a custom path in **Settings → Models**.

## What it can do out of the box
The assistant has native, in-process tools — no configuration required:
- **Memory** — durable notes/knowledge in the shared `~/.ai-context/memory` store.
- **Files** — read/write/list within folders you authorize in **Settings → Context**.
- **macOS** — create Reminders, Calendar events, and Notes; open URLs (prompts for permission on first use).
- **Apple Shortcuts** — list, run, and *create* shortcuts. Describe what you want and the agent builds a `.shortcut` file you can import with a double-click.
- **Plans, live task checklists, multi-agent messaging, and current time.**
- **Behavioral rules** — `list_rules` and `set_rule` tools let the agent manage its own behavior rules.
- **Speech-to-text** — tap the microphone button to dictate; WhisperKit transcribes locally with no cloud API.
- **Mid-generation steering** — send a message while the agent is generating to redirect it on the fly.
- **Image input** — attach images to your messages for multimodal conversations.
- **Multi-agent delegation** — the Navigator can create project agents and delegate tasks to them, each running their own model.

Additional tools (web, shell, etc.) can be added by configuring MCP servers in **Settings → MCP**.

## Build from source
Requires Xcode 16+ and [`xcodegen`](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/WOODSEE-DIGI/SwiftMaestro.git
cd SwiftMaestro

# Local (ad-hoc) build for development:
UNSIGNED=1 CONFIG=Debug ./scripts/build.sh

# …or open in Xcode:
xcodegen generate && open SwiftMaestro.xcodeproj   # then ⌘R
```

### Release: signed + notarized `.dmg`
The release build is Developer ID signed and notarized. One-time, store your notarization credentials:

```bash
xcrun notarytool store-credentials "SwiftMaestroNotary" \
  --apple-id <your-apple-id> --team-id <your-team-id> \
  --password <app-specific-password>
```

Then:

```bash
./scripts/build.sh       # Developer ID signed, hardened-runtime, arm64 Release
./scripts/package.sh     # build DMG → notarize → staple → verify
./scripts/smoke-test.sh  # verify signature, arch, hardening, Gatekeeper
```

## Architecture (overview)
| Component | Path | Purpose |
| --- | --- | --- |
| ChatView / MessageBubble | `Sources/Views/` | Chat UI + markdown rendering |
| ChatViewModel | `Sources/ViewModels/ChatViewModel.swift` | Chat, streaming, system prompt |
| MLXInferenceEngine | `Sources/Engine/MLXInferenceEngine.swift` | In-process MLX inference (the only backend) |
| MaestroTools (+ extensions) | `Sources/Engine/MaestroTools*.swift` | Native in-process tools |
| ModelCatalog | `Sources/Engine/ModelCatalog.swift` | Model list, default, local/Hub resolution |
| WhisperKitService | `Sources/Services/WhisperKitService.swift` | Speech-to-text: model lifecycle, recording, streaming transcription |
| SimpleMemoryStore | `Sources/Memory/SimpleMemoryStore.swift` | Shared `~/.ai-context/memory` store |
| SettingsView | `Sources/Views/SettingsView.swift` | Models, Tuning, Appearance, Rules, Context, MCP, Storage, Secrets, Whisper |
| KeychainService / SecretsStore | `Sources/Services/` | Keychain-backed secrets, `secret://` resolution |

## Privacy & distribution
- No telemetry, analytics, or data collection. All inference is local.
- Not sandboxed (distributed outside the App Store) so it can integrate with the system; it ships with hardened runtime and is notarized.
- Secrets are stored only in the macOS Keychain.

## License
MIT License — see [LICENSE](LICENSE).
