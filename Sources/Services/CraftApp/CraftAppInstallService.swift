import AppKit
import Foundation

// MARK: - Craft App Install Service
//
// Installs the bundled ArtCraft Crafting App payloads (CLI + desktop .app,
// fetched by `scripts/fetch-craft-apps.sh` and copied into the app bundle by
// the "Bundle Craft Apps" post-build script) from
// `Resources/craft-apps/` into
// `~/Library/Application Support/SwiftMaestro/craft-apps/<id>/`.
//
// Mirrors `MCPServerBundleService`: a per-app version key in UserDefaults
// drives idempotent installs; re-runs happen only when the bundled payload
// version changes (i.e. after an update or app upgrade). Unlike that service
// we do NOT ad-hoc re-sign the binaries — they ship Developer ID-signed and
// notarized upstream, and re-signing with an ad-hoc identity would strip
// that. Integrity comes from the fetch script's two-stage scan (SHA-256 +
// codesign/spctl at acquisition time) plus a cheap Mach-O sanity check here.
//
// Deliberately non-@MainActor (same rationale as MCPServerBundleService):
// copying hundreds of MB of .app bundles is heavy synchronous work that must
// never run on the main thread. All state is UserDefaults-backed.

final class CraftAppInstallService: @unchecked Sendable {

    static let shared = CraftAppInstallService()

    /// UserDefaults key: [app id: installed release tag].
    private static let installedVersionsKey = "craftApps.installedVersions"

    private let fm = FileManager.default

    private init() {}

    // MARK: - Install

    /// True when the app bundle carries a fetched Craft Apps payload.
    var hasPayload: Bool {
        guard let url = CraftAppCatalog.bundlePayloadURL else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Install every payload whose version differs from what's installed.
    /// Per-app failures don't abort the rest — an app without a release yet
    /// (cadcraft) or a corrupted single payload must not block the suite.
    ///
    /// - Returns: ids of apps successfully installed this run.
    @discardableResult
    func installIfNeeded() throws -> [String] {
        guard hasPayload, let payload = CraftAppCatalog.bundlePayloadURL else {
            NSLog("[CraftApp] No bundled payload found — skipping install")
            return []
        }

        var installed = installedVersions()
        var installedThisRun: [String] = []

        for app in CraftAppCatalog.apps {
            let expectedVersion = CraftAppCatalog.versions[app.id]?.version ?? "bundled"
            let destination = installDir(for: app)

            if installed[app.id] == expectedVersion, fm.fileExists(atPath: destination.path) {
                continue
            }

            let source = payload.appendingPathComponent(app.id, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
                NSLog("[CraftApp] No payload for %@ at %@ — skipping", app.id, source.path)
                continue
            }

            do {
                NSLog("[CraftApp] Installing %@ (%@)", app.id, expectedVersion)
                // Replace any previous install wholesale — same clean-state
                // approach as MCPServerBundleService.
                try? fm.removeItem(at: destination)
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)

                if let cli = resolvedCLIExecutable(for: app, in: destination) {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
                    verifyBinary(at: cli, label: app.id)
                } else {
                    NSLog("[CraftApp] %@ payload has no CLI executable — marking installed anyway (GUI only)", app.id)
                }

                installed[app.id] = expectedVersion
                installedThisRun.append(app.id)
            } catch {
                NSLog("[CraftApp] Install failed for %@: %@", app.id, error.localizedDescription)
            }
        }

        if !installedThisRun.isEmpty {
            UserDefaults.standard.set(installed, forKey: Self.installedVersionsKey)
        }
        return installedThisRun
    }

    // MARK: - Installed artifact lookup

    func installDir(for app: CraftApp) -> URL {
        SwiftMaestroPaths.appSupportDir
            .appendingPathComponent("craft-apps/\(app.id)", isDirectory: true)
    }

    /// Absolute path of the installed CLI, or nil when absent.
    func installedCLIPath(for app: CraftApp) -> String? {
        let dir = installDir(for: app)
        guard let cli = resolvedCLIExecutable(for: app, in: dir) else { return nil }
        return fm.isExecutableFile(atPath: cli) ? cli : nil
    }

