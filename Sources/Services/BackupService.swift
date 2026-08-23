import Foundation
import CryptoKit

/// Manages Restic backup operations. Wraps the Restic CLI for S3, SFTP, and local backups.
///
/// Use the `shared` singleton: views that create their own instance lose all
/// live state when SwiftUI destroys and recreates the view (e.g. switching
/// workspace panels mid-backup).
@Observable
final class BackupService: @unchecked Sendable {
    /// The single app-wide instance. Long-running backups keep streaming state
    /// here even if every backup view is closed and recreated.
    static let shared = BackupService()

    // MARK: - State

    var destinations: [BackupDestination] = []
    var jobs: [BackupJob] = []
    var logs: [BackupLogEntry] = []
    var currentState: BackupState = .init()

    private var currentProcess: Process?
    private var cancelRequested = false
    private static let dataURL = SwiftMaestroPaths.dataDir.appendingPathComponent("backup-config.json")
    private static let logsURL = SwiftMaestroPaths.dataDir.appendingPathComponent("backup-logs.json")

    // MARK: - Restic Binary

    /// Path to the Restic binary. Tries bundled, then homebrew, then ~/bin.
    static var resticPath: String {
        if let bundled = Bundle.main.path(forResource: "restic", ofType: nil) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/restic",
            "/usr/local/bin/restic",
            "\(NSHomeDirectory())/bin/restic"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "restic"
    }

    // MARK: - Repository URL

    static func repositoryURL(for destination: BackupDestination) -> String {
        switch destination.kind {
        case .s3(let config):
            return "s3:\(config.endpoint)/\(config.bucket)"
        case .sftp(let config):
            return "sftp:\(config.username)@\(config.host):\(config.repositoryPath)"
        case .local(let config):
            return "local:\(config.path)"
        }
    }

    // MARK: - Environment Variables

    static func environment(for destination: BackupDestination, password: String) -> [String: String] {
        var env = [
            "RESTIC_PASSWORD": password,
            "RESTIC_PROGRESS_FPS": "2"
        ]
        switch destination.kind {
        case .s3(let config):
            env["AWS_ACCESS_KEY_ID"] = config.accessKeyID
            env["AWS_SECRET_ACCESS_KEY"] = config.secretAccessKey
            if !config.region.isEmpty {
                env["AWS_DEFAULT_REGION"] = config.region
            }
        case .sftp, .local:
            break
        }
        return env
    }

    // MARK: - Init / Load

