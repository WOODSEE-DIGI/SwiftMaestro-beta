import Foundation

/// Centralized file-system layout for SwiftMaestro.
///
/// Public users get a single app root under `~/Library/Application Support/SwiftMaestro/`
/// with predictable subdirectories for models, data, logs, and backups. The model root
/// can be overridden via Settings → Models, but everything else lives under the app root.
enum SwiftMaestroPaths {

    /// Create a directory, logging (but not throwing) any failure. Persistence
    /// failures must never be silent — every error gets a `[PERSIST]` log line.
    private static func createDir(_ dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[PERSIST] directory create failed at \(dir.path): \(error.localizedDescription)")
        }
    }

    /// Base macOS Application Support directory for SwiftMaestro.
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SwiftMaestro", isDirectory: true)
        createDir(dir)
        return dir
    }

    /// `~/Library/Application Support/SwiftMaestro/data/` — chats, plans, todos, workspace, etc.
    static var dataDir: URL {
        let dir = appSupportDir.appendingPathComponent("data", isDirectory: true)
        createDir(dir)
        return dir
    }

    /// `~/Ai-models/models/` — default MLX model root per project identity.
    /// Users may override this in Settings → Models; use `ModelCatalog.modelsRoot` for the
    /// effective path.
    static var modelsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Ai-models/models", isDirectory: true)
        createDir(dir)
        return dir
    }

    /// `~/Library/Application Support/SwiftMaestro/WhisperKit/` — local WhisperKit model
    /// cache. Kept under Application Support instead of ~/Documents to avoid macOS TCC
    /// directory-access prompts at launch.
    static var whisperKitDir: URL {
        let dir = appSupportDir.appendingPathComponent("WhisperKit", isDirectory: true)
        createDir(dir)
        return dir
    }

    /// `~/Library/Application Support/SwiftMaestro/logs/` — background process output, downloads.
    static var logsDir: URL {
        let dir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
        createDir(dir)
        return dir
    }

    /// `~/Library/Application Support/SwiftMaestro/backups/` — settings and data backups.
    static var backupsDir: URL {
        let dir = appSupportDir.appendingPathComponent("backups", isDirectory: true)
        createDir(dir)
        return dir
    }

    /// `~/Library/Application Support/SwiftMaestro/secrets-index.json` — non-secret metadata
    /// about Keychain-stored secrets. The actual secret values live in the Keychain.
    static var secretsIndexURL: URL {
        appSupportDir.appendingPathComponent("secrets-index.json")
    }

    /// `~/Library/Application Support/SwiftMaestro/plugins/` — user-installed WKWebView UI
    /// plugins (each a subfolder with its own `manifest.json`). Bundled plugins ship inside
    /// the app itself (`Bundle.main.resourceURL/Plugins/`) and don't live here; see
    /// `PluginService` for how both sources are merged.
    static var pluginsDir: URL {
        let dir = appSupportDir.appendingPathComponent("plugins", isDirectory: true)
        createDir(dir)
        return dir
    }

    /// `~/Library/Application Support/SwiftMaestro/skins/` — user-created and imported
    /// skin JSON files. Built-in skins live in `SkinStore` and are not written here.
    static var skinsDir: URL {
        let dir = appSupportDir.appendingPathComponent("skins", isDirectory: true)
        createDir(dir)
        return dir
    }

    // MARK: - Migration

    /// One-time migration from the old flat layout (where chats/plans/todos/workspace lived
    /// directly in the app-support dir) to the new `data/` subdirectory. This is idempotent
    /// and safe to call on every launch.
    static func migrateFromFlatLayout() {
        let fm = FileManager.default
        let root = appSupportDir
        let data = dataDir

        // Files/dirs that should live under data/
        let dataItems = [
            "chats",
            "plans",
            "todos",
            "agent-messages",
            "workspace.json",
        ]

        for item in dataItems {
            let oldURL = root.appendingPathComponent(item)
            let newURL = data.appendingPathComponent(item)
            guard fm.fileExists(atPath: oldURL.path) else { continue }

            // If the new location already exists, leave the old one alone (user downgraded).
            guard !fm.fileExists(atPath: newURL.path) else { continue }

            do {
                try fm.moveItem(at: oldURL, to: newURL)
                NSLog("[PATHS] migrated \(item) -> \(data.path)")
            } catch {
                NSLog("[PATHS] migration failed for \(item): \(error)")
            }
        }

        // Move old settings backup into backups dir if present.
        let oldBackupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/SwiftMaestro", isDirectory: true)
        let oldBackup = oldBackupDir.appendingPathComponent("settings-backup.json")
        let newBackup = backupsDir.appendingPathComponent("settings-backup.json")
        if fm.fileExists(atPath: oldBackup.path), !fm.fileExists(atPath: newBackup.path) {
            do {
                try fm.moveItem(at: oldBackup, to: newBackup)
                NSLog("[PATHS] migrated settings-backup.json -> \(backupsDir.path)")
            } catch {
                NSLog("[PATHS] backup migration failed: \(error)")
            }
        }
    }

    /// One-shot launch diagnostic: prove the data directory is actually writable
    /// and readable. The stores above previously failed silently for weeks
    /// (`try?` swallowed every error); this canary makes the persistence layer's
    /// health visible in Console with a single `[PERSIST]` line per launch.
    static func performPersistenceCanary() {
        let url = dataDir.appendingPathComponent(".persist-canary")
        do {
            try "ok".write(to: url, atomically: true, encoding: .utf8)
            let readBack = try String(contentsOf: url, encoding: .utf8)
            try FileManager.default.removeItem(at: url)
            if readBack == "ok" {
                NSLog("[PERSIST] canary OK — data dir writable at \(dataDir.path)")
            } else {
                NSLog("[PERSIST] canary MISMATCH — wrote 'ok' but read back '\(readBack)' at \(url.path)")
            }
        } catch {
            NSLog("[PERSIST] canary FAILED — data dir not writable at \(dataDir.path): \(error.localizedDescription)")
        }
    }
}
