import Foundation
import Darwin

enum InstallManager {

    enum InstallError: LocalizedError {
        case failed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .failed(let detail):
                return "Installation failed: \(detail)"
            case .cancelled:
                return "Installation was cancelled — no changes were made."
            }
        }
    }

    struct ProgressUpdate: Sendable {
        let message: String?
        let fraction: Double?
        let rawLine: String?
    }

    /// Installs a signed .pkg via `installer(8)` using the standard macOS
    /// administrator prompt. Streams `installer -dumplog -verboseR` output
    /// and reports progress so the UI can show a determinate progress bar
    /// instead of a blind spinner.
    ///
    /// - Parameter onLogLine: Called for every raw log line so the UI can show
    ///   a live tail when the installer spends a long time without percentage
    ///   updates (common with very large packages).
    static func installPackage(
        at path: String,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void,
        onLogLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMaestroSetup-Install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let logURL = workDir.appendingPathComponent("install.log")
        let pidURL = workDir.appendingPathComponent("pid.txt")

        let escapedPath = path.replacingOccurrences(of: "'", with: "\\'")
        let escapedLog = logURL.path.replacingOccurrences(of: "'", with: "\\'")
        let escapedPID = pidURL.path.replacingOccurrences(of: "'", with: "\\'")

        // Launch installer in the background with admin privileges, redirecting
        // its verbose log to a file. The privileged shell exits immediately and
        // returns the background PID on stdout so we can poll the log.
        // We also write the PID to a file as a fallback.
        let launchScript = """
        do shell script "{ /usr/sbin/installer -pkg '\(escapedPath)' -target / -dumplog -verboseR ; echo EXITCODE:$? ; } > '\(escapedLog)' 2>&1 & echo $! > '\(escapedPID)' ; cat '\(escapedPID)'" with administrator privileges
        """

        let pidString: String = try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", launchScript]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus != 0 {
                let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // osascript exits -128-ish when the user cancels the admin prompt.
                if detail.localizedCaseInsensitiveContains("User canceled") || proc.terminationStatus == -128 {
                    throw InstallError.cancelled
                }
                throw InstallError.failed(detail.isEmpty ? "Could not start installer (status \(proc.terminationStatus))" : detail)
            }

            return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value

        // Prefer the PID returned by osascript; fall back to the PID file if parsing fails.
        let pid: Int32
        if let parsed = Int32(pidString) {
            pid = parsed
        } else if let filePID = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let parsedFilePID = Int32(filePID) {
            pid = parsedFilePID
        } else {
            throw InstallError.failed("Could not read installer process ID.")
        }

        // Stream the log until the process exits and an EXITCODE line appears.
        let result = try await streamInstallerLog(
            logURL: logURL,
            pid: pid,
            onProgress: onProgress,
            onLogLine: onLogLine
        )

        try? FileManager.default.removeItem(at: workDir)

        guard result.success else {
            throw InstallError.failed(result.message)
        }
    }

    // MARK: - Private

    private struct StreamResult {
        let success: Bool
        let message: String
    }

    private static func streamInstallerLog(
        logURL: URL,
        pid: Int32,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void,
        onLogLine: @escaping @Sendable (String) -> Void
    ) async throws -> StreamResult {
        var offset: UInt64 = 0
        var lastMessage = "Installing SwiftMaestro…"
        var lastFraction = 0.0
        var exitCode: Int32?
        var deadFor: UInt64 = 0

        while true {
            let alive = processIsAlive(pid)

            if let handle = try? FileHandle(forReadingFrom: logURL) {
                if #available(macOS 10.15.4, *) {
                    _ = try? handle.seek(toOffset: offset)
                } else {
                    handle.seek(toFileOffset: offset)
                }
                let data = handle.readDataToEndOfFile()
                offset = handle.offsetInFile
                handle.closeFile()

                if let text = String(data: data, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { continue }

                        onLogLine(trimmed)

                        if let update = parseInstallerLine(trimmed) {
                            if let message = update.message {
                                lastMessage = message
                            }
                            if let fraction = update.fraction {
                                lastFraction = fraction
                            }
                            onProgress(ProgressUpdate(message: lastMessage, fraction: lastFraction, rawLine: nil))
                        }

                        if trimmed.hasPrefix("EXITCODE:") {
                            let codeString = String(trimmed.dropFirst("EXITCODE:".count))
                            exitCode = Int32(codeString.trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
            }

            if let exitCode {
                if exitCode == 0 {
                    onProgress(ProgressUpdate(message: "Installation complete", fraction: 1.0, rawLine: nil))
                    return StreamResult(success: true, message: "")
                } else {
                    return StreamResult(success: false, message: "installer exited with status \(exitCode).")
                }
            }

            if !alive {
                // The process exited, but we haven't seen the final EXITCODE line yet.
                // Give the log file a moment to flush and re-read before failing.
                deadFor += 1
                if deadFor >= 6 {
                    return StreamResult(success: false, message: "Installer process ended unexpectedly.")
                }
            } else {
                deadFor = 0
            }

            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        // Use kill(0), not waitpid, because the installer is a background root
        // process that is not a child of this app. EPERM means the process
        // exists but we lack permission to signal it; treat that as alive.
        let result = kill(pid, 0)
        if result == 0 { return true }
        return errno == EPERM
    }

    private struct LineParseResult {
        var message: String?
        var fraction: Double?
    }

    private static func parseInstallerLine(_ line: String) -> LineParseResult? {
        var result = LineParseResult()

        if let range = line.range(of: "installer:PHASE:") {
            let message = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                result.message = message
            }
        } else if let range = line.range(of: "installer:STATUS:") {
            let message = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                result.message = message
            }
        } else if let range = line.range(of: "installer:%:") {
            let number = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Double(number) {
                result.fraction = min(max(value / 100.0, 0.0), 1.0)
            }
        } else if line.localizedCaseInsensitiveContains("The install was successful") {
            result.message = "Installation complete"
            result.fraction = 1.0
        }

        return (result.message != nil || result.fraction != nil) ? result : nil
    }
}
