# Secondary Mac — SwiftMaestro Shared Memory Setup

These instructions make a second Mac (e.g. `secondary-mac`) use the same unified AI context store as the primary Mac (e.g. `primary-mac`). After this, decisions, todos, errors, and session updates written by any agent on either machine will be visible to SwiftMaestro and all other agents.

Replace `primary-mac` and `secondary-mac` with your own machine names.

## What the target looks like

On `primary-mac`, the shared memory lives here:

```
~/Library/Mobile Documents/com~apple~CloudDocs/Documents/SwiftMaestro/memory
```

It is an iCloud Drive folder, so it syncs to any Mac signed in to the same Apple ID. The symlink at `~/.ai-context/memory` points to that iCloud path.

## Step 1 — Make sure iCloud Drive is syncing

On `secondary-mac`:

1. Open **System Settings → Apple ID → iCloud → iCloud Drive**.
2. Ensure **iCloud Drive** is turned on.
3. Wait for the folder `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/SwiftMaestro/memory` to appear.

Quick check:

```bash
ls -la "~/Library/Mobile Documents/com~apple~CloudDocs/Documents/SwiftMaestro"
```

You should see a `memory` folder whose contents match `primary-mac`.

## Step 2 — Create the memory symlink

```bash
mkdir -p ~/.ai-context
ln -sfn "~/Library/Mobile Documents/com~apple~CloudDocs/Documents/SwiftMaestro/memory" ~/.ai-context/memory
ls -la ~/.ai-context/memory
```

Expected output (example):

```
lrwxr-xr-x  1 <user>  <group>  79 Oct  7 19:00 .ai-context/memory -> /Users/<user>/Library/Mobile Documents/com~apple~CloudDocs/Documents/SwiftMaestro/memory
```

## Step 3 — Migrate any legacy `data/global` context

If `secondary-mac` has an old `~/.ai-context/data/global/` folder, run the migration script from the SwiftMaestro repo:

```bash
cd ~/GitHub/FUSV/SwiftMaestro
python3 scripts/migrate-global-context.py
```

This will:

- Back up `~/.ai-context/data/global/` to `~/.ai-context/data/global-backup-<timestamp>/`.
- Convert the old monolithic markdown files into structured entries under `~/.ai-context/memory/knowledge/migrated-global/`.

If `secondary-mac` does not have `~/.ai-context/data/global/`, skip this step.

## Step 4 — Wire `ai-context-bridge` into opencode

`ai-context-bridge` is the MCP server that writes to `~/.ai-context/memory` and reads/writes notes in `~/Documents/SwiftMaestro Notes`. On `primary-mac` the active copy runs from:

```
~/.ai-context/mcp-servers/ai-context-bridge/server.js
```

(The older `~/.ai-context/mcp-server/server.js` path is kept in sync but the active MCP server is in `mcp-servers/ai-context-bridge/`.)

Make sure the same folder exists on `secondary-mac`. If it does not, copy it from `primary-mac`:

```bash
# On secondary-mac, if the active bridge folder does not exist:
mkdir -p ~/.ai-context/mcp-servers/ai-context-bridge
# Then copy server.js, memory-index.js, package.json, and node_modules from primary-mac manually or via AirDrop/SCP.
```

Add the server to opencode's MCP config (`~/.config/opencode/opencode.jsonc`):

```jsonc
{
  "mcpServers": {
    "ai-context-bridge": {
      "command": "node",
      "args": ["$HOME/.ai-context/mcp-servers/ai-context-bridge/server.js"]
    }
  }
}
```

Restart opencode after editing the config.

## Step 5 — Make the opencode agent use the bridge

Add this block to the agent's system prompt or project instructions (`AGENTS.md` in the repo root):

```markdown
## Context rules

- Read the active project's context from `ai-context-bridge` at session start.
- Use `ai-context-bridge_add_decision` for every architectural choice.
- Use `ai-context-bridge_add_todo` for every task you identify.
- Use `ai-context-bridge_report_error` for every failure or unexpected behavior.
- Use `ai-context-bridge_update_session` for every state change.
- Use `~/Documents/SwiftMaestro Notes` as the canonical notes folder. Obsidian is retired.
- Never end a session without saving your work.
```

## Step 6 — Verify the bridge works

In an opencode chat on `secondary-mac`, run:

```text
Add a test decision: project SwiftMaestro, title "Memory sync verified on secondary-mac", decision "Shared memory symlink is in place and ai-context-bridge is writing to iCloud."
```

Then on `primary-mac`, search memory:

```bash
ls ~/.ai-context/memory/knowledge/projects/SwiftMaestro/decisions/ | tail -n 5
```

The new entry should appear within a few seconds after iCloud syncs.

You can also verify notes are written to the new vault:

```bash
ls ~/Documents/SwiftMaestro Notes
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `~/.ai-context/memory` does not exist or is not a symlink | Re-run Step 2. |
| iCloud folder is empty | Wait for sync, or check System Settings → iCloud → iCloud Drive → Options → ensure iCloud Drive is enabled. |
| `ai-context-bridge` tool calls fail | Confirm `~/.ai-context/mcp-servers/ai-context-bridge/server.js` exists and opencode config points to it. |
| New memory entries do not appear on the other Mac | Verify both Macs are signed in to the same Apple ID and iCloud Drive is syncing. |
| `add_decision`/`add_todo` return a write lock error | The active bridge server now writes unique entries per call to avoid locked aggregate `.md` files. If it still fails, kill the running `ai-context-bridge/server.js` node processes and try again. |

## One-time cleanup after migration

After you have confirmed everything works, you can delete the old monolithic files:

```bash
# Only run this after verifying migrated entries are searchable on both machines.
mv ~/.ai-context/data/global ~/.ai-context/data/global-archived-$(date +%Y%m%d)
```

Keep the archive until you are sure nothing important was lost.
