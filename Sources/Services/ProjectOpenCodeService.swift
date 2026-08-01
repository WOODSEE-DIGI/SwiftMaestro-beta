import Foundation

// MARK: - .opencode/ project configuration ingestion
//
// Reads OpenCode-style project configuration files from a working directory
// and injects agent instructions, skills, and commands into the system prompt.
// This helps SwiftMaestro project agents behave like OpenCode coding agents.

/// A section discovered inside a .opencode/ directory.
struct ProjectOpenCodeSection: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: ProjectOpenCodeSection.Kind
    let path: String
    let title: String
    let content: String
    let lastModified: Date
}

extension ProjectOpenCodeSection {
    enum Kind: String, Codable, Hashable, CaseIterable {
        case config = "opencode.jsonc"
        case agent = "agent"
        case skill = "skills"
        case command = "command"
    }
}

/// Discovers and caches OpenCode-style project configuration files.
final class ProjectOpenCodeService: @unchecked Sendable {
    static let shared = ProjectOpenCodeService()

    private var cache: [String: [ProjectOpenCodeSection]] = [:]
    private let lock = NSLock()

    private init() {}

    /// Returns all applicable .opencode/ sections for a directory and agent.
    func sections(forWorkingDirectory directory: String, agentName: String) -> [ProjectOpenCodeSection] {
        let standardized = normalize(directory)

        lock.lock()
        let cached = cache[standardized]
        lock.unlock()

        if let cached, !cacheInvalidated(cached) {
            return cached.filter { $0.isApplicable(to: agentName) }
        }

        let sections = loadSections(for: standardized)
        lock.lock()
        cache[standardized] = sections
        lock.unlock()
        return sections.filter { $0.isApplicable(to: agentName) }
    }

    /// Force a fresh disk read, bypassing the cache.
    func refreshSections(forWorkingDirectory directory: String, agentName: String) -> [ProjectOpenCodeSection] {
        let standardized = normalize(directory)
        let sections = loadSections(for: standardized)
        lock.lock()
        cache[standardized] = sections
        lock.unlock()
        return sections.filter { $0.isApplicable(to: agentName) }
    }

    /// Render a block suitable for injection into a system prompt.
    func renderSections(_ sections: [ProjectOpenCodeSection]) -> String {
        guard !sections.isEmpty else { return "" }

        var parts: [String] = [
            "OPENCODE PROJECT CONFIGURATION — READ BEFORE ACTING",
            "The following .opencode/ files were read from the project working directory. "
                + "You MUST follow these project-specific instructions when working on this project.",
        ]
        for section in sections {
            parts.append("\n--- \(section.kind.rawValue): \(section.title) (\(section.path)) ---\n\(section.content)")
        }
        return parts.joined(separator: "\n")
    }

    /// Clear the in-memory cache for a directory (e.g. after a manual refresh).
    func clearCache(forWorkingDirectory directory: String) {
        let standardized = normalize(directory)
        lock.lock()
        cache.removeValue(forKey: standardized)
        lock.unlock()
    }

    // MARK: - Private

    private func normalize(_ directory: String) -> String {
        URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    }

    private func cacheInvalidated(_ sections: [ProjectOpenCodeSection]) -> Bool {
        for section in sections {
            let attributes = try? FileManager.default.attributesOfItem(atPath: section.path)
            let modified = attributes?[.modificationDate] as? Date ?? Date.distantPast
            if modified != section.lastModified { return true }
        }
        return false
    }

