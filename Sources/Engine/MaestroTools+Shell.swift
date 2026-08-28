import Foundation
import MLXLMCommon
import SwiftMaestroKit
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

    static func registerShellTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "execute_command", spec: shellToolSpecs[0],
                category: ToolCategory.shell.rawValue,
                handler: { call in await executeShell(call) }),
            ToolDefinition(
                name: "list_background_processes", spec: shellToolSpecs[1],
                category: ToolCategory.shell.rawValue,
                handler: { _ in await listBackgroundProcesses() }),
            ToolDefinition(
                name: "stop_background_process", spec: shellToolSpecs[2],
                category: ToolCategory.shell.rawValue,
                handler: { call in await stopBackgroundProcess(call) }),
        ])
    }



    static var shellToolSpecs: [ToolSpec] {
        [
            rawSpec("execute_command",
                "Execute a shell command via zsh. Runs a subprocess, captures stdout/stderr, "
                + "and returns the output. This is your terminal — use it whenever the user asks "
                + "you to run a command, start a server, or perform any shell operation. "
                + "Use `dry_run` to preview the classified command without executing. "
                + "ALWAYS use `start_background: true` for long-running processes such as HTTP "
                + "servers, watchers, daemons, or xcodebuild builds (which can take several "
                + "minutes) so they survive after the command returns. "
                + "Background processes are tracked and can be listed/stopped. "
                + "EXACT tool call format example:\n"
                + "<tool_call>\n<function=execute_command>\n<parameter=command>\n"
                + "cd /path/to/site && python3 -m http.server 8001\n"
                + "</parameter>\n</function>\n</tool_call>",
                properties: [
                    "command": ["type": "string", "description": "The shell command to execute. When piping output to a log file (e.g. xcodebuild | tee .build/build.log), always write inside the project directory — never use /tmp/ which is outside authorized roots."],
                    "cwd": ["type": "string", "description": "Optional working directory. Defaults to the agent workspace."],
                    "timeout": ["type": "integer", "description": "Timeout in SECONDS — not milliseconds. 300 = 5 minutes. Default 60, max 3600. For anything longer (xcodebuild, big downloads), use start_background: true instead — background processes have no timeout."],
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
            timeout = try container.decodeIfPresent(LenientInt.self, forKey: .timeout)?.value
            dry_run = try container.decodeIfPresent(LenientBool.self, forKey: .dry_run)?.value
            start_background = try container.decodeIfPresent(LenientBool.self, forKey: .start_background)?.value
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

        // Defensive: strip any thinking/channel tags that leaked into the command
        // parameter (Gemma 4 emits <channel>/</channel>, Qwen emits  think/think).
        // If stripping leaves nothing, the model emitted a tag instead of a command.
        let sanitized = ThinkingTagStripper.strip(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            NSLog("[SHELL] executeShell rejected command after tag stripping. raw='\(raw)'")
            return errorJSON(
                "The command parameter contained only a thinking/channel tag ('\(raw)') "
                + "instead of a real shell command. NEVER put thinking tags or reasoning "
                + "markers inside the <parameter=command> block. Put only the literal shell "
                + "command. Example:\n"
                + "<tool_call>\n<function=execute_command>\n<parameter=command>\n"
                + "brew update\n</parameter>\n</function>\n</tool_call>"
            )
        }
        // 0.4. Fix unclosed double quotes — models (especially small MoE) frequently
        // emit `echo "Build directory not found` (missing closing `"`), which breaks
        // zsh. Count quotes and append a closing one if odd.
        // 0.5. Inject `-quiet` into xcodebuild commands to suppress 170KB+ of noise.
        let command: String = {
            var cmd = sanitized
            let dqCount = cmd.unicodeScalars.filter { $0 == "\"" }.count
            if dqCount % 2 != 0 {
                NSLog("[SHELL] fixing unclosed quote in command (found %d double quotes)", dqCount)
                cmd = cmd + "\""
            }
            // Inject -quiet into xcodebuild if not already present
            if cmd.contains("xcodebuild") && !cmd.contains("-quiet") {
                let pattern = #"(?<!\w)xcodebuild"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) {
                    let range = Range(match.range, in: cmd)!
                    NSLog("[SHELL] injecting -quiet into xcodebuild command")
                    cmd = cmd.replacingCharacters(in: range, with: "xcodebuild -quiet")
                }
            }
            return cmd
        }()

        // 0.6. Auto-create parent directories for `tee` targets. Models frequently
        // pipe build output to `tee .build/build.log` but forget to mkdir first.
        // Detect `| tee <path>` and ensure the parent directory exists.
        ensureTeeDirectories(in: command, cwd: args.cwd ?? NSHomeDirectory())

        // 1. Check if shell tool is enabled
        guard await MainActor.run(body: { ShellPolicyStore.shared.enabled }) else {
            return errorJSON(
                "The execute_command tool is disabled. Enable it in Settings → Shell."
            )
        }

        // 1.5. Data-safeguard screen: destructive commands (delete/overwrite/
        // format) are denied unless the user has an explicit always-allow
        // rule matching this command (Settings → Shell).
        if Self.isDestructiveCommand(command) {
            let explicitlyAllowed: Bool = await MainActor.run(body: {
                ShellPolicyStore.shared.isExplicitlyAllowed(command)
            })
            if !explicitlyAllowed {
                return errorJSON(
                    "Blocked by data-safeguard policy: \"\(command)\" can delete or overwrite data. "
                    + "Agents cannot run destructive commands. Ask the user to run it manually "
                    + "in Terminal, or to add an explicit always-allow rule in Settings → Shell."
                )
            }
        }

        // 2. Classify the command
        let classification: ShellClassification = await MainActor.run(body: {
            ShellPolicyStore.shared.classify(command)
        })

        // 3. Handle deny
        if classification == .denied {
            return errorJSON(
                "Command blocked by always-deny policy: \"\(command)\"."
            )
        }

        // 4. Dry-run — return classification info without executing
        if args.dryRun {
            return encodeJSON(DryRunResult(
                command: command,
                classification: classification,
                cwd: args.cwd
            ))
        }

        // 5. Handle ask — show approval banner and wait
        if classification == .ask {
            let workingDir = args.cwd ?? NSHomeDirectory()
            let approved = await requestShellApproval(command: command, cwd: workingDir)
            guard approved else {
                return errorJSON("Command denied by user: \"\(command)\".")
            }
        }

        // 6. Background process — spawn and return immediately
        if args.startBackground {
            let workingDir = args.cwd ?? NSHomeDirectory()
            return await spawnBackgroundProcess(command, cwd: workingDir)
        }

        // 7. Execute (allowed, unknown, or approved)
        return await runShellCommand(command, cwd: args.cwd, timeout: Self.normalizedTimeout(args.timeout))
    }

    /// Normalize a model-supplied timeout to seconds. Local models frequently
    /// pass MILLISECONDS (e.g. 300000 for "5 minutes") because that convention
    /// dominates their training data — the spec says seconds, but a
    /// 300,000-"second" timeout would let a hung process block the agent loop
    /// for 83 hours (observed live: an xcodebuild that deadlocked at the
    /// codesign step outlived its intended 5-minute cap). Heuristic: any value
    /// above 10,000 is treated as milliseconds (no legitimate foreground agent
    /// command runs longer than ~2.7 hours), then clamped to [1, 3600].
    /// Anything longer must go through start_background (no timeout).
    static func normalizedTimeout(_ raw: Int?) -> Int? {
        guard let raw else { return nil }
        var value = raw
        if value > 10_000 {
            let converted = max(1, value / 1000)
            NSLog("[SHELL] timeout \(raw) looks like milliseconds — interpreting as \(converted)s")
            value = converted
        }
        if value > 3600 {
            NSLog("[SHELL] timeout \(value)s clamped to 3600s (1h max for foreground commands)")
            value = 3600
        }
        return max(1, value)
    }

    // MARK: - Tee directory auto-creation

    /// Detect `| tee <path>` or `|& tee <path>` in a command and ensure the
    /// parent directory exists. Models frequently pipe build output to
    /// `tee .build/build.log` without mkdir -p first — `tee` can't create
    /// parent directories, so the pipe fails silently.
    private static func ensureTeeDirectories(in command: String, cwd: String) {
        // Match: | tee <path> or |& tee <path> (with optional redirect)
        let pattern = #"\|&?\s+tee\s+([^\s;&|]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        for match in regex.matches(in: command, options: [], range: range) {
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: command) else { continue }
            let rawPath = String(command[pathRange]).trimmingCharacters(in: .whitespaces)
            // Resolve relative paths against cwd
            let fullPath: String
            if rawPath.hasPrefix("/") {
                fullPath = rawPath
            } else {
                fullPath = (cwd as NSString).appendingPathComponent(rawPath)
            }
            let dir = (fullPath as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Destructive Command Screen

    /// Patterns that can delete or overwrite data (file deletion, filesystem
    /// formats, raw disk writes, destructive SQL, repo-destroying git).
    /// Denied by default; the user can carve explicit exceptions with
    /// always-allow rules in Settings → Shell.
    private static let destructiveCommandPatterns: [NSRegularExpression] = {
        let patterns = [
            #"(^|[;&|]\s*)rm\s"#,
            #"(^|[;&|]\s*)rmdir\b"#,
            #"(^|[;&|]\s*)unlink\b"#,
            #"(^|[;&|]\s*)shred\b"#,
            #"(^|[;&|]\s*)srm\b"#,
            #"(^|[;&|]\s*)trash\b"#,
            #"(^|[;&|]\s*)mv\b[^\n]*\s+/dev/null\b"#,
            #"\bdd\b[^\n]*\bof\s*=\s*/dev/"#,
            #"\bmkfs[.\w-]*\b"#,
            #"\bdiskutil\s+(erase|secureErase|delete|partition|raid)\b"#,
            #"\b(find|fd)\b[^\n]*\s-delete\b"#,
            #"\bxargs\b[^\n]*\brm\b"#,
            #"\bsqlite3?\b[^\n]*\b(drop\s+table|delete\s+from|truncate\s+table)\b"#,
            #"\bgit\s+clean\s+-"#,
            #"\bgit\s+reset\s+--hard\b"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func isDestructiveCommand(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return destructiveCommandPatterns.contains {
            $0.firstMatch(in: command, options: [], range: range) != nil
        }
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

                // Inherit the user's shell environment.  macOS apps launched from
                // Finder/Launcher don't get the terminal's PATH, so commands like
                // `find`, `grep`, `xcodebuild` fail with "command not found".
                // The login shell (-l) should source ~/.zshrc, but we also pass
                // the current process environment to cover edge cases.
                var env = ProcessInfo.processInfo.environment
                // Ensure HOME is set (some launch contexts strip it).
                if env["HOME"] == nil {
                    env["HOME"] = NSHomeDirectory()
                }
                // Ensure PATH includes common tool locations.
                let extraPaths = [
                    "/usr/local/bin",
                    "/opt/homebrew/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                ]
                let currentPath = env["PATH"] ?? ""
                for p in extraPaths where !currentPath.contains(p) {
                    env["PATH"] = (env["PATH"] ?? "") + ":" + p
                }
                process.environment = env

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

        // Write a wrapper script that exec's the actual command. This avoids
        // the subshell PID problem: when `nohup cmd > log 2> err &` runs a
        // command with pipes, the shell creates a subshell for the pipe and
        // $! gives the subshell's PID (which exits immediately), not the
        // actual command's PID. Using `exec` replaces the shell process with
        // the command, so the tracked PID IS the command's PID.
        let scriptPath = "\(logsDir)/swiftmaestro-bg-\(processID).sh"
        let scriptContent = "#!/bin/zsh\nexec \(effectiveCommand)"
        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptPath
            )
        } catch {
            return errorJSON("Failed to write background wrapper script: \(error.localizedDescription)")
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // nohup + disown ensures the process survives the launcher shell's exit.
        // The wrapper script uses exec so the tracked PID is the actual command,
        // not a short-lived subshell.
        process.arguments = ["-lic", "nohup \"\(scriptPath)\" > \"\(logPath)\" 2> \"\(errPath)\" &\necho $!"]
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

        // Read the PID from stdout. The output may contain shell initialization
        // noise (e.g. zsh prompt setup), so extract just the numeric PID.
        let pidData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let rawPid = String(data: pidData, encoding: .utf8) ?? ""
        // Extract the last line that looks like a pure number (the PID from echo $!).
        // NOTE: allSatisfy on an empty string returns true (vacuous truth), so we
        // must also check !trimmed.isEmpty to avoid matching trailing empty lines.
        let pid = rawPid.components(separatedBy: .newlines)
            .last(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber)
            })
            ?? rawPid.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[BG-SPAWN] Raw PID output: '\(rawPid.trimmingCharacters(in: .whitespacesAndNewlines))' → parsed: '\(pid)'")
        if pid.isEmpty {
            NSLog("[BG-SPAWN] WARNING: Could not parse numeric PID from output, process will not be tracked")
        }

        // Wait a moment and check if the process is actually running
        try? await Task.sleep(nanoseconds: 500_000_000)
        let isRunning = await MainActor.run { BackgroundProcessManager.shared.isProcessRunning(pid: pid) }
        NSLog("[BG-SPAWN] Health check for PID \(pid): isRunning=\(isRunning)")

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

        // Surface the run in the Terminal panel's Agent Log (foreground
        // commands already log via runShellCommand; background spawns were
        // invisible — "I wrote and ran a file but saw nothing run").
        let entryID = await MainActor.run { ShellLogStore.shared.addEntry(command: command, cwd: effectiveCwd) }

        let message: String
        let completedQuickly: Bool
        var stdoutTail = ""
        var stderrTail = ""
        if isRunning {
            message = "Background process \(pid) started. Use list_background_processes to monitor."
            completedQuickly = false
            // Long-running (server/watcher): leave the Agent Log entry spinning
            // (completed=false), which is honest — it IS still running.
        } else {
            stderrTail = Self.fileTail(errPath, maxLines: 20, maxChars: 2048)
            stdoutTail = Self.fileTail(logPath, maxLines: 40, maxChars: 4096)
            await MainActor.run {
                // Quick exit — record output now so the Agent Log shows what ran
                // and what it produced (Python's "Hello, World!" was invisible before).
                ShellLogStore.shared.completeEntry(
                    id: entryID,
                    stdout: stdoutTail,
                    stderr: stderrTail,
                    exitCode: stderrTail.isEmpty ? 0 : 1,
                    durationMs: 500,
                    timedOut: false
                )
            }
            if !stderrTail.isEmpty {
                // Genuine failure: something wrote to stderr before dying.
                completedQuickly = false
                var msg = "Process exited immediately. Error:\n\(stderrTail)"
                if !stdoutTail.isEmpty { msg += "\nOutput:\n\(stdoutTail)" }
                message = msg
            } else {
                // Anything that exits in <0.5s with NO stderr is a completed
                // quick command (e.g. `python3 script.py`), not a failure —
                // surface its output so the model doesn't tell the user the
                // command "exited with an error" when it actually succeeded.
                // For quick one-offs the model should prefer FOREGROUND
                // execution (start_background: false), which returns the
                // output directly instead of racing the health check.
                completedQuickly = true
                message = stdoutTail.isEmpty
                    ? "Process finished quickly with no output. If you expected it to keep running (server/watcher), it has stopped — check \(logPath). For short one-off commands use start_background: false to get output directly."
                    : "Process finished quickly (normal for short commands). Output:\n\(stdoutTail)\nFor short one-off commands use start_background: false to get output directly."
            }
        }

        return encodeJSON(BackgroundProcessResult(
            success: isRunning || completedQuickly,
            process_id: pid,
            command: command,
            cwd: effectiveCwd,
            log_path: logPath,
            err_path: errPath,
            message: message,
            completed_quickly: completedQuickly,
            stdout_tail: stdoutTail,
            stderr_tail: stderrTail
        ))
    }

    /// Read the trailing lines of a log file, capped. Returns "" when the
    /// file is missing or empty (never an error marker by itself).
    private static func fileTail(_ path: String, maxLines: Int, maxChars: Int) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lines = trimmed.components(separatedBy: .newlines).suffix(maxLines)
        return String(lines.joined(separator: "\n").suffix(maxChars))
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

internal struct ShellRawResult {
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
    /// True when the process exited within the health-check window with no
    /// stderr — a completed quick command, not a failure. Its stdout is in
    /// `stdout_tail` so the model gets the output it expected.
    let completed_quickly: Bool
    let stdout_tail: String
    let stderr_tail: String
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
        NSLog("[BG-TRACK] Adding process \(id): \(command)")
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
        let beforeCount = processes.count
        for (id, _) in processes {
            if !isProcessRunning(pid: id) {
                NSLog("[BG-TRACK] Pruning dead process \(id)")
                processes.removeValue(forKey: id)
            }
        }
        if beforeCount != processes.count {
            NSLog("[BG-TRACK] Pruned \(beforeCount - processes.count) dead processes, \(processes.count) remaining")
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
        let trimmed = pid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidNum = pid_t(trimmed), pidNum > 0 else { return false }
        // kill(pid, 0) checks if process exists without sending a signal
        let result = kill(pidNum, 0)
        if result != 0 {
            NSLog("[BG-TRACK] Process \(trimmed) not running (kill result: \(result), errno: \(errno))")
        }
        return result == 0
    }
}
