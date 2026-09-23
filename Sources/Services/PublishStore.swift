import Foundation
import SwiftUI
import MLXLMCommon

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
    internal(set) var socialDestinations: [SocialDestinationConfig] = []
    internal(set) var socialHistory: [SocialPostHistoryEntry] = []
    private(set) var isScanning = false
    internal(set) var lastError: String?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var tagsURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("tags.json") }
    private var draftsURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("drafts.json") }
    private var historyURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("history.json") }
    private var feedsURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("feeds.json") }
    private var neocitiesURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("neocities.json") }
    private var socialDestinationsURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("socialDestinations.json") }
    private var socialHistoryURL: URL { SwiftMaestroPaths.publishDir.appendingPathComponent("socialHistory.json") }

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
        socialDestinations = loadJSON(url: socialDestinationsURL, defaultValue: [])
        socialHistory = loadJSON(url: socialHistoryURL, defaultValue: [])
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

    // MARK: - Social destinations

    func saveSocialDestinations() {
        saveJSON(socialDestinations, url: socialDestinationsURL)
    }

    func saveSocialHistory() {
        saveJSON(socialHistory, url: socialHistoryURL)
    }

    func addSocialDestination(_ destination: SocialDestinationConfig) {
        socialDestinations.append(destination)
        saveSocialDestinations()
    }

    func updateSocialDestination(_ destination: SocialDestinationConfig) {
        guard let index = socialDestinations.firstIndex(where: { $0.id == destination.id }) else { return }
        socialDestinations[index] = destination
        saveSocialDestinations()
    }

    func removeSocialDestination(id: UUID) {
        socialDestinations.removeAll { $0.id == id }
        saveSocialDestinations()
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

    // MARK: - Social cross-posting

    /// Cross-post a single draft to the selected social destinations.
    /// - Returns: one result per destination attempted.
    func crossPost(draftID: String, destinationIDs: [UUID]) async -> [CrossPostResult] {
        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else { return [] }
        let draft = drafts[draftIndex]
        var results: [CrossPostResult] = []

        for destinationID in destinationIDs {
            guard let destination = socialDestinations.first(where: { $0.id == destinationID && $0.isEnabled }) else { continue }

            let text = SocialCrossPostFormatter.text(for: draft, platform: destination.platform)
            let call: ToolCall

            switch destination.platform {
            case .bluesky:
                call = ToolCall(function: .init(name: "post_bluesky", arguments: ["text": text]))
            case .mastodon:
                call = ToolCall(function: .init(name: "post_mastodon", arguments: [
                    "text": text,
                    "server_url": destination.normalizedServerURL ?? "",
                    "secret_name": destination.secretName,
                ]))
            case .facebook:
                call = ToolCall(function: .init(name: "post_facebook_page", arguments: [
                    "text": text,
                    "page_id": destination.accountIdentifier ?? "",
                    "secret_name": destination.secretName,
                ]))
            case .threads:
                call = ToolCall(function: .init(name: "post_threads", arguments: [
                    "text": text,
                    "user_id": destination.accountIdentifier ?? "",
                    "secret_name": destination.secretName,
                ]))
            case .twitter:
                call = ToolCall(function: .init(name: "post_twitter", arguments: [
                    "text": text,
                    "secret_name": destination.secretName,
                ]))
            case .linkedin:
                call = ToolCall(function: .init(name: "post_linkedin", arguments: [
                    "text": text,
                    "author_urn": destination.accountIdentifier ?? "",
                    "secret_name": destination.secretName,
                ]))
            case .patreon:
                results.append(CrossPostResult(
                    destinationID: destination.id,
                    platform: destination.platform,
                    label: destination.label,
                    success: false,
                    message: String(localized: "Patreon does not expose a post-creation API.")))
                continue
            case .instagram:
                guard let mediaURL = await instagramMediaURL(for: draft) else {
                    results.append(CrossPostResult(
                        destinationID: destination.id,
                        platform: destination.platform,
                        label: destination.label,
                        success: false,
                        message: String(localized: "Instagram needs an image/video asset and a Neocities destination to host it temporarily.")))
                    continue
                }
                call = ToolCall(function: .init(name: "post_instagram", arguments: [
                    "caption": text,
                    "user_id": destination.accountIdentifier ?? "",
                    "secret_name": destination.secretName,
                    "media_url": mediaURL.url,
                    "media_type": mediaURL.mediaType,
                ]))
            case .tumblr:
                results.append(CrossPostResult(
                    destinationID: destination.id,
                    platform: destination.platform,
                    label: destination.label,
                    success: false,
                    message: String(localized: "Tumblr posting requires OAuth 1.0a and is not supported yet.")))
                continue
            case .youtube:
                guard let videoPath = draft.assetPaths.first(where: { isVideoFile($0) }) else {
                    results.append(CrossPostResult(
                        destinationID: destination.id,
                        platform: destination.platform,
                        label: destination.label,
                        success: false,
                        message: String(localized: "YouTube upload requires a video asset attached to the draft.")))
                    continue
                }
                call = ToolCall(function: .init(name: "upload_youtube_video", arguments: [
                    "video_path": videoPath,
                    "title": draft.title,
                    "description": text,
                    "privacy_status": "unlisted",
                    "secret_name": destination.secretName,
                ]))
            case .vimeo:
                guard let videoPath = draft.assetPaths.first(where: { isVideoFile($0) }) else {
                    results.append(CrossPostResult(
                        destinationID: destination.id,
                        platform: destination.platform,
                        label: destination.label,
                        success: false,
                        message: String(localized: "Vimeo upload requires a video asset attached to the draft.")))
                    continue
                }
                call = ToolCall(function: .init(name: "upload_vimeo_video", arguments: [
                    "video_path": videoPath,
                    "title": draft.title,
                    "description": text,
                    "privacy": "unlisted",
                    "secret_name": destination.secretName,
                ]))
            case .dailymotion:
                guard let videoPath = draft.assetPaths.first(where: { isVideoFile($0) }) else {
                    results.append(CrossPostResult(
                        destinationID: destination.id,
                        platform: destination.platform,
                        label: destination.label,
                        success: false,
                        message: String(localized: "Dailymotion upload requires a video asset attached to the draft.")))
                    continue
                }
                call = ToolCall(function: .init(name: "upload_dailymotion_video", arguments: [
                    "video_path": videoPath,
                    "title": draft.title,
                    "description": text,
                    "profile_id": destination.accountIdentifier ?? "",
                    "secret_name": destination.secretName,
                ]))
            case .peertube:
                guard let videoPath = draft.assetPaths.first(where: { isVideoFile($0) }) else {
                    results.append(CrossPostResult(
                        destinationID: destination.id,
                        platform: destination.platform,
                        label: destination.label,
                        success: false,
                        message: String(localized: "PeerTube upload requires a video asset attached to the draft.")))
                    continue
                }
                call = ToolCall(function: .init(name: "upload_peertube_video", arguments: [
                    "video_path": videoPath,
                    "title": draft.title,
                    "description": text,
                    "instance_url": destination.normalizedServerURL ?? destination.accountIdentifier ?? "",
                    "secret_name": destination.secretName,
                ]))
            case .tiktok:
                guard let videoPath = draft.assetPaths.first(where: { isVideoFile($0) }) else {
                    results.append(CrossPostResult(
                        destinationID: destination.id,
                        platform: destination.platform,
                        label: destination.label,
                        success: false,
                        message: String(localized: "TikTok upload requires a video asset attached to the draft.")))
                    continue
                }
                call = ToolCall(function: .init(name: "upload_tiktok_video", arguments: [
                    "video_path": videoPath,
                    "title": draft.title,
                    "privacy_level": "SELF_ONLY",
                    "secret_name": destination.secretName,
                ]))
            case .vk:
                guard let videoPath = draft.assetPaths.first(where: { isVideoFile($0) }) else {
                    results.append(CrossPostResult(
                        destinationID: destination.id,
                        platform: destination.platform,
                        label: destination.label,
                        success: false,
                        message: String(localized: "VK Video upload requires a video asset attached to the draft.")))
                    continue
                }
                call = ToolCall(function: .init(name: "upload_vk_video", arguments: [
                    "video_path": videoPath,
                    "title": draft.title,
                    "description": text,
                    "group_id": destination.accountIdentifier ?? "",
                    "secret_name": destination.secretName,
                ]))
            }

            let output = await MaestroTools.execute(call)
            let (success, message, postedURL) = Self.parseCrossPostOutput(output, platform: destination.platform)

            results.append(CrossPostResult(
                destinationID: destination.id,
                platform: destination.platform,
                label: destination.label,
                success: success,
                message: message,
                postedURL: postedURL
            ))

            socialHistory.append(SocialPostHistoryEntry(
                draftID: draft.id,
                draftTitle: draft.title,
                destinationID: destination.id,
                platform: destination.platform,
                label: destination.label,
                success: success,
                message: message,
                postedURL: postedURL
            ))

            if success {
                drafts[draftIndex].modifiedAt = Date()
            }
        }

        saveSocialHistory()
        saveDrafts()
        PublishMaestroDBBridge.shared.pushToDB()
        return results
    }

    private static func parseCrossPostOutput(_ output: String, platform: SocialPlatform) -> (success: Bool, message: String, url: String?) {
        // Tool errors are emitted as JSON containing an `error` key.
        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            return (false, error, nil)
        }

        var url: String?
        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let posted = object["posted"] as? Bool, posted {
                url = object["url"] as? String ?? object["uri"] as? String
                return (true, "Posted to \(platform.displayName).", url)
            }
        }

        return (true, output, nil)
    }
}

