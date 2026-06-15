import Foundation
import MCP
import MLXLMCommon

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

// MARK: - MCP tool source
//
// Client-side MCP integration: SwiftMaestro spawns the user-enabled MCP servers
// (from the MCP settings tab) as subprocesses, speaks JSON-RPC over stdio via the
// official Swift MCP SDK, discovers their tools, and bridges them into the SAME
// agentic loop used by native tools (see MLXInferenceEngine + MaestroTools).
//
// Permissioning is the user's MCP `enabled` flags — not agent-imposed gating.
// This is the deliberate VISION: full tool access, controlled by the user.

/// One live connection to a spawned MCP server.
private final class MCPConnection {
    let serverName: String
    let process: Process
    /// Retained so the underlying pipe file descriptors stay open for the
    /// connection's lifetime (FileHandle closes its fd on dealloc).
    let stdinPipe: Pipe
    let stdoutPipe: Pipe
    let client: Client
    var tools: [MCP.Tool]

    init(
        serverName: String,
        process: Process,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        client: Client,
        tools: [MCP.Tool]
    ) {
        self.serverName = serverName
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.client = client
        self.tools = tools
    }
}

/// Manages MCP client connections and exposes discovered tools to the agent.
actor MCPClientService {

    private var connections: [MCPConnection] = []
    /// Maps a discovered tool name -> the connection that owns it.
    private var routing: [String: MCPConnection] = [:]
    private var started = false

    // MARK: - Lifecycle

    /// Spawn and connect every enabled MCP server that has a script path.
    /// Idempotent: a second call is a no-op once started.
    func startEnabledServers() async {
        guard !started else { return }
        started = true

        let entries = await MainActor.run { SwiftMaestroSettingsStore.loadMCPServers() }
        for entry in entries where entry.enabled && !entry.scriptPath.isEmpty {
            do {
                try await connect(to: entry)
            } catch {
                NSLog("[MCP] Failed to connect to \(entry.name): \(error.localizedDescription)")
            }
        }
    }

    private func connect(to entry: MCPServerEntry) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: entry.command)
        // Prefer the explicit arg vector (supports subcommands like `cli.js mcp`);
        // fall back to the single scriptPath for simple single-script servers.
        if let args = entry.args, !args.isEmpty {
            process.arguments = args
        } else {
            process.arguments = [entry.scriptPath]
        }
        process.environment = mergedEnvironment(entry.env)
        if !entry.workingDir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: entry.workingDir)
        } else {
            process.currentDirectoryURL = URL(fileURLWithPath: entry.scriptPath)
                .deletingLastPathComponent()
        }

        let stdinPipe = Pipe()   // SwiftMaestro -> server stdin
        let stdoutPipe = Pipe()  // server stdout -> SwiftMaestro
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr is left inherited so server logs surface in the console.

        try process.run()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: "SwiftMaestro", version: "1.0.0")

        // Bound handshake + discovery so a misbehaving server can't hang startup.
        let timeout = max(entry.timeout, 4)
        let tools = try await withTimeout(seconds: timeout) {
            try await client.connect(transport: transport)
            let (tools, _) = try await client.listTools()
            return tools
        }

        let connection = MCPConnection(
            serverName: entry.name,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            client: client,
            tools: tools
        )
        connections.append(connection)
        for tool in tools {
            routing[tool.name] = connection
        }
        NSLog("[MCP] Connected to \(entry.name): \(tools.count) tool(s) — \(tools.map { $0.name }.joined(separator: ", "))")
    }

    /// Terminate all spawned servers.
    func shutdown() {
        for connection in connections {
            connection.process.terminate()
        }
        connections.removeAll()
        routing.removeAll()
        started = false
    }

    // MARK: - Tool surface (for the agentic loop)

    /// Which agent surface is asking for MCP tools. Exposure is configured
    /// per server in MCP settings (`advertise` / `advertiseToSubAgents`).
    enum ToolAudience: Sendable {
        case interactive   // Navigator + project-agent chats
        case delegate      // delegated sub-agent runs (ask_project_agent/s)
    }

    /// MCP tool schemas in mlx `ToolSpec` (OpenAI function) format, filtered by
    /// the per-server exposure settings for the given audience. Exposure is read
    /// live so settings changes apply from the next message without reconnecting.
    func currentSchemas(audience: ToolAudience = .interactive) -> [ToolSpec] {
        let entries = SwiftMaestroSettingsStore.loadMCPServers()
        let exposure = Dictionary(
            entries.map { entry in
                (entry.name,
                 audience == .interactive
                     ? entry.advertisesToAgents
                     : entry.advertisesToDelegates)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return routing.values.uniqued()
            .filter { exposure[$0.serverName] ?? true }
            .flatMap { connection in
                connection.tools.map { Self.toolSpec(for: $0) }
            }
    }

    /// Whether an MCP server owns the named tool.
    func handles(_ name: String) -> Bool {
        routing[name] != nil
    }

    /// Execute an MCP tool call and return a string result to feed back to the model.
    func execute(_ call: ToolCall) async -> String {
        let name = call.function.name
        guard let connection = routing[name] else {
            return #"{"error": "unknown MCP tool: \#(name)"}"#
        }
        do {
            let schema = connection.tools.first { $0.name == name }?.inputSchema
            let arguments = try Self.convertArguments(call.function.arguments, schema: schema)
            NSLog("[MCP] -> \(connection.serverName)/\(name) args=\(arguments ?? [:])")
            let (content, isError) = try await connection.client.callTool(
                name: name, arguments: arguments
            )
            let text = Self.stringify(content)
            NSLog("[MCP] <- \(name) isError=\(isError ?? false) result=\(text.prefix(300))")
            if isError == true {
                return #"{"error": \#(Self.jsonEncoded(text))}"#
            }
            // Be explicit about a successful-but-empty result so the model does
            // not fabricate a plausible-looking output to fill the gap.
            return text.isEmpty
                ? #"{"status": "ok", "output": ""}"#
                : text
        } catch {
            NSLog("[MCP] !! \(name) failed: \(error.localizedDescription)")
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    // MARK: - Conversions

    /// Build an mlx `ToolSpec` from an MCP tool definition. The spec is SLIMMED:
    /// descriptions truncated and schema noise dropped. With many MCP servers
    /// connected, the full tool surface dominates the prompt (85 tools ≈ 11k
    /// tokens here), and on hybrid-cache models (non-trimmable KV — e.g. Qwen
    /// 3.6) every fresh conversation pays that as a full prefill.
    private static func toolSpec(for tool: MCP.Tool) -> ToolSpec {
        let parameters = slim(sendable(from: tool.inputSchema))
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": truncate(tool.description ?? "", limit: 200),
                "parameters": parameters,
            ] as [String: any Sendable],
        ]
    }

    /// Trim a tool/parameter description to its leading sentence(s) within `limit`.
    private static func truncate(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = String(trimmed.prefix(limit))
        if let cut = head.range(of: ". ", options: .backwards),
           head.distance(from: head.startIndex, to: cut.upperBound) > limit / 2 {
            return String(head[..<cut.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return head + "…"
    }

    /// Schema keys that cost prompt tokens without improving tool-call accuracy.
    private static let droppedSchemaKeys: Set<String> = [
        "examples", "title", "$schema", "additionalProperties", "default",
    ]

    /// Recursively slim a JSON schema: truncate nested descriptions, drop noise
    /// keys. Structure (type/properties/required/enum/items) is preserved.
    private static func slim(_ value: any Sendable) -> any Sendable {
        if let dict = value as? [String: any Sendable] {
            var out: [String: any Sendable] = [:]
            for (key, v) in dict {
                if droppedSchemaKeys.contains(key) { continue }
                if key == "description", let s = v as? String {
                    out[key] = truncate(s, limit: 120)
                } else {
                    out[key] = slim(v)
                }
            }
            return out as [String: any Sendable]
        }
        if let arr = value as? [any Sendable] {
            return arr.map { slim($0) } as [any Sendable]
        }
        return value
    }

    /// Recursively convert an MCP `Value` (JSON) into native Sendable Swift values
    /// suitable for the chat-template serializer.
    private static func sendable(from value: MCP.Value) -> any Sendable {
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .string(let s):
            return s
        case .data(_, let data):
            return data.base64EncodedString()
        case .array(let arr):
            return arr.map { sendable(from: $0) } as [any Sendable]
        case .object(let obj):
            return obj.mapValues { sendable(from: $0) } as [String: any Sendable]
        }
    }

    /// Convert mlx tool-call arguments (`[String: JSONValue]`) into MCP
    /// `[String: Value]`, coercing stringly-typed values to the tool schema's
    /// declared types. Qwen-family models emit tool calls as XML, so non-string
    /// parameters arrive as STRINGS (e.g. formats="[\"markdown\"]",
    /// onlyMainContent="true"). Native tools tolerate that via lenient decoders,
    /// but MCP servers with strict validation (e.g. Firecrawl's zod schemas)
    /// reject it with -32602 errors.
    private static func convertArguments(
        _ args: [String: JSONValue], schema: MCP.Value? = nil
    ) throws -> [String: MCP.Value]? {
        guard !args.isEmpty else { return nil }
        let data = try JSONEncoder().encode(args)
        var obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let schema,
           let schemaObj = sendable(from: schema) as? [String: Any],
           let properties = schemaObj["properties"] as? [String: Any] {
            obj = coerce(obj, properties: properties)
        }
        let coerced = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode([String: MCP.Value].self, from: coerced)
    }

    /// Coerce top-level string values to the JSON types the schema declares.
    /// JSON-parsing a stringified array/object brings its nested types along.
    /// Values already matching their declared type are left untouched.
    private static func coerce(
        _ args: [String: Any], properties: [String: Any]
    ) -> [String: Any] {
        var out = args
        for (key, value) in args {
            guard let spec = properties[key] as? [String: Any],
                  let expected = spec["type"] as? String,
                  let s = value as? String
            else { continue }
            switch expected {
            case "array", "object":
                if let d = s.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(
                       with: d, options: [.fragmentsAllowed]) {
                    if expected == "array", parsed is [Any] { out[key] = parsed }
                    if expected == "object", parsed is [String: Any] { out[key] = parsed }
                }
            case "boolean":
                switch s.lowercased() {
                case "true", "1", "yes": out[key] = true
                case "false", "0", "no": out[key] = false
                default: break
                }
            case "integer":
                if let i = Int(s) { out[key] = i }
            case "number":
                if let i = Int(s) { out[key] = i }
                else if let d = Double(s) { out[key] = d }
            default:
                break
            }
        }
        return out
    }

    /// Flatten MCP tool result content into a single string for the model.
    private static func stringify(_ content: [MCP.Tool.Content]) -> String {
        var parts: [String] = []
        for item in content {
            switch item {
            case .text(let text, _, _):
                parts.append(text)
            case .image(_, let mimeType, _, _):
                parts.append("[image: \(mimeType)]")
            case .audio(_, let mimeType, _, _):
                parts.append("[audio: \(mimeType)]")
            case .resource(let resource, _, _):
                parts.append("[resource: \(resource.uri)]")
            case .resourceLink(let uri, _, _, _, _, _):
                parts.append("[resource: \(uri)]")
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func jsonEncoded(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let encoded = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return encoded
    }

    // MARK: - Environment

    /// Merge the process environment with the entry's `env` string and ensure a
    /// sane PATH/HOME (GUI apps inherit a minimal environment).
    private func mergedEnvironment(_ envString: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths

        // Parse "KEY=VALUE" pairs separated by newlines or semicolons. (Commas
        // are NOT separators: values themselves can contain commas, e.g. an
        // XCODEBUILDMCP_ENABLED_WORKFLOWS list.)
        let separators = CharacterSet(charactersIn: "\n;")
        for pair in envString.components(separatedBy: separators) {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            if !key.isEmpty { env[key] = value }
        }
        return env
    }
}

// MARK: - Helpers

private extension Sequence where Element == MCPConnection {
    /// De-duplicate connections (routing map may reference the same connection
    /// from many tool names).
    func uniqued() -> [MCPConnection] {
        var seen = Set<ObjectIdentifier>()
        var result: [MCPConnection] = []
        for item in self where seen.insert(ObjectIdentifier(item)).inserted {
            result.append(item)
        }
        return result
    }
}

/// Run an async operation with a timeout (seconds). Throws `MCPTimeoutError` on expiry.
private func withTimeout<T: Sendable>(
    seconds: Int,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            throw MCPTimeoutError()
        }
        guard let result = try await group.next() else { throw MCPTimeoutError() }
        group.cancelAll()
        return result
    }
}

struct MCPTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "MCP server timed out" }
}
