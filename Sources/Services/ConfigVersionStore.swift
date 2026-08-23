import Foundation

// MARK: - Config Version Store
//
// Git-versioned history of SwiftMaestro's restorable state — the Mechanic's
// "reset to last working condition" backend. A LOCAL, offline git repository
// at ~/Library/Application Support/SwiftMaestro/config-history/ (no remote —
// project rule: offline-first git). Each snapshot commits:
//   • settings-backup.json   — the SettingsBackupService snapshot
//   • mcp-servers.json       — the MCP registry (breakage here is common)
// so every backup has a full history: list restore points, diff what changed,
// restore ANY point — not just the latest single slot.

final class ConfigVersionStore: Sendable {

    static let shared = ConfigVersionStore()

    private var repoDir: URL {
        SwiftMaestroPaths.appSupportDir
            .appendingPathComponent("config-history", isDirectory: true)
    }

    private init() {}

    // MARK: - Snapshot (called by the settings_backup_now agent tool)

    /// Commit the current restorable state. Returns the short commit SHA.
    /// (Async: the settings snapshot itself is taken on the MainActor —
    /// SettingsBackupService is MainActor-isolated.)
    @discardableResult
    func snapshot(note: String) async throws -> String {
        let fm = FileManager.default
        let repo = repoDir
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)

        // Stage 1: the settings snapshot (SettingsBackupService's payload).
        await MainActor.run { SettingsBackupService.shared.backup() }
        let settingsSrc = SwiftMaestroPaths.backupsDir
            .appendingPathComponent("settings-backup.json")
        let settingsDst = repo.appendingPathComponent("settings-backup.json")
        if fm.fileExists(atPath: settingsSrc.path) {
            try? fm.removeItem(at: settingsDst)
            try fm.copyItem(at: settingsSrc, to: settingsDst)
        }

        // Stage 2: the MCP registry, if present.
        let mcpSrc = URL(fileURLWithPath: NSHomeDirectory()
            + "/.ai-context/mcp-registry/mcp-servers.json")
        if fm.fileExists(atPath: mcpSrc.path) {
            try? fm.removeItem(at: repo.appendingPathComponent("mcp-servers.json"))
            try fm.copyItem(at: mcpSrc,
                            to: repo.appendingPathComponent("mcp-servers.json"))
        }

        // Init on first use (offline repo — never gets a remote).
        if !fm.fileExists(atPath: repo.appendingPathComponent(".git").path) {
            try git(["init", "--initial-branch=main"], in: repo)
            try git(["config", "user.name", "SwiftMaestro"], in: repo)
            try git(["config", "user.email", "mechanic@swiftmaestro.local"], in: repo)
        }

        try git(["add", "-A"], in: repo)
        let stamp = ISO8601DateFormatter().string(from: Date())
        // Allow empty commits so the user always gets a restore point marker,
        // even when nothing changed since the last snapshot.
        try git(["commit", "--allow-empty", "-m", "snapshot \(stamp) — \(note)"], in: repo)
        let sha = try git(["rev-parse", "--short", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sha
    }

    // MARK: - History

    struct RestorePoint: Sendable {
        var sha: String
        var date: String
        var note: String
    }

    /// Restore points, newest first.
    func history(limit: Int = 20) throws -> [RestorePoint] {
        guard FileManager.default.fileExists(atPath: repoDir.path) else { return [] }
        let out = try git(["log", "--max-count=\(limit)",
                           "--pretty=format:%h|%aI|%s"], in: repoDir)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return RestorePoint(sha: String(parts[0]),
                                date: String(parts[1]),
                                note: String(parts[2]))
        }
    }

    /// Unified diff of what changed between a restore point and HEAD
    /// (or the previous commit when sha is nil).
    func diff(since sha: String?) throws -> String {
        let range = sha.map { "\($0)..HEAD" } ?? "HEAD~1..HEAD"
        return try git(["diff", range, "--stat"], in: repoDir)
    }

    // MARK: - Restore

    /// Restore settings (+ MCP registry if the commit has it) from a restore
    /// point. Returns what was restored. A restart may be needed — the caller
    /// (Mechanic) tells the user that.
    @discardableResult
    func restore(sha: String) async throws -> [String] {
        var restored: [String] = []
        // Extract the settings payload from the commit into the live backup
        // slot, then let SettingsBackupService do the actual apply (it owns
        // UserDefaults translation).
        let settings = try git(["show", "\(sha):settings-backup.json"], in: repoDir)
        let backupURL = SwiftMaestroPaths.backupsDir
            .appendingPathComponent("settings-backup.json")
        try FileManager.default.createDirectory(
            at: SwiftMaestroPaths.backupsDir, withIntermediateDirectories: true)
        try Data(settings.utf8).write(to: backupURL)
        if await MainActor.run(body: { SettingsBackupService.shared.restoreFromBackup() }) {
            restored.append("settings")
        }
        // MCP registry is optional in the commit.
        if let mcp = try? git(["show", "\(sha):mcp-servers.json"], in: repoDir),
           !mcp.isEmpty {
            let registryDir = URL(fileURLWithPath: NSHomeDirectory()
                + "/.ai-context/mcp-registry")
            try FileManager.default.createDirectory(
                at: registryDir, withIntermediateDirectories: true)
            try Data(mcp.utf8).write(
                to: registryDir.appendingPathComponent("mcp-servers.json"))
            restored.append("mcp-servers.json")
        }
        return restored
    }

    // MARK: - git plumbing (system git, offline, no remote)

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw ConfigVersionError.gitFailed(err.isEmpty ? out : err)
        }
        return out
    }

    enum ConfigVersionError: Error, LocalizedError {
        case gitFailed(String)
        var errorDescription: String? {
            switch self {
            case .gitFailed(let detail): return "git failed: \(detail)"
            }
        }
    }
}
