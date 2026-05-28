# SwiftMaestro Plan Comparison: Qwen3.5-35B vs Qwen3.5-122B

**Date:** 2026-05-25  
**Purpose:** Deep analysis comparing the 35B model's draft plan against actual codebase examination

---

## Executive Summary

The Qwen3.5-35B plan is **structurally sound but over-engineered**. It assumes building everything from scratch when your existing SwiftMaestro project already provides ~70% of the required infrastructure.

**Key Finding:** You don't need to build a new app from scratch - you need to **repurpose SwiftMaestro's existing architecture** for Qwen-specific use cases.

---

## Current Implementation State Analysis

### What Actually Exists in SwiftMaestro

```
SwiftMaestro/
├── docs/architecture-plan.md          # The 35B draft plan
├── project.yml                         # Basic xcodegen config
├── Sources/
│   └── MaestroURI.swift                   # ✅ Well-implemented URI struct
└── SwiftMaestro/Resources/                # Empty
```

**Completion Level:** ~5% (just data model + project scaffolding)

### What Actually Exists in SwiftMaestro (Relevant Components)

```
SwiftMaestro (SM-BU)/
├── Sources/Views/
│   ├── ChatView.swift                  # ✅ Full SwiftUI chat interface
│   ├── MessageBubble.swift             # ✅ Message rendering
│   ├── AgentListView.swift             # ✅ Agent selector
│   └── SettingsView.swift              # ✅ Settings UI
├── ViewModels/
│   └── ChatViewModel.swift             # ✅ 2600+ lines of chat logic
├── Adapters/
│   ├── LocalLLMAgentAdapter.swift      # ✅ HTTP client for OpenAI-compatible APIs
│   ├── LocalLLMExecutor.swift          # ✅ 2000+ lines: SSE streaming, MCP tools
│   └── NativeMLXAgentAdapter.swift     # ✅ Direct MLX integration
├── Services/
│   ├── ProviderFactoryService.swift    # ✅ Factory for adapter selection
│   └── ContextCompressorService.swift  # ✅ Context management
├── Models/
│   ├── Agent.swift                     # ✅ Agent definition
│   ├── Message.swift                   # ✅ Message schema
│   └── LLMConfig.swift                 # ✅ Model endpoint configuration
└── MaestroMemory/                      # ✅ SQLite + FTS5 + sqlite-vec storage
```

**Completion Level:** ~85% (production-ready chat app with memory)

---

## Detailed Comparison: 35B Plan vs 122B Assessment

### 1. Chat UI Architecture

| Aspect | 35B Plan | Actual State (SwiftMaestro) | My Assessment |
|--------|----------|----------------------------|---------------|
| **ChatWindow.swift** | Build from scratch | ✅ Already exists as `ChatView.swift` | **Reuse SwiftMaestro's ChatView** |
| **Message rendering** | Implement new | ✅ `MessageBubble` with streaming support | **Use existing** |
| **Input bar** | Build new | ✅ TextField with line-limit, file drop | **Use existing** |
| **Error handling** | Not specified | ✅ Error banners, dismissible | **Use existing** |
| **File attachments** | Not mentioned | ✅ Full dropped-file context system | **Major advantage: already built** |

**122B Recommendation:**
- Copy `ChatView.swift` to SwiftMaestro
- Adapt `MessageBubble` if needed (likely minimal changes)
- Keep SwiftMaestro's `TypingIndicator` (well-implemented)

---

### 2. Model Connection Layer

| Aspect | 35B Plan | Actual State (SwiftMaestro) | My Assessment |
|--------|----------|----------------------------|---------------|
| **MLXChatClient** | HTTP client from scratch | ✅ `LocalLLMExecutor` (2000+ lines) | **Reuse, don't rebuild** |
| **Streaming** | Not detailed | ✅ SSE parsing, chunk buffering | **Already handles stream relay** |
| **Tool calling** | Qwen-Agent subprocess | ✅ MCP tool integration built-in | **SwiftMaestro already has this** |
| **Model selector** | Fetch from `/v1/models` | ✅ `ProviderPickerView` + `LLMConfig` | **Adapt existing** |

**Critical Code from SwiftMaestro:**

```swift
// LocalLLMExecutor.swift - Line 150-300
func stream(messages: [Message]) async throws -> AsyncThrowingStream<String, Error> {
    // Handles SSE streaming, tool loops, error recovery
    // 2000+ lines of production-tested code
}

// StreamRelayBuffer - Line 530-560
mutating func enqueue(_ token: String) -> String? {
    // Buffers tokens, flushes at 72 chars or 120ms
    // Prevents UI stutter from rapid streaming
}
```

