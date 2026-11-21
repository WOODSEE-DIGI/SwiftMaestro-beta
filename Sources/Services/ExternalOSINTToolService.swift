import Foundation

// MARK: - External OSINT Tool Service

/// Executes local OSINT CLI tools on behalf of the SwiftMaestro OSINT agent,
/// parses their output, and optionally records findings into the per-agent
/// OSINT profile store.
///
/// The service is intentionally thin: each tool's intelligence lives in its
/// native implementation. SwiftMaestro provides the invocation bridge,
/// timeout handling, output sanitisation, and structured-memory integration.
actor ExternalOSINTToolService {

    static let shared = ExternalOSINTToolService()

    /// Result of running an external OSINT command.
    struct RunResult: Sendable {
        let success: Bool
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let command: String
        let cwd: String
        let durationMs: Int
        let timedOut: Bool
    }

    /// Thrown when a tool cannot be run because it is missing or not executable.
    struct ToolUnavailableError: LocalizedError, Sendable {
        let tool: ExternalOSINTTool
        let path: String

        var errorDescription: String? {
            "\(tool.displayName) is not available at \(path). Configure it in Settings → OSINT Tools."
        }
    }

    /// Thrown when a command exceeds its allowed runtime.
    struct TimeoutError: LocalizedError, Sendable {
        let command: String
        let timeout: TimeInterval

        var errorDescription: String? {
            "Command timed out after \(Int(timeout))s: \(command)"
        }
    }

    private let config = ExternalOSINTToolConfig.load()

    // MARK: - Public API

    /// Runs a tool with a pre-built shell command string.
    ///
    /// - Parameters:
    ///   - tool: The OSINT tool being run (used for config lookup and error messages).
    ///   - command: The complete shell command to execute.
    ///   - cwd: Working directory for the process. Defaults to the user's home.
    ///   - timeout: Maximum runtime in seconds. Defaults to the config default.
    /// - Returns: A structured run result.
    func run(
        tool: ExternalOSINTTool,
        command: String,
        cwd: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> RunResult {
        guard config.isEnabled(tool) else {
            throw ToolUnavailableError(tool: tool, path: "(disabled in Settings)")
        }

        let effectiveTimeout = timeout ?? TimeInterval(config.defaultTimeoutSeconds)
        let workingDir = (cwd ?? NSHomeDirectory()).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: workingDir) else {
            throw ToolUnavailableError(tool: tool, path: "working directory does not exist: \(workingDir)")
        }

        return try await execute(command: command, cwd: workingDir, timeout: effectiveTimeout)
    }

    /// Runs a tool using its configured executable path and the supplied arguments.
    ///
    /// The executable path is resolved from `ExternalOSINTToolConfig`. Python
    /// scripts are invoked via `python` automatically when the path ends in `.py`.
    func run(
        tool: ExternalOSINTTool,
        arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> RunResult {
        let executable = config.resolvedPath(for: tool).expandingTildeInPath
        let command = Self.commandString(executable: executable, arguments: arguments, cwd: cwd)
        return try await run(tool: tool, command: command, cwd: cwd, timeout: timeout)
    }

    /// Records one or more findings to the OSINT profile store for the given agent.
    func record(findings: [OSINTProfileFinding], forAgent agentId: UUID) async {
        await MainActor.run {
            guard let store = MaestroTools.osintProfileStore else { return }
            for finding in findings {
                store.addFinding(finding, for: agentId)
            }
        }
    }

    /// Convenience: record a single finding.
    func record(finding: OSINTProfileFinding, forAgent agentId: UUID) async {
        await record(findings: [finding], forAgent: agentId)
    }

    // MARK: - Helpers

    /// Builds a shell command from an executable path and arguments.
    ///
    /// - If the executable ends in `.py`, it is prefixed with the best available
    ///   Python interpreter: a `.venv/bin/python` in the working directory is
    ///   preferred, otherwise `python` from PATH. This lets each OSINT tool live
    ///   in its own uv/pip venv without polluting system Python.
    /// - Arguments are single-quoted and any embedded single quotes are escaped.
    static func commandString(executable: String, arguments: [String], cwd: String? = nil) -> String {
        let prefix: String
        if executable.hasSuffix(".py") {
            let python = resolvedPythonExecutable(cwd: cwd)
            prefix = "\(python) \(escapeShellArgument(executable))"
        } else {
            prefix = escapeShellArgument(executable)
        }
        let args = arguments.map(escapeShellArgument).joined(separator: " ")
        return args.isEmpty ? prefix : "\(prefix) \(args)"
    }

    /// Returns the Python interpreter to use for `.py` scripts.
    /// Prefers `.venv/bin/python` in the given working directory, then falls
    /// back to `python3` and finally `python`. macOS systems typically ship
    /// only `python3`, so the python3 check prevents "command not found".
    private static func resolvedPythonExecutable(cwd: String?) -> String {
        let fm = FileManager.default
        if let cwd = cwd {
            let venvPython = (cwd as NSString).appendingPathComponent(".venv/bin/python")
            if fm.fileExists(atPath: venvPython) {
                return venvPython
            }
        }
        if fm.fileExists(atPath: "/usr/bin/python3") {
            return "/usr/bin/python3"
        }
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        if shellExists("python3") { return "python3" }
        return "python"
    }

    /// Lightweight check that a command exists in the shell PATH.
    private static func shellExists(_ command: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v \(command)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Escapes a string for safe use inside a single-quoted shell argument.
    static func escapeShellArgument(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Process execution

    /// Low-level shell execution via `/bin/zsh -lic <command>`.
    /// Mirrors the existing shell tool implementation but runs inside the
    /// service so it can be reused by OSINT tool wrappers without going through
    /// the public `shell_execute` tool.
    private func execute(
        command: String,
        cwd: String,
        timeout: TimeInterval
    ) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startTime = Date()
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lic", command]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)

                var env = ProcessInfo.processInfo.environment
                if env["HOME"] == nil {
                    env["HOME"] = NSHomeDirectory()
                }
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

                process.terminationHandler = { proc in
                    let elapsed = Date().timeIntervalSince(startTime)
                    let timedOut = elapsed >= timeout && proc.terminationStatus != 0

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    var stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    var stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    if timedOut {
                        let timeoutNote = "[timed out after \(Int(timeout))s — partial results only]"
                        if !stderr.isEmpty { stderr += "\n" }
                        stderr += timeoutNote
                    }

                    continuation.resume(returning: RunResult(
                        success: proc.terminationStatus == 0,
                        exitCode: Int32(proc.terminationStatus),
                        stdout: String(stdout.prefix(50_000)),
                        stderr: String(stderr.prefix(50_000)),
                        command: command,
                        cwd: cwd,
                        durationMs: Int(elapsed * 1000),
                        timedOut: timedOut
                    ))
                }

                do {
                    try process.run()
                } catch {
                    let elapsed = Date().timeIntervalSince(startTime)
                    continuation.resume(returning: RunResult(
                        success: false,
                        exitCode: -1,
                        stdout: "",
                        stderr: "Failed to launch process: \(error.localizedDescription)",
                        command: command,
                        cwd: cwd,
                        durationMs: Int(elapsed * 1000),
                        timedOut: false
                    ))
                    return
                }

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
}

// MARK: - String helpers

extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
