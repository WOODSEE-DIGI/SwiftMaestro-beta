//
//  MCPSession.swift
//  SwiftMaestro
//
//  Real MCP session implementation with stdio transport
//

import Foundation
import Combine
import os.log

/// MCP Session state
enum MCPSessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// MCP protocol version
enum MCPProtocolVersion: String {
    case latest = "2024-11-05"
}

/// MCP Session - Manages connection to MCP server
class MCPSession: ObservableObject {
    static let shared = MCPSession()
    
    @Published private(set) var state: MCPSessionState = .disconnected
    @Published private(set) var serverInfo: ServerInfo?
    @Published private(set) var capabilities: ServerCapabilities?
    
    private let logger = Logger(subsystem: "com.swiftmaestro.mcp", category: "MCPSession")
    private var transport: StdioTransport?
    private var requestID: Int64 = 0
    private var pendingRequests: [Int64: (Result<MCPResponse, Error>) -> Void] = [:]
    private var responseHandlers: [String: (JSONValue) -> Void] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.swiftmaestro.mcp.session", qos: .userInitiated)
    private let responseQueue = DispatchQueue(label: "com.swiftmaestro.mcp.responses", qos: .userInitiated)
    
    private init() {}
    
    /// Connect to MCP server
    func connect(serverConfig: ServerConfig) async throws {
        guard state != .connected else {
            logger.info("Already connected to MCP server")
            return
        }
        
        state = .connecting
        
        do {
            transport = StdioTransport(config: serverConfig)
            
            // Set up response handling
            transport?.onResponse = { [weak self] response in
                self?.handleResponse(response)
            }
            
            transport?.onNotification = { [weak self] notification in
                self?.handleNotification(notification)
            }
            
            transport?.onError = { [weak self] error in
                self?.handleError(error)
            }
            
            // Start transport
            try await transport?.start()
            
            // Initialize session
            try await initialize()
            
            state = .connected
            logger.info("Connected to MCP server: \(serverConfig.name)")
            
        } catch {
            state = .error(error.localizedDescription)
            logger.error("Failed to connect to MCP server: \(error)")
            throw error
        }
    }
    
    /// Disconnect from MCP server
    func disconnect() {
        transport?.stop()
        transport = nil
        state = .disconnected
        serverInfo = nil
        capabilities = nil
        logger.info("Disconnected from MCP server")
    }
    
