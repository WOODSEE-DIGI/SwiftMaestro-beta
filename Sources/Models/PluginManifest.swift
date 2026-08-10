import Foundation

/// Describes one WKWebView-hosted UI plugin: a small folder of static web
/// content (HTML/CSS/JS) rendered in its own sandboxed panel, talking to the
/// host app only through the `PluginBridge` message-passing API — never
/// through direct native/file-system access.
///
/// Plugins are discovered from two locations (see `PluginService`):
/// bundled ones ship inside the app itself; user-installed ones live under
/// `~/Library/Application Support/SwiftMaestro/plugins/<id>/`. Both use the
/// exact same manifest format, so a bundled plugin and a hand-written one
/// are indistinguishable to the rest of the app.
struct PluginManifest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    /// SF Symbol name for the sidebar row / panel icon.
    let icon: String
    /// Entry HTML file, relative to this manifest's own folder (e.g. "index.html").
    let entry: String
    let version: String
    /// Bridge capabilities this plugin is granted, secure-by-default (empty =
    /// none). See `PluginCapability` for the full set and what each unlocks.
    /// A plugin must declare a capability here before its JS can use the
    /// matching `swiftMaestro.*` bridge function — undeclared calls are
    /// rejected by `PluginBridge`, not silently allowed.
    let capabilities: [PluginCapability]

    /// The folder this manifest was loaded from — NOT part of the JSON itself
    /// (manifests don't know their own location), populated by `PluginService`
    /// after parsing so the rest of the app can resolve `entry` and any other
    /// relative asset paths.
    var contentRootURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, entry, version, capabilities
    }

    init(
        id: String, name: String, icon: String, entry: String, version: String,
        capabilities: [PluginCapability] = [], contentRootURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.entry = entry
        self.version = version
        self.capabilities = capabilities
        self.contentRootURL = contentRootURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        entry = try container.decode(String.self, forKey: .entry)
        version = try container.decode(String.self, forKey: .version)
        capabilities = try container.decodeIfPresent([PluginCapability].self, forKey: .capabilities) ?? []
        contentRootURL = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(entry, forKey: .entry)
        try container.encode(version, forKey: .version)
        try container.encode(capabilities, forKey: .capabilities)
    }

    /// Full URL to the entry HTML file, if `contentRootURL` has been resolved.
    var entryURL: URL? {
        contentRootURL?.appendingPathComponent(entry)
    }
}

/// A bridge capability a plugin can declare in its manifest to unlock the
/// matching `swiftMaestro.*` JS function. `PluginBridge` checks this before
/// honoring any request — an undeclared capability is a hard rejection, not
/// a soft/ignored one, so a plugin's actual reach is exactly what its
/// manifest states, auditable at a glance.
enum PluginCapability: String, Codable, Hashable, Sendable {
    /// Unlocks `swiftMaestro.fetch(url, options)` — a native URLSession-backed
    /// HTTP proxy. Requests never go through the webview's own fetch/XHR
    /// stack, so they aren't subject to a remote server's CORS policy (most
    /// APIs a plugin would target, e.g. Mastodon instances, don't set
    /// permissive CORS for arbitrary origins).
    case network
    /// Unlocks `swiftMaestro.getSecret(name)` / `setSecret(name, value)` —
    /// Keychain-backed storage, namespaced per-plugin
    /// (`plugin.<id>.<name>`), so one plugin can never read another's.
    case secrets
    /// Unlocks `swiftMaestro.callTool(name, arguments)` — dispatches through
    /// the same native tool registry agents use (`MaestroTools.execute`),
    /// letting a plugin's data be reachable by agents too (or vice versa).
    /// Not required for a read/write-only plugin; opt in deliberately.
    case tools
    /// Unlocks `swiftMaestro.startOAuth(options)` — opens an authorize URL in
    /// the default browser and captures the redirect on a loopback-only
    /// listener (`OAuthLoopbackServer`), returning the authorization code.
    /// The token exchange itself happens via `swiftMaestro.fetch`, so the
    /// host never sees the client secret or the resulting tokens.
    case oauth
}
