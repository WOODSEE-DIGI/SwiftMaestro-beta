import Foundation
import Testing
@testable import SwiftMaestro

/// Runtime tests for the vendored OwnTrack relay stack (Sources/MailTracker).
struct OwnTrackRelayTests {

    /// The embedded relay must bind, answer /health, serve a message summary
    /// for an unknown id (empty counts), and shut down cleanly.
    @Test @MainActor
    func embeddedRelayStartHealthSummaryStop() async throws {
        let manager = OwnTrackRelayManager.shared
        manager.stopRelay() // clean slate in case another test started it
        defer { manager.stopRelay() }

        let started = manager.startRelay()
        if !started {
            Issue.record("startRelay failed: \(manager.lastError ?? "unknown")")
        }
        #expect(started)
        #expect(manager.isRunning)

        // Health
        let healthURL = try #require(URL(string: "http://localhost:8087/health"))
        var healthRequest = URLRequest(url: healthURL)
        healthRequest.timeoutInterval = 5
        let (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
        #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
        let healthText = String(decoding: healthData, as: UTF8.self)
        #expect(healthText.contains("\"ok\""))

        // Register a message, then its summary must report the sent event.
        let registerURL = try #require(URL(string: "http://localhost:8087/v1/messages/register"))
        var registerRequest = URLRequest(url: registerURL)
        registerRequest.httpMethod = "POST"
        registerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        registerRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "messageID": "owntrack-test@swiftmaestro.local",
            "sender": "test@swiftmaestro.local",
            "recipients": ["someone@example.com"],
            "subject": "OwnTrack relay test",
            "trackingMode": "opensAndClicks",
            "metadata": [:], // required: synthesized Codable ignores the init's default
        ])
        let (_, registerResponse) = try await URLSession.shared.data(for: registerRequest)
        let registerStatus = (registerResponse as? HTTPURLResponse)?.statusCode
        #expect(registerStatus == 200 || registerStatus == 201)

        let summaryURL = try #require(URL(string: "http://localhost:8087/v1/messages/owntrack-test@swiftmaestro.local/summary"))
        let (summaryData, summaryResponse) = try await URLSession.shared.data(from: summaryURL)
        #expect((summaryResponse as? HTTPURLResponse)?.statusCode == 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601 // matches the relay's encoder
        let decoded = try decoder.decode(MessageSummaryResponse.self, from: summaryData)
        #expect(decoded.summary.sentCount == 1)
        #expect(decoded.summary.openCount == 0)

        // Unknown message ids correctly 404.
        let missingURL = try #require(URL(string: "http://localhost:8087/v1/messages/definitely-not-registered-xyz/summary"))
        let (_, missingResponse) = try await URLSession.shared.data(from: missingURL)
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)

        manager.stopRelay()
        #expect(!manager.isRunning)
    }

    /// The message-id normalization used by AppleMailService must match the
    /// relay's own normalizeMessageID behavior (strip <> and whitespace).
    @Test
    func messageIDNormalizationMatchesRelay() {
        #expect(AppleMailService.normalizeMessageID("  <abc@example.com>  ") == "abc@example.com")
        #expect(AppleMailService.normalizeMessageID("abc@example.com") == "abc@example.com")
        #expect(AppleMailService.normalizeMessageID("<ABC-123@mail.gmail.com>") == "ABC-123@mail.gmail.com")
    }
}
