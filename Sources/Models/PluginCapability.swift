import Foundation

/// A bridge capability a plugin or browser extension can declare in its manifest
/// to unlock the matching `swiftMaestro.*` JS function. `PluginBridge` checks this
/// before honoring any request — an undeclared capability is a hard rejection, not
/// a soft/ignored one, so an extension's actual reach is exactly what its manifest
/// states, auditable at a glance.
enum PluginCapability: String, Codable, Hashable, Sendable {
    /// Unlocks `swiftMaestro.fetch(url, options)` — a native URLSession-backed
    /// HTTP proxy. Requests never go through the webview's own fetch/XHR stack,
    /// so they aren't subject to a remote server's CORS policy.
    case network

    /// Unlocks `swiftMaestro.getSecret(name)` / `setSecret(name, value)` —
    /// Keychain-backed storage, namespaced per-extension (`plugin.<id>.<name>`),
    /// so one extension can never read another's.
    case secrets

    /// Unlocks `swiftMaestro.callTool(name, arguments)` — dispatches through the
    /// same native tool registry agents use (`MaestroTools.execute`), letting an
    /// extension's data be reachable by agents too.
    case tools

    /// Unlocks `swiftMaestro.startOAuth(options)` — opens an authorize URL in the
    /// default browser and captures the redirect on a loopback-only listener,
    /// returning the authorization code. The token exchange itself happens via
    /// `swiftMaestro.fetch`, so the host never sees the client secret or tokens.
    case oauth

    // MARK: - Browser-extension capabilities

    /// Unlocks `swiftMaestro.storage.local.*` — a JSON-backed key/value store
    /// scoped to this extension and persisted in its app-support directory.
    /// Survives app updates because it lives outside the app bundle.
    case storage

    /// Unlocks `swiftMaestro.tabs.query`, `activate`, and `getCurrent` — read-only
    /// tab introspection.
    case tabs

    /// Unlocks `swiftMaestro.tabs.executeScript` for the active tab and lets a
    /// browser-action extension read/modify the current page when its toolbar
    /// button is clicked. This is a temporary, user-gated permission.
    case activeTab

    /// Unlocks `swiftMaestro.downloads.download` — save files to the user's
    /// Downloads folder with a suggested filename.
    case downloads

    /// Unlocks toolbar-button UI controls: `swiftMaestro.browserAction.setBadgeText`,
    /// `setTitle`, `setEnabled`. Used by browser-action extensions to provide
    /// visual feedback on the SwiftBrowser toolbar.
    case browserAction
}
