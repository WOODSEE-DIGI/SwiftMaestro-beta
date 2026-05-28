# SwiftMaestro MCP Servers - Local Setup

## Overview
All MCP servers have been localized to this directory for consistent operation and version control.

## Directory Structure
```
~/SM-BU-publish/
├── mcp-local/                    # All MCP server files (localized)
│   ├── ai-context-bridge/
│   ├── crawlkit-mcp/
│   ├── firecrawl-mcp/
│   ├── playwright-mcp/
│   ├── swift-terminals/
│   ├── webclaw-mcp/
│   ├── read-website-fast/
│   ├── whatsapp-mcp/
│   ├── xcodebuildmcp/
│   ├── swiftmaestro-mcp/
│   └── sm-bu/
├── mcp-servers-manifest.json     # Server manifest configuration
├── swiftmaestro-mcp-config.json  # SwiftMaestro MCP config
├── setup-mcp-servers.sh          # Setup script
└── README-MCP-SERVERS.md         # This file
```

## Files Created
1. **mcp-servers-manifest.json** - Complete manifest of all MCP servers and their sources
2. **swiftmaestro-mcp-config.json** - SwiftMaestro configuration pointing to local servers
3. **setup-mcp-servers.sh** - Script to copy all servers to local directory
4. **README-MCP-SERVERS.md** - This documentation

## Setup Instructions

### Step 1: Run the setup script
```bash
cd ~/SM-BU-publish
./setup-mcp-servers.sh
```

### Step 2: Configure SwiftMaestro
Point SwiftMaestro to use `~/SM-BU-publish/swiftmaestro-mcp-config.json`

### Step 3: Verify Node.js
```bash
node --version
```

## Server List (11 Total)
| Server | Type | Status |
|--------|------|--------|
| ai-context-bridge | Node.js | Ready |
| crawlkit-mcp | Node.js | Ready |
| firecrawl-mcp | Node.js | Ready |
| playwright-mcp | Node.js | Ready |
| swift-terminals | Node.js | Ready |
| webclaw-mcp | Node.js | Ready |
| read-website-fast | Node.js | Ready |
| whatsapp-mcp | Node.js | Ready |
| xcodebuildmcp | Node.js | Ready |
| swiftmaestro-mcp | Swift Binary | Ready |
| sm-bu | Node.js | Ready |

## Working Directory
All operations should use: `~/SM-BU-publish`

## Next Steps
1. Run `./setup-mcp-servers.sh` to copy all servers
2. Verify all servers in `mcp-local/` directory
3. Configure SwiftMaestro to use local config file
4. Test each MCP server individually
