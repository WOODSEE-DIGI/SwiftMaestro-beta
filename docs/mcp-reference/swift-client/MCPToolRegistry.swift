import Foundation
import Combine

/// Dynamically discovers and registers MCP tools
/// Handles tool lifecycle and provides type-safe execution
class MCPToolRegistry: ObservableObject {
    
    // MARK: - Singleton
    static let shared = MCPToolRegistry()
    
    // MARK: - Published Properties
    @Published private(set) var registeredTools: [MCPTool] = []
    @Published private(set) var toolExecutionHistory: [ToolExecutionRecord] = []
    
    // MARK: - Private Properties
    private var toolHandlers: [String: ToolHandler] = [:]
    private let queue = DispatchQueue(label: "com.swiftmaestro.toolregistry", qos: .userInitiated)
    
    // MARK: - Public Methods
    
    /// Register a tool from MCP server
    func register(tool: MCPTool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if tool already exists
            if let existingIndex = self.registeredTools.firstIndex(where: { $0.id == tool.id }) {
                // Update existing tool
                self.registeredTools[existingIndex] = tool
            } else {
                // Add new tool
                self.registeredTools.append(tool)
            }
            
            // Set up handler for this tool
            self.setupToolHandler(tool: tool)
        }
    }
    
    /// Register multiple tools at once
    func register(tools: [MCPTool]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            for tool in tools {
                self.register(tool: tool)
            }
        }
    }
    
    /// Unregister a tool
    func unregister(toolId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            registeredTools.removeAll { $0.id == toolId }
            toolHandlers.removeValue(forKey: toolId)
        }
    }
    
    /// Check if a tool is registered
    func isRegistered(toolId: String) -> Bool {
        registeredTools.contains { $0.id == toolId }
    }
    
    /// Get tool by ID
    func getTool(toolId: String) -> MCPTool? {
        registeredTools.first { $0.id == toolId }
    }
    
    /// Get all tools from a specific server
    func getTools(from serverId: String) -> [MCPTool] {
        registeredTools.filter { $0.serverId == serverId }
    }
    
    /// Execute a registered tool with type-safe arguments
    func execute<T>(
        toolId: String,
        arguments: T,
        encoder: JSONEncoder = JSONEncoder()
    ) async throws -> MCPToolResult where T: Encodable {
        
        guard let handler = toolHandlers[toolId] else {
            throw MCPToolRegistryError.handlerNotFound(toolId)
        }
        
        // Encode arguments to JSON
        let jsonData = try encoder.encode(arguments)
        
        // Convert to [String: Any]
        guard let argsDict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MCPToolRegistryError.invalidArguments
        }
        
        // Execute through MCP client manager
        do {
            let result = try await MCPClientManager.shared.executeTool(
                name: handler.toolName,
                arguments: argsDict
            )
            
            // Record execution
            recordExecution(toolId: toolId, success: true)
            
            return result
        } catch {
            recordExecution(toolId: toolId, success: false, error: error)
            throw error
        }
    }
    
    /// Execute tool with raw arguments
    func executeRaw(toolId: String, arguments: [String: Any]) async throws -> MCPToolResult {
        guard let handler = toolHandlers[toolId] else {
            throw MCPToolRegistryError.handlerNotFound(toolId)
        }
        
        do {
            let result = try await MCPClientManager.shared.executeTool(
                name: handler.toolName,
                arguments: arguments
            )
            
            recordExecution(toolId: toolId, success: true)
            
            return result
        } catch {
            recordExecution(toolId: toolId, success: false, error: error)
            throw error
        }
    }
    
    /// Get tool schema for UI generation
    func getToolSchema(toolId: String) -> ToolSchema? {
        guard let tool = registeredTools.first(where: { $0.id == toolId }) else {
            return nil
        }
        
        return ToolSchema(
            id: tool.id,
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema
        )
    }
    
    /// Clear all tools
    func clearAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.registeredTools = []
            self.toolHandlers = [:]
        }
    }
    
    // MARK: - Private Methods
    
    private func setupToolHandler(tool: MCPTool) {
        let handler = ToolHandler(
            toolId: tool.id,
            toolName: tool.name,
            serverId: tool.serverId
        )
        
        toolHandlers[tool.id] = handler
    }
    
    private func recordExecution(toolId: String, success: Bool, error: Error? = nil) {
        let record = ToolExecutionRecord(
            toolId: toolId,
            timestamp: Date(),
            success: success,
            error: error?.localizedDescription
        )
        
        toolExecutionHistory.insert(record, at: 0)
        
        // Keep last 100 records
        if toolExecutionHistory.count > 100 {
            toolExecutionHistory = Array(toolExecutionHistory.prefix(100))
        }
    }
}

// MARK: - Supporting Types

struct ToolHandler {
    let toolId: String
    let toolName: String
    let serverId: String
}

struct ToolSchema {
    let id: String
    let name: String
    let description: String
    let inputSchema: [String: Any]
    
    var requiredParameters: [String] {
        if let required = inputSchema["required"] as? [String] {
            return required
        }
        return []
    }
    
    var parameterTypes: [String: String] {
        guard let properties = inputSchema["properties"] as? [String: Any] else {
            return [:]
        }
        
        var types: [String: String] = [:]
        for (key, value) in properties {
            if let prop = value as? [String: Any], let type = prop["type"] as? String {
                types[key] = type
            }
        }
        
        return types
    }
}

struct ToolExecutionRecord {
    let toolId: String
    let timestamp: Date
    let success: Bool
    let error: String?
}

enum MCPToolRegistryError: Error, LocalizedError {
    case handlerNotFound(String)
    case invalidArguments
    case toolNotRegistered(String)
    
    var errorDescription: String? {
        switch self {
        case .handlerNotFound(let toolId):
            return "No handler registered for tool: \(toolId)"
        case .invalidArguments:
            return "Invalid tool arguments format"
        case .toolNotRegistered(let toolId):
            return "Tool not registered: \(toolId)"
        }
    }
}
FILEEOF ; echo "__SWIFTMAESTRO_CWD__=$(pwd)"