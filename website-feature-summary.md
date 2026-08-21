# SwiftMaestro — Complete Feature Summary

> Foundation document for website rewrite. Organized for easy expansion into individual feature pages.

---

## What It Is

SwiftMaestro is a **fully local AI assistant for macOS** that runs entirely on your Mac's GPU — no cloud, no servers, no accounts, no subscriptions. It's a multi-panel workspace where you chat with an AI that can actually *do things*: read your files, manage your calendar, send emails, run shell commands, build documents, track finances, and much more.

Think of it as a **personal AI operating system** that lives on your Mac.

---

## The Big Numbers

| Stat | Detail |
|------|--------|
| **Panels** | 40+ built-in mini-apps |
| **Agent Tools** | 150+ tools across 35 categories |
| **Integrations** | 30+ services and platforms |
| **Settings Tabs** | 14 configuration panels |
| **Agent Categories** | 13 specialized agent types |
| **Bundled MCP Servers** | 11 shipped inside the app |
| **Plugin Architecture** | Open WKWebView plugin system |
| **Zero Dependencies** | No Homebrew, no external runtimes |

---

## Core Features

### 100% Local Inference
- AI models run **in-process on your GPU** via Apple MLX
- No server, no account, no cloud — ever
- Models downloaded once, stored locally
- Multi-model support: switch between models for different tasks

### Multi-Model Support
| Model | Specialty |
|-------|-----------|
| **Gemma 4 26B-A4B** | Vision + Text, general navigator |
| **Qwen 3.5 122B (A10B)** | Deep reasoning, complex tasks |
| **Qwen 3.5 27B (Opus Distilled)** | Balanced performance |
| **Qwen 3 Coder Next** | Coding tasks, sub-agents |
| Plus | Qwen 3.6, DeepSeek R1, Hermes 4, Magistral, Nemotron, Hub models |

### Fully Self-Contained
- Everything ships inside the app — no external runtimes
- Downloads the model you pick on first use
- Bundles FFmpeg, WhisperKit models, and 11 MCP servers

### Auto-Updates via Sparkle
- Built-in update framework with EdDSA signature verification
- Check for updates from the About tab or automatically

---

## The AI Brain

### Panel-Aware Agents
- Tools **activate automatically** when the matching panel is open
- Maestro can open any panel for you — including ones you've never opened
- The AI knows what you're looking at and can work with it

### Multi-Agent Architecture
- **Maestro (Navigator)** — your main AI conductor that delegates to specialists
- **Project Agents** — long-lived per-project AI assistants with their own working directory, model, and tool set
- **13 Agent Categories** — Coding, Research, Analysis, Create, Writing, Design, DevOps, Testing, Data, Marketing, Legal, Finance, General
- **Task Tool** — launch temporary specialist agents for parallel work
- **Compact Tool Mode** — large tool sets deferred behind discovery for cleaner conversations

### Agent Bus
- Reactive pub/sub message broker for agent-to-agent communication
- Persistent polling workers that auto-reply to bus requests
- Real-time bus traffic viewer panel

### Built-in Intelligence
- **Mid-Generation Steering** — inject new input while the AI is generating
- **Reasoning Split** — separates thinking from final answer
- **Chat Compaction** — auto-summarizes when approaching context limits
- **Model Capability Validation** — verifies tool support per model at startup

---

## Built-In Panels (40+ Mini-Apps)

### Chat & Communication

**Chat**
Main AI chat interface with streaming responses, tool calls, image attachments, markdown rendering, and code block syntax highlighting. The AI can read and write files, run commands, and manage your workspace — all from the chat.

**Apple Mail**
A webmail-style mail reader that connects to your Mail.app data. Browse mailboxes, read messages with full HTML rendering, compose replies. No tracking, no analytics — just your mail, surfaced through the AI.

**WhatsApp**
Full WhatsApp chat interface with QR code pairing for multi-device. Read conversations, send messages, search chats — all self-hosted through a local bridge.

**Discord**
Browse servers and channels, read messages, archive conversations, send messages. Connect your Discord workspace to the AI.

### Productivity & Organization

