# SwiftMaestro Vision & Architecture

**Vision:** Bring Apple Intelligence to reality on macOS using open-source Qwen models, MLX framework, and native macOS integration — all offline-first with privacy at the core.

---

## Core Principles

### 1. **Privacy-First, Offline-First**
- All model inference happens locally on Apple Silicon
- No PII or personal data leaves the device unless explicitly requested
- Online access ONLY for:
  - Web research (when user asks)
  - Performing tasks (when user asks)
- Default state: completely offline

### 2. **No App Store Distribution**
- GitHub repo + .dmg installer for end users
- No sandbox restrictions
- Full system access for deep macOS integration
- User-controlled permissions

### 3. **Personal Assistant AI**
- Contextual memory across all conversations
- Deep integration with macOS ecosystem
- Proactive assistance (with user consent)
- Learning from user preferences over time

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    SwiftMaestro                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │  Chat Interface │  │  System Memory  │  │  Task Orchestr. │ │
│  │  (SwiftUI)      │  │  (Local Vault)  │  │  (Agents)       │ │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘ │
│           │                    │                    │          │
│           └────────────────────┼────────────────────┘          │
│                                │                                │
│  ┌─────────────────────────────┼─────────────────────────────┐ │
│  │              Core Services Layer                           │ │
│  ├─────────────┬──────────────┼──────────────┬───────────────┤ │
│  │ MLX Inference│ WebKit     │ macOS APIs   │ MCP Tools     │ │
│  │ (Local LLM) │ (Research)  │ (System)     │ (Extensibility)│ │
│  └─────────────┴──────────────┴──────────────┴───────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Components

### 1. **Chat Interface (SwiftUI)**

**Purpose:** Natural conversation interface with streaming responses

**Features:**
- Markdown rendering with code syntax highlighting
- File drop for context attachment
- Fixed auto-scroll (debounced)
- Streaming token display
- Model selector (35B vs 122B)

**Source:** `Sources/Views/ChatView.swift` (already extracted)

---

### 2. **System Memory (Local Vault)**

**Purpose:** Persistent contextual memory across all conversations

**Implementation:**
- **Storage:** SQLite + FTS5 (full-text search) + sqlite-vec (vector embeddings)
- **Location:** `~/Library/Application Support/SwiftMaestro/memory/`
- **Structure:** OpenViking-style hierarchy
  ```
  memory/
  ├── conversations/      # Chat history
  ├── knowledge/          # Learned facts
  ├── context/            # Current session context
  └── skills/             # Tool capabilities
  ```

**Privacy:** All data stays on device, encrypted at rest

---

### 3. **MLX Inference Engine**

**Purpose:** Run Qwen models locally with Apple Silicon acceleration

**Options:**
1. **oMLX** (Current): Multi-model server with tiered KV cache
2. **MLX Swift Direct** (Future): Embed MLX Swift package directly
3. **Core ML** (Advanced): Convert models to Core ML for Neural Engine

**Models Supported:**
- Qwen 35B (fast, general use)
- Qwen 122B (deep reasoning)
- Future: Vision models (VLMs) for image understanding

---

### 4. **WebKit Integration (Research)**

**Purpose:** Web browsing and research when user explicitly requests

**Implementation:**
- Embedded WKWebView with full Safari engine
- Page content extraction for context
- Screenshot capture for vision models
- History tracking (user-controlled)

**Privacy:**
- No tracking without permission
- No data sent to external servers
- All processing happens locally

**Reference:** `WebKit JS` documentation in Obsidian vault

---

### 5. **macOS System Integration**

**Purpose:** Deep integration with macOS ecosystem

**Target APIs:**
- **Reminders:** Create, list, complete reminders
- **Calendar:** Read events, create meetings
- **Contacts:** Access contact information
- **Mail:** Send emails (with permission)
- **Journal:** Log personal entries
- **Freeform:** Collaborative whiteboards
- **Numbers:** Spreadsheet operations
- **Maps:** Location-based queries
- **Notes:** Access and create notes

**Implementation Strategy:**
- Use **AppleScript** / **Scripting Bridge** for automation
- Leverage **EventKit** for Calendar/Reminders
- Use **Contacts.framework** for contact access
- **NSAppleScript** for legacy app control

**Permission Model:**
- User grants explicit permission per API
- No background access without consent
- Clear UI showing what data is accessed

---

### 6. **MCP Tool System (Extensibility)**

**Purpose:** Extendable tool calling for complex tasks

**Existing MCP Servers:**
- `mcp-web-tools` - Web research
- `mcp-file-operations` - File system access
- `mcp-memory-tool` - Memory system integration
- `mcp-todo-tool` - Task management
- `mcp-osint-crawler` - OSINT gathering

**Custom MCP Servers:**
- **macOS Integration MCP** - Reminders, Calendar, Contacts
- **Obsidian MCP** - Access user's knowledge base
- **Safari MCP** - Web research with full context

---

## Privacy Architecture

### Data Flow (Offline Mode)

```
User Input
    ↓
Local MLX Inference (no network)
    ↓
Context Retrieval (local SQLite)
    ↓
Response Generation (local)
    ↓
Display to User
```

### Data Flow (Online Mode - Explicit)

```
User Request: "Research X"
    ↓
User Grants Permission
    ↓
WebKit Fetches Content
    ↓
Extract & Summarize (local)
    ↓
Send Summary to Model (local)
    ↓
Response to User
```

### What NEVER Happens

- ❌ No data sent to external servers without explicit permission
- ❌ No telemetry or analytics
- ❌ No cloud backups of personal data
- ❌ No model training on user data

---

## Technical Stack

