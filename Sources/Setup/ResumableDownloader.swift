import Foundation
import Observation

/// Downloads a payload with `curl`, resuming from any existing partial file.
/// If the connection drops, the app retries automatically from the current
/// offset — the user does not have to press anything. macOS App Nap and
/// system/display sleep are disabled while a transfer is active.
@MainActor
@Observable
final class ResumableDownloader {

    enum Phase: Equatable {
        case idle
        case downloading
        case paused
        case failed(String)
    }

    enum DownloadError: LocalizedError {
        case transferFailed(String)

        var errorDescription: String? {
            switch self {
            case .transferFailed(let detail):
                return "Download failed: \(detail)"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var bytesDownloaded: Int64 = 0
    private(set) var expectedBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var lastSample: (bytes: Int64, date: Date)?
    private var pausedByUser = false
    private var activityToken: (any NSObjectProtocol)?
    private var lastError: String?

    var isRunning: Bool { phase == .downloading }

    var estimatedSecondsRemaining: TimeInterval? {
        guard bytesPerSecond > 0, expectedBytes > 0 else { return nil }
        let remaining = Double(max(expectedBytes - bytesDownloaded, 0))
        return remaining / bytesPerSecond
    }

    /// Start or resume a download. Throws `CancellationError` when paused by
    /// the user, `DownloadError` when retries are exhausted, or returns once
    /// the destination reaches `expectedBytes`.
    func download(url: URL, to destination: URL, expected: Int64) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // A previous buggy run may have created a directory where the file should
        // be. Curl then fails with error 23 ("Failed writing received data").
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue {
            try fm.removeItem(at: destination)
        }

        expectedBytes = expected
        bytesDownloaded = Self.fileSize(destination)

        guard bytesDownloaded < expected else {
            phase = .idle
            return
        }

        phase = .downloading
        pausedByUser = false
        lastError = nil
        lastSample = (bytesDownloaded, Date())
        startPolling(destination: destination)

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Downloading SwiftMaestro"
        )

        defer {
            if let token = activityToken {
                ProcessInfo.processInfo.endActivity(token)
                activityToken = nil
            }
            pollTask?.cancel()
            pollTask = nil
            process = nil
        }

        let maxAttempts = 100
        var attempt = 0

        while bytesDownloaded < expected {
            try Task.checkCancellation()

            if pausedByUser {
                phase = .paused
                throw CancellationError()
            }

            attempt += 1
            if attempt > maxAttempts {
                let detail = lastError ?? "Too many failed attempts."
                phase = .failed(detail)
                throw DownloadError.transferFailed(detail)
            }

            let offsetBefore = bytesDownloaded
            let exitStatus = await runCurl(url: url, destination: destination)

            bytesDownloaded = Self.fileSize(destination)

            if pausedByUser {
                phase = .paused
                throw CancellationError()
            }

            if exitStatus == 0 && bytesDownloaded >= expected {
                break
            }

            // If we made progress, the resume worked and curl wrote more data.
            // Reset the attempt counter and keep going.
            if bytesDownloaded > offsetBefore {
                attempt = 0
                continue
            }

            // No progress: wait briefly and retry from the same offset.
            let delay = min(30.0, Double(attempt) * 3.0)
            var waited = 0.0
            while waited < delay {
                if pausedByUser { break }
                try? await Task.sleep(for: .seconds(1))
                waited += 1.0
            }
        }

        phase = .idle
    }

    /// Pause the active transfer. The partial file is kept for auto-resume.
    func pause() {
        pausedByUser = true
        process?.terminate()
    }

    // MARK: - Private

    /// Runs one curl process. Returns its exit status; the caller decides
    /// whether to retry.
    private func runCurl(url: URL, destination: URL) async -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "-L", "-C", "-",
            "--fail", "--silent", "--show-error",
            "--connect-timeout", "30",
            "--speed-limit", "1000",
            "--speed-time", "60",
            "-o", destination.path,
            url.absoluteString,
        ]

        let errPipe = Pipe()
        proc.standardError = errPipe

        return await withCheckedContinuation { cont in
            proc.terminationHandler = { [weak self] p in
                Task { @MainActor in
                    self?.process = nil
                    let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let detail, !detail.isEmpty {
                        self?.lastError = detail
                    }
                    cont.resume(returning: p.terminationStatus)
                }
            }

            do {
                try proc.run()
                self.process = proc
            } catch {
                cont.resume(returning: -1)
            }
        }
    }

    private func startPolling(destination: URL) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, self.phase == .downloading {
                try? await Task.sleep(for: .milliseconds(800))
                guard self.phase == .downloading else { return }
                let size = Self.fileSize(destination)
                let now = Date()
                if let last = self.lastSample {
                    let dt = now.timeIntervalSince(last.date)
                    if dt >= 1.0 {
                        let delta = Double(size - last.bytes)
                        if delta >= 0 { self.bytesPerSecond = delta / dt }
                        self.lastSample = (size, now)
                    }
                }
                self.bytesDownloaded = size
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }
}
