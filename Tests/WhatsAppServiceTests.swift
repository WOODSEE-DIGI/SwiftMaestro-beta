import XCTest
import GRDB
@testable import SwiftMaestro

@MainActor
final class WhatsAppServiceTests: XCTestCase {

    // MARK: - QR line detection

    func testLooksLikeQRLineAcceptsBlockCharacters() {
        XCTAssertTrue(WhatsAppService.looksLikeQRLine("████ ▄▄▄▄▄ ██▀▀█  █  ▀   ▀█"))
        XCTAssertTrue(WhatsAppService.looksLikeQRLine("▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"))
    }

    func testLooksLikeQRLineRejectsRegularText() {
        XCTAssertFalse(WhatsAppService.looksLikeQRLine("Scan this QR code with your WhatsApp app:"))
        XCTAssertFalse(WhatsAppService.looksLikeQRLine("Successfully connected and authenticated!"))
        XCTAssertFalse(WhatsAppService.looksLikeQRLine(""))
    }

    // MARK: - ANSI stripping

    func testStripANSIRemovesColorCodes() {
        let input = "\u{1B}[36m [Client INFO] Starting WhatsApp client...\u{1B}[0m"
        let stripped = WhatsAppService.stripANSI(input)
        XCTAssertFalse(stripped.contains("\u{1B}"))
        XCTAssertTrue(stripped.contains("Starting WhatsApp client..."))
    }

    // MARK: - Bridge directory resolution

    func testBridgeDirectoryUsesManualOverride() {
        defer { WhatsAppService.setBridgeDirectoryOverride(nil) }
        WhatsAppService.setBridgeDirectoryOverride("/tmp/my-whatsapp-bridge")
        XCTAssertEqual(WhatsAppService.bridgeDirectory()?.path, "/tmp/my-whatsapp-bridge")
    }

    func testBridgeDirectoryClearsOverrideWithEmptyString() {
        WhatsAppService.setBridgeDirectoryOverride("/tmp/something")
        WhatsAppService.setBridgeDirectoryOverride("")
        // With no override and (almost certainly) no matching MCP server entry
        // in this test environment, resolution should fail gracefully to nil
        // rather than throw or return a stale value.
        XCTAssertNil(UserDefaults.standard.string(forKey: "whatsapp.bridgeDirectoryOverride"))
    }

    // MARK: - consumeOutput state machine (fed real captured bridge output,
    // not synthesized guesses - see the session's live testing that produced
    // this exact QR block).

    func testConsumeOutputDetectsQRBlock() {
        let service = WhatsAppService()
        let sample = """
            20:18:49.522 [Client INFO] Starting WhatsApp client...

            Scan this QR code with your WhatsApp app:
            █████████████████████████████████████████████████████████████████
            ████ ▄▄▄▄▄ ██▀▀█  █  ▀   ▀█   ▄▄▄█  █▄ ▄▀▄▄ ▀█ ▄ █▄ ██ ▄▄▄▄▄ ████
            ████ █   █ █▄▀█▄▄▀████▄▀█ ▄█▄█▄▄█ ▄▄▄██▄▄ ▄▀█▀█▄▄▀▄ ██ █   █ ████
            ████▄▄▄▄▄▄▄█▄▄▄▄▄▄▄▄▄▄▄██▄▄▄▄▄▄█▄█▄▄███▄▄▄█▄▄▄█▄▄▄█████▄██▄▄▄████
            ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
            """
        service.consumeOutput(sample)
        guard case .awaitingQRScan(let qrText) = service.status else {
            XCTFail("expected .awaitingQRScan, got \(service.status)")
            return
        }
        XCTAssertTrue(qrText.contains("████"))
        XCTAssertFalse(qrText.contains("Scan this QR code"))
    }

    func testConsumeOutputDetectsConnected() {
        let service = WhatsAppService()
        service.consumeOutput("\n✓ Connected to WhatsApp! Type 'help' for commands.\n")
        XCTAssertEqual(service.status, .connected)
    }

    func testConsumeOutputDetectsSuccessfulAuthentication() {
        let service = WhatsAppService()
        service.consumeOutput("\nSuccessfully connected and authenticated!\n")
        XCTAssertEqual(service.status, .connected)
    }