// MARK: - Instagram media upload helper

private extension PublishStore {
    struct InstagramMediaURL {
        let url: String
        let mediaType: String
    }

    private func isVideoFile(_ path: String) -> Bool {
        let videoExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv"])
        return videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Uploads the first suitable image/video asset from a draft to the first
    /// configured Neocities site and returns a public HTTPS URL that Instagram
    /// can fetch. Returns nil if no asset or no Neocities destination exists.
    func instagramMediaURL(for draft: PublishDraft) async -> InstagramMediaURL? {
        guard let config = neocitiesConfigs.first else { return nil }
        guard let apiKey = try? KeychainService.read(account: config.apiKeySecretName, allowUI: false),
              !apiKey.isEmpty else { return nil }

        let supportedImage = Set(["jpg", "jpeg", "png", "heic", "heif", "webp"])
        let supportedVideo = Set(["mp4", "mov", "m4v"])

        for path in draft.assetPaths {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            guard supportedImage.contains(ext) || supportedVideo.contains(ext) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }

            let mimeType: String
            if supportedImage.contains(ext) {
                mimeType = "image/\(ext == "jpg" ? "jpeg" : ext)"
            } else {
                mimeType = "video/mp4"
            }

            let filename = "\(UUID().uuidString)-\(url.lastPathComponent)"
            let remotePath = config.remotePath(for: filename)

            do {
                _ = try await NeocitiesAPIClient.upload(
                    sitename: config.sitename,
                    apiKey: apiKey,
                    path: remotePath,
                    data: data,
                    mimeType: mimeType
                )
                let publicURL = "https://\(config.sitename).neocities.org/\(remotePath)"
                let mediaType = supportedVideo.contains(ext) ? "VIDEO" : "IMAGE"
                return InstagramMediaURL(url: publicURL, mediaType: mediaType)
            } catch {
                NSLog("[PUBLISH] Instagram asset upload failed: \(error)")
                continue
            }
        }
        return nil
    }
}

