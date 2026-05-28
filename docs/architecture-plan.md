# SwiftMaestro Architecture Plan

**Created:** 2026-05-25  
**Status:** Planning phase - awaiting user confirmation on implementation priorities

---

## Project Overview

Build a **native macOS SwiftUI chat application** that serves as a desktop alternative to `chat.qwen.ai`, featuring:
- **MLX-backed Qwen model inference** via oMLX multi-model serving
- **OpenViking-style hierarchical contextual memory** (URI-based organization)
- **Qwen-Agent framework integration** for advanced capabilities (tools, planning, RAG)
- **Model routing**: Automatic selection between 122B (deep reasoning), 35B (fast), VL (vision)

---

## Key Insights from Analysis

### Qwen Agent Framework (`AI-ML-Agents/Qwen-Agent/`)
- Backend for `chat.qwen.ai` web interface
- Provides: tool usage, memory/context management, planning capabilities, code interpreter
- Python-based with pluggable components (LLMs, tools, agents)
- Supports Qwen3.5, Qwen3-Coder, Qwen3-VL families

### oMLX (`AI-ML-Agents/omlx/`)
- **Multi-model serving** with LRU eviction when memory limits exceeded
- **Tiered KV cache**: Hot (RAM) + Cold (SSD) across all loaded models
- **API compatibility**: OpenAI-compatible `/v1/chat/completions` endpoint
- **Model pinning**: Keep frequently-used models always loaded
- **Per-model settings**: Configure sampling, chat templates, TTL per model
- Supports VLMs, embeddings, rerankers on Apple Silicon

### Available Models (`~/Ai-models/lm-studio/mlx-community/`)
- `Qwen3.5-122B-A10B-4bit` — deep reasoning (slow, powerful)
- `Qwen3.5-35B-A3B` — fast general use
- `Qwen3-VL-*` variants — vision processing
- `DeepSeek-R1-*` — mathematical/algo reasoning

---

## Proposed Architecture

```
SwiftMaestro/                          # New native macOS app
├── project.yml                           # Xcode project generator (xcodegen)
├── Sources/
│   ├── App/
│   │   └── SwiftMaestroApp.swift           // Entry point, app lifecycle
│   ├── Views/
│   │   ├── ChatWindow.swift             // Main chat UI (message list + input)
│   │   ├── ModelSelectorView.swift      // Dropdown: fetch from oMLX GET /v1/models
│   │   └── SettingsView.swift           // Configure oMLX server path, memory location
│   └── Services/
│       ├── MLXChatClient.swift          // HTTP client for oMLX OpenAI-compatible API
│       ├── SwiftMaestroBackend.swift       // Python subprocess wrapper for Qwen-Agent framework
│       ├── ModelRouter.swift            // Hybrid routing: auto-select model based on query complexity
│       └── OpenVikingStore.swift        // JSON storage with URI-based paths (~/.qwen/openviking/)
├── Resources/
│   ├── Assets.xcassets/                 // App icon, UI assets
│   ├── SwiftMaestro.entitlements           // App sandbox entitlements
│   └── Info.plist                       // Bundle configuration
```

---

## Component Details

### 1. MLXChatClient (Primary Backend)
- HTTP client connecting to oMLX server at `localhost:8000`
- Uses OpenAI-compatible API for streaming chat responses
- Benefits from oMLX's LRU eviction, tiered KV cache, multi-model concurrency

### 2. SwiftMaestroBackend (Advanced Backend - Optional)
- Python subprocess running full Qwen-Agent framework
- Enables: tool calling, planning, RAG, code interpreter
- Fallback when oMLX unavailable or for advanced features

### 3. ModelRouter (Hybrid Routing Logic)
**Routing Rules:**
| Scenario | Auto-Route Model | Manual Override Option |
|----------|------------------|------------------------|
| Vision task (image attached) | VL 30B | Any model |
| Math/algorithm problem | DeepSeek R1 | Qwen 122B for complex proofs |
| Code generation/refactoring | Qwen 35B | Qwen Coder if available |
| System design/architecture | Qwen 122B | Same |
| Simple questions/tasks | Qwen 35B | Any model |

### 4. OpenViking Memory Store (Simplified)
```
Storage location: ~/.qwen/openviking/
URI-based organization:
- maestro://memory/conversations/session-2026-05-25
- maestro://memory/knowledge/swift/observability  
- maestro://context/session/current
```

---

## Implementation Phases

### Phase 1: Basic Chat Interface with oMLX Client (Week 1)
- [x] Project structure with xcodegen (`project.yml`)
- [ ] Generate Xcode project: `xcodegen generate`
- [ ] Implement `SwiftMaestroApp.swift` entry point
- [ ] Create basic `ChatWindow.swift` UI (message list + input field)
- [ ] Implement `MLXChatClient.swift` HTTP client for oMLX API
- [ ] Add model selector fetching from `GET /v1/models`

