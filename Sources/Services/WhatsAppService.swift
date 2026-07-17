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

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var isCapturingQR = false
    private var qrLines: [String] = []

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
    }

    /// Parses stdout incrementally: captures the QR code (consecutive lines
    /// made of Unicode block-drawing characters, printed right after the
    /// bridge's own "Scan this QR code..." prompt) and recognizes the
    /// connected/error markers the bridge prints as plain text. Internal (not
    /// private) so tests can feed it sample bridge output directly, without
    /// needing a real running bridge process.
    func consumeOutput(_ chunk: String) {
        for rawLine in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let stripped = Self.stripANSI(line)

            if stripped.contains("Scan this QR code with your WhatsApp app:") {
                isCapturingQR = true
                qrLines = []
                continue
            }
            if isCapturingQR {
                if Self.looksLikeQRLine(stripped) {
                    qrLines.append(stripped)
                    continue
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
        // If the QR block was still being captured when this chunk ended
        // (common — the block often arrives as one big write), surface it
        // now rather than waiting for a line that never comes.
        if isCapturingQR, !qrLines.isEmpty {
            status = .awaitingQRScan(qrLines.joined(separator: "\n"))
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
                    ORDER BY last_message_time DESC LIMIT 100
                    """)
            }
            chats = rows.map {
                WhatsAppChat(
                    jid: $0["jid"], name: $0["name"],
                    lastMessageTime: $0["last_message_time"])
            }
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
            let rows = try await db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, chat_jid, sender, content, timestamp, is_from_me, media_type
                    FROM messages WHERE chat_jid = ?
                    ORDER BY timestamp DESC LIMIT ?
                    """, arguments: [chatJID, limit])
            }
            messages = rows.map {
                WhatsAppMessage(
                    id: $0["id"], chatJID: $0["chat_jid"], sender: $0["sender"],
                    content: $0["content"], timestamp: $0["timestamp"],
                    isFromMe: $0["is_from_me"], mediaType: $0["media_type"])
            }.reversed()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Sending (via the bridge's local REST API — it owns the live connection)

    func sendMessage(to recipient: String, text: String) async throws {
        let url = URL(string: "http://localhost:\(Self.sendPort)/api/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["recipient": recipient, "message": text])

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
