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

    /// Create the shared `~/.ai-context/memory` subtree up front so a fresh,
    /// self-contained install has its data directory before the first write.
    /// Idempotent: existing directories are left untouched.
    static func ensureScaffold() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let memory = home.appendingPathComponent(".ai-context/memory", isDirectory: true)
        for sub in ["conversations/swiftmaestro", "knowledge", "context", "skills"] {
            try? FileManager.default.createDirectory(
                at: memory.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
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

    // MARK: - Listing & search (native memory tools)

    /// Directory backing a kind (e.g. .knowledge -> <base>/knowledge).
    func directory(for kind: MaestroURI.Kind) -> URL {
        let kindDir = Self.kindDirectoryMap[kind] ?? kind.rawValue
        return baseDir.appendingPathComponent(kindDir, isDirectory: true)
    }

    /// Relative slash paths of every entry stored under a kind (recursive).
    func entries(kind: MaestroURI.Kind) -> [String] {
        let dir = directory(for: kind)
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            out.append(url.path.replacingOccurrences(of: dir.path + "/", with: ""))
        }
        return out.sorted()
    }

    /// Full-text search across the whole store. Returns (relative path, snippet).
    func search(_ query: String, limit: Int = 20) -> [(path: String, snippet: String)] {
        guard let walker = FileManager.default.enumerator(
            at: baseDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let needle = query.lowercased()
        var hits: [(path: String, snippet: String)] = []
        for case let url as URL in walker {
            if hits.count >= limit { break }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  content.lowercased().contains(needle) else { continue }
            let rel = url.path.replacingOccurrences(of: baseDir.path + "/", with: "")
            hits.append((rel, Self.snippet(content, around: needle)))
        }
        return hits
    }

    private static func snippet(_ content: String, around needle: String, width: Int = 160) -> String {
        let collapsed = content.replacingOccurrences(of: "\n", with: " ")
        let lower = collapsed.lowercased()
        guard let r = lower.range(of: needle) else { return String(collapsed.prefix(width)) }
        let startOffset = max(0, lower.distance(from: lower.startIndex, to: r.lowerBound) - 40)
        let s = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
        let e = collapsed.index(s, offsetBy: min(width, collapsed.distance(from: s, to: collapsed.endIndex)))
        return String(collapsed[s..<e]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Private
    
    private func url(for uri: MaestroURI) -> URL {
        let kindDir = Self.kindDirectoryMap[uri.kind] ?? uri.kind.rawValue
        let components = [baseDir.path, kindDir] + uri.path
        return URL(fileURLWithPath: components.joined(separator: "/"))
    }
}
