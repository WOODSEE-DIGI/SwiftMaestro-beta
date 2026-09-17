import Foundation

/// Scans the Notes.md vault for content tagged for publishing across multiple
/// SwiftMaestro apps. Markdown files are treated as Notes.md drafts, HTML files
/// as SwiftWeaver exports/pages, and plain-text files as MaestroDocs sources.
enum PublishVaultSource {

    /// Regex for inline tags like `#draft`, `#publish`, `#review`.
    /// Avoids matching Markdown headings (`# Heading`) by requiring the `#`
    /// to be preceded by whitespace/punctuation or start of line, and followed
    /// immediately by word characters.
    private static let tagRegex: NSRegularExpression = {
        let pattern = #"(?:^|[\s\W])(#[\w-]+)"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let imageRegex: NSRegularExpression = {
        let pattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let htmlImageRegex: NSRegularExpression = {
        let pattern = #"<img[^>]+src=[\"']([^\"']+)[\"']"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let htmlTitleRegex: NSRegularExpression = {
        let pattern = #"<title[^>]*>(.*?)</title>"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    private static let htmlH1Regex: NSRegularExpression = {
        let pattern = #"<h1[^>]*>(.*?)</h1>"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    private static let htmlTagRegex: NSRegularExpression = {
        let pattern = #"<[^>]+>"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let htmlBlockRegex: NSRegularExpression = {
        let pattern = #"<(script|style)[^>]*>.*?</\1>"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    private static let utf8 = String.Encoding.utf8

    /// File extensions the vault scanner understands. Binary office formats
    /// are intentionally excluded here; extracting their text is expensive and
    /// tags inside them are rare. Add a dedicated MaestroDocs binary source if
    /// that becomes necessary.
    private static let supportedExtensions: Set<String> = [
        "md", "markdown",
        "html", "htm",
        "txt", "text"
    ]

    /// Return all vault drafts that carry at least one monitored tag.
    /// Runs off the main actor so large vaults do not block the UI.
    nonisolated static func scan(monitoredTags: Set<String>) async -> [PublishDraft] {
        let vaultURL = await resolveVaultURL()
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return [] }

        let normalizedMonitored = Set(monitoredTags.map { $0.lowercased() })
        var drafts: [PublishDraft] = []
        enumerator(at: vaultURL) { fileURL in
            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { return }

            // Fast path: if none of the monitored tags appear anywhere in the
            // file, skip the more expensive read/parse/HTML conversion.
            guard fileMightContainMonitoredTags(fileURL, monitored: normalizedMonitored) else { return }

            switch ext {
            case "md", "markdown":
                processMarkdown(fileURL, monitored: normalizedMonitored, into: &drafts)
            case "html", "htm":
                processHTML(fileURL, monitored: normalizedMonitored, into: &drafts)
            case "txt", "text":
                processPlainText(fileURL, monitored: normalizedMonitored, into: &drafts)
            default:
                break
            }
        }
        return drafts
    }

    // MARK: - Markdown (Notes.md)

    private static func processMarkdown(_ fileURL: URL, monitored: Set<String>, into drafts: inout [PublishDraft]) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let tags = extractTags(from: content)
        let matched = tags.intersection(monitored)
        guard !matched.isEmpty else { return }

            // Notes.md shows files by their filename, so Publish uses the same
            // name for consistency even if the note's first heading differs.
            let title = fileURL.deletingPathExtension().lastPathComponent
            let summary = extractSummary(from: content)
        let html = PublishMarkdownToHTML.convert(content)
        let assetPaths = extractMarkdownImagePaths(from: content, relativeTo: fileURL)
        let (created, modified) = fileDates(fileURL)

        drafts.append(PublishDraft(
            sourceKind: .notesMD,
            sourcePath: fileURL.path,
            title: title,
            summary: summary,
            bodyMarkdown: content,
            bodyHTML: html,
            tags: Array(tags),
            status: .draft,
            createdAt: created,
            modifiedAt: modified,
            assetPaths: assetPaths,
            linkedSourcePaths: []
        ))
    }

    // MARK: - HTML (SwiftWeaver)

    private static func processHTML(_ fileURL: URL, monitored: Set<String>, into drafts: inout [PublishDraft]) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        // Search tags in the raw HTML source. Tags inside text nodes or
        // comments are captured; tags inside attributes are rare and acceptable
        // to treat as real tags for drafting purposes.
        let tags = extractTags(from: content)
        let matched = tags.intersection(monitored)
        guard !matched.isEmpty else { return }

        let title = extractHTMLTitle(from: content, fallbackURL: fileURL)
        let summary = extractHTMLSummary(from: content)
        let assetPaths = extractHTMLImagePaths(from: content, relativeTo: fileURL)
        let (created, modified) = fileDates(fileURL)

