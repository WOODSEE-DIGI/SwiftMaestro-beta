# MCP Servers in SwiftMaestro

SwiftMaestro can talk to any [Model Context Protocol](https://modelcontextprotocol.io)
server: spawn it as a subprocess, discover its tools over stdio JSON-RPC, and
bridge those tools into the **same agentic loop** native tools use — an agent
doesn't know or care whether a tool call it makes is native Swift code or an
MCP server three processes away.

This doc covers how the integration actually works today, how to add a
server, and what makes a server work *well* with SwiftMaestro. For a minimal,
runnable example server to start from, see [`docs/mcp-template/`](mcp-template/).

## How it works

- Implementation: `Sources/Engine/MCPClientService.swift`, an `actor` built on
  the official [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk)
  (`mcp-swift-sdk` in `project.yml`).
- On launch, SwiftMaestro spawns every **enabled** server you've configured in
  **Settings → MCP** as a `Process`, connects over stdio, and calls `listTools`
  to discover what it offers.
- Discovered tools are converted into the same OpenAI-style function schema
  (`ToolSpec`) native tools use, and merged into the agent's tool menu —
  `MaestroTools.execute(...)` and `MCPClientService.execute(...)` are just two
  routing destinations for the exact same `ToolCall` type.
- Server `stderr` is redirected to a per-server log file (not the app's own
  console), so a chatty server doesn't drown out anything else:
  `~/Library/Application Support/SwiftMaestro/logs/mcp/<server-name>.stderr.log`

There is no external JSON config file to point SwiftMaestro at — each server
is one entry in **Settings → MCP**, persisted locally via `UserDefaults`.

## Adding a server (Settings → MCP)

Click **Add Server**, then fill in:

| Field | Meaning |
|---|---|
| Server name | Just a label — used in logs and the per-server audience toggles below. |
| Command | Absolute path to the interpreter/binary, e.g. `/opt/homebrew/bin/node`, `/usr/bin/python3`, or a compiled binary's own path. |
| Script path | Path to the server's entry script/binary. Used verbatim as the sole argument to `Command` **unless** Arguments (below) is non-empty. |
| Arguments | One per line. Overrides Script path entirely when set — needed for servers invoked with a subcommand or multiple args, e.g. `cli.js`, `mcp` (two lines) for a server whose CLI is `node cli.js mcp`. |
| Env | `KEY=VALUE` pairs separated by newlines or semicolons (not commas — values can contain commas). Merged on top of the app's own environment; `PATH` gets `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` appended since GUI apps inherit a minimal `PATH`. |
| Working directory | Optional. Defaults to the script path's parent directory. |
| Timeout | Seconds allowed for the initial connect + `listTools` handshake (minimum enforced: 4s). A hung/misbehaving server can't block app startup past this. |
| Enabled | Servers are only spawned if enabled. |

Two more toggles per server control **prompt size**, not connectivity — an
unchecked server stays connected either way, its tools are just left out of
that audience's prompt (applies from the next message, no reconnect needed):

- **Chat agents** — advertise this server's tools to interactive Navigator/
  project-agent chats.
- **Delegated sub-agents** — advertise to `ask_project_agent`/`ask_project_agents`
  runs. Sub-agents usually only need a narrow tool set; leave this off for
  servers a delegated agent won't use.

## What makes a server SwiftMaestro-friendly

Tool schemas cost prompt tokens on *every single turn* — with many servers
connected this adds up fast, and on hybrid-KV-cache models (non-trimmable
cache) every fresh conversation re-prefills the whole thing. SwiftMaestro
aggressively slims what it sends to the model, which means a few things are
worth knowing when building or choosing a server:

- **Keep tool descriptions short.** Anything past ~60 characters gets
  truncated (at a sentence boundary where possible). Parameter descriptions
  get truncated at ~30 characters, or dropped for `string`/`integer`/
  `boolean`/`number` params — the parameter *name* is expected to carry the
  meaning.
- **Give every property an explicit `"type"`.** A schema like
  `{"body": {}}` (no type) gets defaulted to `"string"` — but don't rely on
  that; declare it. This specifically matters for Gemma-family models whose
  Jinja chat template does `value['type'] | upper` and breaks on a missing key.
- **Don't rely on `nullable`, `default`, `examples`, `title`, or
  `additionalProperties`** in your schema — these are all stripped before the
  schema reaches the model. Nullability is inferred from `required` instead.
- **Arguments arrive coerced, not always as their declared JSON type.**
  Qwen-family models (and others using XML-style tool calls) emit every
  argument as a *string* — `"true"`, `"[\"markdown\"]"`, `"42"`. SwiftMaestro
  coerces top-level string values back to your schema's declared
  `array`/`object`/`boolean`/`integer`/`number` type before calling your
  server, but if your server does its own extra-strict validation (e.g. a
  Zod schema demanding a real `boolean`, not `"true"`), test with an
  XML-tool-call model to confirm the coercion covers your case.
- **Return plain, useful text.** `content` blocks come back as `text`/
  `image`/`audio`/`resource`/`resourceLink`; text blocks are joined with
  newlines and fed to the model as-is. An error result (`isError: true`)
  is wrapped as `{"error": "..."}` — the model is told explicitly rather than
  left to guess from a confusing success-shaped payload.
- **A successful-but-empty result is reported as empty**, not silently
  dropped — this stops models from fabricating a plausible-looking result
  to fill the gap.

## Troubleshooting

- **Server won't connect / times out**: check its stderr log at
  `~/Library/Application Support/SwiftMaestro/logs/mcp/<name>.stderr.log`,
  and confirm `Command`/`Script path`/`Working directory` are all *absolute*
  paths — GUI apps don't get a shell's `$PATH` or `~` expansion.
  Bump `Timeout` if the server is just slow to start (e.g. spinning up a
  Python virtualenv on first launch).
- **Tool calls fail with a schema/validation error** but work fine from
  another MCP client: almost always the string-coercion case above — the
  calling model emitted a stringified argument your server rejects outright
  instead of accepting or coercing itself.
- **Prompt feels bloated** with many servers connected: turn off
  **Chat agents** and/or **Delegated sub-agents** advertising per-server for
  ones a given agent doesn't actually need, rather than disabling the whole
  server.
