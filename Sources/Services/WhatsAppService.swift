import Foundation
import GRDB

// MARK: - WhatsApp monitoring service
//
// Bridges SwiftMaestro to a self-hosted `whatsapp-bridge` (the Go binary from
// github.com/lharries/whatsapp-mcp, built on the `whatsmeow` library — the
// SAME multi-device linking protocol real WhatsApp Web/Desktop use, not a
// scraped/automated browser). This is a genuinely different shape of
// integration than Numbers/Apple Notes (JXA automation of a local app) or
// Mastodon (a WKWebView plugin talking to an official REST API): WhatsApp
// needs a persistent background PROCESS (the bridge holds the live
// connection) plus direct SQLite reads of the data it maintains locally —
// neither of which fits the plugin bridge's request/response capability
// model well, so this is a native service+panel instead, matching
// AppleNotesService/NumbersService's pattern.
///
/// Responsibilities:
/// - Locate the bridge (auto-detected from the user's existing `whatsapp-mcp`
///   MCP server entry if configured, since that's the same underlying
///   project — falls back to a manual override).
/// - Start/stop the bridge process, capture its stdout to detect QR-pairing
///   prompts (rendered as a real scannable Unicode block-art QR code) and
///   connection state.
/// - Read chats/messages directly (read-only) from the SQLite database the
///   bridge maintains — no HTTP round-trip needed for that.
/// - Send messages via the bridge's own local REST API (`POST /api/send`) —
///   sending requires the live connection the bridge owns; SwiftMaestro
///   can't transmit over WhatsApp's protocol itself.
@Observable
@MainActor
final class WhatsAppService {

    enum Status: Equatable {
        case stopped
        case starting
        case awaitingQRScan(String)
        case connected
        case error(String)
    }

    private(set) var status: Status = .stopped
    private(set) var chats: [WhatsAppChat] = []
    private(set) var messages: [WhatsAppMessage] = []
    private(set) var error: String?
    /// Best-available display name per contact, keyed by BOTH the bare
    /// number and the full JID form (see `loadContactDisplayNames`). Public
    /// so the view can resolve a message's raw `sender` number (e.g.
    /// "61410906593") to a real name (e.g. "George Li") the same way
    /// `loadChats` already does for the chat list itself.
    private(set) var contactDisplayNames: [String: String] = [:]
    /// Local filesystem path for a message's downloaded (or, for a message
    /// this app just sent, not-yet-uploaded) media attachment, keyed by
    /// message id. Populated by `resolveMediaPath` for received media and by
    /// `appendSentMessage` for outgoing media, so the view never re-requests
    /// a download it already has.
    private(set) var resolvedMediaPaths: [String: String] = [:]

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var isCapturingQR = false
    private var qrLines: [String] = []
    /// Holds a trailing, not-yet-newline-terminated fragment of stdout
    /// across separate `consumeOutput` calls. See the doc comment on
    /// `consumeOutput` for why this is required (the bridge's QR renderer
    /// writes one syscall per column, so lines routinely arrive split across
    /// multiple pipe reads).
    private var pendingLine = ""

    private static let bridgeOverrideKey = "whatsapp.bridgeDirectoryOverride"
    private static let sendPort = 8080

    // MARK: - Bridge location