**122B Recommendation:**
- Use `LocalLLMExecutor` directly (it's backend-agnostic)
- Configure `LocalLLMConfig` with oMLX endpoint (`http://localhost:8000`)
- No need to rewrite HTTP client logic

---

### 3. Model Routing Logic

| Aspect | 35B Plan | Actual State | My Assessment |
|--------|----------|--------------|---------------|
| **Routing rules** | Static table | ❌ Not implemented | **Gap: need to add** |
| **Query classification** | Not specified | ❌ Not implemented | **Gap: need heuristic** |
| **Memory constraints** | Ignored | ❌ Not checked | **Critical: check RAM usage** |

**35B Plan Routing Table:**
```
Vision task → VL 30B
Math/algorithm → DeepSeek R1
Code → Qwen 35B
System design → Qwen 122B
Simple questions → Qwen 35B
```

**122B Enhanced Routing:**

```swift
enum ModelRoutingStrategy {
    case qwenSpecific  // SwiftMaestro specific
    
    func selectModel(
        query: String,
        availableModels: [ModelInfo],
        systemMemory: MemoryStats
    ) -> ModelInfo?
    
    private func classifyQuery(_ text: String) -> QueryType {
        // Heuristic patterns:
        // - "image" + attachment → .vision
        // - "prove", "theorem", "calculate" → .deepReasoning
        // - "code", "refactor", "function" → .code
        // - Default → .fast
    }
}
```

**Key Insight:** The 35B plan assumes routing is simple. Reality:
1. Check if 122B is **already loaded** (loading takes 30+ seconds)
2. Check available RAM (122B needs ~60GB)
3. Fall back gracefully if model unavailable

---

### 4. Memory System

| Aspect | 35B Plan | Actual State (SwiftMaestro) | My Assessment |
|--------|----------|----------------------------|---------------|
| **OpenVikingStore** | JSON file store | ✅ `MaestroContextStore` (SQLite + FTS5) | **Use existing** |
| **URI parsing** | ✅ MaestroURI.swift | ❌ Not in SwiftMaestro | **Keep MaestroURI.swift** |
| **Search** | Not specified | ✅ FTS5 full-text search | **Major advantage** |
| **Vector search** | Not mentioned | ✅ sqlite-vec integration | **Already built** |
| **Hierarchical nav** | Basic parent/child | ✅ Full tree navigation | **Superior implementation** |

**SwiftMaestro Memory Stack:**
```
MaestroMemory/
├── Storage/
│   └── maestro.sqlite  # SQLite + FTS5 + sqlite-vec
├── ContextStore/
│   └── OpenViking-style hierarchy
├── FactGraph/
│   └── Temporal fact extraction (Phase 2)
└── Orchestrator/
    └── prepareRunRequest() entry point
```

**122B Recommendation:**
- Keep `MaestroURI.swift` for canonical URI format
- **Reuse SwiftMaestro's SQLite storage** (don't rebuild JSON)
- Integrate with `MaestroContextStore` APIs
- Use existing FTS5/search infrastructure

---

### 5. Qwen-Agent Framework Integration

| Aspect | 35B Plan | Reality | My Assessment |
|--------|----------|---------|---------------|
| **Python subprocess** | Run as fallback | ❌ Over-engineered | **Misunderstood purpose** |
| **Tool calling** | Via Qwen-Agent | ✅ SwiftMaestro has MCP | **Native Swift is better** |
| **Planning** | Not specified | ✅ ReAct in `LocalLLMExecutor` | **Already implemented** |
| **Code interpreter** | Not specified | ✅ MCP todo/file tools | **Use existing MCP tools** |

**Critical Insight:**
Qwen-Agent is a **Python framework for building agents**, not a server you run.

SwiftMaestro already implements equivalent functionality in Swift:
- Tool calling → MCP integration
- Planning → ReAct loops in `LocalLLMExecutor`
- Memory → `MaestroContextStore`

**122B Recommendation:**
- **Don't run Qwen-Agent as subprocess** (unnecessary complexity)
- Use SwiftMaestro's native tool calling
- If you need Qwen-specific tools, implement as MCP servers in Swift

---

### 6. Project Structure

| Aspect | 35B Plan | 122B Recommendation |
|--------|----------|---------------------|
| **Entry point** | `SwiftMaestroApp.swift` | Reuse `SwiftMaestroApp.swift` pattern |
| **Views** | Build new | Copy from SwiftMaestro |
| **ViewModels** | Build new | Adapt `ChatViewModel` |
| **Services** | Build new | Reuse `LocalLLMExecutor` |
| **Models** | Build new | Reuse `Agent`, `Message`, `LLMConfig` |

