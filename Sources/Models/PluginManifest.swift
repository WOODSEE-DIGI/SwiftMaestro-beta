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
/// How an extension integrates with SwiftBrowser.
enum PluginExtensionType: String, Codable, Hashable, Sendable {
    /// Existing behavior: opens as a workspace panel (sidebar icon).
    case panel
    /// Adds a button to SwiftBrowser's toolbar.
    case browserAction = "browser-action"
    /// Injects JS/CSS into matching web pages.
    case contentScript = "content-script"
}

/// A content script entry from the manifest: which pages it runs on and what
/// assets it injects.
struct ContentScriptEntry: Codable, Hashable, Sendable {
    /// URL match patterns, e.g. ["*://*.youtube.com/*"].
    let matches: [String]
    /// JS files relative to the extension root, injected in order.
    let js: [String]
    /// Optional CSS files relative to the extension root.
    let css: [String]?
    /// When to inject: "document_start", "document_end", "document_idle".
    /// Defaults to "document_idle".
    let runAt: String?

    private enum CodingKeys: String, CodingKey {
        case matches, js, css
        case runAt = "run_at"
    }
}

/// Toolbar button configuration for a `browser-action` extension.
struct ToolbarButtonConfig: Codable, Hashable, Sendable {
    /// SF Symbol name shown on the toolbar button.
    let icon: String
    /// Short label shown next to or under the icon.
    let label: String?
    /// Tooltip on hover.
    let tooltip: String?
}

/// Host-side integration hints for an extension.
struct HostConfig: Codable, Hashable, Sendable {
    /// If present, renders a toolbar button in SwiftBrowser.
    let toolbar: ToolbarButtonConfig?
}

struct PluginManifest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    /// SF Symbol name for the sidebar row / panel icon.
    let icon: String
    /// Entry HTML file, relative to this manifest's own folder (e.g. "index.html").
    /// For `browser-action` extensions this is the optional popover page.
    let entry: String
    let version: String
    /// Bridge capabilities this plugin is granted, secure-by-default (empty =
    /// none). See `PluginCapability` for the full set and what each unlocks.
    /// A plugin must declare a capability here before its JS can use the
    /// matching `swiftMaestro.*` bridge function — undeclared calls are
    /// rejected by `PluginBridge`, not silently allowed.
    let capabilities: [PluginCapability]

    // MARK: - Browser-extension fields

    /// How this extension integrates with SwiftBrowser. Defaults to `.panel`
    /// for backward compatibility with existing plugins.
    let type: PluginExtensionType
    /// Host-side UI integration (toolbar button, etc.).
    let host: HostConfig?
    /// Content scripts to inject into matching web pages.
    let contentScripts: [ContentScriptEntry]?

    /// The folder this manifest was loaded from — NOT part of the JSON itself
    /// (manifests don't know their own location), populated by `PluginService`
    /// / `BrowserExtensionService` after parsing so the rest of the app can
    /// resolve `entry` and any other relative asset paths.
    var contentRootURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, entry, version, capabilities
        case type
        case host
        case contentScripts = "content_scripts"
    }

    init(
        id: String, name: String, icon: String, entry: String, version: String,
        capabilities: [PluginCapability] = [],
        type: PluginExtensionType = .panel,
        host: HostConfig? = nil,
        contentScripts: [ContentScriptEntry]? = nil,
        contentRootURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.entry = entry
        self.version = version
        self.capabilities = capabilities
        self.type = type
        self.host = host
        self.contentScripts = contentScripts
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
        type = try container.decodeIfPresent(PluginExtensionType.self, forKey: .type) ?? .panel
        host = try container.decodeIfPresent(HostConfig.self, forKey: .host)
        contentScripts = try container.decodeIfPresent([ContentScriptEntry].self, forKey: .contentScripts)
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
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(contentScripts, forKey: .contentScripts)
    }

    /// Full URL to the entry HTML file, if `contentRootURL` has been resolved.
    var entryURL: URL? {
        contentRootURL?.appendingPathComponent(entry)
    }

    /// True if this manifest describes a SwiftBrowser extension rather than a
    /// plain sidebar-panel plugin.
    var isBrowserExtension: Bool {
        type != .panel
    }
}


