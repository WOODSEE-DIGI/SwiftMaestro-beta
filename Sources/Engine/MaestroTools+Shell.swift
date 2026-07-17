import Foundation
import MLXLMCommon
#if canImport(Darwin)
import Darwin
#endif

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
                + "and returns the output. This is your terminal — use it whenever the user asks "
                + "you to run a command, start a server, or perform any shell operation. "
                + "Use `dry_run` to preview the classified command without executing. "
                + "ALWAYS use `start_background: true` for long-running processes such as HTTP "
                + "servers, watchers, or daemons so they survive after the command returns. "
                + "Background processes are tracked and can be listed/stopped. "
                + "EXACT tool call format example:\n"
                + "<tool_call>\n<function=execute_command>\n<parameter=command>\n"
                + "cd /path/to/site && python3 -m http.server 8001\n"
                + "</parameter>\n</function>\n</tool_call>",
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

        enum CodingKeys: String, CodingKey {
            case command, cwd, timeout, dry_run, start_background
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            timeout = try container.decodeIfPresent(FlexibleInt.self, forKey: .timeout)?.value
            dry_run = try container.decodeIfPresent(FlexibleBool.self, forKey: .dry_run)?.value
            start_background = try container.decodeIfPresent(FlexibleBool.self, forKey: .start_background)?.value
        }
    }

    /// Decodes a Bool from either a JSON boolean or a string like "true"/"false".
    private struct FlexibleBool: Decodable {
        let value: Bool
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
                return
            }
            if let string = try? container.decode(String.self) {
                switch string.lowercased().trimmingCharacters(in: .whitespaces) {
                case "true", "1", "yes", "on": value = true
                case "false", "0", "no", "off": value = false
                default:
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Cannot decode '\(string)' as Bool")
                }
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected Bool or String")
        }
    }

    /// Decodes an Int from either a JSON integer or a numeric string.
    private struct FlexibleInt: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
                return
            }
            if let string = try? container.decode(String.self), let int = Int(string) {
                value = int
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected Int or numeric String")
        }
    }

    // MARK: - Entry Point

    static func executeShell(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ShellArgs.self),
              let raw = args.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            NSLog("[SHELL] executeShell called with empty command. args: \(String(describing: call.function.arguments))")
            return errorJSON(
                "Command is empty. You MUST provide a non-empty shell command in the "
                + "`command` parameter. Example:\n"
                + "<tool_call>\n<function=execute_command>\n<parameter=command>\n"
                + "python3 /path/to/script.py\n</parameter>\n</function>\n</tool_call>"
            )
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
        let logsDir = SwiftMaestroPaths.logsDir.path
        let logPath = "\(logsDir)/swiftmaestro-bg-\(processID).log"
        let errPath = "\(logsDir)/swiftmaestro-bg-\(processID).err"

        // If the command starts with `cd /path &&` or `cd /path;`, extract the directory
        // and run the remainder directly in that directory. This avoids the `cd` builtin
        // failing when wrapped with nohup, and keeps the tracked PID as the actual
        // nohup process rather than a short-lived subshell.
        let (effectiveCwd, effectiveCommand) = splitLeadingCd(command: command, baseCwd: cwd)

        // Check for an obvious port conflict before spawning.
        if let port = portFromCommand(effectiveCommand), isPortInUse(port: port) {
            return errorJSON(
                "Port \(port) is already in use. Stop the existing process or choose a different port."
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // nohup + disown ensures the process survives the launcher shell's exit.
        process.arguments = ["-lic", "nohup \(effectiveCommand) > \"\(logPath)\" 2> \"\(errPath)\" &\necho $!"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if FileManager.default.fileExists(atPath: effectiveCwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: effectiveCwd)
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
                    cwd: effectiveCwd,
                    logPath: logPath,
                    errPath: errPath
                )
            }
        }

        let message: String
        if isRunning {
            message = "Background process \(pid) started. Use list_background_processes to monitor."
        } else {
            let errTail = (try? String(contentsOfFile: errPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .prefix(3)
                .joined(separator: "\n") ?? ""
            if errTail.isEmpty {
                message = "Process exited immediately. Check logs at \(logPath)"
            } else {
                message = "Process exited immediately. Error:\n\(errTail)"
            }
        }

        return encodeJSON(BackgroundProcessResult(
            success: isRunning,
            process_id: pid,
            command: command,
            cwd: effectiveCwd,
            log_path: logPath,
            err_path: errPath,
            message: message
        ))
    }

    /// If `command` starts with `cd /path && ...` or `cd /path; ...`, return the
    /// extracted directory and the remainder of the command. Otherwise return the
    /// original cwd and command unchanged.
    private static func splitLeadingCd(command: String, baseCwd: String) -> (cwd: String, command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [(String, String)] = [
            (#"^cd\s+(\S+)\s+&&\s+(.+)$"#, "&&"),
            (#"^cd\s+(\S+)\s*;\s*(.+)$"#, ";"),
        ]
        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: trimmed, options: [],
                                               range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed))
            else { continue }
            guard let pathRange = Range(match.range(at: 1), in: trimmed),
                  let restRange = Range(match.range(at: 2), in: trimmed)
            else { continue }
            let path = String(trimmed[pathRange])
            let rest = String(trimmed[restRange])
            let resolved = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: baseCwd)).path
            return (resolved, rest)
        }
        return (baseCwd, command)
    }

    /// Extract a TCP port number from a command string, if one is present.
    /// Handles common patterns like `python3 -m http.server 8001`, `nohup ... 8001`, etc.
    private static func portFromCommand(_ command: String) -> Int? {
        // Look for a bare port number (4-5 digits) preceded by a space or `--port=` / `-p `.
        let patterns: [String] = [
            #"\s--port=(\d{2,5})\b"#,
            #"\s-p\s+(\d{2,5})\b"#,
            #"\s(\d{2,5})\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(command.startIndex..<command.endIndex, in: command)
            if let match = regex.firstMatch(in: command, options: [], range: range),
               let portRange = Range(match.range(at: 1), in: command),
               let port = Int(command[portRange]), port > 0, port <= 65535 {
                return port
            }
        }
        return nil
    }

    /// Check whether a TCP port is currently in use on localhost.
    private static func isPortInUse(port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // If bind fails, the port is in use.
        return result != 0
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
        guard let pidNum = pid_t(pid), pidNum > 0, processes[pid] != nil else { return false }
        // Kill the process group first (negative pid), then the specific process.
        kill(-pidNum, SIGTERM)
        let killResult = kill(pidNum, SIGTERM)
        // Also try SIGKILL after a brief delay
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            kill(-pidNum, SIGKILL)
            kill(pidNum, SIGKILL)
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