    /// Resolves the `whatsapp-bridge` folder. Prefers a manual override if
    /// set; otherwise derives it from the user's existing `whatsapp-mcp` MCP
    /// server entry in Settings → MCP (same underlying project — its
    /// `whatsapp-mcp-server` script path has a sibling `whatsapp-bridge`
    /// folder), so there's no separate path to configure for anyone who
    /// already has that MCP server set up.
    static func bridgeDirectory() -> URL? {
        if let saved = UserDefaults.standard.string(forKey: bridgeOverrideKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        let entries = SwiftMaestroSettingsStore.loadMCPServers()
        for entry in entries {
            let candidates = (entry.args ?? []) + [entry.scriptPath, entry.workingDir]
            for candidate in candidates where candidate.hasSuffix("whatsapp-mcp-server") {
                let serverDir = URL(fileURLWithPath: candidate, isDirectory: true)
                let bridgeDir = serverDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("whatsapp-bridge", isDirectory: true)
                if FileManager.default.fileExists(
                    atPath: bridgeDir.appendingPathComponent("whatsapp-client").path
                ) {
                    return bridgeDir
                }
            }
        }
        return nil
    }

    static func setBridgeDirectoryOverride(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set((trimmed?.isEmpty ?? true) ? nil : trimmed, forKey: bridgeOverrideKey)
    }

    private var databaseDirectory: URL? {
        Self.bridgeDirectory()?.appendingPathComponent("store", isDirectory: true)
    }

    // MARK: - Bridge lifecycle

    func start() {
        guard process == nil else { return }
        guard let bridgeDir = Self.bridgeDirectory() else {
            status = .error("Couldn't locate the whatsapp-bridge folder. Set it manually in Settings, "
                + "or configure the whatsapp-mcp MCP server first.")
            return
        }
        let binaryPath = bridgeDir.appendingPathComponent("whatsapp-client").path
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            status = .error("whatsapp-client binary not found or not executable at \(binaryPath).")
            return
        }

        status = .starting
        isCapturingQR = false
        qrLines = []
        pendingLine = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.currentDirectoryURL = bridgeDir

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeOutput(text)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.stdoutPipe = nil
                if case .error = self.status { return } // preserve a more specific error already set
                self.status = .stopped
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = stdout
        } catch {
            status = .error("Failed to launch whatsapp-client: \(error.localizedDescription)")
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        status = .stopped
        pendingLine = ""
    }

    /// Parses stdout incrementally: captures the QR code (consecutive lines
    /// made of Unicode block-drawing characters, printed right after the
    /// bridge's own "Scan this QR code..." prompt) and recognizes the
    /// connected/error markers the bridge prints as plain text. Internal (not
    /// private) so tests can feed it sample bridge output directly, without
    /// needing a real running bridge process.
    ///
    /// IMPORTANT: `qrterminal.GenerateHalfBlock` (the Go bridge's QR
    /// renderer) writes to `os.Stdout` with one `Write()` syscall PER
    /// COLUMN — a single ~60-character QR line can arrive as dozens of
    /// separate `Pipe.availableData` reads, each with no trailing newline.
    /// Without buffering, each of those fragments "looks like a QR line"
    /// (it's built entirely from block-drawing characters) and gets appended
    /// to `qrLines` as its own line, exploding a ~27-line QR code into
    /// ~150-200 fragmented "lines" of wildly inconsistent width — which is
    /// exactly what rendered as a thin, non-square strip. `pendingLine`
    /// carries any newline-less trailing fragment forward to the next call
    /// so a logical line is only ever processed once it's actually complete.
    func consumeOutput(_ chunk: String) {
        let combined = pendingLine + chunk
        let endsWithNewline = combined.hasSuffix("\n")
        var pieces = combined
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if endsWithNewline {
            pendingLine = ""
        } else {
            // The last piece has no terminating newline yet — it's an
            // incomplete line (or line fragment); hold it for the next read
            // instead of processing it prematurely.
            pendingLine = pieces.isEmpty ? "" : pieces.removeLast()
        }

        for line in pieces {
            processLine(line)
        }

        // If the QR block was still being captured when this chunk ended
        // (common — the block often arrives as one big write), surface it
        // now rather than waiting for a line that never comes.
        if isCapturingQR, !qrLines.isEmpty {
            status = .awaitingQRScan(qrLines.joined(separator: "\n"))
        }
    }