    init() {
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: Self.dataURL),
           let decoded = try? JSONDecoder().decode(BackupConfig.self, from: data) {
            destinations = decoded.destinations
            jobs = decoded.jobs
        }
        if let logData = try? Data(contentsOf: Self.logsURL),
           let decoded = try? JSONDecoder().decode([BackupLogEntry].self, from: logData) {
            logs = decoded
        }
        // Entries persisted as .running are always stale: the process that owned
        // them died with the previous app session. Mark them interrupted.
        var cleanedStale = false
        for idx in logs.indices where logs[idx].status == .running {
            logs[idx].status = .failed
            logs[idx].finishedAt = logs[idx].finishedAt ?? Date()
            logs[idx].errorMessage = "Interrupted — app was closed or restarted"
            cleanedStale = true
        }
        if cleanedStale { save() }
        // Also load launchd logs from the shell backup script
        loadLaunchdLogs()
    }

    func save() {
        let config = BackupConfig(destinations: destinations, jobs: jobs)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: Self.dataURL, options: .atomic)
        }
        if let logData = try? JSONEncoder().encode(logs) {
            try? logData.write(to: Self.logsURL, options: .atomic)
        }
    }

    // MARK: - CRUD

    func addDestination(_ dest: BackupDestination) {
        destinations.append(dest)
        save()
    }

    func updateDestination(_ dest: BackupDestination) {
        if let idx = destinations.firstIndex(where: { $0.id == dest.id }) {
            destinations[idx] = dest
            save()
        }
    }

    func deleteDestination(_ dest: BackupDestination) {
        destinations.removeAll { $0.id == dest.id }
        save()
    }

    func addJob(_ job: BackupJob) {
        jobs.append(job)
        save()
    }

    func updateJob(_ job: BackupJob) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
            save()
        }
    }

    func deleteJob(_ job: BackupJob) {
        jobs.removeAll { $0.id == job.id }
        save()
    }

    // MARK: - Operations

    /// Load backup logs from the launchd shell script's log files.
    /// (The daily 2 AM backup runs via launchd independently of the app.)
    private func loadLaunchdLogs() {
        let logDir = NSHomeDirectory() + "/Library/Logs/woodsee-backup"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"

        for file in files where file.hasPrefix("backup-") && file.hasSuffix(".log") {
            let logPath = (logDir as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { continue }

            // Parse the log file to extract backup info
            let lines = content.components(separatedBy: "\n")
            var startedAt = Date()
            var filesScanned = 0
            var totalSizeBytes: Int64 = 0
            var status: BackupLogEntry.Status = .completed
            var snapshotID: String?

            for line in lines {
                if line.contains("Starting backup") {
                    // Extract timestamp from log line: [2026-08-13 02:00:07]
                    if let dateRange = line.range(of: #"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]"#, options: .regularExpression) {
                        let dateStr = String(line[dateRange]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        if let date = ISO8601DateFormatter().date(from: dateStr.replacingOccurrences(of: " ", with: "T")) {
                            startedAt = date
                        }
                    }
                }
                if line.contains("scan finished") {
                    // Extract file count and size
                    if let match = line.range(of: #"(\d+) files, ([\d.]+) TiB"#, options: .regularExpression) {
                        let scanned = String(line[match])
                        // Parse the numbers
                        let parts = scanned.components(separatedBy: " ")
                        if let count = Int(parts[0]) {
                            filesScanned = count
                        }
                        if parts.count > 2, let size = Double(parts[2]) {
                            totalSizeBytes = Int64(size * 1_099_511_627_776) // TiB to bytes
                        }
                    }
                }
                if line.contains("snapshot") && line.contains("saved") {
                    // Extract snapshot ID
                    if let match = line.range(of: #"[a-f0-9]{8,}"#, options: .regularExpression) {
                        snapshotID = String(line[match])
                    }
                }
                if line.contains("Backup complete") || line.contains("All jobs complete") {
                    status = .completed
                }
                if line.contains("ERROR:") && !line.contains("permission denied") {
                    status = .failed
                }
            }

            // Create a log entry if we found useful info
            if filesScanned > 0 || status == .failed {
                let jobID = jobs.first?.id ?? UUID()
                var logEntry = BackupLogEntry(jobID: jobID, startedAt: startedAt)
                logEntry.finishedAt = Date()
                logEntry.status = status
                logEntry.filesScanned = filesScanned
                logEntry.totalSizeBytes = totalSizeBytes
                logEntry.snapshotID = snapshotID
                if status == .failed {
                    logEntry.errorMessage = "Backup may have failed"
                }

                // Avoid duplicates by checking timestamp
                let alreadyExists = logs.contains { existing in
                    abs(existing.startedAt.timeIntervalSince(logEntry.startedAt)) < 60
                }
                if !alreadyExists {
                    logs.append(logEntry)
                }
            }
        }

        // Sort logs by date, newest first
        logs.sort { $0.startedAt > $1.startedAt }
    }

    func initRepository(destination: BackupDestination, password: String) async throws -> String {
        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)
        return try await runRestic(args: ["-r", repoURL, "init"], environment: env)
    }

    func runBackup(job: BackupJob, destination: BackupDestination, password: String) async throws {
        cancelRequested = false
        let logEntry = BackupLogEntry(jobID: job.id)
        currentState = BackupState(jobID: job.id, phase: .running)
        currentProcess = nil
        logs.insert(logEntry, at: 0)
        save()

        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)

        // --verbose=2 is required for restic to emit the "scan_finished" verbose_status
        // event. Per-file verbose lines are cheaply pre-filtered in parseProgressLine.
        var args = ["-r", repoURL, "backup", "--verbose=2", "--json"]
        for path in job.sourcePaths {
            args.append(path)
        }
        for pattern in job.excludePatterns {
            args.append("--exclude=\(pattern)")
        }
        args.append("--tag=swiftmaestro")
        args.append("--host=\(Host.current().localizedName ?? "mac")")

        let streamLines: @Sendable (String) -> Void = { [weak self] line in
            self?.parseProgressLine(line)
        }

        do {
            do {
                _ = try await runResticStreaming(args: args, environment: env, lineHandler: streamLines)
            } catch let error as BackupError {
                // An interrupted run (app quit, cancelled) can leave a stale lock in
                // the repo, which fails every subsequent backup. `restic unlock` only
                // removes locks whose owning process is dead, then retry once.
                guard case .resticFailed(let output) = error, output.contains("already locked") else {
                    throw error
                }
                _ = try? await runRestic(args: ["-r", repoURL, "unlock"], environment: env)
                _ = try await runResticStreaming(args: args, environment: env, lineHandler: streamLines)
            }

            // Retention: prune old snapshots after a successful backup (non-fatal).
            await MainActor.run { currentState.phase = .pruning }
            var pruneError: String?
            do {
                _ = try await runRestic(args: [
                    "-r", repoURL, "forget",
                    "--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "6",
                    "--prune"
                ], environment: env)
            } catch {
                pruneError = error.localizedDescription
            }

            // Integrity: fast structural verification after every successful
            // backup. Restic content IDs are SHA-256 of the content, so
            // `restic check` re-verifies the repository's hash tree (metadata
            // only — no blob re-read, so this is cheap). A failed check is
            // non-fatal to the backup itself but is recorded on the log entry
            // and shown by the status panel's verification badge. The deep
            // `check --read-data` variant stays a manual "Verify Now" action.
            var verifyPassed: Bool?
            var verifyError: String?
            do {
                _ = try await runRestic(args: ["-r", repoURL, "check"], environment: env)
                verifyPassed = true
            } catch {
                verifyPassed = false
                verifyError = error.localizedDescription
            }

            await MainActor.run {
                currentState.pruneComplete = true
                currentState.phase = .finished

                if let idx = self.logs.firstIndex(where: { $0.id == logEntry.id }) {
                    self.logs[idx].status = .completed
                    self.logs[idx].finishedAt = Date()
                    self.logs[idx].filesScanned = self.currentState.filesScanned
                    self.logs[idx].totalSizeBytes = self.currentState.totalBytes
                    self.logs[idx].uploadedBytes = self.currentState.bytesUploaded
                    self.logs[idx].snapshotID = self.currentState.snapshotID
                    if let verifyPassed {
                        self.logs[idx].checksumVerified = verifyPassed
                        self.logs[idx].checksumResult = verifyPassed ? .passed : .failed
                    }
                    if let verifyError {
                        self.logs[idx].errorMessage = "Integrity check failed: \(verifyError)"
                    } else if let pruneError {
                        self.logs[idx].errorMessage = "Prune failed: \(pruneError)"
                    } else if self.currentState.errorCount > 0 {
                        self.logs[idx].errorMessage = "\(self.currentState.errorCount) files could not be read"
                    }
                }
                if let jobIdx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[jobIdx].lastRunDate = Date()
                }
                self.save()
            }
        } catch {
            if cancelRequested {
                // Cancel already updated the log + reset state; nothing further to do.
                return
            }
            await MainActor.run {
                currentState.phase = .failed
                currentState.lastError = error.localizedDescription

                if let idx = self.logs.firstIndex(where: { $0.id == logEntry.id }) {
                    self.logs[idx].status = .failed
                    self.logs[idx].finishedAt = Date()
                    self.logs[idx].errorMessage = error.localizedDescription
                }
                self.save()
            }
            throw error
        }
    }

    func listSnapshots(destination: BackupDestination, password: String) async throws -> String {
        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)
        return try await runRestic(args: ["-r", repoURL, "snapshots"], environment: env)
    }

    func showStats(destination: BackupDestination, password: String) async throws -> String {
        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)
        return try await runRestic(args: ["-r", repoURL, "stats"], environment: env)
    }

    func pruneSnapshots(destination: BackupDestination, password: String, keepDaily: Int = 7, keepWeekly: Int = 4, keepMonthly: Int = 6) async throws -> String {
        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)
        return try await runRestic(args: [
            "-r", repoURL, "forget",
            "--keep-daily", "\(keepDaily)",
            "--keep-weekly", "\(keepWeekly)",
            "--keep-monthly", "\(keepMonthly)",
            "--prune", "--verbose"
        ], environment: env)
    }

    func cancelBackup() {
        cancelRequested = true
        currentProcess?.terminate()
        currentProcess = nil
        let cancelledJobID = currentState.jobID
        currentState = BackupState()

        if let jobID = cancelledJobID,
           let idx = logs.firstIndex(where: { $0.jobID == jobID && $0.status == .running }) {
            logs[idx].status = .cancelled
            logs[idx].finishedAt = Date()
            save()
        }
    }

    /// Dismiss the finished/failed status banner, returning the panel to idle.
    func dismissStatus() {
        guard currentState.phase == .finished || currentState.phase == .failed else { return }
        currentState = BackupState()
    }

    // MARK: - Checksum Verification

    /// Verify repository integrity using Restic's built-in check command.
    /// This verifies all data blobs and tree structures in the repository.
    func verifyRepository(destination: BackupDestination, password: String) async throws -> (passed: Bool, output: String) {
        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)
        do {
            let output = try await runRestic(args: ["-r", repoURL, "check", "--read-data"], environment: env)
            return (true, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Verify a specific snapshot's integrity.
    func verifySnapshot(_ snapshotID: String, destination: BackupDestination, password: String) async throws -> (passed: Bool, output: String) {
        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)
        do {
            let output = try await runRestic(args: ["-r", repoURL, "check", "--read-data", "--snapshot", snapshotID], environment: env)
            return (true, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Generate SHA256 checksum for a local file.
    static func sha256(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generate SHA256 checksums for multiple files.
    static func sha256Checksums(for fileURLs: [URL]) throws -> [String: String] {
        var results: [String: String] = [:]
        for url in fileURLs {
            results[url.path] = try sha256(for: url)
        }
        return results
    }

    /// Verify a file's checksum against an expected value.
    static func verifyChecksum(for fileURL: URL, expected: String) throws -> Bool {
        let actual = try sha256(for: fileURL)
        return actual == expected
    }

    // MARK: - Progress Parsing

    /// Parses one line of restic's `backup --json` output.
    ///
    /// Called from the pipe readability handler (background queue). All state
    /// mutations are hopped to the main queue so SwiftUI `@Observable` tracking
    /// fires reliably.
    ///
    /// Restic's actual schema (backup.go / ui/json.go):
    /// - `status`:        percent_done, total_files, files_done, total_bytes,
    ///                    bytes_done, seconds_elapsed, seconds_remaining, current_files
    /// - `verbose_status` with `action: "scan_finished"` (only at --verbose=2)
    /// - `error`:         per-file errors
    /// - `summary`:       files_new/changed/unmodified, total_files_processed,
    ///                    total_bytes_processed, data_added, snapshot_id, total_duration
    private func parseProgressLine(_ line: String) {
        // Cheap pre-filter — with --verbose=2, restic emits one verbose_status line
        // per file (millions of lines on a big repo). Only parse lines that can
        // actually change UI state.
        guard line.contains("\"message_type\"") else { return }
        let isStatus = line.contains("\"status\"")
        let isSummary = !isStatus && line.contains("\"summary\"")
        let isScanFinished = !isStatus && !isSummary && line.contains("scan_finished")
        let isError = !isStatus && !isSummary && !isScanFinished && line.contains("\"error\"")
        guard isStatus || isSummary || isScanFinished || isError else { return }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else { return }

        switch messageType {
        case "status":
            let totalFiles = (json["total_files"] as? NSNumber)?.intValue
            let filesDone = (json["files_done"] as? NSNumber)?.intValue
            let totalBytes = (json["total_bytes"] as? NSNumber)?.int64Value
            let bytesDone = (json["bytes_done"] as? NSNumber)?.int64Value
            let elapsed = (json["seconds_elapsed"] as? NSNumber)?.doubleValue
            let remaining = (json["seconds_remaining"] as? NSNumber)?.doubleValue
            let errors = (json["error_count"] as? NSNumber)?.intValue
            let currentFiles = json["current_files"] as? [String]

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let totalFiles { currentState.totalFiles = totalFiles }
                if let filesDone { currentState.filesScanned = filesDone }
                if let totalBytes { currentState.totalBytes = totalBytes }
                if let bytesDone { currentState.bytesUploaded = bytesDone }
                if let elapsed { currentState.secondsElapsed = elapsed }
                if let remaining, remaining > 0 { currentState.secondsRemaining = remaining }
                if let errors { currentState.errorCount = errors }
                if let file = currentFiles?.first { currentState.currentFile = file }
                if let elapsed, elapsed > 0, let bytesDone {
                    currentState.speed = Double(bytesDone) / elapsed
                }
            }

        case "verbose_status":
            // Only emitted at --verbose >= 2. Marks the end of the scan phase.
            // Note: this event carries `data_size` (bytes scanned), not `total_bytes`.
            guard isScanFinished, (json["action"] as? String) == "scan_finished" else { return }
            let totalFiles = (json["total_files"] as? NSNumber)?.intValue
            let dataSize = (json["data_size"] as? NSNumber)?.int64Value
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let totalFiles { currentState.totalFiles = totalFiles }
                if let dataSize, currentState.totalBytes <= 0 { currentState.totalBytes = dataSize }
                currentState.scanComplete = true
            }

        case "error":
            let item = json["item"] as? String
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                currentState.errorCount += 1
                if let item { currentState.currentFile = item }
            }

        case "summary":
            let totalFilesProcessed = (json["total_files_processed"] as? NSNumber)?.intValue
            let totalBytesProcessed = (json["total_bytes_processed"] as? NSNumber)?.int64Value
            let dataAdded = (json["data_added"] as? NSNumber)?.int64Value
            let snapshotID = json["snapshot_id"] as? String
            let duration = (json["total_duration"] as? NSNumber)?.doubleValue
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let totalFilesProcessed {
                    currentState.filesScanned = totalFilesProcessed
                    currentState.totalFiles = totalFilesProcessed
                }
                if let totalBytesProcessed { currentState.totalBytes = totalBytesProcessed }
                // data_added = bytes actually written to the repo (deduplicated);
                // fall back to total processed for the first full backup.
                currentState.bytesUploaded = dataAdded ?? totalBytesProcessed ?? currentState.bytesUploaded
                currentState.snapshotID = snapshotID
                if let duration { currentState.secondsElapsed = duration }
                currentState.scanComplete = true
                currentState.uploadComplete = true
            }

        default:
            break
        }
    }

    // MARK: - Process Execution

    func runRestic(args: [String], environment: [String: String]) async throws -> String {
        try await runResticStreaming(args: args, environment: environment) { _ in }
    }

    private func runResticStreaming(args: [String], environment: [String: String], lineHandler: @escaping @Sendable (String) -> Void) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.resticPath)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        currentProcess = process

        // Accumulator protected by a lock: readabilityHandler and terminationHandler
        // fire on arbitrary queues.
        final class Buffer: @unchecked Sendable {
            private let lock = NSLock()
            private var output = ""
            private var pendingLine = ""
            /// Cap retained output so multi-hour verbose runs don't grow memory.
            private let maxRetained = 512 * 1024

            func append(_ str: String, lineHandler: (String) -> Void) {
                lock.lock()
                output += str
                if output.count > maxRetained {
                    output = String(output.suffix(maxRetained))
                }
                pendingLine += str
                var lines: [String] = []
                while let newline = pendingLine.firstIndex(of: "\n") {
                    lines.append(String(pendingLine[pendingLine.startIndex..<newline]))
                    pendingLine = String(pendingLine[pendingLine.index(after: newline)...])
                }
                lock.unlock()
                for line in lines where !line.isEmpty {
                    lineHandler(line)
                }
            }

            /// Flush a final line that had no trailing newline, and return full output.
            func finish(lineHandler: (String) -> Void) -> String {
                lock.lock()
                let remainder = pendingLine
                pendingLine = ""
                let full = output
                lock.unlock()
                if !remainder.isEmpty {
                    lineHandler(remainder)
                }
                return full
            }
        }
        let buffer = Buffer()

        return try await withCheckedThrowingContinuation { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                buffer.append(str, lineHandler: lineHandler)
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let output = buffer.finish(lineHandler: lineHandler)
                if proc.terminationReason == .exit, proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: BackupError.resticFailed(output))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: BackupError.binaryNotFound)
            }
        }
    }
}

// MARK: - Supporting Types

private struct BackupConfig: Codable {
    var destinations: [BackupDestination]
    var jobs: [BackupJob]
}

enum BackupError: LocalizedError {
    case binaryNotFound
    case resticFailed(String)
    case invalidDestination
    case passwordRequired

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Restic binary not found. Install with: brew install restic"
        case .resticFailed(let output):
            return "Restic failed: \(output.prefix(200))"
        case .invalidDestination:
            return "Invalid backup destination configuration"
        case .passwordRequired:
            return "Backup password is required"
        }
    }
}
