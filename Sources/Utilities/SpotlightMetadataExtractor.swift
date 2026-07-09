import Foundation
import CoreServices

/// Extracts file metadata using native macOS Spotlight APIs (`NSMetadataItem`,
/// `NSMetadataQuery`). This provides rich metadata (content type, size, dates,
/// dimensions, Finder tags, color labels, etc.) WITHOUT reading file contents
/// or spawning subprocesses — making it fast even for large directories.
///
/// Replaces the previous `mdls`/`mdfind` CLI approach with direct framework calls.
enum SpotlightMetadataExtractor {

    // MARK: - Metadata model

    /// Metadata extracted for a single file via Spotlight.
    struct FileMetadata: Codable {
        let path: String
        let name: String
        let contentType: String?
        let kind: String?
        let sizeBytes: Int64?
        let created: Date?
        let modified: Date?
        let dimensions: String?       // e.g. "1920 x 1080" for images/video
        let duration: String?          // e.g. "00:03:45" for audio/video
        let pageCount: Int?            // for PDFs
        let wordCount: Int?            // for text documents
        let authors: [String]?
        let title: String?
        let comment: String?
        let keywords: [String]?
        let finderTags: [String]?      // Finder color tags (e.g. ["Red", "Work"])
        let colorLabel: Int?           // 0=none, 1=orange, 2=red, 3=yellow, 4=blue, 5=purple, 6=green, 7=gray
        let audioSampleRate: Double?
        let audioChannelCount: Int?
        let videoCodec: String?
        let hasAlphaChannel: Bool?
        let orientation: Int?
        let latitude: Double?
        let longitude: Double?
        let city: String?
        let country: String?
    }

    // MARK: - Single file extraction

    /// Extract metadata for a single file using `NSMetadataItem`. Returns nil if
    /// the file doesn't exist or Spotlight has no metadata for it.
    static func extract(for path: String) -> FileMetadata? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let url = URL(fileURLWithPath: path)
        guard let item = NSMetadataItem(url: url) else { return nil }

