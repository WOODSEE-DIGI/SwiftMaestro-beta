import Foundation
import CryptoKit

/// Manages Restic backup operations. Wraps the Restic CLI for S3, SFTP, and local backups.
@Observable
final class BackupService: @unchecked Sendable {
    // MARK: - State

    var destinations: [BackupDestination] = []
    var jobs: [BackupJob] = []
    var logs: [BackupLogEntry] = []
    var currentState: BackupState = .init()

    private var currentProcess: Process?
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

    /// Trigger a backup via the launchd shell script (runs independently of the app).
    func triggerLaunchdBackup() async throws {
        let scriptPath = NSHomeDirectory() + "/Scripts/backups/woodsee-backup.sh"
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            throw BackupError.binaryNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", scriptPath]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/bin:/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        currentProcess = process

        try process.run()
    }

    /// Kickstart the launchd job (re-runs it immediately).
    func kickstartLaunchdJob() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.woodsee.offsite-backup"]
        try? process.run()
        process.waitUntilExit()
    }

    /// Load backup logs from the launchd shell script's log files.
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
                if line.contains("error") || line.contains("failed") {
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
        let logEntry = BackupLogEntry(jobID: job.id)
        currentState = BackupState(jobID: job.id, phase: .scanning)
        currentProcess = nil
        logs.insert(logEntry, at: 0)
        save()

        let repoURL = Self.repositoryURL(for: destination)
        let env = Self.environment(for: destination, password: password)

        var args = ["-r", repoURL, "backup", "--verbose", "--json"]
        for path in job.sourcePaths {
            args.append(path)
        }
        for pattern in job.excludePatterns {
            args.append("--exclude=\(pattern)")
        }
        args.append("--tag=swiftmaestro")
        args.append("--host=\(Host.current().localizedName ?? "mac")")

        do {
            _ = try await runResticStreaming(args: args, environment: env) { [weak self] line in
                self?.parseProgressLine(line)
            }

            currentState.phase = .finished

            if let idx = self.logs.firstIndex(where: { $0.id == logEntry.id }) {
                self.logs[idx].status = .completed
                self.logs[idx].finishedAt = Date()
                self.logs[idx].filesScanned = self.currentState.filesScanned
                self.logs[idx].totalSizeBytes = self.currentState.totalBytes
                self.logs[idx].uploadedBytes = self.currentState.bytesUploaded
            }
            if let jobIdx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                self.jobs[jobIdx].lastRunDate = Date()
            }
            self.save()
        } catch {
            currentState.phase = .idle

            if let idx = self.logs.firstIndex(where: { $0.id == logEntry.id }) {
                self.logs[idx].status = .failed
                self.logs[idx].finishedAt = Date()
                self.logs[idx].errorMessage = error.localizedDescription
            }
            self.save()
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
        currentProcess?.terminate()
        currentProcess = nil
        currentState.phase = .idle
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

    private func parseProgressLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let messageType = json["message_type"] as? String {
            switch messageType {
            case "status":
                if let filesNew = json["files_new"] as? Int {
                    currentState.filesScanned = filesNew
                    currentState.phase = .scanning
                }
                if let bytesAdded = json["bytes_added"] as? Int64 {
                    currentState.bytesUploaded = bytesAdded
                    currentState.phase = .uploading
                }
                if let totalBytes = json["total_bytes"] as? Int64 {
                    currentState.totalBytes = totalBytes
                }
            case "summary":
                if let totalFiles = json["files_new"] as? Int {
                    currentState.filesScanned = totalFiles
                    currentState.totalFiles = totalFiles
                }
                if let totalBytes = json["total_bytes"] as? Int64 {
                    currentState.totalBytes = totalBytes
                    currentState.bytesUploaded = totalBytes
                }
            default:
                break
            }
        }
    }

    // MARK: - Process Execution

    func runRestic(args: [String], environment: [String: String]) async throws -> String {
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

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: BackupError.resticFailed(output))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: BackupError.binaryNotFound)
            }
        }
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

        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var outputBuffer = ""

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let str = String(data: data, encoding: .utf8) {
                    outputBuffer += str
                    let lines = str.components(separatedBy: "\n")
                    for line in lines where !line.isEmpty {
                        lineHandler(line)
                    }
                }
            }

            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: outputBuffer)
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
