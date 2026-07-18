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
        GeometryReader { geometry in
            VStack(spacing: 16) {
                Text("Scan with WhatsApp")
                    .font(.title3.bold())
                Text("WhatsApp on your phone → Linked Devices → Link a Device")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Measure the actual square area available for the QR code so
                // the bitmap is generated at the exact display size, not scaled
                // by a nested GeometryReader's interpretation of aspectRatio.
                let maxQRWidth = geometry.size.width - 48 // subtract horizontal padding
                let maxQRHeight = geometry.size.height - 120 // reserve space for text
                let targetSize = min(maxQRWidth, maxQRHeight)

                QRCodeBitmapRenderer(qrText: qrText, targetSize: targetSize)
                    .frame(width: targetSize, height: targetSize)
                    .background(.white)
                    .cornerRadius(8)
                    .shadow(radius: 4)

                Text(QRCodeBitmapRenderer.diagnostic(for: qrText))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            // Show it immediately — the bridge doesn't persist messages it
            // sends via its own REST API back into its SQLite database (see
            // WhatsAppService.loadMessages), so without this the message
            // would send successfully but never appear here.
            service.appendSentMessage(chatJID: chatJID, text: text)
            await service.loadMessages(chatJID: chatJID)
        } catch {
            // Errors surface via the bridge's own status/error state elsewhere;
            // a failed send just leaves the compose text in place to retry.
        }
    }
}

// MARK: - QR bitmap renderer

/// Renders the Unicode half-block QR art produced by `qrterminal` into a
/// pixel-perfect square `CGImage`. Each text character encodes two vertical
/// QR modules, so the output matrix is always padded to a square with a white
/// quiet zone around the decoded modules.
private struct QRCodeBitmapRenderer: View {
    let qrText: String
    let targetSize: CGFloat

    var body: some View {
        if let cgImage = Self.render(qrText: qrText, targetSize: targetSize) {
            Image(decorative: cgImage, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    /// Returns a human-readable diagnostic string for the captured QR art.
    /// Helpful when the bridge output does not arrive in the expected square
    /// half-block shape.
    static func diagnostic(for qrText: String) -> String {
        let lines = qrText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\t", with: "    ") }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let counts = nonEmpty.map(\.count)
        let minWidth = counts.min() ?? 0
        let maxWidth = counts.max() ?? 0
        let textRows = nonEmpty.count * 2
        return "QR: \(nonEmpty.count) lines, \(minWidth)/\(maxWidth) cols, ~\(textRows) modules"
    }

    static func render(qrText: String, targetSize: CGFloat) -> CGImage? {
        // Normalize line endings and tabs.
        let normalized = qrText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\t", with: "    ") }

        // Drop leading and trailing blank lines.
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        // The bridge may occasionally inject blank lines in the middle of the
        // QR block; keep only the lines that actually contain modules.
        let qrLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !qrLines.isEmpty else { return nil }

        let columns = qrLines.map(\.count).max() ?? 0
        // qrterminal GenerateHalfBlock encodes two vertical modules per character.
        let rows = qrLines.count * 2
        guard columns > 0, rows > 0 else { return nil }

        // QR codes are square symbols (per ISO/IEC 18004). Pad the bitmap to a
        // square so that non-square captured text (e.g. width/height mismatch
        // from terminal wrapping) still renders as a square image.
        let squareDimension = max(columns, rows)
        let moduleSize = max(1, Int(floor(targetSize / CGFloat(squareDimension))))
        let pixelSize = squareDimension * moduleSize
        guard pixelSize > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * pixelSize
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White background (quiet zone + padding).
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        // Black modules.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let xOffset = (squareDimension - columns) / 2
        let yOffset = (squareDimension - rows) / 2

        for (lineIndex, line) in qrLines.enumerated() {
            // Text lines are top-down; QR matrix coordinates are bottom-up.
            let baseRow = yOffset + (rows - (lineIndex + 1) * 2)
            for (columnIndex, character) in line.enumerated() {
                let x = (xOffset + columnIndex) * moduleSize
                // CGImage coordinates are bottom-up; lowerY is the bottom of
                // the two-row block, upperY is the top of the lower row.
                let lowerY = baseRow * moduleSize
                let upperY = lowerY + moduleSize

                switch character {
                case "█":
                    // White-White (both light): background, nothing to draw.
                    break
                case " ":
                    // Black-Black (both dark): fill both vertical modules.
                    context.fill(CGRect(x: x, y: lowerY, width: moduleSize, height: moduleSize * 2))
                case "▀":
                    // White-Black (top light, bottom dark): fill bottom module.
                    context.fill(CGRect(x: x, y: lowerY, width: moduleSize, height: moduleSize))
                case "▄":
                    // Black-White (top dark, bottom light): fill top module.
                    context.fill(CGRect(x: x, y: upperY, width: moduleSize, height: moduleSize))
                default:
                    // Any unexpected character is treated as light to avoid
                    // adding phantom dark modules.
                    break
                }
            }
        }

        return context.makeImage()
    }
}

#Preview {
    WhatsAppView()
        .environment(WhatsAppService())
}
