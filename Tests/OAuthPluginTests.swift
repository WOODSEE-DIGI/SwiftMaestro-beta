import XCTest
@testable import SwiftMaestro

/// Tests for the OAuth plugin capability (PluginBridge `startOAuth`),
/// the generic OAuthLoopbackServer callback parser, and the Bluesky
/// facet byte-offset helper used by native Bluesky posting tools.
@MainActor
final class OAuthPluginTests: XCTestCase {

    // MARK: - Manifest: oauth capability

    func testManifestDecodesOAuthCapability() throws {
        let json = """
        {"id":"patreon","name":"Patreon","icon":"heart.circle","entry":"index.html",
         "version":"1.0.0","capabilities":["network","secrets","oauth"]}
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.id, "patreon")
        XCTAssertEqual(manifest.capabilities, [.network, .secrets, .oauth])
    }

    // MARK: - PluginBridge: startOAuth gating

    func testBridgeRejectsOAuthWithoutCapability() async {
        let bridge = PluginBridge(pluginID: "test-plugin", capabilities: [.network, .secrets])
        do {
            _ = try await bridge.handle(type: "startOAuth", payload: [
                "authorizeURL": "https://example.com/auth",
                "state": "abc",
            ])
            XCTFail("expected missingCapability error")
        } catch let error as PluginBridge.BridgeError {
            guard case .missingCapability(.oauth) = error else {
                XCTFail("expected .missingCapability(.oauth), got \(error)")
                return
            }
        } catch {
            XCTFail("expected BridgeError, got \(error)")
        }
    }

    // MARK: - PluginBridge: startOAuth payload validation
    //
    // These all fail before any browser is opened or listener started, so
    // they're safe to exercise in tests.

    private func assertInvalidPayload(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) async {
        let bridge = PluginBridge(pluginID: "test-plugin", capabilities: [.oauth])
        do {
            _ = try await bridge.handle(type: "startOAuth", payload: payload)
            XCTFail("expected invalidPayload error", file: file, line: line)
        } catch let error as PluginBridge.BridgeError {
            guard case .invalidPayload = error else {
                XCTFail("expected .invalidPayload, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("expected BridgeError, got \(error)", file: file, line: line)
        }
    }

    func testOAuthRejectsMissingAuthorizeURL() async {
        await assertInvalidPayload(["state": "abc"])
    }

    func testOAuthRejectsNonHTTPSAuthorizeURL() async {
        await assertInvalidPayload(["authorizeURL": "http://example.com/auth", "state": "abc"])
        await assertInvalidPayload(["authorizeURL": "file:///etc/passwd", "state": "abc"])
    }

    func testOAuthRejectsMissingState() async {
        await assertInvalidPayload(["authorizeURL": "https://example.com/auth"])
    }

    func testOAuthRejectsPrivilegedPort() async {
        await assertInvalidPayload([
            "authorizeURL": "https://example.com/auth",
            "state": "abc",
            "port": 80,
        ])
    }

    // MARK: - OAuthLoopbackServer.parseCallback

    private func httpRequestBytes(_ target: String) -> Data {
        Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    }

    func testParseCallbackSuccessReturnsQueryItems() {
        let result = OAuthLoopbackServer.parseCallback(
            data: httpRequestBytes("/callback?code=authcode123&state=xyz789"),
            expectedState: "xyz789"
        )
        guard case .success(let query) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertEqual(query["code"], "authcode123")
        XCTAssertEqual(query["state"], "xyz789")
    }

    func testParseCallbackStateMismatchIsRejected() {
        let result = OAuthLoopbackServer.parseCallback(
            data: httpRequestBytes("/callback?code=authcode123&state=WRONG"),
            expectedState: "xyz789"
        )
        guard case .failure(let error) = result,
              case .stateMismatch = error else {
            XCTFail("expected stateMismatch, got \(result)")
            return
        }
    }

    func testParseCallbackMissingCode() {
        let result = OAuthLoopbackServer.parseCallback(
            data: httpRequestBytes("/callback?state=xyz789"),
            expectedState: "xyz789"
        )
        guard case .failure(let error) = result,
              case .missingCode = error else {
            XCTFail("expected missingCode, got \(result)")
            return
        }
    }

    func testParseCallbackProviderDenied() {
        // URLComponents decodes %20 (not '+') as a space in query strings.
        let result = OAuthLoopbackServer.parseCallback(
            data: httpRequestBytes("/callback?error=access_denied&error_description=user%20declined&state=xyz789"),
            expectedState: "xyz789"
        )
        guard case .failure(let error) = result,
              case .denied(let description) = error else {
            XCTFail("expected denied, got \(result)")
            return
        }
        XCTAssertEqual(description, "user declined")
    }

    func testParseCallbackGarbageData() {
        let result = OAuthLoopbackServer.parseCallback(
            data: Data("not an http request".utf8),
            expectedState: "xyz789"
        )
        guard case .failure = result else {
            XCTFail("expected failure for garbage input")
            return
        }
    }

    // MARK: - Bluesky facet byte offsets

    func testBlueskyFacetOffsetsPlainASCII() {
        let facets = MaestroTools.detectBlueskyLinkFacets(in: "hello https://example.com world")
        XCTAssertEqual(facets.count, 1)
        let index = facets[0]["index"] as? [String: Int]
        XCTAssertEqual(index?["byteStart"], 6)
        XCTAssertEqual(index?["byteEnd"], 6 + "https://example.com".utf8.count)
        let features = facets[0]["features"] as? [[String: Any]]
        XCTAssertEqual(features?.first?["uri"] as? String, "https://example.com")
    }

    func testBlueskyFacetOffsetsWithEmojiPrefix() {
        // "👋 " is 5 UTF-8 bytes (4-byte emoji + space) but only 2 UTF-16
        // units + space — byteStart must come from UTF-8 counts.
        let facets = MaestroTools.detectBlueskyLinkFacets(in: "👋 https://x.co")
        XCTAssertEqual(facets.count, 1)
        let index = facets[0]["index"] as? [String: Int]
        XCTAssertEqual(index?["byteStart"], "👋 ".utf8.count)
    }

    func testBlueskyFacetNoneWhenNoURL() {
        XCTAssertTrue(MaestroTools.detectBlueskyLinkFacets(in: "just text, no links").isEmpty)
    }
}
