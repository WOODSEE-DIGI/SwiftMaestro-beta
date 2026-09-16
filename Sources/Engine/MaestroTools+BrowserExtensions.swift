import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Browser-extension management tools
//
// Lets Maestro agents install, list, and reload user-created SwiftBrowser
// extensions. Extensions live outside the app bundle so they survive
// SwiftMaestro updates.

extension MaestroTools {

    static func registerBrowserExtensionTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "install_browser_extension",
                spec: browserExtensionToolSpecs[0],
                category: ToolCategory.browser.rawValue,
                handler: { call in await installBrowserExtension(call) }),
            ToolDefinition(
                name: "uninstall_browser_extension",
                spec: browserExtensionToolSpecs[1],
                category: ToolCategory.browser.rawValue,
                handler: { call in await uninstallBrowserExtension(call) }),
            ToolDefinition(
                name: "list_browser_extensions",
                spec: browserExtensionToolSpecs[2],
                category: ToolCategory.browser.rawValue,
                handler: { _ in await listBrowserExtensions() }),
            ToolDefinition(
                name: "reload_browser_extensions",
                spec: browserExtensionToolSpecs[3],
                category: ToolCategory.browser.rawValue,
                handler: { _ in await reloadBrowserExtensions() }),
        ])
    }

    static var browserExtensionToolSpecs: [ToolSpec] {
        [
            rawSpec("install_browser_extension",
                "Install or update a user-created SwiftBrowser extension. Writes the manifest and "
                + "assets to ~/Library/Application Support/SwiftMaestro/BrowserExtensions/<id>/, "
                + "outside the app bundle, so it survives SwiftMaestro updates. The extension can "
                + "add a toolbar button (browser-action), inject content scripts into matching pages, "
                + "or open as a sidebar panel. Use this when the user asks for custom browser behavior, "
                + "e.g. 'add a YouTube download button' or 'highlight prices on Amazon'. "
                + "EXAMPLE: id='com.example.youtube-downloader', name='YouTube Downloader', "
                + "manifest={type:'browser-action', version:'1.0.0', icon:'arrow.down.circle', entry:'popup.html', "
                + "capabilities:['tabs','activeTab','downloads'], host:{toolbar:{icon:'arrow.down.circle', label:'Download'}}, "
                + "content_scripts:[{matches:['*://*.youtube.com/*'], js:['content.js'], run_at:'document_idle'}]}, "
                + "files={ 'popup.html':'<html><body><button id=btn>Download</button><script src=popup.js></script></body></html>', "
                + "'popup.js':'document.getElementById(\"btn\").onclick = () => { swiftMaestro.tabs.query({active:true}, tabs => { console.log(tabs[0].url); }); };', "
                + "'content.js':'console.log(\"YouTube downloader loaded\");' }.",
                properties: [
                    "id": ["type": "string", "description": "Reverse-domain extension id, e.g. 'com.user.youtube-downloader'."],
                    "name": ["type": "string", "description": "Human-readable extension name."],
                    "manifest": ["type": "object", "description": "Extension manifest JSON object. Required keys: type ('panel'|'browser-action'|'content-script'), version, icon (SF Symbol name), entry (HTML file name), capabilities array, optional host:{toolbar:{icon,label?,tooltip?}}, optional content_scripts array where each entry has matches, js, css?, run_at?. id and name are overwritten by the top-level parameters."],
                    "files": ["type": "object", "description": "JSON object mapping relative file paths (e.g. 'index.html', 'toolbar.js') to their UTF-8 content strings. Must be valid JSON, not a Python-style dict."],
                ],
                required: ["id", "name", "manifest", "files"]),
            rawSpec("uninstall_browser_extension",
                "Remove an installed SwiftBrowser extension by id.",
                properties: [
                    "id": ["type": "string", "description": "Extension id to remove."],
                ],
                required: ["id"]),
            rawSpec("list_browser_extensions",
                "List all installed user-created SwiftBrowser extensions with their id, name, type, version, and capabilities.",
                properties: [:],
                required: []),
            rawSpec("reload_browser_extensions",
                "Rescan the BrowserExtensions directory and refresh the toolbar/content-script registries. Call after manual file changes.",
                properties: [:],
                required: []),
        ]
    }

    // MARK: - Args

    private struct InstallArgs: Decodable {
        let id: String
        let name: String
        let manifest: PluginManifest
        let files: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            manifest = try Self.decodeManifest(from: container, forKey: .manifest)
            files = try Self.decodeFiles(from: container, forKey: .files)
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, manifest, files
        }

        private static func decodeManifest(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> PluginManifest {
            // Models sometimes wrap the manifest object in a string; accept either form.
            if let object = try? container.decode(PluginManifest.self, forKey: key) {
                return object
            }
            if let raw = try? container.decode(String.self, forKey: key),
               let normalized = normalizedManifestDictionary(raw),
               let data = try? JSONSerialization.data(withJSONObject: normalized),
               let object = try? JSONDecoder().decode(PluginManifest.self, from: data) {
                return object
            }
            throw DecodingError.typeMismatch(PluginManifest.self, DecodingError.Context(
                codingPath: container.codingPath, debugDescription: "manifest must be a valid JSON object"))
        }

        private static func decodeFiles(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> [String: String] {
            if let object = try? container.decode([String: String].self, forKey: key) {
                return object
            }
            if let raw = try? container.decode(String.self, forKey: key),
               let dict = LenientJSON.dictionary(raw) {
                var files: [String: String] = [:]
                for (path, value) in dict {
                    if let string = value as? String {
                        files[path] = string
                    } else if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                              let string = String(data: data, encoding: .utf8) {
                        files[path] = string
                    }
                }
                if !files.isEmpty { return files }
            }
            throw DecodingError.typeMismatch([String: String].self, DecodingError.Context(
                codingPath: container.codingPath, debugDescription: "files must be a JSON object mapping paths to content strings"))
        }

        /// Normalize a model-generated manifest blob into a dictionary that
        /// PluginManifest's decoder expects. Handles unquoted JS-style keys,
        /// single/backtick-quoted strings, and common alias mistakes.
        private static func normalizedManifestDictionary(_ raw: String) -> [String: Any]? {
            guard let dict = LenientJSON.dictionary(raw) else { return nil }
            var normalized = dict

            // Models often put `toolbar` at the top level instead of `host.toolbar`.
            if normalized["host"] == nil, let toolbar = normalized["toolbar"] as? [String: Any] {
                normalized["host"] = ["toolbar": toolbar]
                normalized.removeValue(forKey: "toolbar")
            }

            // Normalize content script entries.
            if var scripts = normalized["content_scripts"] as? [[String: Any]] {
                for i in scripts.indices {
                    var script = scripts[i]
                    if let hostMatches = script["host_matches"] {
                        script["matches"] = hostMatches
                        script.removeValue(forKey: "host_matches")
                    }
                    if let path = script["path"] as? String {
                        script["js"] = [path]
                        script.removeValue(forKey: "path")
                    }
                    scripts[i] = script
                }
                normalized["content_scripts"] = scripts
            }

            return normalized
        }
    }

    private struct UninstallArgs: Decodable {
        let id: String
    }

    // MARK: - Handlers

    @MainActor
    private static func installBrowserExtension(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: InstallArgs.self) else {
            let diagnostics = argDiagnostics(call)
            return errorJSON("Invalid arguments. Required: id, name, manifest, files. \(diagnostics). "
                + "manifest and files must be valid JSON objects (or JSON strings), not Python-style dicts. "
                + "Use the example in the tool description.")
        }
        let manifest = PluginManifest(
            id: args.id,
            name: args.name,
            icon: args.manifest.icon,
            entry: args.manifest.entry,
            version: args.manifest.version,
            capabilities: args.manifest.capabilities,
            type: args.manifest.type,
            host: args.manifest.host,
            contentScripts: args.manifest.contentScripts
        )

        let service = BrowserExtensionService.shared
        if let installed = service.install(manifest: manifest, files: args.files) {
            return jsonString([
                "status": "installed",
                "id": installed.id,
                "name": installed.name,
                "type": installed.type.rawValue,
                "version": installed.version,
                "capabilities": installed.capabilities.map(\.rawValue),
                "path": installed.contentRootURL?.path ?? "",
            ])
        } else {
            return errorJSON(service.lastError ?? "Installation failed")
        }
    }

    @MainActor
    private static func uninstallBrowserExtension(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UninstallArgs.self), !args.id.isEmpty else {
            return errorJSON("'id' is required")
        }
        let service = BrowserExtensionService.shared
        let ok = service.uninstall(id: args.id)
        var payload: [String: Any] = [
            "status": ok ? "uninstalled" : "failed",
            "id": args.id,
        ]
        if !ok, let err = service.lastError {
            payload["error"] = err
        }
        return jsonString(payload)
    }

    @MainActor
    private static func listBrowserExtensions() async -> String {
        let service = BrowserExtensionService.shared
        let list: [[String: Any]] = service.extensions.map { ext in
            var entry: [String: Any] = [
                "id": ext.id,
                "name": ext.name,
                "type": ext.type.rawValue,
                "version": ext.version,
                "icon": ext.icon,
                "capabilities": ext.capabilities.map(\.rawValue),
                "entry": ext.entry,
                "content_scripts": (ext.contentScripts?.count ?? 0) > 0,
            ]
            entry["toolbar"] = ext.host?.toolbar?.icon
            return entry
        }
        return jsonString(["extensions": list, "count": list.count])
    }

    @MainActor
    private static func reloadBrowserExtensions() async -> String {
        BrowserExtensionService.shared.reload()
        return jsonString([
            "status": "reloaded",
            "count": BrowserExtensionService.shared.extensions.count,
        ])
    }
}
