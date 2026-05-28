import Foundation

/// Adapts LocalLLMExecutor to MaestroAgentProtocol
final class LocalLLMAgentAdapter: MaestroAgentProtocol {
    let providerType: ProviderType = .localLLM
    
    private let executor: LocalLLMExecutor
    
    init(config: LocalLLMConfig, apiKey: String? = nil) {
        self.executor = LocalLLMExecutor(config: config, apiKey: apiKey)
    }
    
    func runAgent(request: AgentRunRequest) async throws -> AsyncThrowingStream<String, Error> {
        return try await executor.stream(messages: request.messages)
    }
}
