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
}