**Notes**
A Markdown editor with folder tree, iCloud sync, and web clipper integration. Create, edit, and search your notes. The AI can read and write directly to your Notes vault.

**Apple Notes**
Browse your native Apple Notes folders and notes. The AI can search, read, and create notes in Apple's own Notes app.

**Calendar**
EventKit-based calendar view. See your events, create new ones, search across your schedule. The AI can manage your calendar through conversation.

**Reminders**
EventKit-based reminders listing. Create, list, and manage your reminders through the AI.

**Contacts**
Native macOS contacts browser. Search, create, update, and delete contacts — all through the AI.

**Kanban**
Kanban boards with drag-and-drop cards, columns, search, and full agent control. The AI can create boards, add cards, move them between columns, and track your projects.

**Plans**
Per-agent markdown plan documents with version history. Create, edit, and track project plans that persist across sessions.

### Data & Databases

**MaestroDB**
A built-in Airtable-style database. Create your own bases with custom tables and typed fields. Grid and kanban views, CSV import/export, linked rows, and full agent control — the AI can query and modify your databases through conversation.

**SQLite**
Direct SQLite database querying. Inspect schemas, run read/write queries with safety gating. The AI can analyze any SQLite database on your system.

**Numbers**
Browse Apple Numbers files, navigate sheets and tables, read and write cells. The AI can work with your spreadsheets directly.

### Documents & Content

**Documents**
View and author PDF, DOCX, RTF, ODT, HTML, CSV, XLSX, PPTX, and EPUB — all native, no external dependencies. The AI can create and edit documents in any of these formats.

**Whiteboard**
Freeform canvas with sticky notes, text boxes, shapes, image insertion, pen/eraser drawing, grid, zoom, and export to PNG, JPEG, PDF, or SVG. Brainstorm and sketch with the AI.

**HTML Builder**
WYSIWYG HTML/CSS editor with live preview. 26 HTML snippets, 21 CSS helpers, 5 templates, copy-to-clipboard, and auto-format. The AI can build web pages for you.

**Overlay Builder**
Live video overlay designer at 1920x1080. Multiple overlay types (text, images, shapes, clocks), safe area guides, transparent PNG export, and HTML overlay editor.

### Media & Creative

**Photos**
Browse Apple Photos albums and assets. The AI can search and reference your photo library.

**Maps**
Apple Maps with geocoding, reverse geocoding, and point-of-interest search. The AI can find locations, calculate distances, and open directions.

**DAM (Digital Asset Management)**
Import, search, rate, tag, and filter your media library. Full-text search across assets with keyword management and filter views.

**Voice Notes**
Record voice notes with local WhisperKit transcription. Export transcriptions to Notes. Push-to-talk hotkey support.

### Business & Finance

**Books**
Full invoicing system: clients, invoices, products, expenses, PDF invoice generation, and Xero accounting sync. The AI can create invoices, track expenses, and manage your books.

**Stocks**
Stock watchlist with quotes, add/remove symbols. The AI can check stock prices and manage your watchlist.

**News**
Apple News launcher — the AI can open articles in Apple News.

### Web & Research

**Web Browser**
Internal browser with WebKit and Chromium CDP engines, tabs, and navigation. The AI can browse the web, read pages, and extract information.

**Plugins**
WKWebView-hosted panels for third-party integrations. Bundled: Mastodon, Bluesky, Patreon. User-installable from the plugins directory.

### System & Monitoring

**Terminal**
Live PTY shell with VT100/ANSI emulation plus agent command log. Run commands directly or watch the AI execute them.

**Agents**
Sidebar launcher listing all Maestro and project agents. Quick access to switch between AI assistants.

**Apps Launcher**
Sidebar launcher for all available workspace panels, organized by category.

**Bus Monitor**
Real-time agent bus traffic viewer — watch agents communicate with each other.

**Resource Monitor**
CPU and memory usage monitoring during AI inference.

**Backup Status**
Backup status indicator showing the health of your data backups.

---

## Agent Tools (150+ Tools)

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

