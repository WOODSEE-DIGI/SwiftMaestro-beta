import Foundation

// MARK: - Notes iCloud Drive support

/// Helpers for keeping the SwiftMaestro Notes vault inside iCloud Drive so notes
/// sync across the user's signed-in Apple devices as plain Markdown files.
///
/// The native Apple approach is an iCloud Drive folder + `NSFileCoordinator` for
/// coordinated reads/writes, plus `NSMetadataQuery` for sync status. We do not use
/// CloudKit here because the goal is files that are visible in iCloud Drive and
/// readable by other apps (Obsidian, Logseq, Finder).
enum NotesiCloudSupport {

    static let iCloudVaultFolderName = "SwiftMaestro Notes"
    static let iCloudSyncEnabledKey = "notes.icloudSyncEnabled"

    /// Whether the user has turned on iCloud Drive sync for the Notes vault.
    /// Defaults to `true` when iCloud Drive is available and the user has not
    /// explicitly disabled it.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: iCloudSyncEnabledKey) == nil {
                return iCloudVaultURL != nil
            }
            return UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: iCloudSyncEnabledKey) }
    }

    /// `true` only after the user has made an explicit choice in onboarding.
    static var onboardingChoiceMade: Bool {
        get { UserDefaults.standard.bool(forKey: "notes.icloudOnboardingChoiceMade") }
        set { UserDefaults.standard.set(newValue, forKey: "notes.icloudOnboardingChoiceMade") }
    }

    /// The path to the user's iCloud Drive root on macOS.
    /// This is the same location shown as `~/iCloud Drive/` in Finder.
    static var iCloudDriveURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The recommended vault location inside iCloud Drive.
    static var iCloudVaultURL: URL? {
        iCloudDriveURL?.appendingPathComponent(iCloudVaultFolderName, isDirectory: true)
    }

    /// The default local vault location: a folder inside the user's Documents.
    /// This keeps notes visible and accessible outside of SwiftMaestro.
    static var localVaultURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(iCloudVaultFolderName, isDirectory: true)
    }

    /// The effective vault URL: iCloud Drive when enabled and available, otherwise
    /// the local Documents vault directory.
    static func effectiveVaultURL() -> URL {
        guard isEnabled, let iCloudURL = iCloudVaultURL else { return localVaultURL }
        return iCloudURL
    }

    /// Move the contents of `from` into `to`, creating `to` if needed.
    /// Existing files at `to` are left untouched unless `force` is true, in which
    /// case `to` is replaced after a backup.
    static func moveVault(from source: URL, to destination: URL, force: Bool = false) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let destinationExists = fm.fileExists(atPath: destination.path, isDirectory: &isDir)

        if destinationExists {
            if force {
                let backup = destination.appendingPathExtension("backup-\(ISO8601DateFormatter().string(from: Date()))")
                try fm.moveItem(at: destination, to: backup)
            } else {
                // Merge: move each child from source into destination.
                let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for child in children {
                    let target = destination.appendingPathComponent(child.lastPathComponent)
                    if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: target)
                    }
                    try fm.moveItem(at: child, to: target)
                }
                return
            }
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
    }

    /// Backup a vault folder before a destructive move.
    static func backupVault(at url: URL) throws -> URL {
        let fm = FileManager.default
        let backupName = "\(url.lastPathComponent).backup-\(ISO8601DateFormatter().string(from: Date()))"
        let backup = url.deletingLastPathComponent().appendingPathComponent(backupName, isDirectory: true)
        try fm.copyItem(at: url, to: backup)
        return backup
    }
}
