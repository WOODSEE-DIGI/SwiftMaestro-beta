import Foundation

enum ProviderFactoryError: LocalizedError {
    case configNotFound(UUID)
    case providerUnavailable(ProviderType)
    
    var errorDescription: String? {
        switch self {
        case .configNotFound(let id):
            return "No LLM configuration found for id \(id.uuidString)"
        case .providerUnavailable(let type):
            return "\(type.displayName) is not yet available"
        }
    }
}

enum ProviderFactoryService {
    static func adapter(
        for agent: Agent,
        configs: [LocalLLMConfig],
        apiKey: String? = nil
    ) throws -> any MaestroAgentProtocol {
        switch agent.providerType {
        case .localLLM, .omLX, .mlx:
            guard let config = configs.first(where: { $0.id == agent.configID }) else {
                throw ProviderFactoryError.configNotFound(agent.configID ?? UUID())
            }
            
            return LocalLLMAgentAdapter(config: config, apiKey: apiKey)
            
        case .claudeCode:
            throw ProviderFactoryError.providerUnavailable(.claudeCode)
        }
    }
}