    private func loadSections(for directory: String) -> [ProjectOpenCodeSection] {
        let fm = FileManager.default
        let opencodeDir = (directory as NSString).appendingPathComponent(".opencode")
        guard fm.fileExists(atPath: opencodeDir) else { return [] }

        var sections: [ProjectOpenCodeSection] = []

        // 1. opencode.jsonc / opencode.json
        for configName in ["opencode.jsonc", "opencode.json"] {
            let configPath = (opencodeDir as NSString).appendingPathComponent(configName)
            if fm.fileExists(atPath: configPath) {
                if let section = loadConfig(at: configPath) {
                    sections.append(section)
                }
                break
            }
        }

        // 2. agent/<name>.md
        let agentDir = (opencodeDir as NSString).appendingPathComponent("agent")
        if fm.fileExists(atPath: agentDir) {
            sections.append(contentsOf: loadMarkdownFiles(in: agentDir, kind: .agent))
        }

        // 3. skills/<name>.md or skills/<name>/SKILL.md
        let skillsDir = (opencodeDir as NSString).appendingPathComponent("skills")
        if fm.fileExists(atPath: skillsDir) {
            sections.append(contentsOf: loadMarkdownFiles(in: skillsDir, kind: .skill))
            // Also check subdirectories.
            if let entries = try? fm.contentsOfDirectory(atPath: skillsDir) {
                for entry in entries {
                    let entryPath = (skillsDir as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: entryPath, isDirectory: &isDir), isDir.boolValue {
                        let skillMd = (entryPath as NSString).appendingPathComponent("SKILL.md")
                        if fm.fileExists(atPath: skillMd),
                           let section = loadMarkdown(at: skillMd, kind: .skill, title: entry) {
                            sections.append(section)
                        }
                    }
                }
            }
        }

        // 4. command/<name>.md
        let commandDir = (opencodeDir as NSString).appendingPathComponent("command")
        if fm.fileExists(atPath: commandDir) {
            sections.append(contentsOf: loadMarkdownFiles(in: commandDir, kind: .command))
        }

        return sections
    }

    private func loadConfig(at path: String) -> ProjectOpenCodeSection? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date ?? Date()

        // Strip // and /* */ comments so the JSON is valid for decoding.
        let stripped = stripJSONCComments(raw)

        // Try to decode a small subset of the config. We are mainly interested
        // in the "rules" array for system prompt injection.
        struct OpenCodeConfig: Codable {
            let rules: [String]?
        }

        var rendered = raw
        if let config = try? JSONDecoder().decode(OpenCodeConfig.self, from: Data(stripped.utf8)),
           let rules = config.rules, !rules.isEmpty {
            rendered = rules.map { "- \($0)" }.joined(separator: "\n")
        }

        return ProjectOpenCodeSection(
            id: UUID(),
            kind: .config,
            path: path,
            title: "project configuration",
            content: rendered,
            lastModified: modified)
    }

    private func loadMarkdownFiles(in directory: String, kind: ProjectOpenCodeSection.Kind) -> [ProjectOpenCodeSection] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var sections: [ProjectOpenCodeSection] = []
        for entry in entries.filter({ $0.hasSuffix(".md") }).sorted() {
            let path = (directory as NSString).appendingPathComponent(entry)
            let title = (entry as NSString).deletingPathExtension
            if let section = loadMarkdown(at: path, kind: kind, title: title) {
                sections.append(section)
            }
        }
        return sections
    }

    private func loadMarkdown(at path: String, kind: ProjectOpenCodeSection.Kind, title: String) -> ProjectOpenCodeSection? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date ?? Date()

        return ProjectOpenCodeSection(
            id: UUID(),
            kind: kind,
            path: path,
            title: title,
            content: content,
            lastModified: modified)
    }

    private func stripJSONCComments(_ raw: String) -> String {
        var result: [Character] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(after: index)
            if raw[index] == "/" && next < raw.endIndex {
                let nextChar = raw[next]
                if nextChar == "/" {
                    // Skip until newline.
                    while index < raw.endIndex && raw[index] != "\n" {
                        index = raw.index(after: index)
                    }
                    continue
                } else if nextChar == "*" {
                    // Skip until */.
                    index = raw.index(after: next)
                    while index < raw.endIndex {
                        let after = raw.index(after: index)
                        if raw[index] == "*" && after < raw.endIndex && raw[after] == "/" {
                            index = raw.index(after: after)
                            break
                        }
                        index = raw.index(after: index)
                    }
                    continue
                }
            }
            result.append(raw[index])
            index = raw.index(after: index)
        }
        return String(result)
    }
}

extension ProjectOpenCodeSection {
    /// Determine if a section applies to a given agent name.
    /// - Config, skills, and commands apply to all agents.
    /// - Agent files apply only when the filename matches the agent name (case-insensitive).
    fileprivate func isApplicable(to agentName: String) -> Bool {
        switch kind {
        case .config, .skill, .command:
            return true
        case .agent:
            return title.lowercased() == agentName.lowercased()
        }
    }
}
