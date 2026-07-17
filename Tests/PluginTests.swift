import XCTest
@testable import SwiftMaestro

@MainActor
final class PluginTests: XCTestCase {

    // MARK: - PluginManifest decoding

    func testManifestDecodesWithCapabilities() throws {
        let json = """
        {"id":"mastodon","name":"Mastodon","icon":"bubble.left","entry":"index.html",
         "version":"1.0.0","capabilities":["network","secrets"]}
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.id, "mastodon")
        XCTAssertEqual(manifest.capabilities, [.network, .secrets])
        XCTAssertFalse(manifest.capabilities.contains(.tools))
    }

    func testManifestDefaultsToNoCapabilitiesWhenFieldMissing() throws {
        let json = """
        {"id":"minimal","name":"Minimal","icon":"circle","entry":"index.html","version":"1.0.0"}
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.capabilities.isEmpty)
    }

    func testEntryURLResolvesAgainstContentRoot() {
        var manifest = PluginManifest(id: "x", name: "X", icon: "circle", entry: "index.html", version: "1.0.0")
        XCTAssertNil(manifest.entryURL)
        manifest.contentRootURL = URL(fileURLWithPath: "/tmp/plugins/x")
        XCTAssertEqual(manifest.entryURL?.path, "/tmp/plugins/x/index.html")
    }

    // MARK: - PluginService discovery

    private func makeTempPluginDir(id: String, name: String, in root: URL) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {"id":"\(id)","name":"\(name)","icon":"circle","entry":"index.html","version":"1.0.0"}
        """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    func testScanFindsValidManifests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeTempPluginDir(id: "alpha", name: "Alpha", in: root)
        try makeTempPluginDir(id: "beta", name: "Beta", in: root)

        let found = PluginService.scan(directory: root)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.id)), ["alpha", "beta"])
        for manifest in found {
            XCTAssertNotNil(manifest.contentRootURL)
            XCTAssertNotNil(manifest.entryURL)
        }
    }

    func testScanIgnoresFoldersWithoutAValidManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeTempPluginDir(id: "good", name: "Good", in: root)
        // A folder with no manifest.json at all.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("no-manifest"), withIntermediateDirectories: true)
        // A folder with a malformed manifest.json.
        let brokenDir = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try "not valid json".write(to: brokenDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let found = PluginService.scan(directory: root)
        XCTAssertEqual(found.map(\.id), ["good"])
    }

    func testScanNonexistentDirectoryReturnsEmpty() {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(PluginService.scan(directory: bogus), [])
    }

    // MARK: - PluginBridge capability gating

    func testBridgeRejectsFetchWithoutNetworkCapability() async {
        let bridge = PluginBridge(pluginID: "test-plugin", capabilities: [])
        do {
            _ = try await bridge.handle(type: "fetch", payload: ["url": "https://example.com"])
            XCTFail("expected missingCapability error")
        } catch let error as PluginBridge.BridgeError {
            guard case .missingCapability(.network) = error else {
                XCTFail("expected .missingCapability(.network), got \(error)")
                return
            }
        } catch {
            XCTFail("expected BridgeError, got \(error)")
        }
    }

    func testBridgeRejectsSecretsWithoutSecretsCapability() async {
        let bridge = PluginBridge(pluginID: "test-plugin", capabilities: [.network])
        do {
            _ = try await bridge.handle(type: "getSecret", payload: ["name": "token"])
            XCTFail("expected missingCapability error")
        } catch let error as PluginBridge.BridgeError {
            guard case .missingCapability(.secrets) = error else {
                XCTFail("expected .missingCapability(.secrets), got \(error)")
                return
            }
        } catch {
            XCTFail("expected BridgeError, got \(error)")
        }
    }

    func testBridgeRejectsCallToolWithoutToolsCapability() async {
        let bridge = PluginBridge(pluginID: "test-plugin", capabilities: [.network, .secrets])
        do {
            _ = try await bridge.handle(type: "callTool", payload: ["name": "get_current_time"])
            XCTFail("expected missingCapability error")
        } catch let error as PluginBridge.BridgeError {
            guard case .missingCapability(.tools) = error else {
                XCTFail("expected .missingCapability(.tools), got \(error)")
                return
            }
        } catch {
            XCTFail("expected BridgeError, got \(error)")
        }
    }

    func testBridgeRejectsUnknownRequestType() async {
        let bridge = PluginBridge(pluginID: "test-plugin", capabilities: [.network, .secrets, .tools])
        do {
            _ = try await bridge.handle(type: "doSomethingWeird", payload: [:])
            XCTFail("expected unknownRequestType error")
        } catch let error as PluginBridge.BridgeError {
            guard case .unknownRequestType("doSomethingWeird") = error else {
                XCTFail("expected .unknownRequestType, got \(error)")
                return
            }
        } catch {
            XCTFail("expected BridgeError, got \(error)")
        }
    }

    func testBridgeCallToolDispatchesWithToolsCapability() async {
        let bridge = PluginBridge(pluginID: "test-plugin", capabilities: [.tools])
        do {
            let result = try await bridge.handle(type: "callTool", payload: ["name": "get_current_time"])
            let text = result as? String ?? ""
            XCTAssertTrue(text.contains("current_time"))
        } catch {
            XCTFail("expected callTool to succeed, got \(error)")
        }
    }

    func testBridgeSecretRoundTripWithSecretsCapability() async throws {
        let pluginID = "test-plugin-\(UUID().uuidString)"
        defer { try? KeychainService.delete(account: "plugin.\(pluginID).unitTestToken") }

        let bridge = PluginBridge(pluginID: pluginID, capabilities: [.secrets])
        _ = try await bridge.handle(type: "setSecret", payload: ["name": "unitTestToken", "value": "sekrit-value"])
        let result = try await bridge.handle(type: "getSecret", payload: ["name": "unitTestToken"])
        XCTAssertEqual(result as? String, "sekrit-value")
    }
}
