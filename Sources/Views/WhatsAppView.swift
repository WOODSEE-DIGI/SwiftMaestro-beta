import SwiftUI
import UniformTypeIdentifiers

struct WhatsAppView: View {
    @Environment(WhatsAppService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var selectedChatID: String?
    @State private var composeText = ""
    @State private var isSending = false
    /// A picked/dropped/pasted image queued to send as the next message's
    /// attachment. Cleared once the send actually goes out (or fails).
    @State private var pendingAttachmentURL: URL?
    /// Belt-and-suspenders duplicate-send guard — see the long comment in
    /// `send(chatJID:)` for why `isSending` alone isn't sufficient.
    @State private var lastSentSignature: String?
    @State private var lastSentAt: Date?
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
                // ROOT CAUSE FIX: Without `.topLeading`, SwiftUI defaults to
                // `.center` alignment, which horizontally centres the
                // connectedView HStack (chatList + detail) inside this
                // frame. On the very first render that produces the
                // connected state the centre-aligned content lands ~250 pt
                // right of where it should be — the "left margin" glitch.
                // Selecting a chat forces a state-driven re-layout that
                // happens to use the correct geometry, which is why it
                // self-corrects. Explicitly pinning to topLeading makes
                // the first frame correct unconditionally.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Belt-and-suspenders alongside `content`'s own `.frame` above: make
        // the WHOLE root VStack explicitly claim all available space too,
        // rather than relying on that inner modifier's width/height request
        // propagating all the way up through this VStack and every
        // ancestor (WorkspacePanelContentView -> WorkspacePanelWindowView's
        // own VStack) to the hosting NSWindow. If that propagation was ever
        // even slightly incomplete anywhere in the chain, the window could
        // end up wider than this view's own ideal size, and SwiftUI centers
        // undersized content in an oversized container by default — which
        // would look exactly like an unexplained leading margin.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: selectedChatID) {
            // Loads immediately when a chat is opened, then keeps polling
            // while it stays open. The bridge has no push mechanism for
            // incoming messages — SwiftMaestro only ever reads its local
            // SQLite DB — so an already-open thread needs to re-poll to
            // pick up replies from the other person; without this, a reply
            // that arrives while the thread is open never appears until the
            // user closes and reopens the chat. `.task(id:)` automatically
            // cancels and restarts this loop when the selected chat changes,
            // and cancels it entirely when the view disappears.
            guard let selectedChatID else { return }
            while !Task.isCancelled {
                await service.loadMessages(chatJID: selectedChatID)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task {
            // Keeps the sidebar chat list (names, last-message ordering)
            // fresh for the same reason. Runs for the view's lifetime.
            while !Task.isCancelled {
                await service.loadChats()
                try? await Task.sleep(for: .seconds(5))
            }
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
                    Task {
                        await service.loadChats()
                        if let selectedChatID {
                            await service.loadMessages(chatJID: selectedChatID)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh chats and current thread")
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
        // The leading-margin glitch — the chat list rendered ~250 pt right
        // of the window's left edge on the very first appearance of the
        // connected state, self-correcting the instant any state change
        // forced a new layout pass — was rooted in `content`'s
        // `.frame(maxWidth: .infinity, maxHeight: .infinity)` using the
        // DEFAULT centre alignment, which horizontally centred the HStack
        // (chatList + detail) inside the oversized frame. Adding
        // `.topLeading` to that inner frame (see `content` above) pins
        // the layout correctly on the very first frame. The ScrollView,
        // WindowLayoutKicker, and connectedViewGeneration rebuilds from
        // earlier fix rounds addressed symptoms, not this root cause, and
        // are all removed now.
        HStack(spacing: 0) {
            chatList
                .frame(width: CGFloat(chatListWidth))
            Divider()
            detail
        }
        // Covers the WHOLE window (sidebar + message thread + compose
        // bar), not just the compose bar's small strip, and adapts
        // automatically to whatever size the window is currently at
        // since it's on the full-size container rather than a
        // fixed-height child. Only takes effect once a chat is actually
        // selected — with none selected there's nowhere to attach a
        // dropped image to.
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard selectedChatID != nil else { return false }
            return handleAttachmentProviders(providers)
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            guard selectedChatID != nil else { return }
            handleAttachmentProviders(providers)
        }
    }

    private var chatList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chats")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            // Two previous attempts at this used AppKit's `List` (first with
            // the default style, then `.listStyle(.plain)`, then removing
            // the `Section` wrapper) and the margin glitch on first
            // appearance survived all of them — it's an NSTableView-backed
            // List's OWN first-layout-pass timing quirk, not anything about
            // Section/style specifically, and it only self-corrects once
            // SOME layout-invalidating change (like a selection) forces a
            // second pass. Rather than keep guessing at List-specific
            // workarounds, this is a fully custom ScrollView + manually
            // drawn rows: no AppKit List/NSTableView involved at all, so
            // there's no such quirk to have in the first place — the layout
            // is correct on the very first frame, unconditionally.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if service.chats.isEmpty {
                        Text("No chats")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(service.chats) { chat in
                            chatRow(chat)
                        }
                    }
                }
            }
        }
    }

    private func chatRow(_ chat: WhatsAppChat) -> some View {
        let isSelected = selectedChatID == chat.jid
        return VStack(alignment: .leading, spacing: 2) {
            Text(chat.displayName)
                .lineLimit(1)
            if let time = chat.lastMessageTime {
                Text(time, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? theme.accent.opacity(0.25) : Color.clear)
        .foregroundStyle(isSelected ? theme.accent : .primary)
        .contentShape(Rectangle())
        .onTapGesture { selectedChatID = chat.jid }
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
        let chatName = service.chats.first { $0.jid == chatJID }?.displayName ?? chatJID
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
            VStack(alignment: .leading, spacing: 4) {
                if !message.isFromMe, let sender = message.sender {
                    // `sender` is often just a bare phone/LID number (e.g.
                    // "00000000000") - resolve it the same way the chat list
                    // does, using contact data the bridge already has but
                    // wasn't using (see WhatsAppService.loadContactDisplayNames).
                    Text(service.contactDisplayNames[sender] ?? sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if message.mediaType == "image" {
                    imageAttachment(for: message)
                }
                if let content = message.content, !content.isEmpty {
                    Text(content)
                } else if let mediaType = message.mediaType, mediaType != "image" {
                    Text("[\(mediaType)]")
                }
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

    /// Renders a message's image attachment from its resolved local path
    /// (see `WhatsAppService.resolveMediaPath`/`resolvedMediaPaths`) — for
    /// a RECEIVED image this is a bridge download (`/api/download`, which
    /// decrypts and saves it, returning an absolute local path); for one
    /// SwiftMaestro just sent, it's the original local file, registered
    /// immediately by `appendSentMessage` with no round-trip needed. Falls
    /// back to a manual "Load image" retry button if the automatic
    /// first attempt (in `.task`) doesn't resolve a path (e.g. the bridge
    /// couldn't download it), rather than spinning forever.
    @ViewBuilder
    private func imageAttachment(for message: WhatsAppMessage) -> some View {
        if let path = service.resolvedMediaPaths[message.id], let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
        } else {
            Button {
                Task { await service.resolveMediaPath(messageID: message.id, chatJID: message.chatJID) }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("Load image")
                        .font(.caption2)
                }
                .frame(width: 120, height: 120)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .task {
                // Attempt automatically once so most images just appear
                // without requiring a manual tap; the button above is the
                // fallback if this first attempt fails.
                await service.resolveMediaPath(messageID: message.id, chatJID: message.chatJID)
            }
        }
    }

    private func composeBar(chatJID: String) -> some View {
        VStack(spacing: 8) {
            if let pendingAttachmentURL {
                attachmentPreview(pendingAttachmentURL)
            }
            HStack {
                Button {
                    pickImageAttachment()
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.plain)
                .help("Attach an image")

                TextField("Message…", text: $composeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    // Return sends (matching ChatView's compose bar); Shift+Return
                    // inserts a newline as usual for a multi-line message.
                    .onSubmit { Task { await send(chatJID: chatJID) } }
                Button {
                    Task { await send(chatJID: chatJID) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .disabled(
                    (composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && pendingAttachmentURL == nil)
                        || isSending
                )
            }
        }
        .padding(10)
        // Drop/paste handling lives on `connectedView` (the whole window),
        // not here — see its comment for why.
    }

    private func attachmentPreview(_ url: URL) -> some View {
        HStack(spacing: 8) {
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "doc.fill")
                    .frame(width: 44, height: 44)
            }
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button {
                pendingAttachmentURL = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(6)
        .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Open a file picker for a single image to attach, matching ChatView's
    /// `pickImages()` pattern.
    private func pickImageAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingAttachmentURL = url
    }

    /// Loads a dropped/pasted image (or file) into `pendingAttachmentURL`.
    /// Mirrors ChatView's `handleProviders`, but resolves to a real FILE PATH
    /// rather than in-memory PNG bytes: a dropped item with a backing file
    /// (`.fileURL`) is used directly so the original format (JPEG/HEIC/etc,
    /// which the bridge's own mimetype detection already handles) is
    /// preserved; an image with no backing file at all (e.g. straight from
    /// the clipboard, like a screenshot preview) is written to a temp PNG
    /// first, since the bridge can only upload from a path on disk.
    @discardableResult
    private func handleAttachmentProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let u = item as? URL { url = u }
                    else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    guard let url else { return }
                    Task { @MainActor in pendingAttachmentURL = url }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let tempURL = Self.writeTempPNG(image) else { return }
                    Task { @MainActor in pendingAttachmentURL = tempURL }
                }
            }
        }
        return handled
    }

    /// `nonisolated`: pure data transformation touching no actor-isolated
    /// state, called from NSItemProvider's asynchronous (non-MainActor)
    /// load-completion handler — matches ChatView's `pngData` helpers.
    private static nonisolated func writeTempPNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftmaestro-whatsapp-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    private func send(chatJID: String) async {
        // Re-entrancy guard: pressing Return triggered TWO overlapping sends
        // of the same text+attachment (confirmed live — a screenshot showed
        // up twice with the same caption). `.onSubmit` on a multi-line
        // `axis: .vertical` TextField can fire more than once per Return
        // press on macOS; `isSending` was only ever used to DISABLE the send
        // button, not to actually stop a second call already in flight
        // before that disabled state re-renders. Checking it FIRST, before
        // touching anything else, makes a second concurrent call to this
        // same function a guaranteed no-op regardless of why it happened.
        guard !isSending else { return }
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentURL = pendingAttachmentURL
        guard !text.isEmpty || attachmentURL != nil else { return }

        // The `isSending` guard above only catches a second call that
        // arrives WHILE the first one is still awaiting the network round
        // trip. Confirmed still double-sending after that fix shipped: the
        // duplicate `.onSubmit` fire isn't always concurrent with the
        // first — sometimes it lands moments AFTER the first send has
        // already fully completed (and `isSending` reset back to false via
        // `defer`), so the in-flight check sees nothing in flight and lets
        // an identical second send straight through. Reject an exact
        // repeat of the same chat+text+attachment within a short window
        // regardless of whether the two calls actually overlapped in time.
        let signature = "\(chatJID)|\(text)|\(attachmentURL?.path ?? "")"
        if signature == lastSentSignature,
           let lastSentAt, Date().timeIntervalSince(lastSentAt) < 2 {
            return
        }

        isSending = true
        lastSentSignature = signature
        lastSentAt = Date()
        defer { isSending = false }
        do {
            try await service.sendMessage(to: chatJID, text: text, mediaPath: attachmentURL?.path)
            composeText = ""
            pendingAttachmentURL = nil
            // Show it immediately — the bridge doesn't persist messages it
            // sends via its own REST API back into its SQLite database (see
            // WhatsAppService.loadMessages), so without this the message
            // would send successfully but never appear here. For an
            // attachment, register the LOCAL file directly (no download
            // round-trip needed for our own outgoing image).
            service.appendSentMessage(
                chatJID: chatJID, text: text,
                mediaType: attachmentURL != nil ? "image" : nil,
                localMediaPath: attachmentURL?.path
            )
            await service.loadMessages(chatJID: chatJID)
        } catch {
            // Errors surface via the bridge's own status/error state elsewhere;
            // a failed send just leaves the compose text/attachment in place to retry.
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
