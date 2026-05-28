import Foundation
import Combine

/// Manages MCP client sessions with automatic reconnection
/// This is a standalone service - can be used independently from chat flow
class MCPClientManager: ObservableObject {
    
    // MARK: - Singleton
    static let shared = MCPClientManager()
    
    // MARK: - Published Properties
    @Published private(set) var connectionStatus: MCPConnectionStatus = .disconnected
    @Published private(set) var connectedServers: [String] = []
    @Published private(set) var availableTools: [MCPTool] = []
    
    // MARK: - Private Properties
    private var sessions: [String: MCPSession] = [:]
    private var reconnectTimers: [String: Timer] = [:]
    private let reconnectInterval: TimeInterval = 30
    private let queue = DispatchQueue(label: "com.swiftmaestro.mcp", qos: .userInitiated)
    
    // MARK: - Initialization
    private init() {
        // Auto-connect to configured servers on launch
        setupDefaultServers()
    }
    
    // MARK: - Public Methods
    
    /// Connect to an MCP server
    func connect(serverId: String, config: MCPConfig) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.setupSession(serverId: serverId, config: config)
        }
    }
    
    /// Disconnect from a specific server
    func disconnect(serverId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.cleanupSession(serverId: serverId)
        }
    }
    
    /// Disconnect all servers
    func disconnectAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let serverIds = Array(self.sessions.keys)
            for id in serverIds {
                self.cleanupSession(serverId: id)
            }
        }
    }
    
    /// List all available tools from connected servers
    func refreshTools() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            var allTools: [MCPTool] = []
            
            for (serverId, session) in self.sessions where session.isConnected {
                do {
                    let tools = try await session.listTools()
                    allTools.append(contentsOf: tools)
                } catch {
                    print("[MCPClientManager] Failed to list tools from \(serverId): \(error)")
                }
            }
            
            DispatchQueue.main.async {
                self.availableTools = allTools
            }
        }
    }
    
    /// Execute a tool with automatic reconnection on failure
    func executeTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        // Find which server has this tool
        guard let serverId = findServerForTool(name: name) else {
            throw MCPError.toolNotFound(name)
        }
        
        guard let session = sessions[serverId] else {
            throw MCPError.sessionNotConnected(serverId)
        }
        
        // Try execution with auto-reconnect
        do {
            return try await session.callTool(name: name, arguments: arguments)
        } catch {
            // Attempt to reconnect and retry
            if shouldReconnect(error: error) {
                try await reconnect(serverId: serverId)
                return try await session.callTool(name: name, arguments: arguments)
            }
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDefaultServers() {
        // Default configuration for local MCP servers
        let defaultConfigs: [MCPConfig] = [
            MCPConfig(
                id: "filesystem",
                name: "File System",
                transport: .stdio,
                command: "/usr/local/bin/mcp-filesystem-server",
                args: ["--allowed-paths", "~/SM-BU-publish"]
            ),
            MCPConfig(
                id: "terminal",
                name: "Terminal",
                transport: .stdio,
                command: "/usr/local/bin/mcp-terminal-server",
                args: []
            )
        ]
        
        for config in defaultConfigs {
            connect(serverId: config.id, config: config)
        }
    }
    
    private func setupSession(serverId: String, config: MCPConfig) {
        let session = MCPSession(config: config)
        
        session.connectionStatePublisher.sink { [weak self] state in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.handleConnectionStateChange(serverId: serverId, state: state)
            }
        }
        .store(in: &session.cancelBag)
        
        sessions[serverId] = session
        
        // Start session
        Task {
            do {
                try await session.connect()
            } catch {
                print("[MCPClientManager] Failed to connect to \(serverId): \(error)")
                scheduleReconnect(serverId: serverId)
            }
        }
    }
    
    private func cleanupSession(serverId: String) {
        // Cancel reconnect timer
        reconnectTimers[serverId]?.invalidate()
        reconnectTimers.removeValue(forKey: serverId)
        
        // Disconnect session
        sessions[serverId]?.disconnect()
        sessions.removeValue(forKey: serverId)
        
        // Update connected servers list
        connectedServers = Array(sessions.keys.filter { sessions[$0]?.isConnected ?? false })
        
        // Refresh tools
        refreshTools()
    }
    
    private func handleConnectionStateChange(serverId: String, state: MCPSessionState) {
        switch state {
        case .connected:
            connectedServers.append(serverId)
            connectedServers = Array(Set(connectedServers)) // Deduplicate
            
            if connectionStatus == .disconnected {
                connectionStatus = .connected
            }
            
            refreshTools()
            
        case .disconnected:
            connectedServers.removeAll { $0 == serverId }
            
            if connectedServers.isEmpty {
                connectionStatus = .disconnected
            } else {
                connectionStatus = .connected
            }
            
            scheduleReconnect(serverId: serverId)
            
        case .connecting:
            if connectionStatus == .disconnected {
                connectionStatus = .connecting
            }
            
        case .error:
            scheduleReconnect(serverId: serverId)
        }
    }
    
    private func scheduleReconnect(serverId: String) {
        // Cancel existing timer
        reconnectTimers[serverId]?.invalidate()
        
        // Schedule new reconnect attempt
        let timer = Timer.scheduledTimer(
            withTimeInterval: reconnectInterval,
            repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            
            if let config = self.getSessionConfig(serverId: serverId) {
                self.connect(serverId: serverId, config: config)
            }
        }
        
        reconnectTimers[serverId] = timer
    }
    
    private func reconnect(serverId: String) async throws {
        guard let config = getSessionConfig(serverId: serverId) else {
            throw MCPError.configurationNotFound(serverId)
        }
        
        try await reconnect(session: sessions[serverId], config: config)
    }
    
    private func reconnect(session: MCPSession?, config: MCPConfig) async throws {
        guard let session = session else {
            throw MCPError.sessionNotConnected(config.id)
        }
        
        // Disconnect old session
        session.disconnect()
        
        // Wait for cleanup
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Reconnect
        try await session.connect()
    }
    
    private func findServerForTool(name: String) -> String? {
        for (serverId, session) in sessions where session.isConnected {
            if session.hasTool(name: name) {
                return serverId
            }
        }
        return nil
    }
    
    private func getSessionConfig(serverId: String) -> MCPConfig? {
        // In production, this would fetch from persistent config
        return nil
    }
    
    private func shouldReconnect(error: Error) -> Bool {
        // Determine if error warrants reconnection
        let reconnectErrors: [String] = [
            "connection closed",
            "session expired",
            "timeout",
            "connection reset"
        ]
        
        let errorDescription = error.localizedDescription.lowercased()
        return reconnectErrors.contains { errorDescription.contains($0) }
    }
}

