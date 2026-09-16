import AppKit
import Foundation
import WebKit
import MLXLMCommon

/// Type-erased Sendable wrapper for WKScriptMessage.body (which is `Any`).
private struct SendableAny: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Native side of a plugin's JS↔Swift bridge. One instance per loaded plugin
/// panel, scoped to that plugin's `id` and the `PluginCapability`s its
/// manifest declared — every request is checked against those capabilities
/// before being honored, so a plugin's actual reach is exactly what its
/// manifest states.
///
/// Wire protocol (see `PluginBridge.injectedScriptSource` for the matching
/// JS side): the webview posts
/// `{ id: String, type: String, payload: [String: Any] }` to the
/// `swiftMaestroBridge` message handler. For anything other than `log`,
/// the native side eventually calls back into
/// `window.__swiftMaestroResolve(id, result)` or
/// `window.__swiftMaestroReject(id, message)` to fulfill the JS-side Promise
/// that call created.
@MainActor
final class PluginBridge: NSObject, WKScriptMessageHandler {

    private let pluginID: String
    private let capabilities: Set<PluginCapability>
    weak var webView: WKWebView?

    init(pluginID: String, capabilities: [PluginCapability]) {
        self.pluginID = pluginID
        self.capabilities = Set(capabilities)
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        // message.body is MainActor-isolated in newer SDKs — snapshot it on
        // the main thread before crossing into the nonisolated context.
        let bodySnapshot: SendableAny = MainActor.assumeIsolated { SendableAny(message.body) }
        guard let dict = bodySnapshot.value as? [String: Any],
              let id = dict["id"] as? String,
              let type = dict["type"] as? String
        else { return }
        let payload = dict["payload"] as? [String: Any] ?? [:]

        Task { @MainActor [weak self] in
            guard let self else { return }
            if type == "log" {
                NSLog("[Plugin:\(self.pluginID)] \((payload["message"] as? String) ?? "")")
                return
            }
            do {
                let result = try await self.handle(type: type, payload: payload)
                self.resolve(id: id, result: result)
            } catch {
                self.reject(id: id, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Dispatch

    enum BridgeError: LocalizedError {
        case missingCapability(PluginCapability)
        case invalidPayload(String)
        case unknownRequestType(String)

        var errorDescription: String? {
            switch self {
            case .missingCapability(let cap):
                return "This plugin hasn't declared the '\(cap.rawValue)' capability in its manifest."
            case .invalidPayload(let detail):
                return "Invalid request payload: \(detail)"
            case .unknownRequestType(let type):
                return "Unknown bridge request type: \(type)"
            }
        }
    }

    private func requireCapability(_ capability: PluginCapability) throws {
        guard capabilities.contains(capability) else { throw BridgeError.missingCapability(capability) }
    }

    /// Internal (not private) so tests can exercise capability gating and
    /// dispatch directly without needing a live WKWebView/WKScriptMessage.
    func handle(type: String, payload: [String: Any]) async throws -> Any? {
        switch type {
        case "getSecret":
            try requireCapability(.secrets)
            guard let name = payload["name"] as? String, !name.isEmpty else {
                throw BridgeError.invalidPayload("'name' is required")
            }
            return try KeychainService.read(account: secretAccount(name))

        case "setSecret":
            try requireCapability(.secrets)
            guard let name = payload["name"] as? String, !name.isEmpty,
                  let value = payload["value"] as? String
            else { throw BridgeError.invalidPayload("'name' and 'value' are required") }
            try KeychainService.store(account: secretAccount(name), value: value, synchronizable: false)
            return nil

        case "fetch":
            try requireCapability(.network)
            guard let urlString = payload["url"] as? String, let url = URL(string: urlString) else {
                throw BridgeError.invalidPayload("'url' is required and must be a valid URL")
            }
            let options = payload["options"] as? [String: Any] ?? [:]
            return try await performFetch(url: url, options: options)

        case "callTool":
            try requireCapability(.tools)
            guard let name = payload["name"] as? String, !name.isEmpty else {
                throw BridgeError.invalidPayload("'name' is required")
            }
            let arguments = (payload["arguments"] as? [String: Any] ?? [:]).mapValues { JSONValue.from($0) }
            let call = ToolCall(function: .init(name: name, arguments: arguments))
            return await MaestroTools.execute(call)

        case "startOAuth":
            try requireCapability(.oauth)
            return try await performOAuth(payload: payload)

        // MARK: - Browser-extension capabilities

        case "storageLocalGet":
            try requireCapability(.storage)
            guard let key = payload["key"] as? String, !key.isEmpty else {
                throw BridgeError.invalidPayload("'key' is required")
            }
            return try storageLocalGet(key: key)

        case "storageLocalSet":
            try requireCapability(.storage)
            guard let key = payload["key"] as? String, !key.isEmpty else {
                throw BridgeError.invalidPayload("'key' is required")
            }
            storageLocalSet(key: key, value: payload["value"])
            return nil

        case "storageLocalRemove":
            try requireCapability(.storage)
            guard let key = payload["key"] as? String, !key.isEmpty else {
                throw BridgeError.invalidPayload("'key' is required")
            }
            storageLocalRemove(key: key)
            return nil

        case "storageLocalClear":
            try requireCapability(.storage)
            storageLocalClear()
            return nil

        case "tabsQuery":
            try requireCapability(.tabs)
            return tabsQuery(payload: payload)

        case "tabsGetCurrent":
            try requireCapability(.tabs)
            return tabsGetCurrent()

        case "tabsExecuteScript":
            try requireCapability(.activeTab)
            guard let script = payload["script"] as? String, !script.isEmpty else {
                throw BridgeError.invalidPayload("'script' is required")
            }
            let tabId = payload["tabId"] as? String
            return try await tabsExecuteScript(script: script, tabId: tabId)

        case "downloadsDownload":
            try requireCapability(.downloads)
            guard let urlString = payload["url"] as? String,
                  let url = URL(string: urlString)
            else { throw BridgeError.invalidPayload("'url' is required and must be valid") }
            return try await downloadsDownload(url: url, filename: payload["filename"] as? String)

        case "browserActionSetBadgeText":
            try requireCapability(.browserAction)
            let text = payload["text"] as? String
            BrowserExtensionService.shared.setBadgeText(text, forExtensionID: pluginID)
            return nil

        default:
            throw BridgeError.unknownRequestType(type)
        }
    }

    private func secretAccount(_ name: String) -> String {
        "plugin.\(pluginID).\(name)"
    }

    // MARK: - Native fetch proxy

    /// `options`: `{ method?: String, headers?: [String: String], body?: String }`.
    /// Returns `{ status: Int, headers: [String: String], body: String }`.
    private func performFetch(url: URL, options: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String)?.uppercased() ?? "GET"
        if let headers = options["headers"] as? [String: String] {
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        if let body = options["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var responseHeaders: [String: String] = [:]
        if let http {
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { responseHeaders[k] = v }
            }
        }
        return [
            "status": http?.statusCode ?? 0,
            "headers": responseHeaders,
            "body": String(data: data, encoding: .utf8) ?? data.base64EncodedString(),
        ]
    }

    // MARK: - OAuth (loopback)

    /// `payload`: `{ authorizeURL: String, state: String, port?: Int, timeoutSeconds?: Int }`.
    /// Opens the authorize URL in the default browser, then waits for the
    /// provider's redirect on a loopback-only listener. Returns the callback's
    /// query items (`{ code, state, … }`) — the plugin performs the token
    /// exchange itself via `fetch`, so client secrets and tokens never pass
    /// through the native side.
    private func performOAuth(payload: [String: Any]) async throws -> [String: String] {
        guard let urlString = payload["authorizeURL"] as? String,
              let authorizeURL = URL(string: urlString),
              authorizeURL.scheme == "https"
        else {
            throw BridgeError.invalidPayload("'authorizeURL' is required and must be an https URL")
        }
        guard let state = payload["state"] as? String, !state.isEmpty else {
            throw BridgeError.invalidPayload("'state' is required")
        }
        let rawPort = (payload["port"] as? Int) ?? 53124
        guard (1024...65535).contains(rawPort), let port = UInt16(exactly: rawPort) else {
            throw BridgeError.invalidPayload("'port' must be between 1024 and 65535")
        }
        let rawTimeout = (payload["timeoutSeconds"] as? Int) ?? 120
        let timeout = max(min(rawTimeout, 600), 15)

        NSWorkspace.shared.open(authorizeURL)
        return try await OAuthLoopbackServer.waitForCallback(
            expectedState: state,
            port: port,
            timeout: .seconds(timeout)
        )
    }

    // MARK: - Browser-extension helpers

    // MARK: Storage

    private func storageURL() -> URL {
        BrowserExtensionService.shared.localStorageURL(forExtensionID: pluginID)
    }

    private func readStorage() -> [String: Any] {
        guard let data = try? Data(contentsOf: storageURL()),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private func writeStorage(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storageURL())
    }

    private func storageLocalGet(key: String) throws -> Any? {
        readStorage()[key]
    }

    private func storageLocalSet(key: String, value: Any?) {
        do {
            var dict = readStorage()
            if let value { dict[key] = value } else { dict.removeValue(forKey: key) }
            try writeStorage(dict)
        } catch {
            NSLog("[PluginBridge:\(pluginID)] storage set failed: \(error)")
        }
    }

    private func storageLocalRemove(key: String) {
        storageLocalSet(key: key, value: nil)
    }

    private func storageLocalClear() {
        do {
            try writeStorage([:])
        } catch {
            NSLog("[PluginBridge:\(pluginID)] storage clear failed: \(error)")
        }
    }

    // MARK: Tabs

    private func tabsQuery(payload: [String: Any]) -> [[String: Any]] {
        let store = WebBrowserStore.shared
        let activeOnly = payload["active"] as? Bool ?? false
        return store.tabs.compactMap { tab in
            if activeOnly, store.selectedTabID != tab.id { return nil }
            return tabPayload(tab, store: store)
        }
    }

    private func tabsGetCurrent() -> [String: Any]? {
        let store = WebBrowserStore.shared
        guard let tab = store.selectedTab else { return nil }
        return tabPayload(tab, store: store)
    }

    private func tabPayload(_ tab: BrowserTab, store: WebBrowserStore) -> [String: Any] {
        [
            "id": tab.id.uuidString,
            "url": tab.currentURL?.absoluteString ?? "",
            "title": tab.title,
            "active": store.selectedTabID == tab.id,
            "loading": tab.isLoading,
            "engine": tab.engineType.rawValue,
        ]
    }

    private func tabsExecuteScript(script: String, tabId: String?) async throws -> Any? {
        let store = WebBrowserStore.shared
        let tab: BrowserTab?
        if let tabId = tabId, !tabId.isEmpty,
           let id = UUID(uuidString: tabId) {
            tab = store.tabs.first(where: { $0.id == id })
        } else {
            tab = store.selectedTab
        }
        guard let tab else { throw BridgeError.invalidPayload("No active/requested tab") }
        guard let data = try await tab.evaluateJavaScript(script) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Downloads

    private func downloadsDownload(url: URL, filename: String?) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as? HTTPURLResponse
        let suggestedName = filename ?? url.lastPathComponent

        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var target = downloadsDir.appendingPathComponent(suggestedName)
        // Disambiguate if file already exists.
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let suffix = ext.isEmpty ? "-\(counter)" : "-\(counter).\(ext)"
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix)"
            target = downloadsDir.appendingPathComponent(name)
            counter += 1
        }
        try data.write(to: target)
        return [
            "success": true,
            "path": target.path,
            "bytes": data.count,
            "status": http?.statusCode ?? 0,
        ]
    }

    // MARK: - JS callbacks

    private func resolve(id: String, result: Any?) {
        let json = Self.bridgeResultJSON(result)
        webView?.evaluateJavaScript("window.__swiftMaestroResolve(\(Self.jsString(id)), \(json))")
    }

    /// Serializes a bridge handler's return value for the JS callback.
    ///
    /// Crash-safe by construction (confirmed live as an app-wide SIGTRAP):
    /// a handler returning `String?.none` (e.g. `getSecret` for a key that
    /// doesn't exist) arrives here as a NON-nil `Any?` holding a nested
    /// `Optional.none`, and feeding that to `JSONSerialization` raises an
    /// uncatchable `NSInvalidArgumentException` ("Invalid top-level type")
    /// that `try?` cannot intercept. So the value is first flattened and
    /// sanitized to a guaranteed-JSON-safe form, and only then serialized —
    /// with `.fragmentsAllowed` so top-level scalars (String/Int/Bool/null)
    /// are legal without the old String-only fallback dance.
    /// Internal (not private) so tests can exercise it without a WKWebView.
    static func bridgeResultJSON(_ result: Any?) -> String {
        let safe = jsonSafeValue(result)
        guard let data = try? JSONSerialization.data(
            withJSONObject: safe, options: .fragmentsAllowed),
              let string = String(data: data, encoding: .utf8)
        else { return "null" }
        return string
    }

    /// Flattens nested optionals and maps anything JSON can't express to a
    /// safe stand-in: missing optionals become NSNull, non-serializable
    /// values become their `String(describing:)`.
    private static func jsonSafeValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first?.value else { return NSNull() }
            return jsonSafeValue(child)
        }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    private func reject(id: String, message: String) {
        webView?.evaluateJavaScript(
            "window.__swiftMaestroReject(\(Self.jsString(id)), \(Self.jsString(message)))")
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    // MARK: - Injected JS

    /// Injected before any plugin content runs (`.atDocumentStart`), so
    /// `window.swiftMaestro` is available immediately to the plugin's own scripts.
    static let injectedScriptSource = """
    (function() {
        const pending = {};
        let nextId = 1;

        function send(type, payload) {
            return new Promise((resolve, reject) => {
                const id = String(nextId++);
                pending[id] = { resolve, reject };
                window.webkit.messageHandlers.swiftMaestroBridge.postMessage({ id, type, payload: payload || {} });
            });
        }

        window.__swiftMaestroResolve = function(id, result) {
            const entry = pending[id];
            if (!entry) return;
            delete pending[id];
            entry.resolve(result);
        };

        window.__swiftMaestroReject = function(id, message) {
            const entry = pending[id];
            if (!entry) return;
            delete pending[id];
            entry.reject(new Error(message));
        };

        window.swiftMaestro = {
            getSecret: (name) => send('getSecret', { name: name }),
            setSecret: (name, value) => send('setSecret', { name: name, value: value }),
            fetch: (url, options) => send('fetch', { url: url, options: options || {} }),
            callTool: (name, args) => send('callTool', { name: name, arguments: args || {} }),
            startOAuth: (options) => send('startOAuth', options || {}),
            log: (message) => {
                window.webkit.messageHandlers.swiftMaestroBridge.postMessage(
                    { id: '0', type: 'log', payload: { message: String(message) } });
            },
            storage: {
                local: {
                    get: (key) => send('storageLocalGet', { key: key }),
                    set: (key, value) => send('storageLocalSet', { key: key, value: value }),
                    remove: (key) => send('storageLocalRemove', { key: key }),
                    clear: () => send('storageLocalClear', {})
                }
            },
            tabs: {
                query: (query) => send('tabsQuery', query || {}),
                getCurrent: () => send('tabsGetCurrent', {}),
                executeScript: (tabId, script) => {
                    if (typeof tabId === 'number' || typeof tabId === 'string') {
                        return send('tabsExecuteScript', { tabId: String(tabId), script: script });
                    }
                    // If first arg is the script (tabId omitted), shift.
                    return send('tabsExecuteScript', { script: tabId });
                }
            },
            downloads: {
                download: (options) => send('downloadsDownload', options || {})
            },
            browserAction: {
                setBadgeText: (text) => send('browserActionSetBadgeText', { text: text })
            }
        };
    })();
    """
}
