import Foundation
import AppKit

/// Backs up and restores SwiftMaestro user settings to a JSON file outside of
/// `UserDefaults` so preferences survive plist deletion, migration bugs, or
/// cross-machine rebuilds. If Chezmoi is installed, the backup file is
/// automatically staged so it can be version-controlled with the user's dotfiles.
@MainActor
final class SettingsBackupService {

    static let shared = SettingsBackupService()

    /// Backups live in `~/Library/Application Support/SwiftMaestro/backups/` so they are
    /// alongside all other SwiftMaestro data and easy to inspect.
    private static var backupDirectory: URL { SwiftMaestroPaths.backupsDir }

    private static var backupURL: URL {
        backupDirectory.appendingPathComponent("settings-backup.json")
    }

    /// Keys that constitute user-created state and should be preserved.
    /// Window frames and one-time migration flags are intentionally excluded.
    private static let backedUpKeys: [String] = [
        // Model selection
        "models.selectedModelID",
        "models.localRoot",
        ModelCatalog.additionalRootsKey,
        "models.systemMemoryReserveFraction",

        // Settings stores
        SwiftMaestroSettingsStore.allowedModelsKey,
        SwiftMaestroSettingsStore.authorizedFoldersKey,
        SwiftMaestroSettingsStore.filesInMemoryKey,
        SwiftMaestroSettingsStore.lastImportDateKey,
        SwiftMaestroSettingsStore.mcpServersKey,
        SwiftMaestroSettingsStore.agentRulesKey,

        // Theme
        ThemeStore.appearanceKey,
        ThemeStore.accentKey,
        ThemeStore.userBubbleKey,
        ThemeStore.userBubbleTextKey,
        ThemeStore.chatBackgroundKey,
        ThemeStore.chatTextKey,
        ThemeStore.sidebarKey,
        ThemeStore.sidebarTextKey,
        ThemeStore.plansPanelKey,
        ThemeStore.plansTextKey,
        ThemeStore.tasksPanelKey,
        ThemeStore.tasksTextKey,

        // Tuning
        "tuning.enableThinking",
        "tuning.temperature",
        "tuning.topP",
        "tuning.repetitionPenalty",

        // Memory/recall
        "SwiftMaestro.Memory.ChatRecallEnabled",
        "SwiftMaestro.Memory.ChatContextRecallLimit",
        "SwiftMaestro.Memory.ChatContextCharacterBudget",
        "SwiftMaestro.Memory.ChatFactRecallLimit",
        "SwiftMaestro.Memory.ChatFactCharacterBudget",

        // Rules / workspace
        "SwiftMaestro.AgentRuleTemplates",
        "SwiftMaestro.WorkspaceSecurityScopedBookmarks",
        "SwiftMaestro.LastMemoryImport",
    ]

    private init() {}

    // MARK: - Backup

    /// Write all user settings to the backup JSON file. Called at launch and
    /// whenever the app goes to the background / terminates.
    func backup() {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in Self.backedUpKeys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = Self.jsonSafeValue(value)
            }
        }

        let payload: [String: Any] = [
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": snapshot,
        ]

        do {
            try FileManager.default.createDirectory(
                at: Self.backupDirectory, withIntermediateDirectories: true,
                attributes: nil)
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.backupURL, options: .atomic)
            stageWithChezmoi()
        } catch {
            NSLog("[SettingsBackupService] backup failed: \(error)")
        }
    }

    /// Convert UserDefaults values into JSON-serializable equivalents.
    /// `Data` is encoded as a base64 marker so it can round-trip through JSON.
    private static func jsonSafeValue(_ value: Any) -> Any {
        switch value {
        case let data as Data:
            return ["__data": data.base64EncodedString()]
        case let array as [Any]:
            return array.map(jsonSafeValue)
        case let dict as [String: Any]:
            return dict.mapValues(jsonSafeValue)
        default:
            return value
        }
    }

    /// Reverse `jsonSafeValue`: convert base64 markers back to `Data`.
    private static func userDefaultsValue(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            if dict.count == 1, let b64 = dict["__data"] as? String {
                return Data(base64Encoded: b64) ?? dict
            }
            return dict.mapValues(userDefaultsValue)
        case let array as [Any]:
            return array.map(userDefaultsValue)
        default:
            return value
        }
    }

    /// If Chezmoi is installed, stage the backup file so the user's next
    /// `chezmoi apply` / commit will version it. We run this detached because
    /// `chezmoi add` is fast and failure should not break the backup itself.
    private func stageWithChezmoi() {
        let url = Self.backupURL
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: "/opt/homebrew/bin/chezmoi")
                    || fm.fileExists(atPath: "/usr/local/bin/chezmoi")
            else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "chezmoi add \(url.path)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Restore

    /// Restore settings from the backup file only when the current UserDefaults
    /// look like a fresh/reset state (no MCP servers, no theme overrides, and no
    /// selected model) AND the backup actually contains those missing settings.
    /// This prevents an incomplete backup from clobbering manually recovered state.
    @discardableResult
    func restoreIfNeeded() -> Bool {
        let defaults = UserDefaults.standard

        // If the user already has any of the main settings, do not auto-restore.
        let hasMCPServers = defaults.object(forKey: SwiftMaestroSettingsStore.mcpServersKey) != nil
        let hasTheme = defaults.object(forKey: ThemeStore.accentKey) != nil
        let hasModel = defaults.string(forKey: ModelCatalog.selectedModelKey) != nil
        guard !hasMCPServers && !hasTheme && !hasModel else {
            return false
        }

        guard FileManager.default.fileExists(atPath: Self.backupURL.path) else {
            return false
        }

        do {
            let data = try Data(contentsOf: Self.backupURL)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let snapshot = json["settings"] as? [String: Any],
                // Only restore if the backup has something worth restoring.
                (snapshot[SwiftMaestroSettingsStore.mcpServersKey] != nil
                 || snapshot[ThemeStore.accentKey] != nil
                 || snapshot[ModelCatalog.selectedModelKey] != nil)
            else {
                return false
            }

            for (key, value) in snapshot {
                defaults.set(Self.userDefaultsValue(value), forKey: key)
            }
            NSLog("[SettingsBackupService] restored \(snapshot.count) settings from \(Self.backupURL.path)")
            return true
        } catch {
            NSLog("[SettingsBackupService] restore failed: \(error)")
            return false
        }
    }

    /// Public restore trigger for a manual "Restore from Backup" button.
    func restoreFromBackup() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.backupURL.path) else {
            return false
        }
        do {
            let data = try Data(contentsOf: Self.backupURL)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let snapshot = json["settings"] as? [String: Any]
            else {
                return false
            }
            for (key, value) in snapshot {
                UserDefaults.standard.set(Self.userDefaultsValue(value), forKey: key)
            }
            return true
        } catch {
            NSLog("[SettingsBackupService] manual restore failed: \(error)")
            return false
        }
    }
}
