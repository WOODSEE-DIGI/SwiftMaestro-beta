import Foundation

enum ModelTierPolicy {
    static let preferredMinimumB: Double = 70
    /// High-quality model recommended when the user wants maximum capability
    /// (e.g. the "Use recommended model" button, Turbo Mode).
    static let recommendedModelID = "Qwen3.5-122B-A10B-4bit"
    /// Model loaded by default on launch: a fast MoE that balances speed and
    /// quality. Used for the startup default and the oMLX configured-model
    /// fallback so the app does not preload the 65GB 122B every launch.
    static let defaultModelID = "Qwen3.6-35B-A3B-MLX-4bit"
    /// The previous auto-set default, migrated away from on first launch.
    static let legacyDefaultModelID = "Qwen3.5-122B-A10B-4bit"

    static func extractTierB(from modelID: String) -> Double? {
        guard
            let regex = try? NSRegularExpression(
                pattern: "(?:^|[-_])([0-9]+(?:\\.[0-9]+)?)B(?=$|[-_])",
                options: [.caseInsensitive]
            )
        else {
            return nil
        }

        let range = NSRange(modelID.startIndex..<modelID.endIndex, in: modelID)
        let matches = regex.matches(in: modelID, options: [], range: range)

        let tiers = matches.compactMap { match -> Double? in
            guard
                match.numberOfRanges > 1,
                let tierRange = Range(match.range(at: 1), in: modelID)
            else {
                return nil
            }
            return Double(modelID[tierRange])
        }

        return tiers.max()
    }

    static func isBelowPreferredTier(_ modelID: String) -> Bool {
        guard let tier = extractTierB(from: modelID) else { return false }
        return tier < preferredMinimumB
    }
}

// MARK: - Message roles

enum MessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
}

// MARK: - Message

struct Message: Identifiable, Codable {
    var id: UUID
    var role: MessageRole
    var content: String
    /// Attached images (raw PNG/JPEG bytes), sent to vision-capable models as
    /// data URIs. Optional so older persisted chats (without the field) still
    /// decode (synthesized Codable uses decodeIfPresent for optionals).
    var imageData: [Data]?
    /// Names of tools this assistant turn invoked, shown as a compact collapsed
    /// "activity" disclosure (kept out of `content` so it doesn't bloat the chat).
    var toolSteps: [String]?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        imageData: [Data]? = nil,
        toolSteps: [String]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.imageData = imageData
        self.toolSteps = toolSteps
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

    /// Single source of truth for the built-in agent names. Used to seed the
    /// sidebar and to populate per-agent scope pickers in Settings.
    static let defaultAgentNames = ["General", "Coding"]
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
        endpointURL: String = "http://localhost:8012",
        modelIdentifier: String = "Qwen3.5-122B-A10B-4bit",
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
        case .omLX: return "http://localhost:8012"
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