### Core Dependencies

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **UI Framework** | SwiftUI | Native macOS interface |
| **ML Framework** | MLX Swift | Apple Silicon inference |
| **Database** | SQLite + FTS5 + sqlite-vec | Memory storage + search |
| **Web Engine** | WebKit (WKWebView) | Web research |
| **Automation** | AppleScript + Scripting Bridge | macOS system control |
| **Tool System** | MCP (Model Context Protocol) | Extensibility |

### Package Dependencies

```swift
// Package.swift
dependencies: [
    // MLX for model inference
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
    
    // WebKit for web research
    // (Built into macOS, no package needed)
    
    // SQLite for memory storage
    .package(url: "https://github.com/stephencorey/SQLite.swift", from: "0.15.0"),
    
    // MCP Swift SDK
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.9.0"),
]
```

---

## Distribution Strategy

### GitHub Repository

**Structure:**
```
SwiftMaestro/
├── Sources/                    # Swift source code
├── Resources/                  # Assets, entitlements
├── scripts/
│   ├── build.sh               # Build script
│   └── package.sh             # DMG creation
├── docs/
│   ├── VISION.md              # This document
│   ├── ARCHITECTURE.md        # Detailed technical docs
│   └── SETUP.md               # User setup guide
└── README.md                   # Quick start
```

### .dmg Installer

**Build Process:**
```bash
# Build release
xcodebuild -scheme SwiftMaestro -configuration Release build

# Create DMG
./scripts/package.sh

# Output: SwiftMaestro-1.0.0.dmg
```

**Installer Features:**
- Drag-to-install interface
- Optional: LaunchAgent for auto-start
- Clear privacy policy
- No hidden components

---

## Development Roadmap

### Phase 1: Core Chat (Week 1-2)
- ✅ Extract ChatView, MessageBubble, ChatViewModel
- ✅ Implement LocalLLMExecutor for oMLX
- ✅ Add SimpleMemoryStore for basic persistence
- **Deliverable:** Working offline chat with Qwen models

### Phase 2: Memory System (Week 3-4)
- Implement SQLite + FTS5 storage
- Add vector search with sqlite-vec
- Integrate OpenViking hierarchy
- **Deliverable:** Full contextual memory with search

### Phase 3: macOS Integration (Week 5-6)
- AppleScript automation layer
- Calendar/Reminders integration
- Contacts access
- **Deliverable:** System control capabilities

### Phase 4: Web Research (Week 7-8)
- WKWebView integration
- Page content extraction
- Screenshot capture for vision
- **Deliverable:** Web research when requested

### Phase 5: MCP Tool System (Week 9-10)
- Custom MCP servers for macOS tools
- Obsidian vault integration
- Task automation workflows
- **Deliverable:** Extensible tool ecosystem

### Phase 6: Polish & Release (Week 11-12)
- UI polish and accessibility
- .dmg packaging
- Documentation
- **Deliverable:** Production-ready release

---

## Obsidian Vault Integration

### Reference Sources Available

**Location:** `~/Obsidian/WDS_Tech_Resources/`

**Key References:**
1. **Core ML** - Apple's ML framework documentation
2. **MLX Swift LM** - LLM/VLM implementation patterns
3. **WebKit JS** - Web browser integration
4. **Create ML** - On-device model training

### Future: Obsidian as Knowledge Base

**Vision:**
- SwiftMaestro can read/write to user's Obsidian vault
- Automatic note creation from conversations
- Link conversations to existing notes
- Search vault for context

**Implementation:**
- MCP server for Obsidian (via file system)
- Markdown parsing and linking
- Tag-based organization

---

## Comparison: App Store vs GitHub

| Aspect | App Store | GitHub + DMG |
|--------|-----------|--------------|
| **Sandbox** | Required | ❌ None |
| **System Access** | Limited | ✅ Full |
| **MLX Integration** | Restricted | ✅ Direct |
| **AppleScript** | Blocked | ✅ Full |
| **Web Research** | Restricted | ✅ Full WKWebView |
| **Distribution** | Apple review | Direct GitHub |
| **Updates** | Store review | Auto-updater |
| **Privacy** | App Tracking Transparency | User-controlled |

**Decision:** GitHub + DMG is the only viable path for this vision.

---

## Success Metrics

### Technical
- ✅ All model inference runs offline
- ✅ Sub-200ms response times for common queries
- ✅ <5GB memory footprint with 122B model loaded
- ✅ Full-text search <100ms for memory recall

### User Experience
- ✅ Natural conversation flow
- ✅ Seamless macOS integration
- ✅ Privacy controls visible and intuitive
- ✅ Zero configuration for offline use

### Adoption
- GitHub stars: 100+ in first month
- Active users: 50+ weekly
- MCP community contributions: 10+ custom tools

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Model too slow** | High | Use 35B for speed, 122B for complex tasks |
| **Memory bloat** | Medium | Implement LRU cache, offload to SSD |
| **Permission complexity** | Medium | Clear UI, granular controls |
| **WebKit security** | High | Sandboxed WebView, no external JS |
| **Model licensing** | Low | Use permissively-licensed Qwen models |

---

## Conclusion

This vision brings together:
1. **Open-source models** (Qwen)
2. **Apple's ML stack** (MLX, Core ML)
3. **macOS ecosystem** (Reminders, Calendar, Contacts, etc.)
4. **Privacy-first design** (offline by default)
5. **Extensible architecture** (MCP tools)

The result is a **true personal AI assistant** that lives on your Mac, learns from you, respects your privacy, and integrates deeply with your workflow — all without depending on cloud services or corporate AI platforms.

**This is Apple Intelligence, built open, owned by the user.**

---

**End of Vision Document**