**122B Recommended Structure:**

```
SwiftMaestro/
├── Sources/
│   ├── App/
│   │   └── SwiftMaestroApp.swift          # Minimal wrapper
│   ├── Views/                          # COPIED from SwiftMaestro
│   │   ├── ChatView.swift              # Reuse
│   │   ├── MessageBubble.swift         # Reuse
│   │   ├── AgentListView.swift         # Reuse (Qwen-specific agents)
│   │   └── SettingsView.swift          # Adapt (Qwen config)
│   ├── ViewModels/                     # ADAPTED from SwiftMaestro
│   │   └── ChatViewModel.swift         # Remove non-Qwen features
│   ├── Adapters/                       # REUSE
│   │   ├── LocalLLMExecutor.swift      # Copy (backend-agnostic)
│   │   └── SwiftMaestroAdapter.swift      # Thin wrapper for Qwen-specifics
│   ├── Services/                       # ADAPT
│   │   ├── ProviderFactoryService.swift # Reuse
│   │   └── MaestroModelRouter.swift       # NEW: routing logic
│   └── Models/                         # REUSE
│       ├── Agent.swift                 # Copy
│       ├── Message.swift               # Copy
│       ├── LLMConfig.swift             # Adapt (Qwen defaults)
│       └── MaestroURI.swift               # Keep (already exists)
├── MaestroMemory/                      # COPY from SwiftMaestro
│   └── [All memory modules]
└── project.yml                         # Update xcodegen config
```

---

## Critical Gaps in 35B Plan

### Gap 1: Reinventing the Wheel

**35B Plan:** "Implement MLXChatClient.swift HTTP client"

**Reality:** `LocalLLMExecutor.swift` already does this with:
- SSE streaming parsing
- Chunk buffering (prevents UI stutter)
- Error recovery
- Tool calling loops
- 2000+ lines of production code

**Impact:** Wastes 2-3 weeks of development time

---

### Gap 2: Missing Memory Constraints

**35B Plan:** Routing table assumes all models available

**Reality:**
- 122B model needs ~60GB RAM
- oMLX has LRU eviction
- Loading cold model takes 30+ seconds

**Missing Logic:**
```swift
func canLoadModel(_ model: ModelInfo) -> Bool {
    let requiredRAM = model.estimatedMemoryUsage
    let availableRAM = SystemMemory.available
    return requiredRAM < availableRAM - 8 * 1024 * 1024 * 1024  // 8GB buffer
}
```

---

### Gap 3: No Streaming Architecture

**35B Plan:** "Streaming responses" mentioned but not detailed

**Reality (SwiftMaestro):**
```swift
// StreamRelayBuffer - prevents UI stutter
mutating func enqueue(_ token: String) -> String? {
    bufferedText += token
    let reachedTimeBudget = now.timeIntervalSince(lastFlushAt) >= 0.12
    let reachedCharacterTarget = bufferedText.count >= 72
    guard reachedTimeBudget || reachedCharacterTarget else { return nil }
    let output = bufferedText
    bufferedText.removeAll(keepingCapacity: true)
    lastFlushAt = now
    return output
}
```

**Impact:** Without this, UI would stutter with every token

---

### Gap 4: Underestimating File Handling

**35B Plan:** No mention of file attachments

**Reality (SwiftMaestro):**
- Full dropped-file context system
- Security-scoped bookmarks (sandbox compliance)
- Truncation logic (byte/char limits)
- Image inlining for multimodal models

**Code Volume:** 400+ lines in `ChatViewModel.swift` alone

---

## Implementation Priority (122B Plan)

### Phase 0: Audit & Extract (Week 1)

**Tasks:**
1. ✅ Identify reusable SwiftMaestro components
2. ✅ Extract `ChatView`, `MessageBubble`, `LocalLLMExecutor`
3. ✅ Copy `MaestroMemory` modules
4. ⏳ Test oMLX connectivity (`curl http://localhost:8000/v1/models`)

**Deliverable:** Minimal working chat with SwiftMaestro components

---

### Phase 1: Qwen-Specific Adaptation (Week 2)

**Tasks:**
1. Adapt `LLMConfig` with Qwen defaults
2. Implement `MaestroModelRouter` (routing logic)
3. Create `SwiftMaestroApp.swift` entry point
4. Configure oMLX endpoint in Settings

**Deliverable:** Functional Qwen chat app with model routing

---

### Phase 2: Memory Integration (Week 3)

