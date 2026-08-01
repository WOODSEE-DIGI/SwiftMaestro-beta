import Foundation

// MARK: - Shared JXA script runner

/// Runs JXA (JavaScript for Automation) scripts via `/usr/bin/osascript`,
/// shared by every native macOS app bridge (Apple Notes, Numbers, Mail, ...).
/// Extracted out of `AppleNotesService` so new bridges don't each reimplement
/// the same `Process` plumbing.
///
/// Scripts run out-of-process and off the main actor so the UI is never
/// blocked waiting for the target app to launch or a permission dialog to be
/// dismissed.
///
/// Robustness guarantees (added after the Mail bridge work):
///   - Pipes are drained *while* the script runs, so a >64 KB stdout (a long
///     email body, a big JSON payload) can't fill the pipe buffer and wedge
///     the script mid-write (classic pipe deadlock).
///   - A hard timeout terminates a hung script — the target app wedging its
///     Apple Event queue (e.g. Mail showing a hidden password sheet) must
///     surface as an error, not an infinite spinner.
enum AppleScriptRunner {

    /// Default per-script timeout. Apple Events have their own ~2 minute
    /// timeout; we bail far earlier so the UI stays responsive.
    static let defaultTimeout: TimeInterval = 25

    /// Runs a JXA `function run(argv) { ... }` script, passing `arguments` as
    /// `argv`, and returns its trimmed stdout.
    ///
    /// - Throws: `AppleScriptError.scriptFailed` with the process's stderr
    ///   (falling back to stdout if stderr is empty) on non-zero exit, or
    ///   `AppleScriptError.timeout` if the script exceeds `timeout` seconds.
    static nonisolated func run(
        _ source: String,
        arguments: [String] = [],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source] + arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Drain pipes concurrently with the running process. Reading only
            // after exit deadlocks once output exceeds the pipe buffer (~64 KB).
            let outputAccumulator = DataAccumulator()
            let errorAccumulator = DataAccumulator()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                outputAccumulator.append(handle.availableData)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                errorAccumulator.append(handle.availableData)
            }

            try process.run()

            // Wait for termination or timeout, whichever comes first.
            let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let gate = ResumeGate()
                process.terminationHandler = { _ in
                    gate.resume(continuation, with: .success(false))
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                        gate.resume(continuation, with: .success(true))
                    }
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            // Capture anything written between termination and handler removal.
            outputAccumulator.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            errorAccumulator.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

            if timedOut {
                throw AppleScriptError.timeout(Int(timeout))
            }

            let output = String(data: outputAccumulator.data, encoding: .utf8) ?? ""
            let stderr = String(data: errorAccumulator.data, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = stderr.isEmpty ? output : stderr
                throw AppleScriptError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

/// Thread-safe accumulation for pipe-drain handlers firing on arbitrary queues.
private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }
}

/// Guarantees a CheckedContinuation resumes exactly once (termination and the
/// timeout task race).
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, with result: Result<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
    }
}

enum AppleScriptError: LocalizedError {
    case scriptFailed(String)
    case timeout(Int)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return message
        case .timeout(let seconds):
            return "The script did not finish within \(seconds)s — the target app may be showing a dialog or is otherwise not responding to automation."
        }
    }
}
