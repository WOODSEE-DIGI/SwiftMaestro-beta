import Foundation
import WebKit
import MLXLMCommon

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
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let type = body["type"] as? String
        else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]

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

    // MARK: - JS callbacks

    private func resolve(id: String, result: Any?) {
        let json: String
        if let result {
            let data = (try? JSONSerialization.data(withJSONObject: result))
                ?? (try? JSONEncoder().encode(result as? String))
                ?? Data("null".utf8)
            json = String(data: data, encoding: .utf8) ?? "null"
        } else {
            json = "null"
        }
        webView?.evaluateJavaScript("window.__swiftMaestroResolve(\(Self.jsString(id)), \(json))")
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
            log: (message) => {
                window.webkit.messageHandlers.swiftMaestroBridge.postMessage(
                    { id: '0', type: 'log', payload: { message: String(message) } });
            },
        };
    })();
    """
}
