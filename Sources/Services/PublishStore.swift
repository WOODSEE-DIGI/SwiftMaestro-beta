import Foundation
import SwiftUI

/// Central store for the Publish app.
/// Tracks draft content across SwiftMaestro apps, manages monitored tags,
/// and records publishing history.
@Observable
@MainActor
final class PublishStore {

    static let shared = PublishStore()

    private(set) var tags: [PublishTag] = []
    internal(set) var drafts: [PublishDraft] = []
    private(set) var history: [PublishHistoryEntry] = []
    internal(set) var feeds: [PublishFeed] = []
    internal(set) var neocitiesConfigs: [NeocitiesConfig] = []
    private(set) var isScanning = false
    internal(set) var lastError: String?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var tagsURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("tags.json") }
    private var draftsURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("drafts.json") }
    private var historyURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("history.json") }
    private var feedsURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("feeds.json") }
    private var neocitiesURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("neocities.json") }

    /// Default system tags the Publish app monitors. Users can rename these,
    /// but their workflow role (and therefore kanban column mapping) stays fixed.
    static let defaultSystemTags = [
        PublishTag(name: "draft", isSystem: true, role: .draft, color: .gray),
        PublishTag(name: "publish", isSystem: true, role: .publish, color: .blue),
        PublishTag(name: "published", isSystem: true, role: .published, color: .green),
        PublishTag(name: "review", isSystem: true, role: .review, color: .yellow)
    ]

    static let defaultFeed = PublishFeed(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "SwiftMaestro Feed"
    )

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
        ensureSystemTags()
        _ = PublishMaestroDBBridge.shared
    }

    // MARK: - Persistence

    private func load() {
        tags = loadJSON(url: tagsURL, defaultValue: Self.defaultSystemTags)
        drafts = loadJSON(url: draftsURL, defaultValue: [])
        history = loadJSON(url: historyURL, defaultValue: [])
        feeds = loadJSON(url: feedsURL, defaultValue: [Self.defaultFeed])
        neocitiesConfigs = loadJSON(url: neocitiesURL, defaultValue: [])
    }

    private func loadJSON<T: Codable>(url: URL, defaultValue: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        return (try? decoder.decode(T.self, from: data)) ?? defaultValue
    }

    func saveTags() {
        saveJSON(tags, url: tagsURL)
    }

    func saveDrafts() {
        saveJSON(drafts, url: draftsURL)
    }

    func saveHistory() {
        saveJSON(history, url: historyURL)
    }

    func saveFeeds() {
        saveJSON(feeds, url: feedsURL)
    }

    func saveNeocitiesConfigs() {
        saveJSON(neocitiesConfigs, url: neocitiesURL)
    }

    func addNeocitiesConfig(_ config: NeocitiesConfig) {
        neocitiesConfigs.append(config)
        saveNeocitiesConfigs()
    }

    func updateNeocitiesConfig(_ config: NeocitiesConfig) {
        guard let index = neocitiesConfigs.firstIndex(where: { $0.id == config.id }) else { return }
        neocitiesConfigs[index] = config
        saveNeocitiesConfigs()
    }

    func removeNeocitiesConfig(id: UUID) {
        neocitiesConfigs.removeAll { $0.id == id }
        saveNeocitiesConfigs()
    }

    private func saveJSON<T: Codable>(_ value: T, url: URL) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSLog("[PUBLISH] save failed at \(url.path): \(error)")
        }
    }

    private func ensureSystemTags() {
        var updated = tags

        // Ensure every system role is represented. This also migrates legacy
        // system tags that may be missing a role/color after the edit feature
        // was introduced.
        for defaultTag in Self.defaultSystemTags {
            let hasRole = updated.contains { $0.isSystem && $0.role == defaultTag.role }
            if let index = updated.firstIndex(where: { $0.id == defaultTag.id }) {
                updated[index].isSystem = true
                updated[index].role = defaultTag.role
                if updated[index].color == nil {
                    updated[index].color = defaultTag.color
                }
            } else if !hasRole {
                updated.append(defaultTag)
            }
        }

        tags = updated
        saveTags()
    }

    // MARK: - Scanning

    /// Rescan all configured sources and merge discovered drafts with existing state.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let monitored = Set(tags.map(\.name))

        // Run all source adapters concurrently off the main actor.
        let discovered = await withTaskGroup(of: [PublishDraft].self) { group in
            group.addTask { await PublishVaultSource.scan(monitoredTags: monitored) }
            group.addTask { await PublishMaestroDBSource.scan(monitoredTags: monitored) }
            group.addTask { await PublishDAMSource.scan(monitoredTags: monitored) }
            group.addTask { await PublishKnowledgeSource.scan(monitoredTags: monitored) }
            group.addTask { await PublishPlansSource.scan(monitoredTags: monitored) }

            var combined: [PublishDraft] = []
            for await result in group {
                combined.append(contentsOf: result)
            }
            return combined
        }

        // Merge with existing drafts so user-set status/history is preserved.
        var mergedByID: [String: PublishDraft] = [:]
        for draft in drafts {
            mergedByID[draft.id] = draft
        }
        for draft in discovered {
            let derivedStatus = PublishStatus.derived(from: Set(draft.tags), registry: tags)
            if let existing = mergedByID[draft.id] {
                var updated = existing
                updated.title = draft.title
                updated.summary = draft.summary
                updated.bodyMarkdown = draft.bodyMarkdown
                updated.bodyHTML = draft.bodyHTML
                updated.tags = draft.tags
                updated.modifiedAt = draft.modifiedAt
                updated.assetPaths = draft.assetPaths
                updated.linkedSourcePaths = draft.linkedSourcePaths

                // Tags drive status for new drafts and can promote a draft to a
                // more advanced column, but never demote a user-set status.
                let promoteFromDraft = existing.status == .draft && derivedStatus != .draft
                let tagSaysPublished = derivedStatus == .published
                if tagSaysPublished || promoteFromDraft {
                    updated.status = derivedStatus
                }

                mergedByID[draft.id] = updated
            } else {
                var newDraft = draft
                newDraft.status = derivedStatus
                mergedByID[draft.id] = newDraft
            }
        }

        // Prune automatic-source drafts that are no longer discovered (e.g. the
        // monitored tag was removed or renamed). Manual/archived sources are left untouched.
        let discoveredIDs = Set(discovered.map(\.id))
        let automaticSourceKinds: Set<PublishSourceKind> = [
            .notesMD, .maestroDB, .dam, .knowledge, .plan,
            .swiftWeaver, .maestroDocs, .appleNotes, .chat
        ]
        for draft in drafts where automaticSourceKinds.contains(draft.sourceKind) && !discoveredIDs.contains(draft.id) {
            mergedByID.removeValue(forKey: draft.id)
        }

        drafts = Array(mergedByID.values).sorted { $0.modifiedAt > $1.modifiedAt }
        saveDrafts()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    // MARK: - Tags

    func addTag(name: String) {
        let tag = PublishTag(name: name)
        guard !tags.contains(where: { $0.id == tag.id }) else { return }
        tags.append(tag)
        saveTags()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func updateTag(_ tag: PublishTag, newName: String, newColor: KanbanColumnColor?) {
        let trimmed = newName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let newID = trimmed
        guard newID == tag.id || !tags.contains(where: { $0.id == newID }) else {
            lastError = String(localized: "A tag with that name already exists.")
            return
        }
        guard let index = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        tags[index].name = trimmed
        tags[index].color = newColor
        saveTags()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func removeTag(name: String) {
        guard let index = tags.firstIndex(where: { $0.name == name.lowercased() }) else { return }
        guard !tags[index].isSystem else {
            lastError = String(localized: "System tags cannot be removed.")
            return
        }
        tags.remove(at: index)
        saveTags()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func setTagColor(name: String, color: KanbanColumnColor?) {
        guard let index = tags.firstIndex(where: { $0.name == name.lowercased() }) else { return }
        tags[index].color = color
        saveTags()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    // MARK: - Feeds

    func addFeed(name: String, outputDirectory: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let feed = PublishFeed(name: trimmed, outputDirectory: outputDirectory)
        feeds.append(feed)
        saveFeeds()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func updateFeed(_ feed: PublishFeed, newName: String, newOutputDirectory: String?) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let index = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[index].name = trimmed
        feeds[index].outputDirectory = newOutputDirectory
        saveFeeds()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func removeFeed(id: UUID) {
        guard id != Self.defaultFeed.id else {
            lastError = String(localized: "The default feed cannot be removed.")
            return
        }
        feeds.removeAll { $0.id == id }
        saveFeeds()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func feed(id: UUID) -> PublishFeed {
        feeds.first { $0.id == id } ?? Self.defaultFeed
    }

    // MARK: - Drafts

    func setStatus(draftID: String, to status: PublishStatus) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[index].status = status
        drafts[index].modifiedAt = Date()
        if status == .published, drafts[index].publishedAt == nil {
            drafts[index].publishedAt = Date()
        }
        saveDrafts()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func updateDraft(_ draft: PublishDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        var updated = draft
        updated.modifiedAt = Date()
        drafts[index] = updated
        saveDrafts()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func deleteDraft(draftID: String) {
        drafts.removeAll { $0.id == draftID }
        saveDrafts()
        PublishMaestroDBBridge.shared.pushToDB()
    }

    func drafts(withStatus status: PublishStatus) -> [PublishDraft] {
        drafts.filter { $0.status == status }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Publishing

    /// Publish a single draft to a feed file on disk.
    /// - Returns: the path of the generated feed file, or nil on failure.
    @discardableResult
    func publish(draftID: String, feedID: UUID? = nil) -> String? {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return nil }
        let draft = drafts[index]
        let feed = feed(id: feedID ?? Self.defaultFeed.id)

        do {
            let outputURL = try feedOutputURL(for: feed)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let writtenURL = try PublishFeedGenerator.writeFeed(
                feedName: feed.name,
                outputURL: outputURL,
                drafts: [draft],
                history: history.filter { $0.feedID == feed.id || $0.feedName == feed.name }
            )

            let entry = PublishHistoryEntry(
                draftID: draft.id,
                title: draft.title,
                feedID: feed.id,
                feedName: feed.name,
                outputPath: writtenURL.path
            )
            history.append(entry)
            saveHistory()

            drafts[index].status = .published
            drafts[index].publishedAt = Date()
            drafts[index].modifiedAt = Date()
            drafts[index].feedID = feed.id
            saveDrafts()

            lastError = nil
            PublishMaestroDBBridge.shared.pushToDB()
            return writtenURL.path
        } catch {
            lastError = error.localizedDescription
            NSLog("[PUBLISH] publish failed: \(error)")
            return nil
        }
    }

    /// Publish a single draft as a static HTML file to a Neocities site.
    /// - Returns: the remote path uploaded, or nil on failure.
    @discardableResult
    func publishToNeocities(draftID: String, configID: UUID) async -> String? {
        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else { return nil }
        guard let config = neocitiesConfigs.first(where: { $0.id == configID }) else {
            lastError = String(localized: "Neocities destination not found.")
            return nil
        }

        do {
            guard let apiKey = try KeychainService.read(account: config.apiKeySecretName, allowUI: false) else {
                lastError = String(localized: "Neocities API key not found in keychain.")
                return nil
            }

            let filename = "\(slugify(drafts[draftIndex].title)).html"
            let remotePath = config.remotePath(for: filename)
            let html = drafts[draftIndex].bodyHTML.isEmpty
                ? drafts[draftIndex].bodyMarkdown
                : drafts[draftIndex].bodyHTML
            guard let data = html.data(using: .utf8) else {
                lastError = String(localized: "Failed to encode draft as HTML.")
                return nil
            }

            let result = try await NeocitiesAPIClient.upload(
                sitename: config.sitename,
                apiKey: apiKey,
                path: remotePath,
                data: data,
                mimeType: "text/html"
            )

            drafts[draftIndex].status = .published
            drafts[draftIndex].publishedAt = Date()
            drafts[draftIndex].modifiedAt = Date()
            saveDrafts()

            lastError = nil
            PublishMaestroDBBridge.shared.pushToDB()
            return result.path
        } catch {
            lastError = error.localizedDescription
            NSLog("[PUBLISH] Neocities upload failed: \(error)")
            return nil
        }
    }

    private func slugify(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = text.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String(slug.prefix(80))
    }

    /// Upload arbitrary HTML to a Neocities destination. Used by SwiftWeaver
    /// to publish pages that are not yet Publish drafts.
    /// - Returns: the remote path uploaded, or nil on failure.
    @discardableResult
    func uploadHTMLToNeocities(configID: UUID, filename: String, html: String) async -> String? {
        guard let config = neocitiesConfigs.first(where: { $0.id == configID }) else {
            lastError = String(localized: "Neocities destination not found.")
            return nil
        }

        do {
            guard let apiKey = try KeychainService.read(account: config.apiKeySecretName, allowUI: false) else {
                lastError = String(localized: "Neocities API key not found in keychain.")
                return nil
            }

            let safeFilename = filename.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let remotePath = config.remotePath(for: safeFilename)
            guard let data = html.data(using: .utf8) else {
                lastError = String(localized: "Failed to encode HTML as UTF-8.")
                return nil
            }

            let result = try await NeocitiesAPIClient.upload(
                sitename: config.sitename,
                apiKey: apiKey,
                path: remotePath,
                data: data,
                mimeType: "text/html"
            )
            lastError = nil
            return result.path
        } catch {
            lastError = error.localizedDescription
            NSLog("[PUBLISH] Neocities HTML upload failed: \(error)")
            return nil
        }
    }

    /// Regenerate a feed from all published drafts currently in that feed.
    func regenerateFeed(feedID: UUID) throws -> URL {
        let feed = feed(id: feedID)
        let outputURL = try feedOutputURL(for: feed)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let feedDrafts = drafts.filter { $0.status == .published }
        return try PublishFeedGenerator.writeFeed(
            feedName: feed.name,
            outputURL: outputURL,
            drafts: feedDrafts,
            history: history.filter { $0.feedID == feed.id || $0.feedName == feed.name }
        )
    }

    private func feedOutputURL(for feed: PublishFeed) throws -> URL {
        if let directory = feed.outputDirectory {
            let dirURL = URL(fileURLWithPath: directory)
            let slug = feed.name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            return dirURL.appendingPathComponent("\(slug).rss")
        }
        return PublishFeedGenerator.defaultOutputURL(feedName: feed.name)
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }
}
