import Foundation

/// Simple memory store using MaestroURI for organization
/// Provides basic context recall without full MaestroMemory complexity
struct SimpleMemoryStore: Sendable {
    private let baseDir: URL
    
    /// Maps MaestroURI kinds to the shared memory directory structure.
    /// Default: ~/.ai-context/memory/ (shared with Qwen Code, LM Studio, Claude Code)
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
            self.baseDir = Self.sharedMemoryRootURL()
        }
    }

    /// The canonical memory root for this machine.
    /// Prefers the iCloud Drive container (`Documents/SwiftMaestro/memory`) so memory
    /// syncs across devices; falls back to a local `~/.ai-context/memory` directory.
    static func sharedMemoryRootURL() -> URL {
        let fileManager = FileManager.default
        if let iCloudContainer = fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/SwiftMaestro/memory", isDirectory: true) {
            try? fileManager.createDirectory(at: iCloudContainer, withIntermediateDirectories: true)
            return iCloudContainer.resolvingSymlinksInPath()
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-context/memory", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    /// Create the shared `~/.ai-context/memory` subtree up front so a fresh,
    /// self-contained install has its data directory before the first write.
    /// Idempotent: existing directories are left untouched. Also creates or repairs
    /// the `~/.ai-context/memory` symlink so it is portable across Macs (relative,
    /// not absolute).
    static func ensureScaffold() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let aiContext = home.appendingPathComponent(".ai-context", isDirectory: true)
        try? fm.createDirectory(at: aiContext, withIntermediateDirectories: true)

        let target = sharedMemoryRootURL()
        let aiMemory = home.appendingPathComponent(".ai-context/memory", isDirectory: true)

        // Make sure the real target exists before we symlink to it.
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)

        // If we're using the iCloud container, keep ~/.ai-context/memory as a
        // relative symlink so it survives on any Mac with the same Apple ID.
        if target.resolvingSymlinksInPath() != aiMemory.resolvingSymlinksInPath() {
            repairOrCreateAIMemorySymlink(aiMemory: aiMemory, target: target)
        }

        for sub in ["conversations/swiftmaestro", "knowledge", "context", "skills"] {
            try? fm.createDirectory(
                at: aiMemory.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    private static func repairOrCreateAIMemorySymlink(aiMemory: URL, target: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: aiMemory.path, isDirectory: &isDir)

        if exists {
            guard let attrs = try? fm.attributesOfItem(atPath: aiMemory.path),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
                // Real directory or file — leave it alone.
                return
            }
            // Resolve the current destination. If it's already relative and valid,
            // keep it; otherwise replace it so it is portable.
            if let dest = try? fm.destinationOfSymbolicLink(atPath: aiMemory.path),
               !dest.hasPrefix("/"),
               fm.fileExists(atPath: target.path) {
                return
            }
            try? fm.removeItem(at: aiMemory)
        }

        let relative = relativePath(from: aiMemory.deletingLastPathComponent().path, to: target.path)
        try? fm.createSymbolicLink(atPath: aiMemory.path, withDestinationPath: relative)
    }

    private static func relativePath(from base: String, to destination: String) -> String {
        let baseComponents = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
        let destComponents = URL(fileURLWithPath: destination).standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseComponents.count, destComponents.count)
                && baseComponents[common] == destComponents[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: baseComponents.count - common)
        let remainder = Array(destComponents.dropFirst(common))
        return (ups + remainder).joined(separator: "/")
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
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir)
            if isDir.boolValue {
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

    /// Relative slash paths of entries stored under a kind (recursive), with optional path prefix and pagination.
    func entries(kind: MaestroURI.Kind, pathPrefix: String? = nil, limit: Int? = nil, offset: Int? = nil) -> [String] {
        let dir = directory(for: kind)
        let subpaths: [String]
        do {
            subpaths = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        } catch {
            return []
        }
        let prefix = pathPrefix?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var out: [String] = []
        for sub in subpaths {
            guard (try? dir.appendingPathComponent(sub).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if let prefix = prefix, !prefix.isEmpty, !sub.hasPrefix(prefix) && !sub.hasPrefix(prefix + "/") { continue }
            out.append(sub)
        }
        let sorted = out.sorted()
        let total = sorted.count
        let start = max(0, min(offset ?? 0, total))
        let end: Int
        if let limit = limit, limit > 0 {
            end = min(total, start + limit)
        } else {
            end = total
        }
        guard start < end else { return [] }
        return Array(sorted[start..<end])
    }

    /// Count entries under a kind, optionally filtered by a path prefix.
    func countEntries(kind: MaestroURI.Kind, pathPrefix: String? = nil) -> Int {
        let dir = directory(for: kind)
        let subpaths: [String]
        do {
            subpaths = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        } catch {
            return 0
        }
        let prefix = pathPrefix?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var count = 0
        for sub in subpaths {
            guard (try? dir.appendingPathComponent(sub).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let prefix = prefix, !prefix.isEmpty, !sub.hasPrefix(prefix) && !sub.hasPrefix(prefix + "/") { continue }
            count += 1
        }
        return count
    }

    /// Full-text search across the whole store. Returns (relative path, snippet).
    func search(_ query: String, limit: Int = 20) -> [(path: String, snippet: String)] {
        let subpaths: [String]
        do {
            subpaths = try FileManager.default.subpathsOfDirectory(atPath: baseDir.path)
        } catch {
            return []
        }
        let needle = query.lowercased()
        var hits: [(path: String, snippet: String)] = []
        for sub in subpaths {
            if hits.count >= limit { break }
            let url = baseDir.appendingPathComponent(sub)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  content.lowercased().contains(needle) else { continue }
            hits.append((sub, Self.snippet(content, around: needle)))
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
