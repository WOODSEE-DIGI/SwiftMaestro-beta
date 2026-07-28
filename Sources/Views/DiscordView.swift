import SwiftUI

/// SwiftMaestro's Discord client panel. Uses a bot token stored in the Keychain
/// (via `secret://discord-bot-token`) to read servers, channels, and messages
/// from Discord's REST API. Messages can be searched locally and archived to
/// the local Application Support folder for offline browsing and later cloning.
@MainActor
struct DiscordView: View {
    @Environment(DiscordService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var serverIDText: String = ""
    @State private var searchText: String = ""
    @State private var showArchiveSaved: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if service.status == .connecting || service.status == .fetchingChannels || service.status == .fetchingMessages {
                ProgressView()
                    .padding()
                Spacer()
            } else if let error = service.errorMessage, service.status != .connected {
                errorBanner(error)
            }

            if !service.channels.isEmpty {
                HSplitView {
                    channelSidebar
                        .frame(minWidth: 200, idealWidth: 240)
                    messagePane
                        .frame(minWidth: 400)
                }
            } else {
                setupPane
            }
        }
        .onAppear {
            serverIDText = service.selectedServerID
        }
        .onChange(of: service.selectedServerID) { _, new in
            serverIDText = new
        }
        .alert("Archive Saved", isPresented: $showArchiveSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The current channel's messages have been saved to the local Discord archive.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.title2)
                    .foregroundStyle(theme.accent)
                Text("Discord")
                    .font(.title2.bold())
                Spacer()
                statusBadge
            }

            HStack(spacing: 12) {
                TextField("Server ID", text: $serverIDText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await setServerID() }
                    }
                Button(service.isConnected ? "Reconnect" : "Connect") {
                    Task { await connectOrReconnect() }
                }
                .disabled(serverIDText.trimmingCharacters(in: .whitespaces).isEmpty)