        drafts.append(PublishDraft(
            sourceKind: .swiftWeaver,
            sourcePath: fileURL.path,
            title: title,
            summary: summary,
            bodyMarkdown: plainTextFromHTML(content),
            bodyHTML: content,
            tags: Array(tags),
            status: .draft,
            createdAt: created,
            modifiedAt: modified,
            assetPaths: assetPaths,
            linkedSourcePaths: []
        ))
    }

    // MARK: - Plain text (MaestroDocs / generic documents)

    private static func processPlainText(_ fileURL: URL, monitored: Set<String>, into drafts: inout [PublishDraft]) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let tags = extractTags(from: content)
        let matched = tags.intersection(monitored)
        guard !matched.isEmpty else { return }

        let title = fileURL.deletingPathExtension().lastPathComponent
        let summary = extractTextSummary(from: content)
        let html = PublishMarkdownToHTML.convert(escapeHTML(content))
        let (created, modified) = fileDates(fileURL)

        drafts.append(PublishDraft(
            sourceKind: .maestroDocs,
            sourcePath: fileURL.path,
            title: title,
            summary: summary,
            bodyMarkdown: content,
            bodyHTML: html,
            tags: Array(tags),
            status: .draft,
            createdAt: created,
            modifiedAt: modified,
            assetPaths: [],
            linkedSourcePaths: []
        ))
    }

    // MARK: - Extraction helpers

    private static func extractTags(from content: String) -> Set<String> {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var tags: Set<String> = []
        for match in tagRegex.matches(in: content, options: [], range: range) {
            guard let tagRange = Range(match.range(at: 1), in: content) else { continue }
            var tag = String(content[tagRange])
            tag.removeFirst() // drop #
            tag = tag.lowercased().trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty {
                tags.insert(tag)
            }
        }
        return tags
    }

    private static func extractSummary(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var foundTitle = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                foundTitle = true
                continue
            }
            if foundTitle {
                return trimmed
            }
        }
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    private static func extractTextSummary(from content: String) -> String {
        content.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func extractMarkdownImagePaths(from content: String, relativeTo fileURL: URL) -> [String] {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var paths: [String] = []
        for match in imageRegex.matches(in: content, options: [], range: range) {
            guard let urlRange = Range(match.range(at: 2), in: content) else { continue }
            let src = String(content[urlRange])
            if src.hasPrefix("http://") || src.hasPrefix("https://") { continue }
            let resolved = URL(string: src, relativeTo: fileURL.deletingLastPathComponent())?.path ?? src
            paths.append(resolved)
        }
        return paths
    }

    private static func extractHTMLTitle(from content: String, fallbackURL: URL) -> String {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        for regex in [htmlTitleRegex, htmlH1Regex] {
            if let match = regex.firstMatch(in: content, options: [], range: range),
               let captureRange = Range(match.range(at: 1), in: content) {
                let raw = String(content[captureRange])
                let cleaned = plainTextFromHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return fallbackURL.deletingPathExtension().lastPathComponent
    }

    private static func extractHTMLSummary(from content: String) -> String {
        let text = plainTextFromHTML(content)
        let lines = text.components(separatedBy: .newlines)
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func extractHTMLImagePaths(from content: String, relativeTo fileURL: URL) -> [String] {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var paths: [String] = []
        for match in htmlImageRegex.matches(in: content, options: [], range: range) {
            guard let urlRange = Range(match.range(at: 1), in: content) else { continue }
            let src = String(content[urlRange])
            if src.hasPrefix("http://") || src.hasPrefix("https://") { continue }
            let resolved = URL(string: src, relativeTo: fileURL.deletingLastPathComponent())?.path ?? src
            paths.append(resolved)
        }
        return paths
    }

    private static func plainTextFromHTML(_ html: String) -> String {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let noBlocks = htmlBlockRegex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "\n")
        let noTagsRange = NSRange(noBlocks.startIndex..<noBlocks.endIndex, in: noBlocks)
        let noTags = htmlTagRegex.stringByReplacingMatches(in: noBlocks, options: [], range: noTagsRange, withTemplate: " ")
        return noTags.decodingHTMLEntities()
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func fileDates(_ fileURL: URL) -> (created: Date, modified: Date) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = attrs?[.modificationDate] as? Date ?? Date()
        let created = attrs?[.creationDate] as? Date ?? modified
        return (created, modified)
    }

    // MARK: - Vault URL

    private static func resolveVaultURL() async -> URL {
        // Use Notes.md's own resolution so we always scan the same vault the user sees.
        await NotesViewModel.resolveVaultURL()
    }

    // MARK: - File enumeration

    private static func enumerator(at url: URL, handler: (URL) -> Void) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let itemURL as URL in enumerator {
            let resources = try? itemURL.resourceValues(forKeys: keys)
            // Never follow symlinks: the AI Memory tree or other linked stores can
            // contain tens of thousands of unrelated files.
            guard resources?.isSymbolicLink != true else { continue }
            guard resources?.isRegularFile == true else { continue }
            handler(itemURL)
        }
    }

    /// Inexpensive pre-filter: read raw data and check whether any monitored tag
    /// string is present. This avoids String construction + regex for the vast
    /// majority of vault files that have no publishing tags.
    private static func fileMightContainMonitoredTags(_ fileURL: URL, monitored: Set<String>) -> Bool {
        guard monitored.isEmpty == false else { return true }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return true }
        guard let text = String(data: data, encoding: utf8) else { return true }
        let lower = text.lowercased()
        return monitored.contains { lower.contains("#\($0)") }
    }
}

// MARK: - HTML entity decoding

private extension String {
    func decodingHTMLEntities() -> String {
        var result = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}
