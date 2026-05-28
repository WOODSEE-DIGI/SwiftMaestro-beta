# SwiftMaestro

**Bringing Apple Intelligence to reality on macOS using open-source Qwen models, MLX framework, and native macOS integration — all offline-first with privacy at the core.**

Native macOS chat application for Qwen models, built with SwiftUI and powered by oMLX.

## 🎯 Vision

SwiftMaestro is a **personal AI assistant** that:

✅ **Runs entirely offline** - All model inference happens locally on Apple Silicon  
✅ **Respects your privacy** - No PII leaves your device unless you explicitly ask for research  
✅ **Integrates with macOS** - Reminders, Calendar, Contacts, Notes, and more (coming soon)  
✅ **Learns from you** - Contextual memory across all conversations  
✅ **Open and extensible** - GitHub repo with MCP tool ecosystem  

**This is Apple Intelligence, built open, owned by the user.**

## Quick Start

### 1. Start oMLX Server

```bash
cd "~/GitHub/AI-ML-Agents/SwiftMaestro"
./scripts/start-omlx.sh
```

This starts oMLX with the Qwen 35B model on port 8000.

### 2. Test the Endpoint

```bash
./scripts/test-omlx.sh
```

### 3. Build and Run

```bash
# Generate Xcode project
xcodegen generate

# Open in Xcode
open SwiftMaestro.xcodeproj

# Build and run (Cmd+R)
```

## Models Available

- **Qwen 35B** (`Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit`) - Fast, general use
- **Qwen 122B** (`Qwen3.5-122B-A10B-4bit`) - Deep reasoning, complex tasks

To use the 122B model, modify `scripts/start-omlx.sh`:

```bash
omlx serve "~/Ai-models/Qwen3.5-122B-A10B-4bit" --port 8000
```

## Architecture

### Core Components

| Component | Path | Purpose |
|-----------|------|---------|
| **ChatView** | `Sources/Views/ChatView.swift` | Main chat UI with fixed auto-scroll |
| **MessageBubble** | `Sources/Views/MessageBubble.swift` | Markdown/code block rendering |
| **ChatViewModel** | `Sources/ViewModels/ChatViewModel.swift` | Chat logic (streaming, file attachments) |
| **LocalLLMExecutor** | `Sources/Adapters/LocalLLMExecutor.swift` | HTTP client for oMLX |
| **LocalLLMAgentAdapter** | `Sources/Adapters/LocalLLMAgentAdapter.swift` | Protocol adapter |
| **ProviderFactoryService** | `Sources/Services/ProviderFactoryService.swift` | Factory for adapters |
| **SimpleMemoryStore** | `Sources/Memory/SimpleMemoryStore.swift` | File-based conversation storage |
| **MaestroURI** | `Sources/MaestroURI.swift` | Memory URI scheme |

### Key Features

- ✅ **Fixed auto-scroll** - Debounced to prevent haphazard jumping during streaming
- ✅ **Streamlined ViewModel** - 300 lines (vs 2600 in SwiftMaestro)
- ✅ **Stream relay buffer** - Smooth UI updates with 120ms/72-char flushing
- ✅ **File drop support** - Drag files into chat for context
- ✅ **Markdown rendering** - Code blocks with copy/run buttons
- ✅ **Simple memory** - File-based storage with MaestroURI organization

## Project Structure

```
SwiftMaestro/
├── Sources/
│   ├── App/
│   │   └── SwiftMaestroApp.swift
│   ├── Views/
│   │   ├── ChatView.swift
│   │   ├── MessageBubble.swift
│   │   └── ContentView.swift
│   ├── ViewModels/
│   │   └── ChatViewModel.swift
│   ├── Adapters/
│   │   ├── LocalLLMExecutor.swift
│   │   └── LocalLLMAgentAdapter.swift
│   ├── Services/
│   │   └── ProviderFactoryService.swift
│   ├── Models/
│   │   └── SwiftMaestroModels.swift
│   ├── Memory/
│   │   ├── ConversationStore.swift
│   │   └── SimpleMemoryStore.swift
│   └── MaestroURI.swift
├── scripts/
│   ├── start-omlx.sh
│   └── test-omlx.sh
├── docs/
│   ├── EXTRACTION-SUMMARY.md
│   ├── comparison-plan-35b-vs-122b.md
│   └── architecture-plan.md
└── project.yml
```

## Development Notes

### Fixed Issues from SwiftMaestro

1. **Auto-scroll haphazardness** - Now uses 150ms debounce + pending scroll queue
2. **ViewModel bloat** - Removed Finder tag fast-path, background monitoring (~2300 lines removed)
3. **Executor complexity** - Stripped MCP tool loops, terminal execution (~1800 lines removed)

### Memory System

Current implementation uses simple file-based storage:

```
~/Library/Application Support/SwiftMaestro/memory/
├── memory/
│   └── conversations/
│       └── <agent-id>/
│           └── history.json
├── knowledge/
├── context/
└── skill/
```

Future enhancement could integrate MaestroMemory's SQLite + FTS5 for full-text search.

## Dependencies

- **SwiftUI** - macOS 14.0+
- **oMLX** - Multi-model server (already installed)
- **MLX** - Apple's ML framework (via oMLX)

No additional Swift package dependencies.

## 📦 Distribution: GitHub + .dmg (Not App Store)

**Why not App Store?** The App Store sandbox restrictions prevent:
- Full system integration (Reminders, Calendar, Contacts, etc.)
- Direct MLX model access
- AppleScript automation
- Obsidian vault access

**Solution:** GitHub repo + .dmg installer
- ✅ No sandbox restrictions
- ✅ Full macOS integration
- ✅ User-controlled permissions
- ✅ Easy updates via GitHub Releases

**Privacy:** No telemetry, no analytics, no data collection

## Troubleshooting

### oMLX not starting

Check if models exist:

```bash
ls -la "~/Ai-models/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit/"
```

### No models in endpoint

oMLX needs to be started with a model:

```bash
omlx serve "~/Ai-models/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit" --port 8000
```

### Build errors in Xcode

Regenerate project:

```bash
xcodegen generate --clean
```

## Comparison: 35B Plan vs Actual

| 35B Plan | Actual |
|----------|--------|
| Build HTTP client from scratch (Week 1) | ✅ Reuse SwiftMaestro's LocalLLMExecutor |
| Implement JSON memory store (Week 2) | ✅ Simple file-based store (200 lines) |
| Build chat UI from scratch (Week 1-2) | ✅ Reuse SwiftMaestro's ChatView (fixed bugs) |
| **Total: 3-4 weeks** | **Actual: 1 week to MVP** |

## License

MIT License - See LICENSE file

---

**Built with ❤️ using SwiftMaestro components and oMLX**