### Database
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
| **Apple Mail** | Reads Mail.app data via SQLite EDB + JXA fallback |
| **Calendar & Reminders** | Full EventKit integration |
| **Apple Notes** | Browse and read via AppleScript/JXA |
| **Contacts** | Native macOS Contacts framework |
| **Maps** | MapKit geocoding, reverse geocoding, POI search |
| **Photos** | PhotoKit album and asset browsing |
| **Numbers** | JXA automation for spreadsheets |
| **Shortcuts** | List, run, and create Apple Shortcuts |
| **Stocks** | Watchlist management and quotes |
| **News** | Apple News launcher |

### Messaging
| Platform | What's Possible |
|----------|----------------|
| **WhatsApp** | Self-hosted bridge, read/send messages, QR pairing |
| **Discord** | Servers, channels, messages, archiving |
| **Bluesky** | Full social media management |
| **Mastodon** | WKWebView plugin panel |

### Social & Creator
| Platform | What's Possible |
|----------|----------------|
| **Patreon** | Campaigns, members, posts, memberships |
| **Bluesky** | Search, profiles, feeds, posting |

### Web & Research
| Tool | What It Does |
|------|-------------|
| **Firecrawl** | Self-hosted web scraping |
| **Internal Browser** | WebKit + Chromium CDP |
| **Web Clipper** | Clip pages to Notes |
| **Obsidian** | Vault access + REST API |

### Security
| Feature | How It Works |
|---------|-------------|
| **Keychain** | All secrets in macOS Keychain (iCloud sync) |
| **SecretRedactor** | Strips secrets before memory writes |
| **Authorized Folders** | File access restricted to approved dirs |
| **Shell Policy** | Command classification: allowed/denied/ask |
| **Hardened Runtime** | App-level security hardening |

### Accounting
| Integration | What It Does |
|-------------|-------------|
| **Xero** | OAuth2 sync, invoices, clients, products |

### Media
| Tool | What It Does |
|------|-------------|
| **FFmpeg** | Bundled — video processing and recording |
| **WhisperKit** | Local speech-to-text via CoreML |

### Infrastructure
| Tool | What It Does |
|------|-------------|
| **MCP Servers** | 11 bundled servers for external tool access |
| **Python Venv** | Managed environment for ML tools |
| **Sparkle** | Auto-update with EdDSA verification |
| **LM Studio** | Remote model backend integration |

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
| **Rules** | Agent behavioral rules |
| **Context** | Authorized folders, files in memory |
| **MCP** | MCP server configuration |
| **Storage** | Paths, backup, data management |
| **Secrets** | Keychain secrets (add/edit/delete, iCloud sync, scope) |
| **Whisper** | WhisperKit model, push-to-talk hotkey, dictation |
| **Shell** | Command policy rules (approve/deny patterns) |
| **About** | Version, credits, links |

---

## Security Model

### Privacy by Design
- **No telemetry, no analytics, no data collection**
- All inference local on Apple Silicon
- Secrets only in macOS Keychain

### Access Control
- Authorized folders for file access
- Shell command policy classification
- Permission service (allow/ask/deny per tool/path)
- ChangeGuard rollback for file overwrites
- SecretRedactor strips values before memory writes

### Code Integrity
- Hardened Runtime
- Automatic code signing
- EdDSA verification for updates

---

## Extensibility

### Plugin System
- WKWebView-based UI plugins
- Capabilities: network, secrets, tools, OAuth
- Bundled: Mastodon, Bluesky, Patreon
- User-installable

### MCP (Model Context Protocol)
- Connect to external tool servers
- 11 bundled servers
- Custom server configuration

### Multi-Agent Communication
- Agent bus for reactive pub/sub
- Inter-agent messaging inbox
- Persistent polling workers

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

## Build & Distribution

### Requirements
- macOS 14.0+ (Sonoma or later)
- Apple Silicon M1 or later

### Distribution
- GitHub releases with DMG installer
- Auto-updates via Sparkle
- Source-available (PolyForm Noncommercial License)

### What's Inside
- Swift 6.3, SwiftUI
- Apple MLX for in-process inference
- GRDB for databases
- SwiftTerm for terminal
- FFmpeg bundled
- WhisperKit bundled
- 11 MCP servers bundled
