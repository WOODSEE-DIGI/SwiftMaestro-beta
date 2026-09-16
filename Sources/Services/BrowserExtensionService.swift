import Foundation

/// Manages user-created SwiftBrowser extensions stored outside the app bundle
/// in `~/Library/Application Support/SwiftMaestro/BrowserExtensions/`.
///
/// Extensions are folder-based (one folder per extension id) with a
/// `manifest.json` at the root plus HTML/JS/CSS assets. Because they live in
/// Application Support, they survive SwiftMaestro app updates and reinstalls.
@Observable
@MainActor
final class BrowserExtensionService {

    static let shared = BrowserExtensionService()

    private(set) var extensions: [PluginManifest] = []
    private(set) var lastError: String?

    /// Toolbar badge text per extension id, observed by WebBrowserToolbar.
    private(set) var badgeText: [String: String] = [:]

    private let decoder = JSONDecoder()
    private let fm = FileManager.default

    init() {
        loadExtensions()
    }

    // MARK: - Discovery

    /// Rescan the extensions directory and publish the current list.
    func loadExtensions() {
        lastError = nil
        extensions = Self.scan(directory: SwiftMaestroPaths.browserExtensionsDir, decoder: decoder)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Scans immediate subdirectories of `directory` for a `manifest.json`.
    /// Malformed folders are skipped so one broken extension doesn't block others.
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

    // MARK: - CRUD

    /// Install or update an extension by writing its manifest and assets to the
    /// extensions directory. Existing files with the same id are replaced.
    ///
    /// - Parameters:
    ///   - manifest: A complete `PluginManifest` (id, name, type, capabilities, etc.).
    ///   - files: Relative path -> content string for assets (HTML/JS/CSS).
    /// - Returns: The installed manifest, or nil on failure.
    @discardableResult
    func install(manifest: PluginManifest, files: [String: String]) -> PluginManifest? {
        lastError = nil
        let id = manifest.id
        let root = SwiftMaestroPaths.browserExtensionsDir.appendingPathComponent(id, isDirectory: true)

        do {
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            let manifestURL = root.appendingPathComponent("manifest.json")
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: manifestURL)

            for (relativePath, content) in files {
                let fileURL = root.appendingPathComponent(relativePath)
                try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            loadExtensions()
            return self.extensions.first { $0.id == id }
        } catch {
            lastError = error.localizedDescription
            NSLog("[BrowserExtensionService] install failed for \(id): \(error)")
            return nil
        }
    }

    /// Remove an installed extension entirely.
    func uninstall(id: String) -> Bool {
        lastError = nil
        let root = SwiftMaestroPaths.browserExtensionsDir.appendingPathComponent(id, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else {
            lastError = "Extension '\(id)' is not installed."
            return false
        }
        do {
            try fm.removeItem(at: root)
            loadExtensions()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Force a rescan; useful after manual changes to the extensions directory.
    func reload() {
        loadExtensions()
    }

    // MARK: - Storage helpers

    /// Returns the per-extension storage directory for the `storage` capability.
    /// Creates it on demand.
    func storageDirectory(forExtensionID id: String) -> URL {
        let dir = SwiftMaestroPaths.browserExtensionsDir
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("_storage", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Path to the JSON store used by `swiftMaestro.storage.local.*`.
    func localStorageURL(forExtensionID id: String) -> URL {
        storageDirectory(forExtensionID: id).appendingPathComponent("local.json")
    }

    // MARK: - Badge text

    func setBadgeText(_ text: String?, forExtensionID id: String) {
        if let text, !text.isEmpty {
            badgeText[id] = text
        } else {
            badgeText.removeValue(forKey: id)
        }
    }

    // MARK: - Content scripts

    /// Returns all content-script entries whose match patterns include `url`.
    func matchingContentScripts(for url: URL) -> [(manifest: PluginManifest, entry: ContentScriptEntry)] {
        var result: [(PluginManifest, ContentScriptEntry)] = []
        for manifest in extensions where manifest.type == .contentScript {
            guard let scripts = manifest.contentScripts else { continue }
            for entry in scripts {
                if entry.matches.contains(where: { Self.matchPattern($0, url: url) }) {
                    result.append((manifest, entry))
                }
            }
        }
        return result
    }

    /// Reads a content-script asset (JS or CSS) from an extension's folder.
    func contentScriptAsset(relativePath: String, in manifest: PluginManifest) -> String? {
        guard let root = manifest.contentRootURL else { return nil }
        let url = root.appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Simple glob-style URL matcher for content-script `matches` patterns like
    /// `*://*.youtube.com/*` or `https://example.com/watch*`.
    private static func matchPattern(_ pattern: String, url: URL) -> Bool {
        guard let scheme = url.scheme, let host = url.host else { return false }
        let path = url.path
        let components = pattern.components(separatedBy: "://")
        guard components.count == 2 else { return false }
        let patternScheme = components[0]
        let rest = components[1]

        // Scheme match.
        if patternScheme != "*" && patternScheme.lowercased() != scheme.lowercased() {
            return false
        }

        // Split host and path from the rest.
        let hostPathParts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let patternHost = String(hostPathParts.first ?? "")
        let patternPath = hostPathParts.count > 1 ? "/" + hostPathParts[1] : ""

        // Host match: * is a wildcard for any prefix/suffix/whole segment.
        if !matchHost(patternHost, host) { return false }

        // Path match.
        return matchWildcard(patternPath, path)
    }

    private static func matchHost(_ pattern: String, _ host: String) -> Bool {
        if pattern == "*" { return true }
        let lowerPattern = pattern.lowercased()
        let lowerHost = host.lowercased()
        if lowerPattern.hasPrefix("*.") {
            let suffix = String(lowerPattern.dropFirst(2))
            return lowerHost == suffix || lowerHost.hasSuffix("." + suffix)
        }
        return lowerPattern == lowerHost
    }

    private static func matchWildcard(_ pattern: String, _ text: String) -> Bool {
        // Fast path: exact match.
        if pattern == text || pattern == "*" || pattern.isEmpty { return true }
        // Convert glob pattern to regex.
        var regex = ""
        for char in pattern {
            switch char {
            case "*": regex.append(".*")
            case "?": regex.append(".")
            case ".", "\\", "+", "[", "]", "(", ")", "^", "$", "|":
                regex.append("\\\(char)")
            default: regex.append(char)
            }
        }
        guard let re = try? NSRegularExpression(pattern: "^\(regex)$", options: [.caseInsensitive])
        else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}