    func testConsumeOutputDetectsError() {
        let service = WhatsAppService()
        service.consumeOutput("20:18:13.993 [Client ERROR] Failed to establish stable connection\n")
        guard case .error(let message) = service.status else {
            XCTFail("expected .error, got \(service.status)")
            return
        }
        XCTAssertTrue(message.contains("Failed to establish stable connection"))
    }

    func testConsumeOutputStripsANSIBeforeMatching() {
        // Real bridge output colorizes log lines - matching must work on the
        // stripped text, not get fooled by escape codes splitting a phrase.
        let service = WhatsAppService()
        service.consumeOutput("\u{1B}[31m[Client ERROR] Failed to establish stable connection\u{1B}[0m\n")
        guard case .error = service.status else {
            XCTFail("expected .error, got \(service.status)")
            return
        }
    }

    // MARK: - Fragmented stdout reads (the actual QR-rendering root cause)
    //
    // `qrterminal.GenerateHalfBlock` writes to `os.Stdout` with ONE syscall
    // per QR column (see qrterminal's writeHalfBlocks), and Go's os.Stdout is
    // unbuffered. A single ~60-char QR line can therefore arrive across the
    // pipe as dozens of separate `availableData` reads with no embedded
    // newline. Live testing showed this exact failure: a QR block that
    // should be ~27 lines was captured as ~195 fragmented "lines" of
    // wildly inconsistent width (3-65 cols), which rendered as a thin,
    // non-square, unscannable strip. These tests pin the fix: a
    // newline-less trailing fragment must be buffered (`pendingLine`) and
    // never treated as a complete QR line on its own.

    private static let referenceQRBlock = [
        "█████████████████████████████████████████████████████████████████",
        "████ ▄▄▄▄▄ ██▀▀█  █  ▀   ▀█   ▄▄▄█  █▄ ▄▀▄▄ ▀█ ▄ █▄ ██ ▄▄▄▄▄ ████",
        "████ █   █ █▄▀█▄▄▀████▄▀█ ▄█▄█▄▄█ ▄▄▄██▄▄ ▄▀█▀█▄▄▀▄ ██ █   █ ████",
        "████▄▄▄▄▄▄▄█▄▄▄▄▄▄▄▄▄▄▄██▄▄▄▄▄▄█▄█▄▄███▄▄▄█▄▄▄█▄▄▄█████▄██▄▄▄████",
        "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
    ]

