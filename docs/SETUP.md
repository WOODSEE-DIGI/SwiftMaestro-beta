# SwiftMaestro Setup Guide

**Version:** 1.0.0  
**Date:** 2026-05-25

---

## Quick Start

### Option 1: Download DMG (Recommended)

1. **Download** the latest `.dmg` from [GitHub Releases](https://github.com/your-org/SwiftMaestro/releases)
2. **Open** the `.dmg` file
3. **Drag** SwiftMaestro.app to your Applications folder
4. **Launch** SwiftMaestro from Applications

### Option 2: Build from Source

```bash
# Clone repository
git clone https://github.com/your-org/SwiftMaestro.git
cd SwiftMaestro

# Install dependencies
brew install xcodegen

# Build
./scripts/build.sh

# Package
./scripts/package.sh

# Output: SwiftMaestro-1.0.0.dmg
```

---

## System Requirements

### Minimum
- **macOS:** 14.0 (Sonoma) or later
- **Processor:** Apple Silicon (M1, M2, M3, or later)
- **Memory:** 16GB RAM (32GB recommended for 122B model)
- **Storage:** 50GB free space (for models)

### Recommended
- **Processor:** M2 Max or M3 Max
- **Memory:** 64GB RAM
- **Storage:** SSD with 100GB+ free

---

## Model Setup

### Available Models

| Model | Size | RAM Required | Use Case |
|-------|------|--------------|----------|
| **Qwen 35B** | 4-bit quantized | ~24GB | Fast, general use |
| **Qwen 122B** | 4-bit quantized | ~60GB | Deep reasoning, complex tasks |

### Model Locations

Models are stored in:
```
~/Ai-models/
├── Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit
└── Qwen3.5-122B-A10B-4bit
```

### Starting oMLX Server

**For Qwen 35B (recommended for daily use):**
```bash
./scripts/start-omlx.sh
```

**For Qwen 122B (complex tasks):**
Edit `scripts/start-omlx.sh`:
```bash
omlx serve "~/Ai-models/Qwen3.5-122B-A10B-4bit" --port 8000
```

### Verify Models Are Loaded

```bash
curl http://localhost:8000/v1/models
```

Expected output:
```json
{
  "object": "list",
  "data": [
    {
      "id": "Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
      "object": "model"
    }
  ]
}
```

---

## Privacy & Permissions

### What SwiftMaestro Does

✅ **Offline by default** - All model inference happens locally  
✅ **No data collection** - No telemetry, no analytics  
✅ **User-controlled online access** - Only when you explicitly ask for research  
✅ **Local memory storage** - All conversations stored on your device  

### Permissions Required

| Permission | Purpose | Optional? |
|------------|---------|-----------|
| **Full Disk Access** | Access files, Obsidian vault | Yes (for file context) |
| **Automation (AppleScript)** | Control Reminders, Calendar, etc. | Yes (for system tasks) |
| **Network Access** | Web research when requested | Yes (can be disabled) |

### Managing Permissions

**macOS System Settings:**
1. Open **System Settings** → **Privacy & Security**
2. **Full Disk Access** → Add SwiftMaestro
3. **Automation** → Toggle desired apps (Reminders, Calendar, etc.)

---

## Features

### Core Features

#### 🧠 **Local AI Chat**
- Conversations with Qwen models entirely offline
- Streaming responses with smooth UI
- Contextual memory across sessions

#### 📁 **File Context**
- Drag and drop files into chat
- Automatic content extraction
- Support for: text, code, PDFs, images

#### 💾 **Persistent Memory**
- Conversations saved locally
- Full-text search across all chats
- Organized by OpenViking hierarchy

### Advanced Features (Coming Soon)

#### 🔍 **Web Research**
- Request research on any topic
- Privacy-focused (DuckDuckGo)
- Extract and summarize content

#### ⚙️ **macOS Integration**
- Create reminders and calendar events
- Access contacts and notes
- Automate system tasks

#### 📓 **Obsidian Integration**
- Read/write to your Obsidian vault
- Link conversations to notes
- Automatic note creation

---

## Configuration

### Model Selection

SwiftMaestro supports multiple models. Configure in `~/.qwen/config.json`:

```json
{
  "defaultModel": "qwen-35b",
  "models": {
    "qwen-35b": {
      "path": "~/Ai-models/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
      "endpoint": "http://localhost:8000"
    },
    "qwen-122b": {
      "path": "~/Ai-models/Qwen3.5-122B-A10B-4bit",
      "endpoint": "http://localhost:8000"
    }
  }
}
```

### Memory Storage

Memory is stored in:
```
~/Library/Application Support/SwiftMaestro/memory/
```

To backup your memory:
```bash
cp -r ~/Library/Application\ Support/SwiftMaestro/memory ~/Backup/qwen-memory
```

---

## Troubleshooting

### oMLX Server Won't Start

**Symptom:** `curl http://localhost:8000/v1/models` returns nothing

**Solution:**
1. Check if oMLX is running: `ps aux | grep omlx`
2. Start with explicit model path:
   ```bash
   omlx serve "~/Ai-models/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit" --port 8000
   ```

### Models Not Loading

**Symptom:** Server starts but no models listed

**Solution:**
1. Verify model directory exists
2. Check model has required files (`config.json`, `model.safetensors`)
3. Ensure sufficient RAM available

### App Crashes on Launch

**Symptom:** SwiftMaestro immediately quits

**Solution:**
1. Check Console.app for crash logs
2. Verify macOS version (14.0+)
3. Rebuild from source if needed

### Slow Response Times

**Symptom:** Model takes >10 seconds per token

**Solution:**
1. Use 35B model for speed
2. Close other memory-intensive apps
3. Check thermal throttling (Macs under load)

---

## Advanced Usage

### Custom MCP Tools

Add custom MCP servers in `~/.qwen/mcp-servers.json`:

```json
{
  "mcp-servers": [
    {
      "name": "custom-tool",
      "command": "/path/to/server",
      "args": ["--flag", "value"]
    }
  ]
}
```

### Obsidian Integration

To enable Obsidian vault access:

1. Add vault path to config:
   ```json
   {
     "obsidianVault": "~/ObsidianVault"
   }
   ```

2. Grant Full Disk Access in System Settings

3. Restart SwiftMaestro

### CLI Usage

SwiftMaestro includes a CLI for automation:

```bash
# Send message to model
swiftmaestro chat "What is machine learning?"

# Research a topic
swiftmaestro research "Latest developments in AI"

# Create reminder
swiftmaestro remind "Buy groceries" tomorrow
```

---

## Updates

### Automatic Updates

SwiftMaestro checks for updates on launch. To disable:

1. Open **SwiftMaestro** → **Settings**
2. Uncheck **Check for updates**

### Manual Update

1. Download latest `.dmg` from GitHub
2. Quit SwiftMaestro
3. Replace app in `/Applications`
4. Launch new version

---

## Support

### Reporting Issues

1. Check [existing issues](https://github.com/your-org/SwiftMaestro/issues)
2. Create new issue with:
   - macOS version
   - SwiftMaestro version
   - Model being used
   - Steps to reproduce

### Community

- **Discussions:** [GitHub Discussions](https://github.com/your-org/SwiftMaestro/discussions)
- **Documentation:** [docs/](docs/)

---

## Uninstall

### Remove Application

```bash
# Move to Trash
rm -rf /Applications/SwiftMaestro.app
```

### Remove Data

```bash
# Memory and configuration
rm -rf ~/Library/Application\ Support/SwiftMaestro

# Logs (if any)
rm -rf ~/Library/Logs/SwiftMaestro
```

---

## License

MIT License - See [LICENSE](LICENSE) for details

---

## Credits

- **Models:** Qwen team (Alibaba Cloud)
- **ML Framework:** MLX (Apple)
- **Server:** oMLX
- **Built with:** Swift, SwiftUI, WebKit

---

**Built with ❤️ for the macOS community**
