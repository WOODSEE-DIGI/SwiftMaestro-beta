import Foundation
import SwiftUI

// MARK: - Discord service

/// Swift-native Discord integration for SwiftMaestro. Uses a bot token (stored
/// in the Keychain via `SecretsStore` and referenced as `secret://discord-bot-token`)
/// to read servers, channels, and messages over Discord's REST API.
///
/// The service is designed to be target-agnostic: Phase 1 focuses on browsing
/// and archiving a Discord server. Later phases can add a `CloneDestination`
/// adapter (e.g., Stoat or Spacebar) without changing this core.
@Observable
@MainActor
final class DiscordService {

    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case fetchingChannels
        case fetchingMessages
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var guilds: [DiscordGuild] = []
    private(set) var channels: [DiscordChannel] = []
    private(set) var roles: [DiscordRole] = []
    private(set) var messages: [DiscordMessage] = []
    private(set) var errorMessage: String?

    var isConnected: Bool { client != nil }

    var selectedServerID: String {
        didSet { UserDefaults.standard.set(selectedServerID, forKey: Self.serverIDKey) }
    }
    var selectedChannelID: String? {
        didSet { UserDefaults.standard.set(selectedChannelID, forKey: Self.channelIDKey) }
    }

    /// How many messages to fetch per page (max 100). Kept conservative to
    /// avoid long stalls during the first click.
    var fetchBatchSize: Int = 100
    /// How many pages to fetch when "Load more" is clicked.
    var fetchPageCount: Int = 5

    private var client: DiscordAPIClient?

    private static let serverIDKey = "discord.archive.serverID"
    private static let channelIDKey = "discord.archive.selectedChannelID"
    private static let defaultTokenReference = "secret://discord-bot-token"

    init() {
        selectedServerID = UserDefaults.standard.string(forKey: Self.serverIDKey) ?? ""
        selectedChannelID = UserDefaults.standard.string(forKey: Self.channelIDKey)
    }

    // MARK: - Connection

    /// Connects using the bot token resolved from `secret://discord-bot-token`.
    /// The resolved value is never stored; the client holds it only in memory.
    func connect() async {
        guard client == nil else { return }
        status = .connecting
        errorMessage = nil

        guard let token = SecretsStore.resolve(reference: Self.defaultTokenReference, currentProject: nil), !token.isEmpty else {
            status = .error("No bot token found. Create a secret named \"discord-bot-token\" in Settings → Secrets.")
            return
        }

        let client = DiscordAPIClient(token: token)
        self.client = client

        do {
            guilds = try await client.getCurrentGuilds()
            // If the user has configured a server ID, select it automatically.
            if !selectedServerID.isEmpty {
                await loadServer(id: selectedServerID)
            }
            status = .connected
        } catch {
            status = .error(error.localizedDescription)
            self.client = nil
        }
    }

    func disconnect() {
        client = nil
        status = .idle
        guilds = []
        channels = []
        roles = []
        messages = []
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Server loading

    func selectServer(id: String) async {
        selectedServerID = id
        await loadServer(id: id)
    }

    func loadServer(id: String) async {
        guard let client else { return }
        status = .fetchingChannels
        do {
            let fetchedChannels = try await client.getGuildChannels(id: id)
            channels = fetchedChannels.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            roles = try await client.getGuildRoles(id: id)
            if selectedChannelID != nil, !channels.contains(where: { $0.id == selectedChannelID }) {
                selectedChannelID = nil
            }
            status = .connected
        } catch {
            status = .error("Failed to load server: \(error.localizedDescription)")
        }
    }

    // MARK: - Message loading

    func selectChannel(id: String) async {
        selectedChannelID = id
        await loadMessages(channelID: id)
    }

    func loadMessages(channelID: String) async {
        guard client != nil else { return }
        status = .fetchingMessages
        messages = []
        do {
            messages = try await fetchMessages(channelID: channelID, before: nil)
            status = .connected
        } catch {
            status = .error("Failed to load messages: \(error.localizedDescription)")
        }
    }

    /// Loads more messages older than the current oldest message.
    func loadOlderMessages() async {
        guard client != nil, let channelID = selectedChannelID, let oldest = messages.last else { return }
        status = .fetchingMessages
        do {
            let older = try await fetchMessages(channelID: channelID, before: oldest.id)
            messages.insert(contentsOf: older, at: 0)
            status = .connected
        } catch {
            status = .error("Failed to load older messages: \(error.localizedDescription)")
        }
    }

    /// Fetches a fixed number of pages. Returns the collected messages, oldest first.
    private func fetchMessages(channelID: String, before: String?) async throws -> [DiscordMessage] {
        guard let client else { return [] }
        var collected: [DiscordMessage] = []
        var lastID: String? = before
        var remainingPages = fetchPageCount

        while remainingPages > 0, !Task.isCancelled {
            let page = try await client.getMessages(channelID: channelID, limit: fetchBatchSize, before: lastID)
                guard !page.isEmpty else { break }
                collected.insert(contentsOf: page, at: 0)
                lastID = page.last?.id
                remainingPages -= 1
        }
        return collected
    }

    // MARK: - Archive

    /// Returns a directory where Discord archives can be saved.
    var archiveDirectory: URL {
        let dir = SwiftMaestroPaths.appSupportDir
            .appendingPathComponent("discord-archives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the currently loaded messages for the selected channel to a JSON file.
    func saveCurrentChannelArchive() async {
        guard let channelID = selectedChannelID else { return }
        let file = archiveDirectory
            .appendingPathComponent("server-\(selectedServerID)", isDirectory: true)
            .appendingPathComponent("channel-\(channelID).json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(messages)
            try data.write(to: file, options: [.atomic])
        } catch {
            status = .error("Archive failed: \(error.localizedDescription)")
        }
    }

    /// Loads a previously saved archive for the selected channel, if any.
    func loadCurrentChannelArchive() async {
        guard let channelID = selectedChannelID else { return }
        let file = archiveDirectory
            .appendingPathComponent("server-\(selectedServerID)", isDirectory: true)
            .appendingPathComponent("channel-\(channelID).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            messages = try decoder.decode([DiscordMessage].self, from: data)
        } catch {
            status = .error("Failed to load archive: \(error.localizedDescription)")
        }
    }
}
