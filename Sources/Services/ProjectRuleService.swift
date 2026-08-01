import Foundation

// MARK: - Project rule ingestion
//
// Automatically reads project-specific rule files from an agent's working
// directory and injects them into the system prompt. This makes every project
// agent follow the project's own AGENTS.md/README.md without requiring the
// user to manually copy rules into Settings → Rules.

/// A project rule file discovered on disk.
struct ProjectRule: Identifiable, Codable, Hashable {
    let id: UUID
    let source: ProjectRuleSource
    let path: String
    let content: String
    let lastModified: Date
    let enabled: Bool
}

/// Known project rule file locations, in the order they should be presented.
/// The order matters: AGENTS.md is the most authoritative, followed by the
/// project README, then the AI-Context README for cross-tool conventions.
enum ProjectRuleSource: String, Codable, Hashable, CaseIterable {
    case agentsMD = "AGENTS.md"
    case readmeMD = "README.md"
    case aiContextReadme = ".ai-context/README.md"

    /// Relative path from the working directory.
    var relativePath: String { rawValue }

    /// Display label for the system prompt.
    var displayName: String {
        switch self {
        case .agentsMD: return "AGENTS.md"
        case .readmeMD: return "README.md"
        case .aiContextReadme: return "AI-Context README"
        }
    }

    /// How important the file is (lower = presented first).
    var priority: Int {
        switch self {
        case .agentsMD: return 0
        case .readmeMD: return 1
        case .aiContextReadme: return 2
        }
    }
}

/// Discovers and caches project rule files from a working directory.
///
/// The service is safe to call from the main thread: it only reads small local
/// markdown files and uses a lock to protect the in-memory cache.
final class ProjectRuleService: @unchecked Sendable {
    static let shared = ProjectRuleService()

    private var cache: [String: [ProjectRule]] = [:]
    private let lock = NSLock()

    private init() {}

    /// Returns all project rules for the given directory, using the cache when
    /// the discovered files have not changed on disk.
    func rules(forWorkingDirectory directory: String) -> [ProjectRule] {
        let standardized = normalize(directory)

        lock.lock()
        let cached = cache[standardized]
        lock.unlock()

        if let cached, !cacheInvalidated(cached) {
            return cached
        }

        let rules = loadRules(for: standardized)
        lock.lock()
        cache[standardized] = rules
        lock.unlock()
        return rules
    }

    /// Force a fresh disk read, bypassing the cache.
    func refreshRules(forWorkingDirectory directory: String) -> [ProjectRule] {
        let standardized = normalize(directory)
        let rules = loadRules(for: standardized)
        lock.lock()
        cache[standardized] = rules
        lock.unlock()
        return rules
    }

    /// Render a block suitable for injection into a system prompt.
    func renderRules(_ rules: [ProjectRule]) -> String {
        guard !rules.isEmpty else { return "" }

        var parts: [String] = [
            "PROJECT RULES — READ BEFORE ACTING",
            "The following files were read from the project working directory. "
                + "You MUST follow these project-specific rules when working on this project.",
        ]
        for rule in rules {
            parts.append("\n--- \(rule.source.displayName) (\(rule.path)) ---\n\(rule.content)")
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

    /// True if any cached rule's file has changed since it was loaded.
    private func cacheInvalidated(_ rules: [ProjectRule]) -> Bool {
        for rule in rules {
            let attributes = try? FileManager.default.attributesOfItem(atPath: rule.path)
            let modified = attributes?[.modificationDate] as? Date ?? Date.distantPast
            if modified != rule.lastModified { return true }
        }
        return false
    }

    private func loadRules(for directory: String) -> [ProjectRule] {
        let fm = FileManager.default
        var rules: [ProjectRule] = []

        for source in ProjectRuleSource.allCases.sorted(by: { $0.priority < $1.priority }) {
            let fullPath = (directory as NSString).appendingPathComponent(source.relativePath)
            guard fm.fileExists(atPath: fullPath) else { continue }

            let url = URL(fileURLWithPath: fullPath)
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8),
                  !content.isEmpty else { continue }

            let attributes = try? fm.attributesOfItem(atPath: fullPath)
            let modified = attributes?[.modificationDate] as? Date ?? Date()

            rules.append(ProjectRule(
                id: UUID(),
                source: source,
                path: fullPath,
                content: content,
                lastModified: modified,
                enabled: true))
        }
        return rules
    }
}