        return buildMetadata(from: item, path: path, url: url)
    }

    /// Extract metadata for multiple files in a single directory using
    /// `NSMetadataQuery`. Much faster than per-file `NSMetadataItem` calls
    /// because Spotlight serves all results from its database in one query.
    /// Returns a dictionary keyed by file path.
    static func extractBatch(for paths: [String]) -> [String: FileMetadata] {
        guard !paths.isEmpty else { return [:] }

        // Group files by parent directory for efficient querying
        var byParent: [String: [String]] = [:]
        for path in paths {
            let parent = (path as NSString).deletingLastPathComponent
            byParent[parent, default: []].append(path)
        }

        var results: [String: FileMetadata] = [:]

        for (parentDir, childPaths) in byParent {
            let query = NSMetadataQuery()
            query.searchScopes = [parentDir]

            // Build predicate: match any of the file names in this directory
            let names = childPaths.map { ($0 as NSString).lastPathComponent }
            let namePredicates = names.map { name in
                NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, name)
            }
            guard let compound = NSCompoundPredicate(orPredicateWithSubpredicates: namePredicates) as NSPredicate? else { continue }
            query.predicate = compound

            let sema = DispatchSemaphore(value: 0)
            var gatheredItems: [NSMetadataItem] = []

            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { _ in
                gatheredItems = query.results.compactMap { $0 as? NSMetadataItem }
                sema.signal()
            }

            guard query.start() else { continue }
            _ = sema.wait(timeout: .now() + 5.0)
            query.stop()

            for item in gatheredItems {
                guard let itemPath = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let url = URL(fileURLWithPath: itemPath)
                let meta = buildMetadata(from: item, path: itemPath, url: url)
                results[itemPath] = meta
            }
        }

        return results
    }

    // MARK: - Spotlight search

    /// Search Spotlight for files matching a query string within a directory.
    /// Uses `NSMetadataQuery` natively — no subprocess.
    /// Returns matching file paths.
    static func search(in directory: String, query: String) -> [String] {
        let metaQuery = NSMetadataQuery()
        metaQuery.searchScopes = [directory]

        // Support both simple text queries and NSPredicate-style queries
        let predicate: NSPredicate
        if query.contains("==") || query.contains("!=") || query.contains(">=") || query.contains("<=") || query.contains("CONTAINS") || query.contains("BEGINSWITH") {
            // Already a predicate format string
            predicate = NSPredicate(format: query)
        } else {
            // Simple text search — match against display name or content
            predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemDisplayNameKey, query)
        }
        metaQuery.predicate = predicate

        let sema = DispatchSemaphore(value: 0)
        var results: [String] = []

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: metaQuery,
            queue: .main
        ) { _ in
            results = metaQuery.results.compactMap { item in
                (item as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
            }
            sema.signal()
        }

        guard metaQuery.start() else { return [] }
        _ = sema.wait(timeout: .now() + 10.0)
        metaQuery.stop()

        return results
    }

    // MARK: - Build metadata from NSMetadataItem

    private static func buildMetadata(from item: NSMetadataItem, path: String, url: URL) -> FileMetadata {
        let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String
            ?? (path as NSString).lastPathComponent

        let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        let kind = item.value(forAttribute: NSMetadataItemKindKey) as? String

        let sizeBytes = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value

        let created = item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date
        let modified = item.value(forAttribute: NSMetadataItemContentModificationDateKey) as? Date

        let pixelHeight = (item.value(forAttribute: NSMetadataItemPixelHeightKey) as? NSNumber)?.intValue
        let pixelWidth = (item.value(forAttribute: NSMetadataItemPixelWidthKey) as? NSNumber)?.intValue

        let durationSeconds = (item.value(forAttribute: NSMetadataItemDurationSecondsKey) as? NSNumber)?.doubleValue
        let pageCount = (item.value(forAttribute: "kMDItemPageCount") as? NSNumber)?.intValue
        let wordCount = (item.value(forAttribute: "kMDItemWordCount") as? NSNumber)?.intValue

        let authors = item.value(forAttribute: NSMetadataItemAuthorsKey) as? [String]
        let title = item.value(forAttribute: NSMetadataItemTitleKey) as? String
        let comment = item.value(forAttribute: NSMetadataItemCommentKey) as? String
        let keywords = item.value(forAttribute: NSMetadataItemKeywordsKey) as? [String]

        // Audio/video metadata
        let audioSampleRate = (item.value(forAttribute: NSMetadataItemAudioSampleRateKey) as? NSNumber)?.doubleValue
        let audioChannelCount = (item.value(forAttribute: NSMetadataItemAudioChannelCountKey) as? NSNumber)?.intValue
        let videoCodec = (item.value(forAttribute: "kMDItemVideoCodecs") as? [String])?.first
        let hasAlphaChannel = item.value(forAttribute: NSMetadataItemHasAlphaChannelKey) as? Bool
        let orientation = (item.value(forAttribute: NSMetadataItemOrientationKey) as? NSNumber)?.intValue

        // GPS metadata
        let latitude = (item.value(forAttribute: NSMetadataItemLatitudeKey) as? NSNumber)?.doubleValue
        let longitude = (item.value(forAttribute: NSMetadataItemLongitudeKey) as? NSNumber)?.doubleValue
        let city = item.value(forAttribute: NSMetadataItemCityKey) as? String
        let country = item.value(forAttribute: NSMetadataItemCountryKey) as? String

        // Finder tags from URL resource values
        let resourceValues = try? url.resourceValues(forKeys: [.tagNamesKey])
        let finderTags = resourceValues?.tagNames

        // Finder color label from Spotlight metadata (kMDItemFSLabel: 0=none, 1-7=colors)
        let colorLabel = (item.value(forAttribute: "kMDItemFSLabel") as? NSNumber)?.intValue

        // Compute derived fields
        var dimensions: String?
        if let h = pixelHeight, let w = pixelWidth {
            dimensions = "\(w) x \(h)"
        }

        var duration: String?
        if let secs = durationSeconds {
            let totalSeconds = Int(secs)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            if hours > 0 {
                duration = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            } else {
                duration = String(format: "%02d:%02d", minutes, seconds)
            }
        }

        return FileMetadata(
            path: path,
            name: name,
            contentType: contentType,
            kind: kind,
            sizeBytes: sizeBytes,
            created: created,
            modified: modified,
            dimensions: dimensions,
            duration: duration,
            pageCount: pageCount,
            wordCount: wordCount,
            authors: authors,
            title: title,
            comment: comment,
            keywords: keywords,
            finderTags: finderTags,
            colorLabel: colorLabel,
            audioSampleRate: audioSampleRate,
            audioChannelCount: audioChannelCount,
            videoCodec: videoCodec,
            hasAlphaChannel: hasAlphaChannel,
            orientation: orientation,
            latitude: latitude,
            longitude: longitude,
            city: city,
            country: country
        )
    }

    // MARK: - Summarization

    /// Format a human-readable summary of file metadata for the agent.
    static func summarize(_ metadata: FileMetadata) -> String {
        var parts: [String] = []
        parts.append(metadata.name)

        if let kind = metadata.kind {
            parts.append("(\(kind))")
        }

        if let size = metadata.sizeBytes {
            parts.append(formatBytes(size))
        }

        if let dimensions = metadata.dimensions {
            parts.append("[\(dimensions)]")
        }

        if let duration = metadata.duration {
            parts.append("[\(duration)]")
        }

        if let pageCount = metadata.pageCount {
            parts.append("(\(pageCount) pages)")
        }

        if let wordCount = metadata.wordCount {
            parts.append("(\(wordCount) words)")
        }

        if let tags = metadata.finderTags, !tags.isEmpty {
            parts.append("tags: \(tags.joined(separator: ", "))")
        }

        if let colorLabel = metadata.colorLabel, colorLabel > 0 {
            let colorNames = ["", "Orange", "Red", "Yellow", "Blue", "Purple", "Green", "Gray"]
            let colorName = colorLabel >= 1 && colorLabel <= 7 ? colorNames[colorLabel] : "Unknown"
            parts.append("color: \(colorName)")
        }

        if let title = metadata.title, title != metadata.name {
            parts.append("title: \(title)")
        }

        if let authors = metadata.authors, !authors.isEmpty {
            parts.append("by: \(authors.joined(separator: ", "))")
        }

        if let modified = metadata.modified {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            parts.append("modified: \(df.string(from: modified))")
        }

        if let city = metadata.city, let country = metadata.country {
            parts.append("location: \(city), \(country)")
        }

        return parts.joined(separator: " ")
    }

    /// Return a detailed JSON-compatible dictionary of all metadata fields
    /// that have values. Used by the `spotlight_search` tool for rich results.
    static func detailedDict(_ metadata: FileMetadata) -> [String: Any] {
        var dict: [String: Any] = [
            "path": metadata.path,
            "name": metadata.name,
        ]
        if let v = metadata.contentType { dict["contentType"] = v }
        if let v = metadata.kind { dict["kind"] = v }
        if let v = metadata.sizeBytes { dict["sizeBytes"] = v }
        if let v = metadata.created { dict["created"] = ISO8601DateFormatter().string(from: v) }
        if let v = metadata.modified { dict["modified"] = ISO8601DateFormatter().string(from: v) }
        if let v = metadata.dimensions { dict["dimensions"] = v }
        if let v = metadata.duration { dict["duration"] = v }
        if let v = metadata.pageCount { dict["pageCount"] = v }
        if let v = metadata.wordCount { dict["wordCount"] = v }
        if let v = metadata.authors, !v.isEmpty { dict["authors"] = v }
        if let v = metadata.title { dict["title"] = v }
        if let v = metadata.comment { dict["comment"] = v }
        if let v = metadata.keywords, !v.isEmpty { dict["keywords"] = v }
        if let v = metadata.finderTags, !v.isEmpty { dict["finderTags"] = v }
        if let v = metadata.colorLabel { dict["colorLabel"] = v }
        if let v = metadata.audioSampleRate { dict["audioSampleRate"] = v }
        if let v = metadata.audioChannelCount { dict["audioChannelCount"] = v }
        if let v = metadata.videoCodec { dict["videoCodec"] = v }
        if let v = metadata.hasAlphaChannel { dict["hasAlphaChannel"] = v }
        if let v = metadata.orientation { dict["orientation"] = v }
        if let v = metadata.latitude { dict["latitude"] = v }
        if let v = metadata.longitude { dict["longitude"] = v }
        if let v = metadata.city { dict["city"] = v }
        if let v = metadata.country { dict["country"] = v }
        return dict
    }

    // MARK: - Helpers

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
