import Foundation
import MLXLMCommon

// MARK: - Shell Execution Tool

/// Shell command execution tool for SwiftMaestro agents.
///
/// Supports:
/// - Dry-run preview (`dry_run`)
/// - Policy classification (allowed/denied/ask/unknown)
/// - User approval flow for ask-classified commands
/// - Concurrency-limited execution via `ShellExecutionQueue`
/// - Timeout enforcement
extension MaestroTools {

    static let shellToolNames: Set<String> = [
        "execute_command", "list_background_processes", "stop_background_process",
    ]

    static var shellToolSpecs: [ToolSpec] {
        [
            rawSpec("execute_command",
                "Execute a shell command via zsh. Runs a subprocess, captures stdout/stderr, "
                + "and returns the output. Use `dry_run` to preview the classified command "
                + "without executing. Use `start_background: true` for long-running processes "
                + "(e.g. HTTP servers) that should survive after the command returns. "
                + "Background processes are tracked and can be listed/stopped.",
                properties: [
                    "command": ["type": "string", "description": "The shell command to execute (e.g. 'ls -la /tmp')."],
                    "cwd": ["type": "string", "description": "Optional working directory. Defaults to the agent workspace."],
                    "timeout": ["type": "integer", "description": "Timeout in seconds (default: 60). Ignored for background processes."],
                    "dry_run": ["type": "boolean", "description": "If true, classify the command against policy and return the classification without executing."],
                    "start_background": ["type": "boolean", "description": "If true, run the process in the background. Returns immediately with a process ID. Use list_background_processes to check status."],
                ],
                required: ["command"]),
            rawSpec("list_background_processes",
                "List all running background processes started with start_background.",
                properties: [:],
                required: []),
            rawSpec("stop_background_process",
                "Stop a background process by its ID (from list_background_processes).",
                properties: [
                    "process_id": ["type": "string", "description": "The process ID to stop."],
                ],
                required: ["process_id"]),
        ]
    }

    private struct ShellArgs: Decodable {
        let command: String?
        let cwd: String?
        let timeout: Int?
        let dry_run: Bool?
        let start_background: Bool?

        var dryRun: Bool { dry_run ?? false }
        var startBackground: Bool { start_background ?? false }
    }

    // MARK: - Entry Point