    /// Initialize MCP session
    private func initialize() async throws {
        let request = JSONRPCRequest(
            id: nextRequestID(),
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPProtocolVersion.latest.rawValue),
                "capabilities": .object([
                    "roots": .object(["listChanged": .bool(true)])
                ]),
                "clientInfo": .object([
                    "name": .string("SwiftMaestro"),
                    "version": .string("1.0.0")
                ])
            ])
        )
        
        let response = try await sendRequest(request)
        
        switch response {
        case .success(let result):
            guard case .object(let obj) = result else {
                throw MCPError.invalidResponse("Invalid initialize response")
            }
            
            // Extract server info
            if let serverInfoObj = obj["serverInfo"]?.object {
                serverInfo = ServerInfo(
                    name: serverInfoObj["name"]?.string ?? "Unknown",
                    version: serverInfoObj["version"]?.string ?? "0.0.0"
                )
            }
            
            // Extract capabilities
            if let capsObj = obj["capabilities"]?.object {
                capabilities = parseCapabilities(capsObj)
            }
            
        case .error(let error):
            throw MCPError.initializeFailed(error.message)
        }
    }
    
    /// List available tools from server
    func listTools() async throws -> [Tool] {
        guard state == .connected else {
            throw MCPError.notConnected
        }
        
        let request = JSONRPCRequest(
            id: nextRequestID(),
            method: "tools/list",
            params: .null
        )
        
        let response = try await sendRequest(request)
        
        switch response {
        case .success(let result):
            guard case .array(let toolsArray) = result else {
                throw MCPError.invalidResponse("Invalid tools/list response")
            }
            
            var tools: [Tool] = []
            for toolJSON in toolsArray {
                if case .object(let obj) = toolJSON {
                    if let tool = parseTool(obj) {
                        tools.append(tool)
                    }
                }
            }
            
            return tools
            
        case .error(let error):
            throw MCPError.toolListFailed(error.message)
        }
    }
    
    /// Call a tool by name
    func callTool(name: String, arguments: [String: AnyCodable] = [:]) async throws -> ToolResult {
        guard state == .connected else {
            throw MCPError.notConnected
        }
        
        var params: [String: JSONValue] = ["name": .string(name)]
        
        if !arguments.isEmpty {
            let argsJSON = arguments.mapValues { value in
                convertToJSONValue(value)
            }
            params["arguments"] = .object(argsJSON)
        }
        
        let request = JSONRPCRequest(
            id: nextRequestID(),
            method: "tools/call",
            params: .object(params)
        )
        
        let response = try await sendRequest(request)
        
        switch response {
        case .success(let result):
            return parseToolResult(result)
            
        case .error(let error):
            throw MCPError.toolCallFailed(error.message)
        }
    }
    
    /// Send JSON-RPC request and wait for response
    private func sendRequest(_ request: JSONRPCRequest) async throws -> JSONValue {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: MCPError.sessionDestroyed)
                    return
                }
                
                let requestID = request.id
                self.pendingRequests[requestID] = { result in
                    self.responseQueue.async {
                        self.pendingRequests.removeValue(forKey: requestID)
                        
                        switch result {
                        case .success(let value):
                            continuation.resume(returning: value)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
                
                // Send request
                do {
                    try self.transport?.send(request)
                } catch {
                    self.pendingRequests.removeValue(forKey: requestID)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Handle incoming JSON-RPC response
    private func handleResponse(_ response: JSONRPCResponse) {
        responseQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let handler = self.pendingRequests[response.id] {
                handler(.success(response.result))
            }
        }
    }
    
    /// Handle incoming notification
    private func handleNotification(_ notification: JSONRPCNotification) {
        logger.debug("Received notification: \(notification.method)")
        
        // Handle specific notifications
        if notification.method == "notifications/tools/list_changed" {
            logger.info("Tool list changed - refreshing registry")
        }
    }
    
    /// Handle transport errors
    private func handleError(_ error: Error) {
        logger.error("Transport error: \(error)")
        
        if state == .connected {
            state = .disconnected
        }
    }
    
    /// Parse tool from JSON
    private func parseTool(_ json: JSONValue.Object) -> Tool? {
        guard let name = json["name"]?.string,
              let description = json["description"]?.string else {
            return nil
        }
        
        let inputSchema = parseSchema(json["inputSchema"])
        
        return Tool(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
    }
    
    /// Parse tool schema
    private func parseSchema(_ json: JSONValue?) -> ToolSchema {
        guard case .object(let obj) = json else {
            return ToolSchema(type: "object", properties: [:], required: [])
        }
        
        let type = obj["type"]?.string ?? "object"
        
        var properties: [String: ToolProperty] = [:]
        if let props = obj["properties"]?.object {
            for (key, value) in props {
                if case .object(let propObj) = value {
                    properties[key] = parseProperty(propObj)
                }
            }
        }
        
        var required: [String] = []
        if let req = obj["required"]?.array {
            required = req.compactMap { $0.string }
        }
        
        return ToolSchema(type: type, properties: properties, required: required)
    }
    
    /// Parse property from JSON
    private func parseProperty(_ json: JSONValue.Object) -> ToolProperty {
        let type = json["type"]?.string ?? "string"
        let description = json["description"]?.string ?? ""
        
        return ToolProperty(type: type, description: description)
    }
    
    /// Parse tool result from JSON
    private func parseToolResult(_ json: JSONValue) -> ToolResult {
        var content: [ToolContent] = []
        var isError = false
        
        if case .object(let obj) = json {
            isError = obj["isError"]?.bool ?? false
            
            if let contentArray = obj["content"]?.array {
                for item in contentArray {
                    if let toolContent = parseToolContent(item) {
                        content.append(toolContent)
                    }
                }
            }
        }
        
        return ToolResult(content: content, isError: isError)
    }
    
    /// Parse tool content item
    private func parseToolContent(_ json: JSONValue) -> ToolContent? {
        guard case .object(let obj) = json else { return nil }
        
        guard let type = obj["type"]?.string else { return nil }
        
        switch type {
        case "text":
            let text = obj["text"]?.string ?? ""
            return .text(text)
            
        case "image":
            guard let data = obj["data"]?.string,
                  let mimeType = obj["mimeType"]?.string else {
                return nil
            }
            return .image(data: data, mimeType: mimeType)
            
        case "resource":
            guard let resource = obj["resource"]?.object else {
                return nil
            }
            let uri = resource["uri"]?.string ?? ""
            let text = resource["text"]?.string
            let mimeType = resource["mimeType"]?.string
            
            return .resource(uri: uri, text: text, mimeType: mimeType)
            
        default:
            return nil
        }
    }
    
    /// Parse server capabilities
    private func parseCapabilities(_ json: JSONValue.Object) -> ServerCapabilities {
        var tools = false
        var resources = false
        var prompts = false
        
        if let toolsCaps = json["tools"]?.object {
            tools = toolsCaps["listChanged"]?.bool ?? false
        }
        
        if let resourcesCaps = json["resources"]?.object {
            resources = resourcesCaps["subscribe"]?.bool ?? false
        }
        
        if let promptsCaps = json["prompts"]?.object {
            prompts = promptsCaps["listChanged"]?.bool ?? false
        }
        
        return ServerCapabilities(tools: tools, resources: resources, prompts: prompts)
    }
    
    /// Convert AnyCodable to JSONValue
    private func convertToJSONValue(_ value: AnyCodable) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .number(n)
        case .string(let s):
            return .string(s)
        case .array(let arr):
            return .array(arr.map { convertToJSONValue($0) })
        case .object(let obj):
            let jsonObj: [String: JSONValue] = obj.mapValues { convertToJSONValue($0) }
            return .object(jsonObj)
        }
    }
    
    /// Generate next request ID
    private func nextRequestID() -> Int64 {
        requestID += 1
        return requestID
    }
}

// MARK: - Supporting Types

/// Server configuration
struct ServerConfig: Codable {
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]?
}

