import Foundation

/// Locates the FFmpeg and FFprobe binaries bundled inside the app and provides
/// a simple async wrapper for running them.
struct FFmpegService: Sendable {
    /// URL to the bundled `ffmpeg` executable, or `nil` if it was not copied
    /// into the app bundle.
    var ffmpegURL: URL? {
        Bundle.main.url(forResource: "ffmpeg", withExtension: nil)
    }

    /// URL to the bundled `ffprobe` executable, or `nil` if it was not copied
    /// into the app bundle.
    var ffprobeURL: URL? {
        Bundle.main.url(forResource: "ffprobe", withExtension: nil)
    }

    /// Runs the bundled FFmpeg with the supplied arguments.
    /// - Parameters:
    ///   - arguments: arguments passed to ffmpeg after the executable.
    ///   - input: optional data to write to the child process's stdin.
    /// - Returns: the process's stdout and stderr as `Data`.
    /// - Throws: `FFmpegError.missingBinary` if ffmpeg is not bundled, or a
    ///   `CocoaError` / `Process` error if launch fails.
    func runFFmpeg(arguments: [String], input: Data? = nil) async throws -> (stdout: Data, stderr: Data) {
        guard let url = ffmpegURL else {
            throw FFmpegError.missingBinary("ffmpeg")
        }
        return try await runProcess(url: url, arguments: arguments, input: input)
    }

    /// Runs the bundled FFprobe with the supplied arguments.
    func runFFprobe(arguments: [String], input: Data? = nil) async throws -> (stdout: Data, stderr: Data) {
        guard let url = ffprobeURL else {
            throw FFmpegError.missingBinary("ffprobe")
        }
        return try await runProcess(url: url, arguments: arguments, input: input)
    }

    private func runProcess(url: URL, arguments: [String], input: Data?) async throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let input = input, !input.isEmpty {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            Task {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let stdout = stdoutPipe.fileHandleForReading.availableData
                let stderr = stderrPipe.fileHandleForReading.availableData
                continuation.resume(returning: (stdout, stderr))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum FFmpegError: LocalizedError {
    case missingBinary(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary(let name):
            return "Bundled \(name) binary was not found in the app bundle. Run scripts/download-ffmpeg.sh to stage it."
        }
    }
}

extension FFmpegError {
    var isMissingBinary: Bool {
        if case .missingBinary = self { return true }
        return false
    }
}