// MARK: - Cross-post text formatter

private enum SocialCrossPostFormatter {
    static func text(for draft: PublishDraft, platform: SocialPlatform) -> String {
        let limit = platform.characterLimit
        guard limit > 0 else { return draft.title }

        var parts: [String] = []
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        if !title.isEmpty {
            parts.append(title)
        }
        if !summary.isEmpty {
            parts.append(summary)
        } else {
            let bodyPreview = draft.bodyMarkdown
                .replacingOccurrences(of: #"!\[.*?\]\(.*?\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[#*_>`-]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !bodyPreview.isEmpty {
                parts.append(bodyPreview)
            }
        }

        // Append tags as hashtags.
        let hashtags = draft.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
            .map { "#\($0)" }
        if !hashtags.isEmpty {
            parts.append(hashtags.joined(separator: " "))
        }

        let joined = parts.joined(separator: "\n\n")
        if joined.count <= limit { return joined }

        // Truncate with ellipsis, preserving hashtags if possible.
        let reserve = 3
        let maxBody = limit - reserve
        var body = joined.prefix(maxBody)
        // Drop partial word at the end for cleanliness.
        if let lastBreak = body.lastIndex(where: { $0.isWhitespace || $0.isNewline }) {
            let trimmed = String(body[..<lastBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body = Substring(trimmed) }
        }
        return String(body) + "…"
    }
}
