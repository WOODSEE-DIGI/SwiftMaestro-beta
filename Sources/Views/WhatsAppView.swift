import SwiftUI

struct WhatsAppView: View {
    @Environment(WhatsAppService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var selectedChatID: String?
    @State private var composeText = ""
    @State private var isSending = false
    @AppStorage("whatsapp.chatListWidth") private var chatListWidth = 240.0

    var body: some View {
        ResizablePanelHost(panes: [
            ResizablePane(
                id: "chats",
                length: Binding(get: { CGFloat(chatListWidth) }, set: { chatListWidth = Double($0) }),
                minLength: 200,
                maxLength: 360
            ) {
                chatList
            },
            ResizablePane(id: "detail", length: nil) {
                detail
            },
        ])
        .onChange(of: selectedChatID) { _, newValue in
            guard let newValue else { return }
            Task { await service.loadMessages(chatJID: newValue) }
        }
    }

    // MARK: - Chat list

    private var chatList: some View {
        VStack(spacing: 0) {
            statusHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            List(selection: $selectedChatID) {
                Section("Chats") {
                    if service.chats.isEmpty {
                        Text(service.status == .connected ? "No chats" : "Not connected")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        ForEach(service.chats) { chat in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.name ?? chat.jid)
                                    .lineLimit(1)
                                if let time = chat.lastMessageTime {
                                    Text(time, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(chat.jid)
                        }
                    }
                }
            }
        }
    }

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("WhatsApp")
                .font(.headline)
            Spacer()
            switch service.status {
            case .stopped, .error:
                Button("Start") { service.start() }
            case .starting, .awaitingQRScan:
                ProgressView().controlSize(.small)
            case .connected:
                Button {
                    Task { await service.loadChats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh chats")
                Button("Stop") { service.stop() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.leading, 6)
            }
        }
    }

    private var statusColor: Color {
        switch service.status {
        case .stopped: return .gray
        case .starting, .awaitingQRScan: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch service.status {
        case .awaitingQRScan(let qrText):
            qrScanView(qrText)
        case .stopped:
            ContentUnavailableView(
                "WhatsApp Bridge Stopped",
                systemImage: "message",
                description: Text("Click Start to connect. If your session needs re-linking, "
                    + "a QR code will appear here to scan with your phone.")
            )
        case .starting:
            ContentUnavailableView(
                "Starting…", systemImage: "message",
                description: Text("Connecting to the WhatsApp bridge."))
        case .error(let message):
            ContentUnavailableView(
                "WhatsApp Error", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .connected:
            if let selectedChatID {
                messageThread(chatJID: selectedChatID)
            } else {
                ContentUnavailableView(
                    "Select a Chat", systemImage: "message",
                    description: Text("Choose a chat from the list to view messages."))
            }
        }
    }

    private func qrScanView(_ qrText: String) -> some View {
        VStack(spacing: 12) {
            Text("Scan with WhatsApp")
                .font(.title3.bold())
            Text("WhatsApp on your phone → Linked Devices → Link a Device")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(qrText)
                .font(.system(size: 6, weight: .regular, design: .monospaced))
                .lineSpacing(0)
                .foregroundStyle(.black)
                .padding(12)
                .background(.white)
                .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func messageThread(chatJID: String) -> some View {
        let chatName = service.chats.first { $0.jid == chatJID }?.name ?? chatJID
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(service.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: service.messages.count) { _, _ in
                    if let last = service.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            composeBar(chatJID: chatJID)
        }
        .navigationTitle(chatName)
    }

    private func messageBubble(_ message: WhatsAppMessage) -> some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                if !message.isFromMe, let sender = message.sender {
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(message.content ?? message.mediaType.map { "[\($0)]" } ?? "")
                if let time = message.timestamp {
                    Text(time, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(
                (message.isFromMe ? theme.accent : Color.gray.opacity(0.2)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(message.isFromMe ? .white : .primary)
            if !message.isFromMe { Spacer(minLength: 40) }
        }
    }

    private func composeBar(chatJID: String) -> some View {
        HStack {
            TextField("Message…", text: $composeText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                Task { await send(chatJID: chatJID) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(10)
    }

    private func send(chatJID: String) async {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await service.sendMessage(to: chatJID, text: text)
            composeText = ""
            await service.loadMessages(chatJID: chatJID)
        } catch {
            // Errors surface via the bridge's own status/error state elsewhere;
            // a failed send just leaves the compose text in place to retry.
        }
    }
}

#Preview {
    WhatsAppView()
        .environment(WhatsAppService())
}
