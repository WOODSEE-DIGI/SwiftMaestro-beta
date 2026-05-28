import Foundation

// MARK: - Message roles

enum MessageRole: String {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
}

// MARK: - Message

struct Message: Identifiable {
    var id: UUID
    var role: MessageRole
    var content: String
    
    init(id: UUID = UUID(), role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

// MARK: - Agent

struct Agent: Identifiable {
    var id: UUID
    var name: String
    var providerType: ProviderType
    var configID: UUID?
    var workspaceFolders: [String]
    var rules: [String]
    var messages: [Message]
    
    init(
        id: UUID = UUID(),
        name: String,
        providerType: ProviderType = .localLLM,
        configID: UUID? = nil,
        workspaceFolders: [String] = [],
        rules: [String] = [],
        messages: [Message] = []
    ) {
        self.id = id
        self.name = name
        self.providerType = providerType
        self.configID = configID
        self.workspaceFolders = workspaceFolders
        self.rules = rules
        self.messages = messages
    }
}

// MARK: - Provider types

enum ProviderType: String, Codable {
    case localLLM = "local_llm"
    case omLX = "omlx"
    case mlx = "mlx"
    case claudeCode = "claude_code"
    
    var displayName: String {
        switch self {
        case .localLLM: return "Local LLM"
        case .omLX: return "oMLX"
        case .mlx: return "MLX"
        case .claudeCode: return "Claude Code"
        }
    }
}

// MARK: - LLM Config

struct LocalLLMConfig: Identifiable, Codable {
    var id: UUID
    var name: String
    var endpointURL: String
    var modelIdentifier: String
    var requiresAPIKey: Bool
    var runtimeBackend: LocalModelRuntimeBackend
    var requestTimeoutSeconds: TimeInterval
    
    init(
        id: UUID = UUID(),
        name: String = "Default",
        endpointURL: String = "http://localhost:8000",
        modelIdentifier: String = "qwen3.5-35b",
        requiresAPIKey: Bool = false,
        runtimeBackend: LocalModelRuntimeBackend = .omLX,
        requestTimeoutSeconds: TimeInterval = 300
    ) {
        self.id = id
        self.name = name
        self.endpointURL = endpointURL
        self.modelIdentifier = modelIdentifier
        self.requiresAPIKey = requiresAPIKey
        self.runtimeBackend = runtimeBackend
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }
    
    var chatCompletionURL: URL? {
        let base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: base + "/v1/chat/completions")
    }
}

enum LocalModelRuntimeBackend: String, Codable {
    case omLX = "omlx"
    case mlx = "mlx"
    case liteLLM = "litellm"
    
    var displayName: String {
        switch self {
        case .omLX: return "oMLX"
        case .mlx: return "MLX (Apple Silicon)"
        case .liteLLM: return "LiteLLM Proxy"
        }
    }
    
    var defaultEndpointURL: String {
        switch self {
        case .omLX: return "http://localhost:8000"
        case .mlx: return "http://localhost:8080"
        case .liteLLM: return "http://localhost:4000"
        }
    }
}

// MARK: - Agent Run Request

struct AgentRunRequest {
    let messages: [Message]
    let prompt: String
    let metadata: AgentRunMetadata
    
    init(messages: [Message], prompt: String, metadata: AgentRunMetadata) {
        self.messages = messages
        self.prompt = prompt
        self.metadata = metadata
    }
}

struct AgentRunMetadata {
    let agentID: UUID
    let agentName: String
    let workspaceFolders: [String]
    
    init(agentID: UUID, agentName: String, workspaceFolders: [String]) {
        self.agentID = agentID
        self.agentName = agentName
        self.workspaceFolders = workspaceFolders
    }
}

// MARK: - Agent Protocol

protocol MaestroAgentProtocol: AnyObject {
    var providerType: ProviderType { get }
    func runAgent(request: AgentRunRequest) async throws -> AsyncThrowingStream<String, Error>
}
