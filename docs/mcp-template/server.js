#!/usr/bin/env node
// Minimal example MCP server for SwiftMaestro.
//
// This is the smallest useful starting point for a new server: three trivial
// tools (echo, get_time, add_numbers) demonstrating the exact schema
// conventions that keep a server working well with SwiftMaestro (see
// ../MCP-SERVERS.md "What makes a server SwiftMaestro-friendly" for why each
// of these matters):
//
//   1. Tool descriptions stay short (~60 chars) — longer ones get truncated
//      by SwiftMaestro anyway, so write the important part first.
//   2. EVERY property in inputSchema has an explicit "type" — never omit it,
//      even for a schema that's conceptually "anything" (use "string" or
//      spell out an object schema; an empty {} gets defaulted but relying on
//      that default is fragile, e.g. breaks Gemma's chat template).
//   3. No "nullable", "default", "examples", "title", or
//      "additionalProperties" in schemas — SwiftMaestro strips these before
//      the model ever sees them, so they're pure wasted effort to write.
//   4. Handle string-typed arguments defensively. Some calling models emit
//      tool calls as XML, so a "boolean"/"integer"/"number" argument can
//      arrive as the STRING "true"/"42" even though your schema declares a
//      real type — SwiftMaestro coerces top-level values back to the
//      declared type before calling you, but a defensive Number(x)/coercion
//      on your end costs nothing and protects against edge cases.
//   5. Always return { content: [...] }, and set isError: true on failure
//      instead of throwing past the handler — SwiftMaestro surfaces
//      isError results to the model as an explicit error, which stops it
//      from fabricating a plausible-looking result to fill the gap.
//
// Run standalone to sanity-check it starts:
//   node server.js
// (it will sit there waiting for stdio input — that's normal; Ctrl-C to quit)
//
// Wire it into SwiftMaestro via Settings → MCP → Add Server:
//   Command:          /opt/homebrew/bin/node   (or `which node`)
//   Script path:       /absolute/path/to/this/server.js
//   Working directory: /absolute/path/to/this/folder
//   (leave Arguments/Env empty, Timeout at its default, then tick Enabled)

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "swiftmaestro-mcp-template", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "echo",
      description: "Echo a string back. Sanity-check that this server is wired up correctly.",
      inputSchema: {
        type: "object",
        required: ["text"],
        properties: {
          text: { type: "string" },
        },
      },
    },
    {
      name: "get_time",
      description: "Return the current server-side date/time as an ISO 8601 string.",
      inputSchema: {
        type: "object",
        properties: {},
      },
    },
    {
      name: "add_numbers",
      description: "Add two numbers together.",
      inputSchema: {
        type: "object",
        required: ["a", "b"],
        properties: {
          a: { type: "number" },
          b: { type: "number" },
        },
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  try {
    switch (name) {
      case "echo": {
        if (typeof args?.text !== "string") {
          return { content: [{ type: "text", text: "Error: 'text' is required" }], isError: true };
        }
        return { content: [{ type: "text", text: args.text }] };
      }

      case "get_time": {
        return { content: [{ type: "text", text: new Date().toISOString() }] };
      }

      case "add_numbers": {
        // Defensive coercion (see file header, point 4): accept a numeric
        // string even though the schema declares "number".
        const a = Number(args?.a);
        const b = Number(args?.b);
        if (Number.isNaN(a) || Number.isNaN(b)) {
          return { content: [{ type: "text", text: "Error: 'a' and 'b' must be numbers" }], isError: true };
        }
        return { content: [{ type: "text", text: String(a + b) }] };
      }

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }
  } catch (err) {
    // Never let an exception escape unhandled — always report it as an
    // explicit tool error so the model can react instead of getting a
    // protocol-level failure with no useful message.
    return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
