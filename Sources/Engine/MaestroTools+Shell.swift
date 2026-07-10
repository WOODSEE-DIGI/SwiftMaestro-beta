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

    static let shellToolNames: Set<String> = ["execute_command"]

    static var shellToolSpecs: [ToolSpec] {
        [
            rawSpec("execute_command",
                "Execute a shell command via zsh. Runs a subprocess, captures stdout/stderr, "
                + "and returns the output. Use `dry_run` to preview the classified command "
                + "without executing. The command will be rejected if it matches an always-deny "
                + "rule or if the tool is disabled in settings.",
                properties: [
                    "command": ["type": "string", "description": "The shell command to execute (e.g. 'ls -la /tmp')."],
                    "cwd": ["type": "string", "description": "Optional working directory. Defaults to the agent workspace."],
                    "timeout": ["type": "integer", "description": "Timeout in seconds (default: 60)."],
                    "dry_run": ["type": "boolean", "description": "If true, classify the command against policy and return the classification without executing."]
                ],
                required: ["command"]),
        ]
    }

    private struct ShellArgs: Decodable {
        let command: String?
        let cwd: String?
        let timeout: Int?
        let dry_run: Bool?

        var dryRun: Bool { dry_run ?? false }
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

        // 6. Execute (allowed, unknown, or approved)
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

    // MARK: - Encoding Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
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
