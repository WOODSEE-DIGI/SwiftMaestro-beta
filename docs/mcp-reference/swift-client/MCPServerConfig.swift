import Foundation

struct MCPServerConfig: Identifiable, Codable, Equatable {
    enum Transport: String, Codable, CaseIterable {
        case stdio
    }

    let id: UUID
    var name: String
    var transport: Transport
    var command: String
    var args: [String]
    var env: [String: String]
    var workingDirectory: String?
    var isEnabled: Bool
    var startupTimeoutSeconds: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        transport: Transport = .stdio,
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil,
        isEnabled: Bool = true,
        startupTimeoutSeconds: Int = 8
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.workingDirectory = workingDirectory
        self.isEnabled = isEnabled
        self.startupTimeoutSeconds = startupTimeoutSeconds
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "MCP Server" : trimmed
    }

    var hasValidLaunchCommand: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
