import Foundation

// MARK: - ACP agent runner
//
// Implements a minimal Agent Client Protocol (ACP) v1 agent over JSON-RPC 2.0
// on stdin/stdout. This lets Xcode (26.6+) launch SwiftMaestro as a subprocess
// agent and drive it through the standard ACP lifecycle.

@MainActor
final class ACPAgent: @unchecked Sendable {
    private let engine: MLXInferenceEngine
    private let catalog: ModelCatalog
    private let input: FileHandle
    private let output: FileHandle
    private var sessions: [String: ACPChatSession] = [:]
    private var assistantBuffers: [String: String] = [:]
    private var initialized = false

    init(engine: MLXInferenceEngine, catalog: ModelCatalog,
         input: FileHandle = .standardInput,
         output: FileHandle = .standardOutput) {
        self.engine = engine
        self.catalog = catalog
        self.input = input
        self.output = output
    }

    /// Run the ACP loop until stdin closes or an unrecoverable error occurs.
    func run() async {
        // Register native tools so the headless engine can use them.
        await MaestroTools.registerAllMigratedTools()
        // Start any configured MCP servers.
        let mcpService = MCPClientService()
        await mcpService.startEnabledServers()
        engine.mcpService = mcpService

        // Read JSON-RPC lines from stdin synchronously on a background queue and
        // dispatch them to this MainActor-isolated instance.
        let agent = self
        await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                var buffer = Data()
                while !Task.isCancelled {
                    let data = self.input.availableData
                    if data.isEmpty {
                        // EOF or no data yet; sleep briefly and retry.
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                    buffer.append(data)
                    while let line = extractLine(from: &buffer) {
                        await agent.handleLine(line)
                    }
                }
            }.value
        } onCancel: {
            // Nothing to clean up here.
        }
    }

    private func handleLine(_ line: Data) async {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: line) else {
            send(error: JSONRPCError(code: -32700, message: "Parse error", data: nil), id: nil)
            return
        }
        await handleRequest(request)
    }

    private func handleRequest(_ request: JSONRPCRequest) async {
        switch request.method {
        case "initialize":
            handleInitialize(request)
        case "session/new":
            handleSessionNew(request)
        case "session/prompt":
            await handleSessionPrompt(request)
        case "session/cancel":
            // Cancellation is a notification; no response.
            break
        default:
            send(error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)", data: nil), id: request.id)
        }
    }

    private func handleInitialize(_ request: JSONRPCRequest) {
        initialized = true
        let response = ACPInitializeResponse(
            protocolVersion: "2025-03-26",
            agentCapabilities: ACPAgentCapabilities(
                promptCapabilities: ACPPromptCapabilities(image: false, audio: false, embeddedContext: true),
                mcpCapabilities: ACPMcpCapabilities(http: false, sse: false),
                sessionCapabilities: ACPSessionCapabilities(close: true, list: false, delete: false, resume: false)
            ),
            agentInfo: ACPImplementation(name: "SwiftMaestro", version: "1.0")
        )
        send(result: encodeToDictionary(response), id: request.id)
    }

    private func handleSessionNew(_ request: JSONRPCRequest) {
        guard let params = request.params,
              let newRequest = decodeFromDictionary(ACPNewSessionRequest.self, params) else {
            send(error: JSONRPCError(code: -32602, message: "Invalid session/new params", data: nil), id: request.id)
            return
        }
        let sessionId = UUID().uuidString
        let session = ACPChatSession(
            engine: engine,
            catalog: catalog,
            workingDirectory: newRequest.cwd,
            systemPrompt: ACPChatSession.defaultSystemPrompt(workingDirectory: newRequest.cwd)
        )
        sessions[sessionId] = session
        let response = ACPNewSessionResponse(sessionId: sessionId)
        send(result: encodeToDictionary(response), id: request.id)
    }

    private func handleSessionPrompt(_ request: JSONRPCRequest) async {
        guard let params = request.params,
              let promptRequest = decodeFromDictionary(ACPPromptRequest.self, params) else {
            send(error: JSONRPCError(code: -32602, message: "Invalid session/prompt params", data: nil), id: request.id)
            return
        }
        guard let session = sessions[promptRequest.sessionId] else {
            send(error: JSONRPCError(code: -32602, message: "Unknown session", data: nil), id: request.id)
            return
        }

        let userText = promptRequest.prompt.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .resource(let r): return r.text
            case .resourceLink: return nil
            }
        }.joined(separator: "\n")

        // Stream the response as session/update message notifications.
        let agent = self
        let _ = await session.run(prompt: userText) { chunk in
            Task { @MainActor in
                agent.appendAssistantChunk(sessionId: promptRequest.sessionId, chunk: chunk)
            }
        }

        let response = ACPPromptResponse(stopReason: "stop")
        send(result: encodeToDictionary(response), id: request.id)
    }

    private func appendAssistantChunk(sessionId: String, chunk: String) {
        var existing = assistantBuffers[sessionId] ?? ""
        existing.append(chunk)
        assistantBuffers[sessionId] = existing
        let update = ACPSessionUpdateNotification(
            sessionId: sessionId,
            update: .message(ACPMessageUpdate(role: "assistant", content: [.text(existing)]))
        )
        send(notification: "session/update", params: encodeToDictionary(update))
    }

    // MARK: - Output helpers

    private func send(result: [String: ACPJSONValue]?, id: JSONRPCID?) {
        let response = JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
        send(response: response)
    }

    private func send(error: JSONRPCError, id: JSONRPCID?) {
        let response = JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: error)
        send(response: response)
    }

    private func send(notification: String, params: [String: ACPJSONValue]?) {
        let payload: [String: ACPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(notification),
            "params": params.map { .object($0) } ?? .object([:])
        ]
        sendJSON(payload)
    }

    private func send(response: JSONRPCResponse) {
        guard let data = try? JSONEncoder().encode(response),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: any Sendable] else { return }
        let jsonDict = dict.mapValues { ACPJSONValue.from($0) }
        sendJSON(jsonDict)
    }

    private func sendJSON(_ dict: [String: ACPJSONValue]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let line = data + Data([0x0A])
        output.write(line)
    }
}

// MARK: - Helpers

private func extractLine(from buffer: inout Data) -> Data? {
    guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return nil }
    let line = buffer.prefix(newlineIndex)
    let dropCount = newlineIndex + 1
    buffer.removeFirst(dropCount)
    return line
}

private func encodeToDictionary<T: Encodable>(_ value: T) -> [String: ACPJSONValue]? {
    guard let data = try? JSONEncoder().encode(value),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: any Sendable] else {
        return nil
    }
    return dict.mapValues { ACPJSONValue.from($0) }
}

private func decodeFromDictionary<T: Decodable>(_ type: T.Type, _ dict: [String: ACPJSONValue]) -> T? {
    guard let data = try? JSONEncoder().encode(dict) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

private extension ACPJSONValue {
    static func from(_ value: Any) -> ACPJSONValue {
        switch value {
        case is NSNull: return .null
        case let bool as Bool: return .bool(bool)
        case let int as Int: return .int(int)
        case let double as Double: return .double(double)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map { from($0) })
        case let dict as [String: any Sendable]: return .object(dict.mapValues { from($0) })
        default: return .string(String(describing: value))
        }
    }
}
