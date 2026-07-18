import SwiftUI

struct WhatsAppView: View {
    @Environment(WhatsAppService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var selectedChatID: String?
    @State private var composeText = ""
    @State private var isSending = false
    @AppStorage("whatsapp.chatListWidth") private var chatListWidth = 260.0

    var body: some View {
        // WhatsApp is always a single-pane window. The previous split-pane
        // layout (ResizablePanelHost) forced a centre divider that squeezed the
        // QR code and confused the initial view. Every state now fills one
        // unified pane; only the connected state adds a non-resizable sidebar
        // for the chat list.
        VStack(spacing: 0) {
            statusHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedChatID) { _, newValue in
            guard let newValue else { return }
            Task { await service.loadMessages(chatJID: newValue) }
        }
    }

    // MARK: - Header

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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch service.status {
        case .awaitingQRScan(let qrText):
            qrScanView(qrText)
        case .stopped:
            ContentUnavailableView(
                "WhatsApp Bridge Stopped",
                systemImage: "message",
                description: Text("Click Start in the header to connect. "
                    + "If your session needs re-linking, a QR code will appear here to scan with your phone.")
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
            connectedView
        }
    }

    // MARK: - QR scan

    private func qrScanView(_ qrText: String) -> some View {
        VStack(spacing: 16) {
            Text("Scan with WhatsApp")
                .font(.title3.bold())
            Text("WhatsApp on your phone → Linked Devices → Link a Device")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            QRCodeBitmapRenderer(qrText: qrText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(.white)
                .cornerRadius(8)
                .shadow(radius: 4)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 24)
    }

    // MARK: - Connected

    private var connectedView: some View {
        HStack(spacing: 0) {
            chatList
                .frame(width: CGFloat(chatListWidth))
            Divider()
            detail
        }
    }

    private var chatList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedChatID) {
                Section("Chats") {
                    if service.chats.isEmpty {
                        Text("No chats")
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

    @ViewBuilder
    private var detail: some View {
        if let selectedChatID {
            messageThread(chatJID: selectedChatID)
        } else {
            ContentUnavailableView(
                "Select a Chat", systemImage: "message",
                description: Text("Choose a chat from the list to view messages."))
        }
    }

    // MARK: - Message thread

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

// MARK: - QR bitmap renderer

/// Renders the Unicode half-block QR art produced by `qrterminal` into a
/// pixel-perfect NSImage. The image is generated at the exact display size
/// (rounded to integer module pixels) so the QR code is always square, sharp,
/// and scannable, without relying on SwiftUI text layout or Canvas sizing.
private struct QRCodeBitmapRenderer: View {
    let qrText: String

    var body: some View {
        GeometryReader { geometry in
            let square = min(geometry.size.width, geometry.size.height)
            if let image = Self.render(qrText: qrText, targetSize: square) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
    }

    static func render(qrText: String, targetSize: CGFloat) -> NSImage? {
        let lines = qrText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\t", with: " ") }
        guard !lines.isEmpty else { return nil }

        let columns = lines.map(\.count).max() ?? 0
        // qrterminal GenerateHalfBlock encodes two vertical modules per character,
        // so the rendered grid is twice as tall as the text line count.
        let rows = lines.count * 2
        guard columns > 0, rows > 0 else { return nil }

        let maxDimension = max(columns, rows)
        let moduleSize = max(1, Int(floor(targetSize / CGFloat(maxDimension))))
        let pixelWidth = columns * moduleSize
        let pixelHeight = rows * moduleSize
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let image = NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
        image.lockFocus()

        // Light background first.
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)).fill()

        for (lineIndex, line) in lines.enumerated() {
            // Convert from top-down text line to bottom-up NSImage coordinates.
            let blockBaseY = (rows - (lineIndex + 1) * 2) * moduleSize

            for (columnIndex, character) in line.enumerated() {
                let x = columnIndex * moduleSize

                switch character {
                case "█":
                    // Both rows light — already background.
                    break
                case " ":
                    // Both rows dark.
                    NSColor.black.setFill()
                    NSBezierPath(rect: NSRect(
                        x: x, y: blockBaseY,
                        width: moduleSize, height: moduleSize * 2
                    )).fill()
                case "▀":
                    // UPPER HALF BLOCK: top row light, bottom row dark.
                    NSColor.black.setFill()
                    NSBezierPath(rect: NSRect(
                        x: x, y: blockBaseY,
                        width: moduleSize, height: moduleSize
                    )).fill()
                case "▄":
                    // LOWER HALF BLOCK: top row dark, bottom row light.
                    NSColor.black.setFill()
                    NSBezierPath(rect: NSRect(
                        x: x, y: blockBaseY + moduleSize,
                        width: moduleSize, height: moduleSize
                    )).fill()
                default:
                    // Unknown character: treat as light to avoid phantom modules.
                    break
                }
            }
        }

        image.unlockFocus()
        return image
    }
}

#Preview {
    WhatsAppView()
        .environment(WhatsAppService())
}
