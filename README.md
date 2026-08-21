# SwiftMaestro

A native macOS AI assistant that runs large language models **fully on-device** on Apple Silicon via Apple [MLX](https://github.com/ml-explore/mlx) (`mlx-swift-lm`). No server, no account, no cloud — your conversations and files never leave your Mac.

## The Big Numbers

| | |
|---|---|
| **40+** built-in panels | **150+** agent tools |
| **30+** integrations | **14** settings tabs |
| **13** agent categories | **11** bundled MCP servers |
| **Zero** external dependencies | **Zero** cloud required |

---

## Highlights

- **100% local inference** — models run in-process on the Apple Silicon GPU through MLX. No external runtime or server to start or manage.
- **Self-contained** — on first launch a guided onboarding walks you through picking, downloading, and loading a model. Nothing is hard-wired to a specific machine. Bundles FFmpeg, WhisperKit models, and 11 MCP servers inside the app.
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
- **Distributed as a signed `.dmg`** — Developer ID signed for Apple Silicon Mac. Auto-updates via Sparkle with EdDSA verification.

---

## Built-In Panels (40+ Mini-Apps)

SwiftMaestro is a **multi-panel workspace** with a tiling canvas. Each panel can be docked in the main window or floated as its own window. Drag, drop, resize, and rearrange freely.

### Chat & Communication

**Chat** — Main AI chat interface with streaming responses, tool calls, image attachments, markdown rendering, and code block syntax highlighting. The AI can read and write files, run commands, and manage your workspace — all from the chat.

**Apple Mail** — A webmail-style mail reader that connects to your Mail.app data. Browse mailboxes, read messages with full HTML rendering, compose replies. No tracking, no analytics — just your mail, surfaced through the AI.

**WhatsApp** — Full WhatsApp chat interface with QR code pairing for multi-device. Read conversations, send messages, search chats — all self-hosted through a local bridge.

**Discord** — Browse servers and channels, read messages, archive conversations, send messages. Connect your Discord workspace to the AI.

### Productivity & Organization

**Notes** — A Markdown editor with folder tree, iCloud sync, and web clipper integration. Create, edit, and search your notes. The AI can read and write directly to your Notes vault.

**Apple Notes** — Browse your native Apple Notes folders and notes. The AI can search, read, and create notes in Apple's own Notes app.

**Calendar** — EventKit-based calendar view. See your events, create new ones, search across your schedule. The AI can manage your calendar through conversation.

**Reminders** — EventKit-based reminders listing. Create, list, and manage your reminders through the AI.

**Contacts** — Native macOS contacts browser. Search, create, update, and delete contacts — all through the AI.

**Kanban** — Kanban boards with drag-and-drop cards, columns, search, and full agent control. The AI can create boards, add cards, move them between columns, and track your projects.

**Plans** — Per-agent markdown plan documents with version history. Create, edit, and track project plans that persist across sessions.

### Data & Databases

**MaestroDB** — A built-in Airtable-style database. Create your own bases with custom tables and typed fields. Grid and kanban views, CSV import/export, linked rows, and full agent control — the AI can query and modify your databases through conversation.

**SQLite** — Direct SQLite database querying. Inspect schemas, run read/write queries with safety gating. The AI can analyze any SQLite database on your system.

**Numbers** — Browse Apple Numbers files, navigate sheets and tables, read and write cells. The AI can work with your spreadsheets directly.

### Documents & Content

**Documents** — View and author PDF, DOCX, RTF, ODT, HTML, CSV, XLSX, PPTX, and EPUB — all native, no external dependencies. The AI can create and edit documents in any of these formats.

**Whiteboard** — Freeform canvas with sticky notes, text boxes, shapes, image insertion, pen/eraser drawing, grid, zoom, and export to PNG, JPEG, PDF, or SVG. Brainstorm and sketch with the AI.

**HTML Builder** — WYSIWYG HTML/CSS editor with live preview. 26 HTML snippets, 21 CSS helpers, 5 templates, copy-to-clipboard, and auto-format. The AI can build web pages for you.

**Overlay Builder** — Live video overlay designer at 1920x1080. Multiple overlay types (text, images, shapes, clocks), safe area guides, transparent PNG export, and HTML overlay editor.

### Media & Creative

**Photos** — Browse Apple Photos albums and assets. The AI can search and reference your photo library.

**Maps** — Apple Maps with geocoding, reverse geocoding, and point-of-interest search. The AI can find locations, calculate distances, and open directions.

**DAM (Digital Asset Management)** — Import, search, rate, tag, and filter your media library. Full-text search across assets with keyword management and filter views.

**Voice Notes** — Record voice notes with local WhisperKit transcription. Export transcriptions to Notes. Push-to-talk hotkey support.

### Business & Finance

**Books** — Full invoicing system: clients, invoices, products, expenses, PDF invoice generation, and Xero accounting sync. The AI can create invoices, track expenses, and manage your books.

**Stocks** — Stock watchlist with quotes, add/remove symbols. The AI can check stock prices and manage your watchlist.

**News** — Apple News launcher — the AI can open articles in Apple News.

### Web & Research

**Web Browser** — Internal browser with WebKit and Chromium CDP engines, tabs, and navigation. The AI can browse the web, read pages, and extract information.

**Plugins** — WKWebView-hosted panels for third-party integrations. Bundled: Mastodon, Bluesky, Patreon. User-installable from the plugins directory.

### System & Monitoring

**Terminal** — Live PTY shell with VT100/ANSI emulation plus agent command log. Run commands directly or watch the AI execute them.

**Agents** — Sidebar launcher listing all Maestro and project agents. Quick access to switch between AI assistants.

**Apps Launcher** — Sidebar launcher for all available workspace panels, organized by category.

**Bus Monitor** — Real-time agent bus traffic viewer — watch agents communicate with each other.

**Resource Monitor** — CPU and memory usage monitoring during AI inference.

**Backup Status** — Backup status indicator showing the health of your data backups.

---

## The AI Brain

### Panel-Aware Agents

Tools **activate automatically** when the matching panel is open. Maestro can open any panel for you — including ones you've never opened. The AI knows what you're looking at and can work with it.

### Multi-Agent Architecture

- **Maestro (Navigator)** — your main AI conductor that delegates to specialists
- **Project Agents** — long-lived per-project AI assistants with their own working directory, model, and tool set
- **13 Agent Categories** — Coding, Research, Analysis, Create, Writing, Design, DevOps, Testing, Data, Marketing, Legal, Finance, General
- **Task Tool** — launch temporary specialist agents for parallel work
- **Compact Tool Mode** — large tool sets deferred behind discovery for cleaner conversations

### Agent Bus

Reactive pub/sub message broker for agent-to-agent communication. Persistent polling workers that auto-reply to bus requests. Real-time bus traffic viewer panel.

### Built-in Intelligence

- **Mid-Generation Steering** — inject new input while the AI is generating
- **Reasoning Split** — separates thinking from final answer
- **Chat Compaction** — auto-summarizes when approaching context limits
- **Model Capability Validation** — verifies tool support per model at startup

---

## Agent Tools (150+ Tools in 35 Categories)

### File Operations
`read_file` · `write_file` · `list_dir` · `copy_file` · `move_file` · `delete_file` · `create_directory` · `glob_files` · `grep_code` · `edit_file` · `ocr_image` · `list_file_snapshots` · `restore_file_snapshot`

### Shell & Development
`execute_command` (with dry-run, background, approval flow) · `list_background_processes` · `stop_background_process` · `git_status` · `git_diff` · `git_log` · `git_branch` · `upload_release`

### Memory & Knowledge
`memory_write` · `memory_read` · `memory_search` · `memory_list` · `context_update` · `context_read` · `fact_remember` · `fact_query` · `memory_promote` · `memory_learn`

### Documents
`document_read` (PDF/docx/rtf/odt/html/csv/xlsx/pptx/epub) · `document_create` · `document_info`

### Invoicing
`client_create` · `client_list` · `invoice_create` · `invoice_list` · `invoice_read` · `invoice_status` · `invoice_payment` · `invoice_publish` · `product_create` · `product_list` · `expense_create` · `expense_list` · `xero_status` · `xero_sync` · `xero_disconnect`

### Database (MaestroDB)
`db_list_bases` · `db_create_base` · `db_list_tables` · `db_create_table` · `db_table_schema` · `db_add_field` · `db_list_rows` · `db_add_row` · `db_update_row` · `db_delete_row` · `db_import_csv` · `db_export_csv`

### SQLite
`execute_sqlite` (schema inspection, read/write queries with safety gating)

### Workspace & Agents
`create_project_agent` · `list_workspace` · `archive_project_agent` · `ask_project_agent` · `ask_project_agents` · `set_agent_model` · `list_models` · `open_panel` · `close_panel` · `task`

### Agent Bus
`bus_publish` · `bus_subscribe` · `bus_read` · `bus_request` · `bus_reply` · `bus_context_snapshot` · `bus_worker_start` · `bus_worker_stop`

### Notes & Kanban
`create_note` · `list_notes` · `read_note` · `write_note` · `search_notes` · `list_kanban_boards` · `create_kanban_board` · `list_kanban_cards` · `create_kanban_card` · `move_kanban_card` · `update_kanban_card` · `delete_kanban_card`

### Apple Apps
`list_apple_note_folders` · `list_apple_notes` · `read_apple_note` · `create_calendar_event` · `list_calendar_events` · `create_reminder` · `list_reminders` · `list_reminder_lists` · `search_contacts` · `create_contact` · `update_contact` · `delete_contact` · `list_shortcuts` · `run_shortcut` · `create_shortcut` · `open_url`

### Maps & Photos
`geocode_address` · `reverse_geocode` · `search_poi` · `open_apple_maps` · `open_maps_panel` · `search_maps_panel` · `list_photos_albums` · `list_photos_assets` · `open_photos_app`

### Stocks & Numbers
`open_stocks` · `list_stocks` · `add_stock` · `remove_stock` · `stock_quote` · `list_numbers_documents` · `create_numbers_document` · `read_numbers_table` · `write_numbers_cell` · `export_numbers_document`

### Mail
`open_apple_mail` · `open_apple_mail_panel` · `compose_apple_mail` · `apple_mail_selected_message`

### Messaging
`whatsapp_status` · `start_whatsapp_bridge` · `stop_whatsapp_bridge` · `list_whatsapp_chats` · `read_whatsapp_messages` · `send_whatsapp_message` · `list_discord_servers` · `list_discord_channels` · `read_discord_messages` · `archive_discord_channel` · `send_discord_message` · `send_agent_message` · `read_agent_messages`

### Web & Research
`web_search` · `fetch_url` · `deep_fetch` · `web_crawl` · `site_map`

### Browser
`browser_open` · `browser_list` · `browser_focus` · `browser_close` · `browser_navigate` · `browser_read` · `browser_current` · `browser_clip` · `browser_eval` · `browser_screenshot` · `browser_links`

### Social
`search_bluesky_posts` · `get_bluesky_profile` · `post_bluesky` · `like_bluesky_post` · `get_patreon_campaign` · `list_patreon_members` · `list_patreon_posts` · `get_patreon_memberships`

### Obsidian Vault
`obsidian_search_vault` · `obsidian_read_note` · `obsidian_write_note` · `obsidian_list_vault`

### Indexing & Search
`index_directory` · `save_index` · `spotlight_search` · `index_document` · `search_chunks` · `read_chunk`

### HTTP Servers
`start_server` · `stop_server` · `list_servers`

### Rules & Meta
`list_rules` · `set_rule` · `read_project_rules` · `search_tools` · `call_tool` · `get_current_time`

---

## Integrations (30+ Services)

### Apple Ecosystem

| Service | How It Works |
|---------|-------------|
| **Apple Mail** | Reads Mail.app data via SQLite EDB + JXA fallback. Compose via JXA or mailto: links |
| **Calendar & Reminders** | Full EventKit integration — create, list, search events and reminders |
| **Apple Notes** | Browse and read via AppleScript/JXA automation |
| **Contacts** | Native macOS Contacts framework — search, create, update, delete |
| **Maps** | MapKit geocoding, reverse geocoding, POI search |
| **Photos** | PhotoKit album and asset browsing |
| **Numbers** | JXA automation for spreadsheets |
| **Shortcuts** | List, run, and create Apple Shortcuts via AppleScript |
| **Stocks** | Watchlist management and quotes |
| **News** | Apple News launcher |

### Messaging

| Platform | What's Possible |
|----------|----------------|
| **WhatsApp** | Self-hosted bridge (whatsmeow/multi-device). Read chats, send messages, QR code pairing |
| **Discord** | REST API integration — servers, channels, messages, archiving |
| **Bluesky** | AT Protocol — search, profiles, feeds, posting, like/repost |
| **Mastodon** | WKWebView plugin panel |

### Social & Creator

| Platform | What's Possible |
|----------|----------------|
| **Patreon** | Campaigns, members, posts, memberships |
| **Bluesky** | Full social media management from the AI |

### Web & Research

| Tool | What It Does |
|------|-------------|
| **Firecrawl** | Self-hosted web scraping (localhost:3002) — scrape, crawl, search, extract |
| **Internal Browser** | WebKit + Chromium CDP engines with tabs, navigation, evaluation |
| **Web Clipper** | Clip web pages directly into your Notes vault |
| **Obsidian** | File-based vault access + REST API integration |

### Security

| Feature | How It Works |
|---------|-------------|
| **Keychain** | All secrets in macOS Keychain (iCloud sync aware). Never in source, logs, or memory |
| **SecretRedactor** | Strips secret values before writing to shared memory |
| **Authorized Folders** | File access restricted to user-approved directories |
| **Shell Policy** | Command classification: allowed/denied/ask with approval queue |
| **Hardened Runtime** | App-level security hardening |

### Accounting

| Integration | What It Does |
|-------------|-------------|
| **Xero** | OAuth2 loopback auth, sync invoices/clients/products, export |

### Media

| Tool | What It Does |
|------|-------------|
| **FFmpeg** | Bundled — video processing and recording |
| **WhisperKit** | Local speech-to-text via CoreML models |

### Infrastructure

| Tool | What It Does |
|------|-------------|
| **MCP Servers** | 11 bundled servers (ai-context-bridge, crawlkit, firecrawl, playwright, webclaw, whatsapp, xcodebuildmcp, and more) |
| **Python Venv** | Managed virtual environment for HuggingFace downloads and vision proxy |
| **Sparkle** | Auto-update framework with EdDSA signature verification |
| **LM Studio** | Remote LM Studio server integration for additional model backends |

---

## Settings (14 Tabs)

| Tab | What You Configure |
|-----|-------------------|
| **Models** | Model selection, downloads, bundled install, remote LM Studio |
| **Tuning** | Temperature, top_p, top_k, min_p, repetition_penalty, max tokens, context length — per-model |
| **Vision Proxy** | Vision model, proxy mode (MLX or Python), image resize limits |
| **Appearance** | Theme, accent color, light/dark mode, custom skins |
| **Apps** | Enable/disable individual panels |
| **Mail** | Mail panel configuration |
| **Rules** | Agent behavioral rules (injected into system prompt) |
| **Context** | Authorized folders, files in memory |
| **MCP** | MCP server configuration (bundled presets, custom servers) |
| **Storage** | Paths, backup, data management |
| **Secrets** | Keychain secrets (add/edit/delete, iCloud sync, scope) |
| **Whisper** | WhisperKit model, push-to-talk hotkey, dictation |
| **Shell** | Command policy rules (approve/deny patterns) |
| **About** | Version, credits, links |

---

## The Workspace Experience

### Flexible Tiling Canvas
- Free-tile drag-and-drop panels
- Tab stacking for organized views
- Split across multiple displays
- Persistent layout between sessions

### Floating Windows
- Pop out any panel as its own window
- Agent chat windows for side-by-side viewing
- Plan windows for focused editing

### Customization
- Full theme system with accent colors
- Light/dark mode
- Custom skins
- Per-agent model and tool selection
- Tool category toggles
- Shell command approval workflow

---

## Requirements
- Apple Silicon Mac (M1 or later). Intel is not supported — MLX is Apple-Silicon-only.
- macOS 14 (Sonoma) or later.
- **Designed for:** M-series Pro/Max/Ultra with 64GB+ unified memory (128GB optimal for running multiple large models).
- **Lighter runs:** any Apple Silicon Mac with 32GB+ unified memory; smaller Hub models work well.
- Disk space and RAM scale with the model you choose (see [Models](#models)).

## Install (beta)
1. Download **[SwiftMaestro-0.1.2-beta.dmg](https://swiftmaestro.com/download/SwiftMaestro-0.1.2-beta.dmg)** from the SwiftMaestro website.
2. Open the `.dmg` and drag **SwiftMaestro** to **Applications**.
3. Launch it. Because it's Developer ID signed, it opens cleanly on first launch.

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
| Qwen 3 Coder Next | ~45 GB | Coding tasks, sub-agents | ✅ |

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

---

## Security Model

### Privacy by Design
- **No telemetry, no analytics, no data collection**
- All inference local on Apple Silicon
- Secrets only in macOS Keychain

### Access Control
- Authorized folders for file access
- Shell command policy classification (allowed/denied/ask)
- Permission service (allow/ask/deny per tool/path)
- ChangeGuard rollback for file overwrites
- SecretRedactor strips values before memory writes

### Code Integrity
- Hardened Runtime
- Automatic code signing (Developer ID)
- EdDSA verification for updates

---

## Extensibility

### Plugin System
- WKWebView-based UI plugins with `manifest.json` + entry HTML/CSS/JS
- **Capabilities:** network (HTTP), secrets (Keychain), tools (native call), OAuth
- Bundled: Mastodon, Bluesky, Patreon
- User-installable from `~/Library/Application Support/SwiftMaestro/plugins/`

### MCP (Model Context Protocol)
- Connect to external tool servers
- 11 bundled servers shipped inside the app
- Custom server configuration in Settings

### Multi-Agent Communication
- Agent bus for reactive pub/sub messaging
- Inter-agent messaging inbox
- Persistent polling workers for auto-reply

---

## Project Status

| Phase | Status | Description |
| --- | --- | --- |
| 1 | ✅ Complete | Native macOS app — multi-agent chat, streaming, secure storage, model picker, notarised DMG |
| 2 | ✅ Complete | On-device tools — memory, file I/O, document indexing, Reminders/Calendar/Notes/Contacts, Apple Shortcuts, speech-to-text, image input, vision proxy |
| 3 | ✅ Complete | Per-agent model overrides, mid-generation steering, thinking display, multi-model residency, SQLite, shell, WhatsApp bridge |
| 4 | 🚧 In Progress | Advanced memory — context store, fact graph, learning engine, knowledge promotion |
| 5 | 📋 Planned | Personalised on-device fine-tuning (LoRA) |

---

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

---

## Architecture (overview)

| Component | Path | Purpose |
| --- | --- | --- |
| ChatView / MessageBubble | `Sources/Views/` | Chat UI + markdown rendering |
| CanvasWorkspaceView | `Sources/Views/CanvasWorkspaceView.swift` | Tiling workspace canvas |
| ChatViewModel | `Sources/ViewModels/ChatViewModel.swift` | Chat, streaming, system prompt |
| MLXInferenceEngine | `Sources/Engine/MLXInferenceEngine.swift` | In-process MLX inference (the only backend) |
| AgentExecutor | `Sources/Engine/AgentExecutor.swift` | Agentic loop with delegation, steering, compaction |
| MaestroTools (+ extensions) | `Sources/Engine/MaestroTools*.swift` | 150+ native in-process tools |
| ModelCatalog | `Sources/Engine/ModelCatalog.swift` | Model list, default, local/Hub/remote resolution |
| MaestroDB | `Sources/MaestroDB/` | Dynamic-schema database engine |
| DAM | `Sources/DAM/` | Digital Asset Management |
| Books | `Sources/Books/` | Invoicing and Xero sync |
| Documents | `Sources/Documents/` | PDF/DOCX/RTF/ODT/XLSX/PPTX engine |

| WhisperKitService | `Sources/Services/WhisperKitService.swift` | Speech-to-text |
| VisionProxyService | `Sources/Services/VisionProxyService.swift` | Image captioning proxy |
| SimpleMemoryStore | `Sources/Memory/SimpleMemoryStore.swift` | Shared `~/.ai-context/memory` store |
| PluginService / PluginBridge | `Sources/Services/Plugin*.swift` | WKWebView plugin system |
| KeychainService / SecretsStore | `Sources/Services/` | Keychain-backed secrets |
| SettingsView | `Sources/Views/SettingsView.swift` | 14-tab settings window |

---

## Privacy & distribution
- No telemetry, analytics, or data collection. All inference is local.
- Not sandboxed (distributed outside the App Store) so it can integrate with the system; it ships with hardened runtime and is notarized.
- Secrets are stored only in the macOS Keychain.

## License
**PolyForm Noncommercial 1.0.0** — see [LICENSE](LICENSE).

Free to use, copy, modify, and share for **non-commercial** purposes.
Commercial use of any kind (selling, charging for, or commercially
redistributing SwiftMaestro or derivatives) requires a commercial license
from the author — contact via [swiftmaestro.com](https://swiftmaestro.com/contact.html).
