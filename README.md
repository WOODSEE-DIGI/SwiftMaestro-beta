# SwiftMaestro

A native macOS AI assistant that runs large language models **fully on-device** on Apple Silicon via Apple [MLX](https://github.com/ml-explore/mlx) (`mlx-swift-lm`). No server, no account, no cloud — your conversations and files never leave your Mac.

## Highlights
- **100% local inference** — models run in-process on the Apple Silicon GPU through MLX. No external runtime or server to start or manage.
- **Self-contained** — on first launch a guided onboarding walks you through picking, downloading, and loading a model. Nothing is hard-wired to a specific machine.
- **Multi-Agent Workspace** — create named agents for different domains (coding, research, writing, operations). The Navigator delegates tasks and keeps project agents coordinated.
- **Durable Memory** — native memory tools backed by SQLite + vector search, stored locally at `~/.ai-context/memory`.
- **Files & Documents** — read and write files within authorised folders, with extraction for text, Markdown, DOCX, PDF, RTF, HTML, and arbitrary binary. Index documents into searchable chunks.
- **Apple Integration** — create Reminders, Calendar events, and Notes; search and manage Contacts; run and create Apple Shortcuts; use Apple Notes, Numbers, and Calendar data in chat.
- **Speech-to-text** — built-in WhisperKit integration lets you dictate messages via the microphone button. The speech model downloads on first use with a progress dialog.
- **Vision & Images** — attach images for multimodal conversations, or use the Vision Proxy to caption images locally with vision-capable models.
- **Extensible Tools** — native in-process tools for SQLite, shell, local servers, Kanban boards, Canvas, and WhatsApp bridge. Add more via MCP servers.
- **Per-agent models** — assign a different model to each agent. Fast for chat, coder for project work, reasoning for deep tasks.
- **Mid-generation steering** — send a follow-up message while the agent is still generating to redirect it without cancelling the current run.
- **Thinking display** — stream-split reasoning chain (collapsible) so you can see the model's thought process without cluttering the answer.
- **Multi-model residency** — keep multiple models loaded in memory for instant switching between agents.
- **Appearance settings** — themeable accent colours, light/dark mode, and per-panel background tints.
- **Plans & task checklists** — docked panels, resizable plan windows, and Markdown export.
- **Behavioral rules** — add custom rules that guide the agent's behaviour, scoped globally or per-agent.
- **Private by design** — no telemetry, no analytics. Secrets live in the macOS Keychain and are never written to chat history or the memory store.
- **Distributed as a notarized `.dmg`** — Developer ID signed and Apple-notarized, so it opens cleanly on any Apple Silicon Mac.

## Requirements
- Apple Silicon Mac (M1 or later). Intel is not supported — MLX is Apple-Silicon-only.
- macOS 14 (Sonoma) or later.
- **Designed for:** M-series Pro/Max/Ultra with 64GB+ unified memory (128GB optimal for running multiple large models).
- **Lighter runs:** any Apple Silicon Mac with 32GB+ unified memory; smaller Hub models work well.
- Disk space and RAM scale with the model you choose (see [Models](#models)).

## Install (beta)
1. Download the latest `SwiftMaestro-<version>.dmg` from the [Releases page](https://github.com/WOODSEE-DIGI/SwiftMaestro/releases).
2. Open the `.dmg` and drag **SwiftMaestro** to **Applications**.
3. Launch it. Because it's notarized, it opens without Gatekeeper warnings.

On first launch a guided onboarding walks you through picking and downloading a language model. A separate one-time setup dialog installs the speech recognition model (~3 GB) when you first use the microphone.

## Models
Models download on first use from Hugging Face and are cached locally. Pick one in **Settings → Models**.

### Verified core models
These models are the supported focus for SwiftMaestro and have verified tool support:

| Model | Approx. size / RAM | Best for | Tools |
| --- | --- | --- | --- |
| Gemma 4 26B-A4B 8-bit (default) | ~26 GB | Vision + text, general navigator | ✅ |
| Gemma 4 26B-A4B 4-bit | ~16 GB | Lower memory, same checkpoint | ✅ |
| Qwen 3.5 122B (A10B) | ~65 GB | Deepest reasoning | ✅ |
| Qwen 3.5 27B (Opus Distilled) | ~14 GB | Balanced performance | ✅ |
| Qwen 3 Coder 30B-A3B | ~17 GB | Coding tasks, sub-agents | ✅ |

### Experimental models
These models are available for exploration but are not part of the verified core:

| Model | Approx. size / RAM | Best for |
| --- | --- | --- |
| Qwen 3.6 35B-A3B | ~20 GB | Fast, general use |
| Qwen 3.6 27B (dense) | ~15 GB | Balanced quality / speed on 24 GB Macs |
| Qwen 3.6 35B-A3B (8-bit) | ~35 GB | Higher-quality MoE for 64 GB Macs |
| Gemma 4 26B-A4B (mlx-community 4-bit) | ~16 GB | Vision + text, alternative quant |
| Gemma 4 31B (QAT 4-bit) | ~17 GB | Vision + text on 24–32 GB Macs |
| Gemma 4 E4B (QAT 4-bit) | ~4 GB | Small vision + text on 16 GB Macs |
| DeepSeek R1 8B (Qwen3) | ~4 GB | Lightweight reasoning |
| Hermes 4 70B | ~56 GB | General purpose |
| Magistral Small | ~13 GB | Fast inference |
| Nemotron Cascade 30B | ~1 GB | Ultra-low memory |
| DeepSeek V4-Flash | ~151 GB | Long-context reasoning (128 GB+ Mac) |
| GLM-5.1 | ~150 GB | Coding, MIT license (128 GB+ Mac) |
| MiniMax M2.7 | ~128 GB | Agentic coding (128 GB+ Mac) |
| Kimi K2.6 | ~186 GB | Agentic coding / swarms (512 GB Mac) |
| Llama 4 Scout | ~60 GB | Long context (10M tokens), vision + text |
| Hub models (Qwen 3 8B/4B, Llama 3.2 1B) | ~1–6 GB | Quick experiments |

### Per-agent model overrides
Assign different models to different agents via the **"This agent"** picker in the chat toolbar. For example:
- **Navigator** → Gemma 4 26B-A4B (general chat + vision)
- **Coder sub-agent** → Qwen 3 Coder 30B (coding focus)
- **Reasoning sub-agent** → Qwen 3.5 122B (deep reasoning)

Each agent runs its own model independently — no conflicts, no shared state.

By default models are stored under `~/Library/Application Support/SwiftMaestro/models`. To reuse an existing collection (for example on an external drive), set a custom path in **Settings → Models**.

## What it can do out of the box
The assistant has native, in-process tools — no configuration required:
- **Multi-Agent Workspace** — create named agents for different domains, each with its own memory, rules, and model.
- **Memory** — durable notes/knowledge in the shared `~/.ai-context/memory` store.
- **Files** — read and write almost any file type within folders you authorize in **Settings → Context**:
  - Plain text, Markdown, CSV, JSON, code, etc.
  - Documents: `.docx`, `.pdf`, `.rtf`, `.odt`, `.pages`, `.html`
  - Images: description + raw/base64 payload for multimodal models
  - Arbitrary binary: base64-encoded read/write
- **Document indexing & retrieval** — index large files into searchable chunks and pull back the exact original text with `index_document`, `search_chunks`, and `read_chunk`. No summarization; the model sees verbatim source snippets.
- **Apple Integration** — create Reminders, Calendar events, and Notes; search and manage Contacts; run and create Apple Shortcuts; use Apple Notes, Numbers, and Calendar data in chat.
- **Plans, live task checklists, multi-agent messaging, and current time.**
- **Behavioral rules** — `list_rules` and `set_rule` tools let the agent manage its own behaviour rules.
- **Speech-to-text** — tap the microphone button to dictate; WhisperKit transcribes locally with no cloud API.
- **Vision & Images** — attach images to your messages, or use the Vision Proxy to caption images locally for multimodal conversations.
- **Mid-generation steering** — send a message while the agent is generating to redirect it on the fly.
- **Extensible tools** — SQLite, shell, local servers, Kanban boards, Canvas, and WhatsApp bridge. Add more via MCP servers in **Settings → MCP**.

See [`docs/MCP-SERVERS.md`](docs/MCP-SERVERS.md) for how the MCP integration works and what makes a server SwiftMaestro-friendly, and [`docs/mcp-template/`](docs/mcp-template/) for a minimal, verified-working example server.

## Project Status

| Phase | Status | Description |
| --- | --- | --- |
| 1 | ✅ Complete | Native macOS app — multi-agent chat, streaming, secure storage, model picker, notarised DMG |
| 2 | ✅ Complete | On-device tools — memory, file I/O, document indexing, Reminders/Calendar/Notes/Contacts, Apple Shortcuts, speech-to-text, image input, vision proxy |
| 3 | ✅ Complete | Per-agent model overrides, mid-generation steering, thinking display, multi-model residency, SQLite, shell, WhatsApp bridge |
| 4 | 🚧 In Progress | Advanced memory — context store, fact graph, learning engine, knowledge promotion |
| 5 | 📋 Planned | Personalised on-device fine-tuning (LoRA) |

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
| MaestroTools+Indexing | `Sources/Engine/MaestroTools+Indexing.swift` | Chunk-based document RAG (index/search/read) |
| FileContentExtractor | `Sources/Utilities/FileContentExtractor.swift` | Text extraction for documents, images, and binary |
| ModelCatalog | `Sources/Engine/ModelCatalog.swift` | Model list, default, local/Hub/remote resolution |
| WhisperKitService | `Sources/Services/WhisperKitService.swift` | Speech-to-text: model lifecycle, recording, streaming transcription |
| SimpleMemoryStore | `Sources/Memory/SimpleMemoryStore.swift` | Shared `~/.ai-context/memory` store |
| SettingsView | `Sources/Views/SettingsView.swift` | Models, Tuning, Vision Proxy, Appearance, Rules, Context, MCP, Storage, Secrets, Whisper, Shell |
| KeychainService / SecretsStore | `Sources/Services/` | Keychain-backed secrets, `secret://` resolution |

## Privacy & distribution
- No telemetry, analytics, or data collection. All inference is local.
- Not sandboxed (distributed outside the App Store) so it can integrate with the system; it ships with hardened runtime and is notarized.
- Secrets are stored only in the macOS Keychain.

## License
MIT License — see [LICENSE](LICENSE).