    static func executeShell(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ShellArgs.self),
              let raw = args.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return errorJSON("Command is empty. Provide a shell command to execute.")
        }

        // 1. Check if shell tool is enabled
        guard await MainActor.run(body: { ShellPolicyStore.shared.enabled }) else {
            return errorJSON(
                "The execute_command tool is disabled. Enable it in Settings → Shell."
            )
        }

        // 2. Classify the command
        let classification: ShellClassification = await MainActor.run(body: {
            ShellPolicyStore.shared.classify(raw)
        })

        // 3. Handle deny
        if classification == .denied {
            return errorJSON(
                "Command blocked by always-deny policy: \"\(raw)\"."
            )
        }

        // 4. Dry-run — return classification info without executing
        if args.dryRun {
            return encodeJSON(DryRunResult(
                command: raw,
                classification: classification,
                cwd: args.cwd
            ))
        }

        // 5. Handle ask — show approval banner and wait
        if classification == .ask {
            let workingDir = args.cwd ?? NSHomeDirectory()
            let approved = await requestShellApproval(command: raw, cwd: workingDir)
            guard approved else {
                return errorJSON("Command denied by user: \"\(raw)\".")
            }
        }

        // 6. Background process — spawn and return immediately
        if args.startBackground {
            let workingDir = args.cwd ?? NSHomeDirectory()
            return await spawnBackgroundProcess(raw, cwd: workingDir)
        }

        // 7. Execute (allowed, unknown, or approved)
        return await runShellCommand(raw, cwd: args.cwd, timeout: args.timeout)
    }

    // MARK: - Approval Flow

    private static func requestShellApproval(command: String, cwd: String) async -> Bool {
        let requestId = await MainActor.run(body: {
            ShellApprovalStore.shared.addApproval(
                ShellApprovalRequest(
                    command: command,
                    cwd: URL(fileURLWithPath: cwd),
                    classification: .unknown,
                    agentName: "Agent"
                )
            )
        })

        // Poll for approval with a 5-minute timeout
        let deadline = Date().addingTimeInterval(5 * 60)
        while Date() < deadline {
            let result: ShellApprovalResult? = await MainActor.run(body: {
                let store = ShellApprovalStore.shared
                if store.isExpired(id: requestId) {
                    store.cleanupExpired()
                    return .expired
                }
                // Still pending (removed on approve/deny)
                return nil
            })

            if let result = result {
                return result == .approved || result == .approvedAndRemember
            }

            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        await MainActor.run(body: { ShellApprovalStore.shared.cleanupExpired() })
        return false
    }

    // MARK: - Command Execution

    private static func runShellCommand(
        _ command: String,
        cwd: String?,
        timeout: Int?
    ) async -> String {
        let effectiveTimeout = timeout ?? 60
        let workingDir = cwd ?? NSHomeDirectory()

        // Log the command start
        let logID = await MainActor.run(body: {
            ShellLogStore.shared.addEntry(command: command, cwd: workingDir)
        })

        // Run with concurrency control
        let shellQueue = await MainActor.run(body: { ShellExecutionQueue.shared })
        let result: ShellRawResult = await (try? shellQueue.execute {
            await shellExecuteProcess(
                command: command,
                cwd: workingDir,
                timeout: TimeInterval(effectiveTimeout)
            )
        }) ?? ShellRawResult(
            success: false, exitCode: -1, stdout: "",
            stderr: "Shell queue rejected command (concurrency limit or draining).",
            durationMs: 0, timedOut: false
        )

        // Log the result
        await MainActor.run(body: {
            ShellLogStore.shared.completeEntry(
                id: logID,
                stdout: String(result.stdout.prefix(50_000)),
                stderr: String(result.stderr.prefix(50_000)),
                exitCode: result.exitCode,
                durationMs: result.durationMs,
                timedOut: result.timedOut
            )
        })

        return encodeJSON(ShellCommandResult(
            success: result.success,
            exitCode: result.exitCode,
            stdout: String(result.stdout.prefix(50_000)),
            stderr: String(result.stderr.prefix(50_000)),
            command: command,
            cwd: workingDir,
            durationMs: result.durationMs,
            timedOut: result.timedOut
        ))
    }

    // MARK: - Process Execution

    private static func shellExecuteProcess(
        command: String,
        cwd: String,
        timeout: TimeInterval
    ) async -> ShellRawResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startTime = Date()
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lic", command]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if FileManager.default.fileExists(atPath: cwd) {
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }

                process.terminationHandler = { proc in
                    let elapsed = Date().timeIntervalSince(startTime)
                    let timedOut = elapsed >= timeout && proc.terminationStatus != 0

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    continuation.resume(returning: ShellRawResult(
                        success: proc.terminationStatus == 0,
                        exitCode: Int32(proc.terminationStatus),
                        stdout: stdout,
                        stderr: stderr,
                        durationMs: Int(elapsed * 1000),
                        timedOut: timedOut
                    ))
                }

                do {
                    try process.run()
                } catch {
                    let elapsed = Date().timeIntervalSince(startTime)
                    continuation.resume(returning: ShellRawResult(
                        success: false,
                        exitCode: -1,
                        stdout: "",
                        stderr: "Failed to launch zsh: \(error.localizedDescription)",
                        durationMs: Int(elapsed * 1000),
                        timedOut: false
                    ))
                    return
                }

                // Kill on timeout
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.1)
                    if process.isRunning {
                        process.interrupt()
                    }
                }
            }
        }
    }

    // MARK: - Background Process Management

    /// Spawn a long-running process that survives after the command returns.
    private static func spawnBackgroundProcess(_ command: String, cwd: String) async -> String {
        let processID = UUID().uuidString.prefix(8).lowercased()
        let logPath = NSTemporaryDirectory() + "swiftmaestro-bg-\(processID).log"
        let errPath = NSTemporaryDirectory() + "swiftmaestro-bg-\(processID).err"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // nohup + disown ensures the process survives shell exit
        process.arguments = ["-lic", "nohup \(command) > \"\(logPath)\" 2> \"\(errPath)\" &\necho $!"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        do {
            try process.run()
        } catch {
            return errorJSON("Failed to launch background process: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        // Read the PID from stdout
        let pidData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let pid = String(data: pidData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

        // Wait a moment and check if the process is actually running
        try? await Task.sleep(nanoseconds: 500_000_000)
        let isRunning = await MainActor.run { BackgroundProcessManager.shared.isProcessRunning(pid: pid) }

        if isRunning {
            await MainActor.run {
                BackgroundProcessManager.shared.addProcess(
                    id: pid,
                    command: command,
                    cwd: cwd,
                    logPath: logPath,
                    errPath: errPath
                )
            }
        }

        return encodeJSON(BackgroundProcessResult(
            success: isRunning,
            process_id: pid,
            command: command,
            cwd: cwd,
            log_path: logPath,
            err_path: errPath,
            message: isRunning
                ? "Background process \(pid) started. Use list_background_processes to monitor."
                : "Process exited immediately. Check logs at \(logPath)"
        ))
    }

    /// List all tracked background processes.
    static func listBackgroundProcesses() async -> String {
        let processes = await MainActor.run { BackgroundProcessManager.shared.listProcesses() }
        return encodeJSON(BackgroundProcessList(processes: processes, count: processes.count))
    }

    /// Stop a background process by ID.
    static func stopBackgroundProcess(_ call: ToolCall) async -> String {
        struct Args: Decodable { let process_id: String? }
        guard let args = decodeArgs(call, as: Args.self),
              let pid = args.process_id, !pid.isEmpty else {
            return errorJSON("Provide a process_id to stop.")
        }

        let stopped = await MainActor.run { BackgroundProcessManager.shared.stopProcess(pid: pid) }
        if stopped {
            return jsonString(["success": true, "message": "Process \(pid) stopped."])
        } else {
            return errorJSON("Process \(pid) not found or already stopped.")
        }
    }

    // MARK: - Encoding Helpers

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}

// MARK: - Result Types

private struct DryRunResult: Encodable {
    let command: String
    let classification: ShellClassification
    let cwd: String?
}

private struct ShellCommandResult: Encodable {
    let success: Bool
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let command: String
    let cwd: String
    let durationMs: Int
    let timedOut: Bool
}

private struct ShellRawResult {
    let success: Bool
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let durationMs: Int
    let timedOut: Bool
}

private struct BackgroundProcessResult: Encodable {
    let success: Bool
    let process_id: String
    let command: String
    let cwd: String
    let log_path: String
    let err_path: String
    let message: String
}

private struct BackgroundProcessList: Encodable {
    let processes: [BackgroundProcessManager.TrackedProcess]
    let count: Int
}

// MARK: - Background Process Manager

/// Tracks long-running background processes spawned by agents.
@MainActor
private final class BackgroundProcessManager {

    static let shared = BackgroundProcessManager()

    struct TrackedProcess: Encodable {
        let id: String
        let command: String
        let cwd: String
        let logPath: String
        let errPath: String
        let startedAt: Date
    }

    private var processes: [String: TrackedProcess] = [:]

    func addProcess(id: String, command: String, cwd: String, logPath: String, errPath: String) {
        processes[id] = TrackedProcess(
            id: id,
            command: command,
            cwd: cwd,
            logPath: logPath,
            errPath: errPath,
            startedAt: Date()
        )
    }

    func listProcesses() -> [TrackedProcess] {
        // Prune processes that are no longer running
        for (id, _) in processes {
            if !isProcessRunning(pid: id) {
                processes.removeValue(forKey: id)
            }
        }
        return Array(processes.values)
    }

    func stopProcess(pid: String) -> Bool {
        guard processes[pid] != nil else { return false }
        // Kill the process group
        let killResult = kill(pid_t(Int(pid) ?? 0), SIGTERM)
        // Also try SIGKILL after a brief delay
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            kill(pid_t(Int(pid) ?? 0), SIGKILL)
        }
        processes.removeValue(forKey: pid)
        return killResult == 0
    }

    func isProcessRunning(pid: String) -> Bool {
        guard let pidNum = pid_t(pid), pidNum > 0 else { return false }
        // kill(pid, 0) checks if process exists without sending a signal
        return kill(pidNum, 0) == 0
    }
}