/// Server information
struct ServerInfo {
    let name: String
    let version: String
}

/// Server capabilities
struct ServerCapabilities {
    let tools: Bool
    let resources: Bool
    let prompts: Bool
}

/// Tool definition
struct Tool {
    let name: String
    let description: String
    let inputSchema: ToolSchema
}

/// Tool schema
struct ToolSchema {
    let type: String
    let properties: [String: ToolProperty]
    let required: [String]
}

/// Tool property
struct ToolProperty {
    let type: String
    let description: String
}

/// Tool result
struct ToolResult {
    let content: [ToolContent]
    let isError: Bool
}

/// Tool content
enum ToolContent {
    case text(String)
    case image(data: String, mimeType: String)
    case resource(uri: String, text: String?, mimeType: String?)
}

/// MCP errors
enum MCPError: LocalizedError {
    case notConnected
    case sessionDestroyed
    case invalidResponse(String)
    case initializeFailed(String)
    case toolListFailed(String)
    case toolCallFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to MCP server"
        case .sessionDestroyed:
            return "Session has been destroyed"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .initializeFailed(let msg):
            return "Initialize failed: \(msg)"
        case .toolListFailed(let msg):
            return "Failed to list tools: \(msg)"
        case .toolCallFailed(let msg):
            return "Failed to call tool: \(msg)"
        }
    }
}
FILEEOF ; echo "__SWIFTMAESTRO_CWD__=$(pwd)"