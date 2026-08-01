import Foundation

/// Discovers WKWebView UI plugins from two locations, merges them, and hands
/// out a stable list the rest of the app (sidebar, workspace panels) can
/// treat as a single flat catalog:
///
/// 1. **Bundled** — shipped inside the app itself at
///    `Bundle.main.resourceURL/Plugins/<id>/`. This is where SwiftMaestro's
///    own first-party plugins (e.g. Mastodon) live.
/// 2. **User-installed** — `~/Library/Application Support/SwiftMaestro/plugins/<id>/`.
///    Anyone can drop a folder with a `manifest.json` + entry HTML there.
///
/// If the same `id` exists in both locations, the user-installed one wins —
/// it's the override, matching how most plugin systems let a user-provided
/// copy shadow a bundled default.
@Observable
@MainActor
final class PluginService {

    private(set) var plugins: [PluginManifest] = []
    private(set) var error: String?

    private let decoder = JSONDecoder()

    func loadPlugins() {
        error = nil
        var byID: [String: PluginManifest] = [:]

        // Bundled first (lower precedence)...
        if let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) {
            for manifest in Self.scan(directory: bundledRoot, decoder: decoder) {
                byID[manifest.id] = manifest
            }
        }
        // ...then user-installed, overriding any bundled plugin with the same id.
        for manifest in Self.scan(directory: SwiftMaestroPaths.pluginsDir, decoder: decoder) {
            byID[manifest.id] = manifest
        }

        plugins = byID.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func manifest(id: String) -> PluginManifest? {
        plugins.first { $0.id == id }
    }

    /// Scans immediate subdirectories of `directory` for a `manifest.json`,
    /// skipping (not failing on) anything malformed — one broken plugin
    /// folder shouldn't prevent every other plugin from loading. Internal
    /// (not private) so tests can exercise this directly against a temp
    /// directory without touching the real bundle/app-support paths.
    static func scan(directory: URL, decoder: JSONDecoder = JSONDecoder()) -> [PluginManifest] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [PluginManifest] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let manifestURL = entry.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  var manifest = try? decoder.decode(PluginManifest.self, from: data)
            else { continue }
            manifest.contentRootURL = entry
            found.append(manifest)
        }
        return found
    }
}
