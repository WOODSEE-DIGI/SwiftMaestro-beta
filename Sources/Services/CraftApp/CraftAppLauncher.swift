import AppKit
import Foundation

// MARK: - Craft App Launcher (MaestroDAM integration)
//
// Drives the Craft desktop apps from MaestroDAM:
//
//  * "Open in Craft App" (DAMContextMenu) routes the selected assets to every
//    Craft app whose file-type table matches, launching the installed .app
//    with those files (our Application Support copy first, then a
//    user-installed copy by bundle id).
//  * After the editing app quits, the affected folders are delta-imported
//    into the DAM catalog (`DAMImportService.importFolder` upserts by path
//    and mtime-checks existing rows — the same cheap mechanism Books uses
//    after publishing an invoice), so edited assets show fresh metadata and
//    thumbnails without a manual re-scan.
//
// Phase 2 candidates: watch mtime while the app is still running, and a
// headless CLI edit path for agent-initiated edits (MCP already covers that).

@MainActor
final class CraftAppLauncher {

    static let shared = CraftAppLauncher()

    /// Folders to delta-import when a given app's process terminates:
    /// bundle id → parent directories of the files we opened with it.
    private var pendingImports: [String: Set<String>] = [:]

    private init() {
        // Fired on the main thread by AppKit. Filtered by the bundle ids we
        // actually opened files with; a quit of any other app is ignored.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editingAppDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil)
    }

    // MARK: - Routing

    /// Apps that handle at least one of the assets' file types (manifest order).
    /// Nonisolated so the DAM context-menu builder (a synchronous, nonisolated
    /// @ViewBuilder) can consult it without hopping actors.
    nonisolated static func matchingApps(for assets: [DAMAsset]) -> [CraftApp] {
        CraftAppCatalog.matchingApps(for: assets)
    }

    /// Whether the app can be launched right now (cheap file-exists checks).
    nonisolated static func isReady(_ app: CraftApp) -> Bool {
        CraftAppInstallService.shared.isInstalled(app)
    }

    /// The desktop app's own icon, read from the installed bundle (our
    /// Application Support copy, a user-installed copy, or the bundle
    /// payload). Nil before install — callers fall back to an SF Symbol.
    nonisolated static func icon(for app: CraftApp) -> NSImage? {
        guard let url = CraftAppInstallService.shared.installedGUIAppURL(for: app) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Open

    /// Launch `app` as its own window with no files attached — backs the
    /// "ArtCraft Apps" rows in the Apps launcher and Settings. The desktop
    /// app runs outside the workspace canvas (each launch is its own
    /// window), which keeps it clear of the tiling panel system.
    func launch(_ app: CraftApp) {
        guard let appURL = CraftAppInstallService.shared.installedGUIAppURL(for: app) else {
            presentNotInstalledAlert(for: app)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task {
            do {
                // No `createsNewApplicationInstance`: a second launch while
                // the app is running activates its existing window instead.
                _ = try await NSWorkspace.shared.open(appURL, configuration: configuration)
            } catch {
                NSLog("[CraftApp] Failed to launch %@: %@",
                      app.name, error.localizedDescription)
                await MainActor.run {
                    self.presentAlert(
                        title: String(localized: "Could not open \(app.name)"),
                        message: error.localizedDescription)
                }
            }
        }
    }

    /// Launch `app` with the assets it can handle. Shows a clear alert when
    /// the app isn't installed (payload not fetched yet) rather than failing
    /// silently from the menu.
    func open(_ app: CraftApp, with assets: [DAMAsset]) {
        // Only hand the app the files it actually handles — a multi-select
        // can span several types, and each app gets its own subset.
        let exts = Set(app.fileExtensions)
        let urls = assets
            .map { URL(fileURLWithPath: $0.path) }
            .filter { exts.contains($0.pathExtension.lowercased()) }
        guard !urls.isEmpty else { return }

        guard let appURL = CraftAppInstallService.shared.installedGUIAppURL(for: app) else {
            presentNotInstalledAlert(for: app)
            return
        }

        let folders = Set(urls.map { $0.deletingLastPathComponent().path })
        pendingImports[app.bundleID, default: []].formUnion(folders)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    urls, withApplicationAt: appURL, configuration: configuration)
            } catch {
                NSLog("[CraftApp] Failed to open %@ with %@: %@",
                      app.name, appURL.path, error.localizedDescription)
                await MainActor.run {
                    self.pendingImports[app.bundleID] = nil
                    self.presentAlert(
                        title: String(localized: "Could not open \(app.name)"),
                        message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Post-edit catalog refresh

    @objc private func editingAppDidTerminate(_ notification: Notification) {
        guard let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = running.bundleIdentifier,
              let folders = pendingImports.removeValue(forKey: bundleID),
              !folders.isEmpty else { return }

        NSLog("[CraftApp] %@ quit — delta-importing %d folder(s) into MaestroDAM",
              bundleID, folders.count)
        Task.detached(priority: .utility) {
            for folder in folders {
                // Upsert-by-path with mtime checks; cheap for unchanged files.
                _ = try? await DAMImportService.shared.importFolder(at: URL(fileURLWithPath: folder))
            }
        }
    }

    // MARK: - Alerts

    private func presentNotInstalledAlert(for app: CraftApp) {
        presentAlert(
            title: String(localized: "\(app.name) is not installed"),
            message: String(localized: """
            Its payload hasn't been fetched yet. Run scripts/fetch-craft-apps.sh \
            in the SwiftMaestro repo (downloads the official release, verifies \
            SHA-256 + code signature, and bundles it on the next build), or \
            install \(app.name) from \(app.repo) yourself.
            """))
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