    func testConsumeOutputReconstructsLineSplitAcrossTwoReads() {
        // Simulates the left-border write() landing separately from the
        // rest of a QR line's column writes.
        let service = WhatsAppService()
        service.consumeOutput("Scan this QR code with your WhatsApp app:\n")
        service.consumeOutput("████ ▄▄▄▄▄ ") // no trailing newline: line not yet complete
        service.consumeOutput("██▀▀█  █  ▀   ▀█\n") // completes the line

        guard case .awaitingQRScan(let qrText) = service.status else {
            XCTFail("expected .awaitingQRScan, got \(service.status)")
            return
        }
        let lines = qrText.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 1, "the split write should reconstruct into a single line, not two")
        XCTAssertEqual(String(lines[0]), "████ ▄▄▄▄▄ ██▀▀█  █  ▀   ▀█")
    }

    func testConsumeOutputReconstructsQRBlockFragmentedOneCharacterAtATime() {
        // Worst case: every single character arrives as its own read, as can
        // happen with qrterminal's one-write()-per-column output pattern.
        let service = WhatsAppService()
        service.consumeOutput("Scan this QR code with your WhatsApp app:\n")

        let fullBlock = Self.referenceQRBlock.joined(separator: "\n") + "\n"
        for character in fullBlock {
            service.consumeOutput(String(character))
        }

        guard case .awaitingQRScan(let qrText) = service.status else {
            XCTFail("expected .awaitingQRScan, got \(service.status)")
            return
        }
        let lines = qrText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertEqual(
            lines.count, Self.referenceQRBlock.count,
            "fragmenting every byte into its own read must still reconstruct the original line count, "
                + "not explode it into far more (this was the actual cause of the non-square QR bitmap)"
        )
        for (reconstructed, expected) in zip(lines, Self.referenceQRBlock) {
            XCTAssertEqual(String(reconstructed), expected)
        }
    }

    func testConsumeOutputDoesNotPrematurelyTreatPartialLineAsQRLine() {
        // A newline-less fragment must not itself be published as part of
        // the QR text before its line is actually complete.
        let service = WhatsAppService()
        service.consumeOutput("Scan this QR code with your WhatsApp app:\n")
        service.consumeOutput("████████████████████████████████████████\n") // one complete line

        guard case .awaitingQRScan(let firstText) = service.status else {
            XCTFail("expected .awaitingQRScan after the first complete line, got \(service.status)")
            return
        }
        XCTAssertEqual(firstText, "████████████████████████████████████████")

        service.consumeOutput("████ ▄▄▄▄▄ ") // deliberately incomplete, no newline

        guard case .awaitingQRScan(let stillFirstText) = service.status else {
            XCTFail("expected .awaitingQRScan, got \(service.status)")
            return
        }
        XCTAssertEqual(
            stillFirstText, firstText,
            "an incomplete, newline-less fragment must stay buffered rather than appear in the QR text early"
        )
    }

    // MARK: - Sent-message visibility
    //
    // The bridge's `/api/send` handler only calls `client.SendMessage` and
    // returns success/failure - it never writes the outgoing message into
    // its own SQLite database. whatsmeow also doesn't deliver a self-echo
    // `events.Message` for a send made by THIS client instance (only
    // messages arriving from elsewhere, e.g. the phone or another linked
    // device, get persisted that way). So a message you just sent would
    // send successfully (confirmed on the phone) but never appear in
    // SwiftMaestro, because `loadMessages` only ever reads from that same
    // SQLite database. These tests pin the client-side optimistic-append
    // fix and its DB-reload-safe merge behavior.

    func testAppendSentMessageShowsImmediatelyWithoutWaitingForTheBridgeDB() {
        let service = WhatsAppService()
        service.appendSentMessage(chatJID: "123@s.whatsapp.net", text: "hello there")

        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages.first?.content, "hello there")
        XCTAssertEqual(service.messages.first?.chatJID, "123@s.whatsapp.net")
        XCTAssertTrue(service.messages.first?.isFromMe ?? false)
    }

    func testLoadMessagesPreservesLocallyAppendedSentMessageTheDBDoesNotHaveYet() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatsAppServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("store", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            WhatsAppService.setBridgeDirectoryOverride(nil)
        }
        WhatsAppService.setBridgeDirectoryOverride(tempDir.path)

        // Seed a bridge-style messages.db with one *incoming* message, the
        // way the real bridge would after `handleMessage` fires - but
        // deliberately with no row for an outgoing send, matching the real
        // bridge's actual (buggy) behavior.
        let dbPath = tempDir.appendingPathComponent("store/messages.db").path
        let setupDB = try DatabaseQueue(path: dbPath)
        try await setupDB.write { db in
            try db.execute(sql: """
                CREATE TABLE chats (
                    jid TEXT PRIMARY KEY, name TEXT, last_message_time TIMESTAMP
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages (
                    id TEXT, chat_jid TEXT, sender TEXT, content TEXT,
                    timestamp TIMESTAMP, is_from_me BOOLEAN, media_type TEXT,
                    PRIMARY KEY (id, chat_jid)
                )
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, chat_jid, sender, content, timestamp, is_from_me)
                VALUES ('incoming-1', '123@s.whatsapp.net', '123', 'hi there', ?, 0)
                """, arguments: [Date(timeIntervalSince1970: 1_000_000)])
        }

        let service = WhatsAppService()
        service.appendSentMessage(chatJID: "123@s.whatsapp.net", text: "my reply")
        await service.loadMessages(chatJID: "123@s.whatsapp.net")

        XCTAssertEqual(
            service.messages.count, 2,
            "the locally-appended sent message must survive a DB reload, not disappear"
        )
        XCTAssertTrue(service.messages.contains { $0.content == "hi there" && !$0.isFromMe })
        XCTAssertTrue(service.messages.contains { $0.content == "my reply" && $0.isFromMe })
    }

    func testLoadMessagesDropsLocalPlaceholderOnceDBHasAMatchingRealRow() async throws {
        // If the bridge (or a future fix) ever does persist the sent
        // message, the local placeholder should be replaced rather than
        // shown as a duplicate.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatsAppServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("store", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            WhatsAppService.setBridgeDirectoryOverride(nil)
        }
        WhatsAppService.setBridgeDirectoryOverride(tempDir.path)

        let dbPath = tempDir.appendingPathComponent("store/messages.db").path
        let setupDB = try DatabaseQueue(path: dbPath)
        try await setupDB.write { db in
            try db.execute(sql: """
                CREATE TABLE chats (
                    jid TEXT PRIMARY KEY, name TEXT, last_message_time TIMESTAMP
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages (
                    id TEXT, chat_jid TEXT, sender TEXT, content TEXT,
                    timestamp TIMESTAMP, is_from_me BOOLEAN, media_type TEXT,
                    PRIMARY KEY (id, chat_jid)
                )
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, chat_jid, sender, content, timestamp, is_from_me)
                VALUES ('outgoing-real-1', '123@s.whatsapp.net', 'me', 'my reply', ?, 1)
                """, arguments: [Date()])
        }

        let service = WhatsAppService()
        service.appendSentMessage(chatJID: "123@s.whatsapp.net", text: "my reply")
        await service.loadMessages(chatJID: "123@s.whatsapp.net")

        let matches = service.messages.filter { $0.content == "my reply" && $0.isFromMe }
        XCTAssertEqual(
            matches.count, 1,
            "once the DB has a real row with matching content, the local placeholder must not duplicate it"
        )
    }

    // MARK: - LID/phone-number conversation reconciliation
    //
    // WhatsApp increasingly addresses a contact via a privacy-preserving LID
    // (Linked ID) instead of their phone-number JID, and the bridge stores
    // whichever raw form a given event arrives with as `chat_jid` — it
    // doesn't reconcile the two. The SAME real conversation can therefore
    // silently split into two different chat_jid rows the moment WhatsApp's
    // servers switch forms. Live testing showed exactly this: sent messages
    // kept working (recipient JIDs resolve server-side either way), but
    // every incoming reply started arriving tagged with the contact's LID —
    // invisible to a query scoped to the phone-number JID, no matter how
    // often it was re-polled (confirmed directly in the bridge's own SQLite
    // files: the "Brock McFadzean" chat's messages just stopped, while an
    // unrelated-looking chat named "210414809956389" silently accumulated
    // every message in the conversation from that point on). These tests
    // pin the fix, which reconciles the two forms using the bridge's own
    // whatsmeow_lid_map table (in its whatsapp.db session store).

    func testMergeLIDDuplicatesCombinesSameContactUnderCanonicalPNJid() throws {
        let lidMap = ["246007237447707@lid": "61434035561@s.whatsapp.net"]
        let raw = [
            WhatsAppChat(
                jid: "61434035561@s.whatsapp.net", name: "Brock McFadzean",
                lastMessageTime: Date(timeIntervalSince1970: 1_000)),
            WhatsAppChat(
                jid: "246007237447707@lid", name: "210414809956389",
                lastMessageTime: Date(timeIntervalSince1970: 2_000)),
        ]
        let merged = WhatsAppService.mergeLIDDuplicates(raw, lidMap: lidMap)

        XCTAssertEqual(merged.count, 1, "the two rows must merge into a single chat")
        let chat = try XCTUnwrap(merged.first)
        XCTAssertEqual(chat.jid, "61434035561@s.whatsapp.net", "must canonicalize on the phone-number JID")
        XCTAssertEqual(chat.name, "Brock McFadzean", "must prefer the real name over the raw numeric LID name")
        XCTAssertEqual(
            chat.lastMessageTime, Date(timeIntervalSince1970: 2_000),
            "must keep the most recent last-message time across both halves"
        )
    }

    func testMergeLIDDuplicatesLeavesUnrelatedChatsAlone() {
        let raw = [
            WhatsAppChat(jid: "111@s.whatsapp.net", name: "Alice", lastMessageTime: Date()),
            WhatsAppChat(jid: "222@s.whatsapp.net", name: "Bob", lastMessageTime: Date()),
        ]
        let merged = WhatsAppService.mergeLIDDuplicates(raw, lidMap: [:])
        XCTAssertEqual(merged.count, 2, "chats with no LID/PN counterpart must be left untouched")
    }

    func testLoadChatsAndLoadMessagesReconcileALiveLIDSplitConversation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatsAppServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("store", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            WhatsAppService.setBridgeDirectoryOverride(nil)
        }
        WhatsAppService.setBridgeDirectoryOverride(tempDir.path)

        // messages.db: two chat rows and messages under BOTH forms for the
        // same real contact, matching what was found in the live bridge DB.
        let messagesDBPath = tempDir.appendingPathComponent("store/messages.db").path
        let messagesDB = try DatabaseQueue(path: messagesDBPath)
        try await messagesDB.write { db in
            try db.execute(sql: """
                CREATE TABLE chats (
                    jid TEXT PRIMARY KEY, name TEXT, last_message_time TIMESTAMP
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages (
                    id TEXT, chat_jid TEXT, sender TEXT, content TEXT,
                    timestamp TIMESTAMP, is_from_me BOOLEAN, media_type TEXT,
                    PRIMARY KEY (id, chat_jid)
                )
                """)
            try db.execute(sql: """
                INSERT INTO chats (jid, name, last_message_time)
                VALUES ('61434035561@s.whatsapp.net', 'Brock McFadzean', ?)
                """, arguments: [Date(timeIntervalSince1970: 1_000)])
            try db.execute(sql: """
                INSERT INTO chats (jid, name, last_message_time)
                VALUES ('246007237447707@lid', '210414809956389', ?)
                """, arguments: [Date(timeIntervalSince1970: 2_000)])
            try db.execute(sql: """
                INSERT INTO messages (id, chat_jid, sender, content, timestamp, is_from_me)
                VALUES ('old-1', '61434035561@s.whatsapp.net', '61434035561', 'an older message', ?, 0)
                """, arguments: [Date(timeIntervalSince1970: 500)])
            try db.execute(sql: """
                INSERT INTO messages (id, chat_jid, sender, content, timestamp, is_from_me)
                VALUES ('new-lid-1', '246007237447707@lid', '246007237447707', 'a newer reply via LID', ?, 0)
                """, arguments: [Date(timeIntervalSince1970: 2_000)])
        }

        // whatsapp.db: the whatsmeow session store's own LID<->PN mapping,
        // exactly as the real bridge maintains it in whatsmeow_lid_map.
        let whatsappDBPath = tempDir.appendingPathComponent("store/whatsapp.db").path
        let whatsappDB = try DatabaseQueue(path: whatsappDBPath)
        try await whatsappDB.write { db in
            try db.execute(sql: "CREATE TABLE whatsmeow_lid_map (lid TEXT PRIMARY KEY, pn TEXT UNIQUE NOT NULL)")
            try db.execute(sql: "INSERT INTO whatsmeow_lid_map (lid, pn) VALUES ('246007237447707', '61434035561')")
        }

        let service = WhatsAppService()
        await service.loadChats()
        XCTAssertEqual(service.chats.count, 1, "the two chat rows for the same contact must merge into one")
        let chat = try XCTUnwrap(service.chats.first)
        XCTAssertEqual(chat.jid, "61434035561@s.whatsapp.net")
        XCTAssertEqual(chat.name, "Brock McFadzean")

        await service.loadMessages(chatJID: "61434035561@s.whatsapp.net")
        XCTAssertEqual(
            service.messages.count, 2,
            "messages from both the phone-number and LID chat_jid rows must appear in one thread"
        )
        XCTAssertTrue(service.messages.contains { $0.content == "an older message" })
        XCTAssertTrue(
            service.messages.contains { $0.content == "a newer reply via LID" },
            "a reply stored under the contact's LID chat_jid must surface even though the UI "
                + "is scoped to the phone-number JID"
        )
    }
}