// MARK: - Supporting Types

enum MCPConnectionStatus {
    case disconnected
    case connecting
    case connected
    case error(String)
}

struct MCPConfig {
    let id: String
    let name: String
    let transport: MCPTransportType
    let command: String?
    let args: [String]
    let env: [String: String]?
    
    enum MCPTransportType {
        case stdio
        case sse
        case streamableHTTP
    }
}

struct MCPTool: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let serverId: String
    
    static func == (lhs: MCPTool, rhs: MCPTool) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct MCPToolResult {
    let content: [MCPToolContent]
    let isError: Bool
    
    enum MCPToolContent {
        case text(String)
        case image(data: Data, mimeType: String)
        case resource(uri: String, mimeType: String, blob: Data?)
    }
}

enum MCPError: Error, LocalizedError {
    case toolNotFound(String)
    case sessionNotConnected(String)
    case configurationNotFound(String)
    case connectionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .sessionNotConnected(let serverId):
            return "Session not connected to \(serverId)"
        case .configurationNotFound(let serverId):
            return "Configuration not found for \(serverId)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        }
    }
}

// MARK: - Mock Session for Testing
// In production, this would be a real MCP protocol implementation
class MCPSession {
    let config: MCPConfig
    var isConnected: Bool = false
    var cancelBag: Set<AnyCancellable> = []
    
    var connectionStatePublisher: AnyPublisher<MCPSessionState, Never> {
        Just(.connected).eraseToAnyPublisher()
    }
    
    init(config: MCPConfig) {
        self.config = config
    }
    
    func connect() async throws {
        isConnected = true
    }
    
    func disconnect() {
        isConnected = false
    }
    
    func listTools() async throws -> [MCPTool] {
        // Mock implementation - returns sample tools
        return [
            MCPTool(
                id: "filesystem_list_directory",
                name: "list_directory",
                description: "List contents of a directory",
                inputSchema: ["type": "object", "properties": ["path": ["type": "string"]]],
                serverId: config.id
            ),
            MCPTool(
                id: "filesystem_read_file",
                name: "read_file",
                description: "Read contents of a file",
                inputSchema: ["type": "object", "properties": ["path": ["type": "string"]]],
                serverId: config.id
            )
        ]
    }
    
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        // Mock implementation
        return MCPToolResult(
            content: [.text("Mock result for \(name)")],
            isError: false
        )
    }
    
    func hasTool(name: String) -> Bool {
        // Mock implementation - check against known tools
        let knownTools = ["list_directory", "read_file", "execute_command", "search_files"]
        return knownTools.contains(name)
    }
}

enum MCPSessionState {
    case disconnected
    case connecting
    case connected
    case error
}
FILEEOF ; echo "__SWIFTMAESTRO_CWD__=$(pwd)"