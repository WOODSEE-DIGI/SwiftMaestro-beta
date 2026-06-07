import Foundation

/// Simple memory store using MaestroURI for organization
/// Provides basic context recall without full MaestroMemory complexity
final class SimpleMemoryStore {
    private let baseDir: URL
    
    /// Maps MaestroURI kinds to the shared memory directory structure.
    /// Default: ~/.ai-context/memory/ (shared with Warp, Qwen Code, LM Studio, Claude Code)
    private static let kindDirectoryMap: [MaestroURI.Kind: String] = [
        .memory: "conversations/swiftmaestro",
        .knowledge: "knowledge",
        .context: "context",
        .skill: "skills"
    ]
    
    init(basePath: URL? = nil) {
        if let path = basePath {
            self.baseDir = path
        } else {
            // Use the shared memory directory — same store as all other AI tools
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDir = home.appendingPathComponent(".ai-context/memory")
        }
    }
    
    // MARK: - Storage
    
    func save(_ content: String, at uri: MaestroURI) throws {
        let fileURL = url(for: uri)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), 
                                                 withIntermediateDirectories: true)
        // Safety net: strip any known secret values before they can land in the
        // shared ~/.ai-context/memory/ store (read by all AI tools).
        let safeContent = SecretRedactor.redact(content)
        try safeContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    func load(_ uri: MaestroURI) throws -> String? {
        let fileURL = url(for: uri)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
    
    func delete(_ uri: MaestroURI) throws {
        let fileURL = url(for: uri)
        try FileManager.default.removeItem(at: fileURL)
    }
    
    // MARK: - Hierarchy
    
    func listChildren(of uri: MaestroURI) throws -> [MaestroURI] {
        let dirURL = url(for: uri)
        guard FileManager.default.fileExists(atPath: dirURL.path) else {
            return []
        }
        
        let contents = try FileManager.default.contentsOfDirectory(at: dirURL, 
                                                                    includingPropertiesForKeys: nil)
        return contents.compactMap { itemURL -> MaestroURI? in
            let component = itemURL.lastPathComponent
            // Check if it's a directory or JSON file
            let isDir = FileManager.default.fileExists(atPath: itemURL.path, isDirectory: nil)
            if isDir {
                return uri.appending(component)
            } else if component.hasSuffix(".json") {
                return uri.appending(String(component.dropLast(5)))
            }
            return nil
        }
    }
    
    // MARK: - Conversation history
    
    func saveConversationHistory(_ agentID: String, messages: [Message]) throws {
        let uri = MaestroURI(kind: .memory, path: ["conversations", agentID, "history"])
        let content = messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n\n")
        try save(content, at: uri)
    }
    
    func loadConversationHistory(_ agentID: String) throws -> [Message]? {
        let uri = MaestroURI(kind: .memory, path: ["conversations", agentID, "history"])
        guard let content = try load(uri) else {
            return nil
        }
        
        // Parse back to messages
        var messages: [Message] = []
        for line in content.components(separatedBy: "\n\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let role = MessageRole(rawValue: String(parts[0])) ?? .user
            let content = String(parts[1])
            messages.append(Message(role: role, content: content))
        }
        return messages.isEmpty ? nil : messages
    }
    
    // MARK: - Private
    
    private func url(for uri: MaestroURI) -> URL {
        let kindDir = Self.kindDirectoryMap[uri.kind] ?? uri.kind.rawValue
        let components = [baseDir.path, kindDir] + uri.path
        return URL(fileURLWithPath: components.joined(separator: "/"))
    }
}