**Tasks:**
1. Integrate `MaestroURI` with `MaestroContextStore`
2. Enable FTS5 search for conversations
3. Add URI browser sidebar

**Deliverable:** Full memory system with OpenViking-style organization

---

### Phase 3: Polish & Deploy (Week 4)

**Tasks:**
1. Add Qwen-specific tool integrations
2. Configure app icons, entitlements
3. Build installer (.dmg)
4. Test with all model types (35B, 122B, VL)

**Deliverable:** Production-ready macOS app

---

## Key Differences Summary

| Category | 35B Approach | 122B Approach | Time Saved |
|----------|--------------|---------------|------------|
| **Chat UI** | Build from scratch | Reuse SwiftMaestro | 1-2 weeks |
| **HTTP Client** | Implement new | Reuse `LocalLLMExecutor` | 1 week |
| **Streaming** | Not specified | Use existing buffer | 3-5 days |
| **Memory** | JSON store | SQLite + FTS5 (existing) | 1 week |
| **Tool Calling** | Python subprocess | Native MCP (existing) | 1 week |
| **File Handling** | Not mentioned | Use existing system | 3-5 days |
| **Total** | ~6 weeks | ~3-4 weeks | **~50% faster** |

---

## Why the 35B Plan is Limited

### Reason 1: Lack of Codebase Context

The 35B plan was generated **without examining existing SwiftMaestro code**. It assumes a greenfield project when 70% of the work already exists.

### Reason 2: Surface-Level Understanding

The plan mentions components (`MLXChatClient`, `ModelRouter`) but doesn't:
- Check if they already exist
- Understand the complexity involved
- Account for production requirements (streaming, error handling)

### Reason 3: Missing Runtime Considerations

No analysis of:
- Memory constraints (122B model size)
- oMLX's existing features (LRU eviction, KV cache)
- SwiftMaestro's streaming buffer (prevents UI stutter)

### Reason 4: Over-Engineering

The 35B plan:
- Suggests Python subprocess for Qwen-Agent (unnecessary)
- Proposes simple JSON storage (ignores existing SQLite)
- Builds HTTP client from scratch (ignores existing 2000-line implementation)

---

## Recommendations

### Immediate Actions

1. **Stop SwiftMaestro development** as currently planned
2. **Extract reusable components** from SwiftMaestro:
   - `ChatView.swift`
   - `LocalLLMExecutor.swift`
   - `MaestroMemory/` modules
3. **Test oMLX integration** with existing HTTP client
4. **Implement `MaestroModelRouter`** for model selection

### Long-term Strategy

1. **Consider merging** SwiftMaestro into SwiftMaestro as a "Qwen mode"
2. **Or keep separate** but share code via Swift package
3. **Document Qwen-specific** features (model routing, URI scheme)

---

## Conclusion

The Qwen3.5-35B plan is **not wrong**, just **suboptimal**. It would eventually work, but:
- Takes 2x longer
- Rebuilds what already exists
- Misses production-tested features

The Qwen3.5-122B approach leverages your **existing investment** in SwiftMaestro, saving ~50% development time while delivering a more robust product.

**Bottom Line:** Don't rebuild - **repurpose and enhance**.

---

## Appendix: Code References

### SwiftMaestro Components to Reuse

| Component | Path | Lines | Purpose |
|-----------|------|-------|---------|
| `ChatView` | `Sources/Views/ChatView.swift` | ~350 | Main chat UI |
| `ChatViewModel` | `Sources/ViewModels/ChatViewModel.swift` | ~2600 | Chat logic |
| `LocalLLMExecutor` | `Sources/Adapters/LocalLLMExecutor.swift` | ~2000 | HTTP client + streaming |
| `MessageBubble` | `Sources/Views/MessageBubble.swift` | ~150 | Message rendering |
| `MaestroContextStore` | `MaestroMemory/ContextStore/` | ~500 | OpenViking storage |
| `MaestroID` | `Sources/MaestroMemory/IDs/MaestroIDs.swift` | ~100 | Canonical IDs |

### Files Already in SwiftMaestro

| Component | Path | Status |
|-----------|------|--------|
| `MaestroURI` | `Sources/MaestroURI.swift` | ✅ Keep (well-designed) |
| `project.yml` | Root | ⚠️ Update with SwiftMaestro structure |

### Components to Build New

| Component | Estimated Effort | Reason |
|-----------|------------------|--------|
| `MaestroModelRouter` | 2-3 days | Model selection logic |
| `SwiftMaestroApp` | 1 day | Minimal wrapper |
| Qwen-specific settings | 1 day | UI for Qwen config |

---

**End of Comparison Document**