                if service.isConnected {
                    Button("Disconnect") {
                        service.disconnect()
                    }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Bot token: secret://discord-bot-token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
                    .font(.caption)
            }
        }
        .padding()
    }

    private var statusBadge: some View {
        let (label, color) = statusLabel
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var statusLabel: (String, Color) {
        switch service.status {
        case .idle: return ("Idle", .secondary)
        case .connecting: return ("Connecting…", .orange)
        case .connected: return ("Connected", .green)
        case .fetchingChannels: return ("Loading Channels…", .orange)
        case .fetchingMessages: return ("Loading Messages…", .orange)
        case .error: return ("Error", .red)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.primary)
            Spacer()
            Button("Dismiss") {
                service.clearError()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Setup

    private var setupPane: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Enter a Discord server ID and connect")
                .font(.headline)
            Text("A bot token with Read Message History, View Channels, and Message Content Intent is required.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Channel sidebar

    private var channelSidebar: some View {
        List(service.channels, selection: .init(
            get: { service.selectedChannelID },
            set: { id in
                guard let id else { return }
                Task { await service.selectChannel(id: id) }
            }
        )) { channel in
            channelRow(channel)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func channelRow(_ channel: DiscordChannel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: channelIcon(for: channel))
                .foregroundStyle(theme.accent)
            Text(channel.name ?? "Unnamed")
                .lineLimit(1)
            Spacer()
            if service.selectedChannelID == channel.id {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
            }
        }
        .tag(channel.id)
        .contextMenu {
            Button("Load Recent Messages") {
                Task { await service.selectChannel(id: channel.id) }
            }
            Button("Load Older Messages") {
                Task { await service.loadOlderMessages() }
            }
            Divider()
            Button("Archive Channel") {
                Task {
                    await service.saveCurrentChannelArchive()
                    showArchiveSaved = true
                }
            }
        }
    }

    private func channelIcon(for channel: DiscordChannel) -> String {
        switch channel.type {
        case 2: return "mic.fill"
        case 4: return "folder"
        case 5: return "megaphone.fill"
        case 15: return "person.3.fill"
        default: return "number"
        }
    }

    // MARK: - Message pane

    private var messagePane: some View {
        VStack(spacing: 0) {
            HStack {
                if let channel = service.channels.first(where: { $0.id == service.selectedChannelID }) {
                    Text("#\(channel.name ?? "channel")")
                        .font(.headline)
                } else {
                    Text("Select a channel")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !service.messages.isEmpty {
                    Text("\(service.messages.count) messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Load Older") {
                    Task { await service.loadOlderMessages() }
                }
                .disabled(service.status == .fetchingMessages)
                Button("Archive") {
                    Task {
                        await service.saveCurrentChannelArchive()
                        showArchiveSaved = true
                    }
                }
                .disabled(service.selectedChannelID == nil)
            }
            .padding()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search loaded messages", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button("Clear") { searchText = "" }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            messageList
        }
    }

    private var messageList: some View {
        let filtered = filteredMessages
        return ScrollViewReader { proxy in
            List(filtered) { message in
                messageRow(message)
                    .id(message.id)
            }
            .listStyle(.plain)
            .onChange(of: service.messages) { _, _ in
                if let last = filtered.last {
                    withAnimation(.none) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredMessages: [DiscordMessage] {
        if searchText.isEmpty { return service.messages }
        let lower = searchText.lowercased()
        return service.messages.filter {
            $0.content.lowercased().contains(lower)
            || $0.author.username.lowercased().contains(lower)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: DiscordMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                avatar(for: message.author)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.author.username)
                            .font(.subheadline.weight(.semibold))
                        Text(message.timestamp, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(message.timestamp, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    if !message.attachments.isEmpty {
                        attachmentPreview(message.attachments)
                    }
                    if !message.embeds.isEmpty {
                        embedsPreview(message.embeds)
                    }
                    if let reactions = message.reactions, !reactions.isEmpty {
                        reactionsView(reactions)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func avatar(for user: DiscordUser) -> some View {
        if let avatar = user.avatar, !avatar.isEmpty,
           let url = URL(string: "https://cdn.discordapp.com/avatars/\(user.id)/\(avatar).png?size=64") {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholderAvatar(username: user.username)
                }
            }
            .clipShape(Circle())
        } else {
            placeholderAvatar(username: user.username)
        }
    }

    private func placeholderAvatar(username: String) -> some View {
        ZStack {
            Circle().fill(theme.accent.opacity(0.2))
            Text(String(username.prefix(1)).uppercased())
                .font(.caption.bold())
                .foregroundStyle(theme.accent)
        }
    }

    private func attachmentPreview(_ attachments: [DiscordAttachment]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(attachments) { attachment in
                if let url = URL(string: attachment.url), attachment.isImage {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: 240, maxHeight: 160)
                    .cornerRadius(8)
                } else if let url = URL(string: attachment.url) {
                    Link(destination: url) {
                        Label(attachment.filename, systemImage: "doc")
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func embedsPreview(_ embeds: [DiscordEmbed]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(embeds.enumerated()), id: \.offset) { _, embed in
                VStack(alignment: .leading, spacing: 4) {
                    if let title = embed.title {
                        Text(title).font(.subheadline.weight(.semibold))
                    }
                    if let description = embed.description {
                        Text(description).font(.caption)
                    }
                    if let url = embed.url, let link = URL(string: url) {
                        Link("Open", destination: link)
                            .font(.caption)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    private func reactionsView(_ reactions: [DiscordReaction]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(reactions.enumerated()), id: \.offset) { _, reaction in
                HStack(spacing: 2) {
                    if reaction.emoji.isCustom, let url = reaction.emoji.imageURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().frame(width: 14, height: 14)
                            }
                        }
                    } else if let name = reaction.emoji.name {
                        Text(name)
                            .font(.caption)
                    }
                    Text("\(reaction.count)")
                        .font(.caption2)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Actions

    private func setServerID() async {
        let id = serverIDText.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        await service.selectServer(id: id)
    }

    private func connectOrReconnect() async {
        await setServerID()
        await service.connect()
    }
}