**Milestone:** User can select loaded models from oMLX and chat with streaming responses.

### Phase 2: Qwen-Agent Integration & Advanced Features (Week 2)
- [ ] Implement `SwiftMaestroBackend.swift` Python subprocess wrapper
- [ ] Add tool calling support via Qwen-Agent framework
- [ ] Enable planning/RAG capabilities (optional, user-configurable)
- [ ] Hybrid routing logic in `ModelRouter.swift`

**Milestone:** App can use advanced Qwen-Agent features with automatic model selection.

### Phase 3: OpenViking Memory System (Week 3)
- [ ] Implement `OpenVikingStore.swift` JSON storage
- [ ] Add URI parsing and validation (`MaestroURI` struct)
- [ ] Build `MemoryBrowserView.swift` sidebar UI (tree view of URI hierarchy)

**Milestone:** User can browse, search, and organize conversations using OpenViking URIs.

---

## Technical Decisions & Trade-offs

### Decision 1: oMLX HTTP Client vs Qwen-Agent Subprocess
- **Recommendation:** Use oMLX as primary backend (better memory efficiency), Qwen-Agent as optional advanced backend

### Decision 2: OpenViking Memory Depth
- **Recommendation:** Start with simple JSON store, add L0/L1/L2 layers later if needed

### Decision 3: App Sandbox & Model Access
- User grants access to model directory via file picker (security-scoped bookmarks)
- oMLX server manages actual model loading/unloading

---

## Next Steps (Awaiting User Confirmation)

1. **Backend priority:** Start with oMLX HTTP client or Qwen-Agent subprocess?
   - Recommendation: oMLX first for simplicity and memory efficiency

2. **UI aesthetic:** Clone chat.qwen.ai web interface, or distinct native macOS design?
   - Recommendation: Native macOS look with SF Symbols

3. **Memory depth:** Simple JSON store or full OpenViking L0/L1/L2 layers?
   - Recommendation: Start simple, add complexity later if needed

4. **oMLX dependency:** App auto-starts oMLX server, or user manages separately?
   - Recommendation: User-managed with helpful UI hints

---

## Related References

- [oMLX README](~/GitHub/AI-ML-Agents/omlx/README.md) — Multi-model serving, LRU eviction, tiered KV cache
- [Qwen-Agent README](~/GitHub/AI-ML-Agents/Qwen-Agent/README.md) — Tool calling, planning, RAG framework
- [SwiftMaestro v2 Memory Architecture](~/SM-BU/docs/architecture/v2-overview.md) — OpenViking-inspired L0/L1/L2 layers (reference for future enhancement)

---

## Safety Analysis: AI Context Scripts

### Script Review Findings (2026-05-25)

**Safe to run per-chat:**
- `chat-context-warmup.sh` — Read-only operations, graceful failures with `|| true`
- `context-memory-index.py` — Only reads/indexes markdown files, builds SQLite search DB
- `github-repo-sync-categorize.py` — Operates on GitHub repo structure only

**⚠️ Do NOT run per-chat (bootstrap-only):**
- `bootstrap-warp-parity.sh` — Modifies `~/.ssh/config`, creates git hooks, runs MCP sync. Running repeatedly could break SSH connections and block legitimate git pushes.
- `sync-mcp.sh` — Regenerates `~/.warp/.mcp.json`, clones git repos on each run. Causes unnecessary disk/network I/O per chat.

**Isolated operations:**
- `network-remap-daily.py` — Runs network scans, SSH to router, writes output only to `~/.ai-context/data/network-remap/`. Safe but heavy (use when needed, not per-chat).

### Recommended Configuration for Qwen Code

Add mode flag to warmup script:
```bash
CHAT_WARMUP_MODE="${CHAT_WARMUP_MODE:-normal}"  # normal | minimal | bootstrap-only

if [ "${CHAT_WARMUP_MODE}" = "minimal" ]; then
    MAX_LINES=50
    TAIL_LINES=20
fi
```

**Usage in Qwen Code:**
```bash
CHAT_WARMUP_MODE=minimal ~/Library/Mobile\ Documents/com~apple~CloudDocs/.ai-context/scripts/chat-context-warmup.sh
```

This ensures lightweight file reading per-chat while bootstrap scripts (`bootstrap-warp-parity.sh`, `sync-mcp.sh`) run once at system startup or manually.

**Conclusion:** The warmup script is safe for Qwen Code as long as bootstrap scripts are excluded from per-chat execution.
