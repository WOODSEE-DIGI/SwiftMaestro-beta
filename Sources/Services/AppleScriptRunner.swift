import Foundation

// MARK: - Shared JXA script runner

/// Runs JXA (JavaScript for Automation) scripts via `/usr/bin/osascript`,
/// shared by every native macOS app bridge (Apple Notes, Numbers, ...).
/// Extracted out of `AppleNotesService` so new bridges don't each reimplement
/// the same `Process` plumbing.
///
/// Scripts run out-of-process and off the main actor so the UI is never
/// blocked waiting for the target app to launch or a permission dialog to be
/// dismissed.
enum AppleScriptRunner {

    /// Runs a JXA `function run(argv) { ... }` script, passing `arguments` as
    /// `argv`, and returns its trimmed stdout.
    ///
    /// - Throws: `AppleScriptError.scriptFailed` with the process's stderr
    ///   (falling back to stdout if stderr is empty) on non-zero exit.
    static nonisolated func run(_ source: String, arguments: [String] = []) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source] + arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let stderr = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = stderr.isEmpty ? output : stderr
                throw AppleScriptError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

enum AppleScriptError: LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return message
        }
    }
}
