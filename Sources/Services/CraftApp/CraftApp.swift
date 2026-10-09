import Foundation

// MARK: - ArtCraft Crafting Apps — models
//
// SwiftMaestro ships the ArtCraft team's open-source "Crafting Apps"
// (https://getartcraft.com) as bundled payloads: a `*-cli` binary per app for
// headless / MCP use, and the desktop .app for interactive editing from
// MaestroDAM. Two JSON documents describe the payload:
//
//  * `craft-apps-manifest.json` — authored, version-controlled, ships inside
//    the app bundle (Sources/Resources/). Static configuration: which apps
//    exist, their MCP args, which file types they handle, defaults.
//  * `craft-apps-versions.json` — written by `scripts/fetch-craft-apps.sh`
//    next to the downloaded payloads (BundledCraftApps/, gitignored). Runtime
//    facts: fetched release tag, resolved CLI executable name (asset naming
//    differs between apps — pdfcraft releases ship `printcraft-cli`), the
//    .app bundle name, SHA-256, MCP support probe result, scan timestamp.
//
// Attribution: see the `attribution` string in the manifest, surfaced in
// Settings and shipped as a notice. The ArtCraft name/logos are trademarks of
// the ArtCraft Team used only inside their official builds; we redistribute
// those builds unmodified.

/// One Craft app as described by the authored manifest.
struct CraftApp: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    /// GitHub repo, e.g. `storytold/photocraft` — used by the updater.
    let repo: String
    /// One-line human description (Settings UI).
    let summary: String
    /// Bundle identifier of the desktop app (fallback launch lookup).
    let bundleID: String
    /// Argument vector for the CLI's MCP server subcommand.
    let mcpArgs: [String]
    /// Lowercased file extensions this app should handle — drives MaestroDAM's
    /// "Open in Craft App" routing.
    let fileExtensions: [String]
    /// Whether this server's tools are advertised to interactive chats.
    /// Large tool tables dominate the prompt (see MCPServerEntry.advertise),
    /// so only the headline apps default to true.
    let advertise: Bool
    /// Whether the MCP server entry starts enabled.
    let enabledByDefault: Bool

    /// MCP server entry name registered in Settings → MCP.
    var mcpEntryName: String { "craft-\(id)" }
}

/// Per-app facts recorded by the fetch script after its scans passed.
struct CraftAppVersion: Codable, Sendable, Hashable {
    /// Release tag, e.g. `v0.3.0`.
    let version: String
    /// Actual CLI binary filename inside the payload dir (renames happen —
    /// pdfcraft's release assets currently use a `printcraft` prefix).
    let cliExecutable: String?
    /// `.app` bundle filename inside the payload dir, if the GUI was fetched.
    let guiApp: String?
    /// SHA-256 of the downloaded CLI zip (from the release's SHA256SUMS.txt).
    let sha256: String?
    /// Whether `<cli> --help` advertises an `mcp` subcommand.
    let mcpSupported: Bool?
    /// ISO-8601 timestamp of when the two-stage scan completed.
    let verifiedAt: String?
}

/// Top-level authored manifest.
struct CraftAppManifest: Codable, Sendable {
    let schemaVersion: Int
    let attribution: String
    let apps: [CraftApp]
}

// MARK: - Catalog (static loading + routing)

enum CraftAppCatalog {

    /// Cached manifest — the context-menu builder consults this on every
    /// right-click; decoding JSON each time would be wasteful.
    static let manifest: CraftAppManifest? = {
        guard let url = Bundle.main.url(forResource: "craft-apps-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CraftAppManifest.self, from: data)
        else {
            NSLog("[CraftApp] No craft-apps-manifest.json in bundle — Crafting Apps disabled")
            return nil
        }
        return decoded
    }()

    /// All configured apps, manifest order.
    static var apps: [CraftApp] { manifest?.apps ?? [] }

    /// Apps eligible for the launcher's "ArtCraft Apps" section and the
    /// Settings → Apps list: everything the fetch script has staged a
    /// verified release for. Apps with no releases (cadcraft) stay hidden.
    static var launcherApps: [CraftApp] {
        apps.filter { versions[$0.id] != nil }
    }

    /// Attribution notice for Settings / About.
    static var attribution: String { manifest?.attribution ?? "" }

    /// Root of the fetched payload inside the app bundle (may be absent when
    /// `scripts/fetch-craft-apps.sh` hasn't run).
    static var bundlePayloadURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("craft-apps", isDirectory: true)
    }

    /// Authored defaults for one app's fetched-version record — used before
    /// the fetch script has ever run (everything optional collapses to nil).
    static func fetchedVersion(for app: CraftApp) -> CraftAppVersion? {
        versions[app.id]
    }

    /// Parsed `craft-apps-versions.json` from the bundle payload (cached).
    static let versions: [String: CraftAppVersion] = {
        guard let payload = bundlePayloadURL else { return [:] }
        let url = payload.appendingPathComponent("craft-apps-versions.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CraftAppVersion].self, from: data)
        else { return [:] }
        return decoded
    }()

    /// Apps whose file-type routing matches at least one of the given assets.
    /// Manifest order is preserved so PhotoCraft (the common case) stays on
    /// top. Result is order-unique by app id.
    static func matchingApps(for assets: [DAMAsset]) -> [CraftApp] {
        guard !apps.isEmpty, !assets.isEmpty else { return [] }
        let assetExtensions = Set(assets.map {
            URL(fileURLWithPath: $0.path).pathExtension.lowercased()
        }).filter { !$0.isEmpty }
        guard !assetExtensions.isEmpty else { return [] }
        return apps.filter { app in
            !assetExtensions.isDisjoint(with: app.fileExtensions)
        }
    }
}