    /// Absolute URL of the installed desktop app: first our own copy under
    /// Application Support, then a user-installed copy resolved by bundle id
    /// (someone may have installed the official DMG in /Applications), then
    /// the bundle payload itself (a launch that races the install step).
    func installedGUIAppURL(for app: CraftApp) -> URL? {
        let dir = installDir(for: app)
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let bundled = contents.first(where: { $0.pathExtension == "app" }) {
            return bundled
        }
        if let system = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return system
        }
        if let name = CraftAppCatalog.versions[app.id]?.guiApp,
           let payload = CraftAppCatalog.bundlePayloadURL {
            let url = payload
                .appendingPathComponent(app.id, isDirectory: true)
                .appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// True when this app is usable right now (GUI and/or CLI present).
    func isInstalled(_ app: CraftApp) -> Bool {
        installedGUIAppURL(for: app) != nil || installedCLIPath(for: app) != nil
    }

    // MARK: - MCP registration

    /// Append MCP server entries for installed Craft apps to Settings → MCP.
    ///
    /// Idempotent and non-destructive: an entry name that already exists is
    /// never touched (the user may have disabled or edited it), and a
    /// version-key per app means a deleted entry is not re-added until the
    /// payload version changes (an update intentionally re-registers).
    func registerMCPEntriesIfNeeded() async {
        let apps = CraftAppCatalog.apps
        guard !apps.isEmpty, hasPayload else { return }

        var entries = SwiftMaestroSettingsStore.loadMCPServers()
        let existingNames = Set(entries.map(\.name))
        var registered = registeredVersions()
        var changed = false

        for app in apps {
            let expectedVersion = CraftAppCatalog.versions[app.id]?.version ?? "bundled"
            guard registered[app.id] != expectedVersion else { continue }

            guard existingNames.contains(app.mcpEntryName) == false else {
                // Entry exists (user's copy wins) — just record the version so
                // we don't loop on it every launch.
                registered[app.id] = expectedVersion
                changed = true
                continue
            }
            guard let cli = installedCLIPath(for: app) else {
                // Not installed yet (payload fetch/install pending) — leave the
                // version unrecorded so registration retries next launch.
                continue
            }
            // The fetch script probes `--help` for an `mcp` subcommand; when
            // it's absent the server would fail its handshake and log noise.
            // Require POSITIVE confirmation from the probe (== true) plus
            // manifest args — filmcraft 0.2.1 has no MCP subcommand at all.
            guard app.mcpArgs.isEmpty == false else {
                NSLog("[CraftApp] %@ has no manifest MCP args — skipping registration", app.id)
                registered[app.id] = expectedVersion
                continue
            }
            guard let versionInfo = CraftAppCatalog.versions[app.id] else {
                // No versions.json entry yet (fetch pending) — leave
                // unrecorded so registration retries after the next fetch.
                NSLog("[CraftApp] %@ has no versions.json entry yet — will retry MCP registration after fetch", app.id)
                continue
            }
            guard versionInfo.mcpSupported == true else {
                NSLog("[CraftApp] %@ has no MCP subcommand — skipping registration", app.id)
                registered[app.id] = expectedVersion
                continue
            }

            let notes = "\(app.name) by the ArtCraft team — \(app.summary). "
                + "Bundled CLI: \(URL(fileURLWithPath: cli).lastPathComponent). "
                + "Attribution: getartcraft.com"
            entries.append(MCPServerEntry(
                name: app.mcpEntryName,
                command: cli,
                scriptPath: "",
                env: "",
                workingDir: installDir(for: app).path,
                timeout: 30,
                enabled: app.enabledByDefault,
                args: app.mcpArgs,
                advertise: app.advertise,
                notes: notes
            ))
            NSLog("[CraftApp] Registered MCP server %@ (advertise: %@)",
                  app.mcpEntryName, app.advertise ? "yes" : "no")
            registered[app.id] = expectedVersion
            changed = true
        }

        if changed {
            registeredVersionsStore(registered)
            SwiftMaestroSettingsStore.saveMCPServers(entries)
        }
    }

    // MARK: - Private

    /// Resolve the CLI executable inside an installed payload dir:
    /// versions.json name (authoritative — releases rename binaries) →
    /// sole Mach-O executable at the top level → nil.
    private func resolvedCLIExecutable(for app: CraftApp, in dir: URL) -> String? {
        if let named = CraftAppCatalog.versions[app.id]?.cliExecutable {
            let path = dir.appendingPathComponent(named).path
            if fm.fileExists(atPath: path) { return path }
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var candidates: [String] = []
        for item in contents {
            let path = dir.appendingPathComponent(item).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard fm.isExecutableFile(atPath: path), isMachOBinary(at: path) else { continue }
            candidates.append(path)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Cheap acquisition-time sanity check (the authoritative two-stage scan
    /// happens in the fetch script): the payload must be a Mach-O binary and
    /// its Developer ID signature must still verify. Failures are logged —
    /// registration proceeds only for binaries that exist and execute.
    private func verifyBinary(at path: String, label: String) {
        guard isMachOBinary(at: path) else {
            NSLog("[CraftApp] WARNING: %@ payload at %@ is not Mach-O", label, path)
            return
        }
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", "--verbose=2", path]
        let err = Pipe()
        verify.standardError = err
        do {
            try verify.run()
            verify.waitUntilExit()
            if verify.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("[CraftApp] WARNING: codesign verify failed for %@: %@", label, msg)
            }
        } catch {
            NSLog("[CraftApp] codesign verify could not run for %@: %@", label, error.localizedDescription)
        }
    }

    /// Mach-O magic bytes (32/64, both endians, fat/universal) — same check
    /// MCPServerBundleService uses before touching a file as a binary.
    private func isMachOBinary(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch magic {
        case 0xFEEDFACE, 0xCEFAEDFE,
             0xFEEDFACF, 0xCFFAEDFE,
             0xCAFEBABE, 0xBEBAFECA,
             0xCAFEBABF, 0xBFBAFECA:
            return true
        default:
            return false
        }
    }

    private func installedVersions() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.installedVersionsKey) as? [String: String] ?? [:]
    }

    private func registeredVersions() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.installedVersionsKey + ".registered") as? [String: String] ?? [:]
    }

    private func registeredVersionsStore(_ dict: [String: String]) {
        UserDefaults.standard.set(dict, forKey: Self.installedVersionsKey + ".registered")
    }
}
