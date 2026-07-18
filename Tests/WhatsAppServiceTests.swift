import XCTest
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
}