    private func processLine(_ rawLine: String) {
        let stripped = Self.stripANSI(rawLine)

        if stripped.contains("Scan this QR code with your WhatsApp app:") {
            isCapturingQR = true
            qrLines = []
            return
        }
        if isCapturingQR {
            if Self.looksLikeQRLine(stripped) {
                qrLines.append(stripped)
                return
            } else if !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                // First non-QR, non-blank line ends the QR block.
                isCapturingQR = false
                status = .awaitingQRScan(qrLines.joined(separator: "\n"))
            }
        }
        if stripped.contains("Successfully connected and authenticated!")
            || stripped.contains("Connected to WhatsApp! Type 'help' for commands.") {
            isCapturingQR = false
            status = .connected
            Task { await self.loadChats() }
        } else if stripped.contains("Failed to establish stable connection")
            || stripped.contains("Timeout waiting for QR code scan")
            || stripped.contains("Failed to connect") {
            isCapturingQR = false
            status = .error(stripped.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static let qrBlockCharacters = CharacterSet(charactersIn: "█▄▀▌▐ \t")

    static func looksLikeQRLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.unicodeScalars.allSatisfy { qrBlockCharacters.contains($0) }
    }

    static func stripANSI(_ line: String) -> String {
        // The bridge colorizes log level prefixes with ANSI escape codes
        // (\x1b[36m...\x1b[0m); strip them so substring matching above and
        // the QR block-character check both work on the actual text.
        guard let regex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*m") else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    // MARK: - Reading chats/messages (direct SQLite, read-only)

    func loadChats() async {
        guard let dbDir = databaseDirectory else { return }
        let dbPath = dbDir.appendingPathComponent("messages.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            var config = GRDB.Configuration()
            config.readonly = true
            let db = try DatabaseQueue(path: dbPath, configuration: config)
            let rows = try await db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT jid, name, last_message_time FROM chats
                    ORDER BY last_message_time DESC LIMIT 300
                    """)
            }
            let rawChats = rows.map {
                WhatsAppChat(
                    jid: $0["jid"], name: $0["name"],
                    lastMessageTime: $0["last_message_time"])
            }

            // The bridge's own GetChatName only ever checked contact.FullName
            // (which comes from the LOCAL phone's address book sync) before
            // falling back to the raw phone/LID number - it never checked
            // PushName (the name the OTHER person set for their own WhatsApp
            // profile, which is present for essentially every contact who's
            // ever messaged us, address-book entry or not). That's why chats
            // like "61410906593" and "93278217216209" showed raw numbers
            // instead of names, even though whatsmeow_contacts already had
            // "George Li" / "Carissa Anderson" recorded as push_name. Fixed
            // at the source in the Go bridge for NEW chats going forward;
            // this resolves it client-side for every chat ALREADY stored
            // with a bad name, using the same already-collected data, so it
            // takes effect immediately without needing the bridge to
            // rewrite anything.
            contactDisplayNames = await loadContactDisplayNames()
            let resolvedChats = rawChats.map { chat -> WhatsAppChat in
                guard Self.looksLikeRawID(chat.name), let resolved = contactDisplayNames[chat.jid] else {
                    return chat
                }
                return WhatsAppChat(jid: chat.jid, name: resolved, lastMessageTime: chat.lastMessageTime)
            }
            chats = Self.mergeLIDDuplicates(resolvedChats, lidMap: await loadLIDMap())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMessages(chatJID: String, limit: Int = 100) async {
        guard let dbDir = databaseDirectory else { return }
        let dbPath = dbDir.appendingPathComponent("messages.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            var config = GRDB.Configuration()
            config.readonly = true
            let db = try DatabaseQueue(path: dbPath, configuration: config)

            // WhatsApp's multi-device protocol increasingly addresses a
            // contact by a privacy-preserving LID (Linked ID) instead of
            // their phone-number JID, and the bridge stores whichever raw
            // form a given event arrived with as `chat_jid` — it doesn't
            // reconcile the two. That means the SAME real conversation can
            // silently split into two different chat_jid rows the moment
            // WhatsApp's servers switch which form they tag it with. This is
            // exactly what happened live: outgoing sends kept working (the
            // recipient JID is resolved server-side either way), but every
            // incoming reply started arriving tagged with the contact's LID
            // — invisible to a query scoped only to the phone-number JID, no
            // matter how often it's re-polled. Resolve every JID that refers
            // to this same contact via the bridge's OWN whatsmeow_lid_map
            // table (in its separate whatsapp.db session store, which it
            // already maintains for protocol reasons) and query across all
            // of them, so both "halves" of the split conversation merge back
            // into one thread — no bridge changes required.
            var jids: Set<String> = [chatJID]
            if let counterpart = await loadLIDMap()[chatJID] {
                jids.insert(counterpart)
            }
            let allJIDs = Array(jids)

            let placeholders = allJIDs.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible?] = allJIDs
            arguments.append(limit)
            let rows = try await db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, chat_jid, sender, content, timestamp, is_from_me, media_type
                    FROM messages WHERE chat_jid IN (\(placeholders))
                    ORDER BY timestamp DESC LIMIT ?
                    """, arguments: StatementArguments(arguments))
            }
            // Normalize every row to the caller's chatJID regardless of
            // which underlying raw chat_jid it actually came from, so the
            // merge logic below (and the UI) treats this as one conversation.
            let loaded = rows.map {
                WhatsAppMessage(
                    id: $0["id"], chatJID: chatJID, sender: $0["sender"],
                    content: $0["content"], timestamp: $0["timestamp"],
                    isFromMe: $0["is_from_me"], mediaType: $0["media_type"])
            }.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }

            // The bridge's `/api/send` handler never writes the message it
            // just sent back into its own SQLite database, and whatsmeow
            // doesn't deliver a self-echo `events.Message` for a send made by
            // THIS client instance (only messages arriving from elsewhere —
            // the phone, another linked device — get persisted that way). So
            // a message you just sent would never appear in a DB reload even
            // though WhatsApp itself confirms delivery. Keep any locally
            // appended "sent" placeholders (see `appendSentMessage`) that the
            // DB doesn't know about yet, and drop one only once a real row
            // with matching content shows up (e.g. from a future history
            // sync), so the outgoing message never visually disappears and
            // never duplicates.
            let stillPendingLocalOnly = messages.filter { message in
                message.chatJID == chatJID
                    && message.id.hasPrefix(Self.localMessageIDPrefix)
                    && !loaded.contains {
                        $0.isFromMe && $0.content == message.content && $0.mediaType == message.mediaType
                    }
            }
            messages = (loaded + stillPendingLocalOnly)
                .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads the bridge's LID (Linked ID) <-> phone-number JID mapping from
    /// its whatsmeow session store (`whatsapp.db`, separate from
    /// `messages.db`). Returns a bidirectional lookup keyed by both the bare
    /// number and the full JID form (`<number>@lid` / `<number>@s.whatsapp.net`)
    /// so a lookup with either succeeds. Returns an empty map (not an error)
    /// if the file or table is missing, so this degrades gracefully to the
    /// pre-LID-reconciliation behavior rather than failing a load.
    private func loadLIDMap() async -> [String: String] {
        guard let dbDir = databaseDirectory else { return [:] }
        let dbPath = dbDir.appendingPathComponent("whatsapp.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        do {
            var config = GRDB.Configuration()
            config.readonly = true
            let db = try DatabaseQueue(path: dbPath, configuration: config)
            let rows = try await db.read { db in
                try Row.fetchAll(db, sql: "SELECT lid, pn FROM whatsmeow_lid_map")
            }
            var map: [String: String] = [:]
            for row in rows {
                guard let lid: String = row["lid"], let pn: String = row["pn"] else { continue }
                map[lid] = pn
                map[pn] = lid
                map["\(lid)@lid"] = "\(pn)@s.whatsapp.net"
                map["\(pn)@s.whatsapp.net"] = "\(lid)@lid"
            }
            return map
        } catch {
            return [:]
        }
    }

    /// Merges chat rows that represent the same real contact under
    /// WhatsApp's LID/phone-number dual addressing (see `loadMessages`'s doc
    /// comment) into a single entry: keeps the most human-readable name and
    /// the most recent last-message time, and canonicalizes on the
    /// phone-number-style JID when both forms are known (that's already the
    /// form used for sending).
    static func mergeLIDDuplicates(_ rawChats: [WhatsAppChat], lidMap: [String: String]) -> [WhatsAppChat] {
        func canonical(for jid: String) -> String {
            if jid.hasSuffix("@lid"), let pn = lidMap[jid] { return pn }
            return jid
        }

        var merged: [String: WhatsAppChat] = [:]
        for chat in rawChats {
            let key = canonical(for: chat.jid)
            if let existing = merged[key] {
                let name = Self.preferredName(existing.name, chat.name)
                let time = [existing.lastMessageTime, chat.lastMessageTime].compactMap { $0 }.max()
                merged[key] = WhatsAppChat(jid: key, name: name, lastMessageTime: time)
            } else {
                merged[key] = WhatsAppChat(jid: key, name: chat.name, lastMessageTime: chat.lastMessageTime)
            }
        }
        return merged.values.sorted {
            ($0.lastMessageTime ?? .distantPast) > ($1.lastMessageTime ?? .distantPast)
        }
    }

    /// A LID-only chat's stored "name" is often just the raw numeric LID —
    /// the bridge can't always resolve a friendly contact name for a bare
    /// LID the same way it can for a phone-number JID with saved contact
    /// info — so prefer whichever candidate isn't purely numeric.
    private static func preferredName(_ a: String?, _ b: String?) -> String? {
        if !looksLikeRawID(a) { return a }
        if !looksLikeRawID(b) { return b }
        return a ?? b
    }

    /// True for nil, empty, or a name that's purely digits — i.e. a raw
    /// phone number or LID with no real display name resolved, whether it's
    /// a chat's stored `name` or a message's `sender`.
    static func looksLikeRawID(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return true }
        return name.allSatisfy(\.isNumber)
    }

