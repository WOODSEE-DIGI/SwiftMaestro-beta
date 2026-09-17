import Foundation

/// Scans the shared AI knowledge store (`~/.ai-context/memory/knowledge`) for
/// Markdown files containing monitored Publish tags.
enum PublishKnowledgeSource {

    static func scan(monitoredTags: Set<String>) async -> [PublishDraft] {
        let root = SimpleMemoryStore.sharedMemoryRootURL()
            .appendingPathComponent("knowledge", isDirectory: true)
        return await scanMarkdownFiles(at: root, sourceKind: .knowledge, monitoredTags: monitoredTags)
    }
}

/// Scans plan markdown mirrors (`~/.ai-context/memory/knowledge/plans`) for
/// Markdown files containing monitored Publish tags.
enum PublishPlansSource {

    static func scan(monitoredTags: Set<String>) async -> [PublishDraft] {
        let root = SimpleMemoryStore.sharedMemoryRootURL()
            .appendingPathComponent("knowledge/plans", isDirectory: true)
        return await scanMarkdownFiles(at: root, sourceKind: .plan, monitoredTags: monitoredTags)
    }
}

// MARK: - Shared scanner

private func scanMarkdownFiles(
    at root: URL,
    sourceKind: PublishSourceKind,
    monitoredTags: Set<String>
) async -> [PublishDraft] {
    guard !monitoredTags.isEmpty,
          FileManager.default.fileExists(atPath: root.path) else { return [] }

    return await Task.detached(priority: .userInitiated) {
        var drafts: [PublishDraft] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let itemURL = enumerator?.nextObject() as? URL {
            guard itemURL.pathExtension.lowercased() == "md" else { continue }
            guard let content = try? String(contentsOf: itemURL, encoding: .utf8) else { continue }

            let lowered = content.lowercased()
            let matchedTags = monitoredTags.filter { lowered.contains($0.lowercased()) }
            guard !matchedTags.isEmpty else { continue }

            let title = MarkdownScanner.title(from: content, fallbackURL: itemURL)
            let summary = MarkdownScanner.summary(from: content)
            let modifiedAt = (try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            drafts.append(PublishDraft(
                sourceKind: sourceKind,
                sourcePath: itemURL.path,
                title: title,
                summary: summary,
                bodyMarkdown: content,
                bodyHTML: PublishMarkdownToHTML.convert(content),
                tags: Array(matchedTags),
                modifiedAt: modifiedAt
            ))
        }

        return drafts
    }.value
}

private enum MarkdownScanner {
    static func title(from content: String, fallbackURL: URL) -> String {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return fallbackURL.deletingPathExtension().lastPathComponent
    }

    static func summary(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var paragraph = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            paragraph = trimmed
            break
        }
        return String(paragraph.prefix(240))
    }
}
