# SwiftMaestro MCP server template

A minimal, verified-working example MCP server to start a new one from. Three
trivial tools (`echo`, `get_time`, `add_numbers`) demonstrating the schema
conventions covered in [`../MCP-SERVERS.md`](../MCP-SERVERS.md) — read that
first for *why* each convention matters.

## Try it standalone

```bash
cd docs/mcp-template
npm install
node server.js   # sits waiting for stdio input - Ctrl-C to quit, this is normal
```

To actually exercise it without wiring up SwiftMaestro first, use the
official SDK's client from a second script:

```js
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({ command: process.execPath, args: ["server.js"] });
const client = new Client({ name: "test-client", version: "1.0.0" });
await client.connect(transport);

const { tools } = await client.listTools();
console.log(tools.map(t => t.name));

console.log(await client.callTool({ name: "echo", arguments: { text: "hi" } }));
```

## Wire it into SwiftMaestro

**Settings → MCP → Add Server:**

| Field | Value |
|---|---|
| Server name | `swiftmaestro-mcp-template` (or anything) |
| Command | `/opt/homebrew/bin/node` (run `which node` to confirm your path) |
| Script path | absolute path to this folder's `server.js` |
| Working directory | absolute path to this folder |
| Enabled | ✅ |

Then ask an agent to use the `echo`, `get_time`, or `add_numbers` tool. Check
`~/Library/Application Support/SwiftMaestro/logs/mcp/swiftmaestro-mcp-template.stderr.log`
if it doesn't connect.

## Building your own server from this

1. Copy this folder, rename it, update `package.json`'s `name`.
2. Replace the three example tools in both `ListToolsRequestSchema` (the
   catalog) and `CallToolRequestSchema` (the implementation) with your own.
3. Keep every property's `"type"` explicit, keep descriptions short, and
   always return `{ content: [...] }` with `isError: true` on failure —
   see the comments at the top of `server.js` for the full list of
   conventions and why they matter for SwiftMaestro specifically.
4. Add whatever real dependencies you need to `package.json` — this template
   only depends on the MCP SDK itself.