    /// Loads best-available display names from the bridge's own whatsmeow
    /// contact-sync data (`whatsmeow_contacts`, in the SAME `whatsapp.db`
    /// session store `loadLIDMap` already reads). Preference order: FullName
    /// (usually from the local phone's address-book sync) > FirstName >
    /// PushName (the OTHER person's own WhatsApp display name — present for
    /// almost every contact who's ever messaged us, even with zero
    /// address-book entry, which is exactly the gap this closes) >
    /// BusinessName. Keyed by BOTH the full JID and the bare number (e.g.
    /// both "61410906593@s.whatsapp.net" and "61410906593"), since
    /// `chats.jid` stores full JIDs but `messages.sender` stores bare
    /// numbers. Returns an empty map (not an error) if the file/table is
    /// missing, so this degrades gracefully.
    private func loadContactDisplayNames() async -> [String: String] {
        guard let dbDir = databaseDirectory else { return [:] }
        let dbPath = dbDir.appendingPathComponent("whatsapp.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        do {
            var config = GRDB.Configuration()
            config.readonly = true
            let db = try DatabaseQueue(path: dbPath, configuration: config)
            let rows = try await db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT their_jid, first_name, full_name, push_name, business_name
                    FROM whatsmeow_contacts
                    """)
            }
            var names: [String: String] = [:]
            for row in rows {
                guard let jid: String = row["their_jid"] else { continue }
                let candidates: [String?] = [
                    row["full_name"], row["first_name"], row["push_name"], row["business_name"],
                ]
                guard let resolved = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { continue }
                names[jid] = resolved
                if let atIndex = jid.firstIndex(of: "@") {
                    names[String(jid[jid.startIndex..<atIndex])] = resolved
                }
            }
            return names
        } catch {
            return [:]
        }
    }

    private static let localMessageIDPrefix = "local-pending-"

    /// Optimistically appends a message (optionally with a media attachment)
    /// you just sent so it appears immediately, without waiting for (or
    /// depending on) the bridge ever persisting it — see the comment in
    /// `loadMessages` for why it doesn't. When `localMediaPath` is provided
    /// (the file about to be/just uploaded), it's registered directly in
    /// `resolvedMediaPaths` so the sent image renders immediately from the
    /// local copy already on disk — no round-trip download needed for your
    /// own outgoing attachment.
    func appendSentMessage(chatJID: String, text: String, mediaType: String? = nil, localMediaPath: String? = nil) {
        let id = Self.localMessageIDPrefix + UUID().uuidString
        messages.append(WhatsAppMessage(
            id: id,
            chatJID: chatJID,
            sender: nil,
            content: text,
            timestamp: Date(),
            isFromMe: true,
            mediaType: mediaType
        ))
        if let localMediaPath {
            resolvedMediaPaths[id] = localMediaPath
        }
    }

    // MARK: - Sending (via the bridge's local REST API — it owns the live connection)

    /// - Parameter mediaPath: absolute local filesystem path to an image (or
    ///   other media) to send as an attachment, with `text` used as the
    ///   caption. The bridge already supports this via `/api/send`'s
    ///   `media_path` field (it uploads the file to WhatsApp itself) — this
    ///   was simply never exposed anywhere in SwiftMaestro's UI.
    func sendMessage(to recipient: String, text: String, mediaPath: String? = nil) async throws {
        let url = URL(string: "http://localhost:\(Self.sendPort)/api/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["recipient": recipient, "message": text]
        if let mediaPath { body["media_path"] = mediaPath }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WhatsAppError.sendFailed("No HTTP response from bridge")
        }
        struct SendResponse: Decodable { let success: Bool; let message: String }
        let decoded = try? JSONDecoder().decode(SendResponse.self, from: data)
        guard http.statusCode == 200, decoded?.success == true else {
            throw WhatsAppError.sendFailed(decoded?.message ?? "HTTP \(http.statusCode)")
        }
    }

    // MARK: - Media

    /// Downloads (or reuses an already-downloaded copy of) a received
    /// message's media attachment via the bridge's `/api/download` endpoint,
    /// which uploads/decrypts it from WhatsApp's servers and returns an
    /// ABSOLUTE LOCAL FILE PATH (both SwiftMaestro and the bridge run on the
    /// same machine, so no base64/streaming round-trip is needed). Caches
    /// the resolved path in `resolvedMediaPaths` so repeat calls (e.g. from
    /// the periodic message-list polling) are a no-op once resolved.
    /// Best-effort: failures just leave the message unresolved so the view
    /// can show a placeholder rather than propagating an error.
    func resolveMediaPath(messageID: String, chatJID: String) async {
        guard resolvedMediaPaths[messageID] == nil else { return }
        let url = URL(string: "http://localhost:\(Self.sendPort)/api/download")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(["message_id": messageID, "chat_jid": chatJID]) else { return }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return }
        struct DownloadResponse: Decodable { let success: Bool; let path: String? }
        guard let decoded = try? JSONDecoder().decode(DownloadResponse.self, from: data),
              decoded.success, let path = decoded.path
        else { return }
        resolvedMediaPaths[messageID] = path
    }
}

enum WhatsAppError: LocalizedError {
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .sendFailed(let message): return "Send failed: \(message)"
        }
    }
}

// MARK: - Models

struct WhatsAppChat: Identifiable, Hashable, Sendable {
    var id: String { jid }
    let jid: String
    let name: String?
    let lastMessageTime: Date?
}

struct WhatsAppMessage: Identifiable, Hashable, Sendable {
    let id: String
    let chatJID: String
    let sender: String?
    let content: String?
    let timestamp: Date?
    let isFromMe: Bool
    let mediaType: String?
}
