import Foundation
import Combine

/// Manages FFmpeg-based ingest listeners (RTMP/SRT/RTP) using the bundled
/// `ffmpeg` binary. Each session is a separate child process; logs and status
/// are streamed back to the UI via async callbacks.
@MainActor
final class StreamIngestService: ObservableObject {
    static let shared = StreamIngestService()

    @Published private(set) var sessions: [IngestSession] = []
    @Published private(set) var snapshots: [UUID: IngestRuntimeSnapshot] = [:]
    @Published var selectedSessionID: UUID? = nil

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var processes: [UUID: Process] = [:]
    private var logs: [UUID: [String]] = [:]
    private var startTimes: [UUID: Date] = [:]
    private var ffmpegService = FFmpegService()

    private init() {
        loadSessions()
    }

    // MARK: - Persistence

    private var saveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SwiftMaestro/StreamIngest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private func loadSessions() {
        guard let data = try? Data(contentsOf: saveURL),
              let saved = try? JSONDecoder().decode([IngestSession].self, from: data) else {
            sessions = [
                IngestSession.default(streamProtocol: .rtmp),
                IngestSession.default(streamProtocol: .srt)
            ]
            return
        }
        sessions = saved
    }

    private func saveSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    // MARK: - Session CRUD

    func addSession(_ session: IngestSession) {
        sessions.append(session)
        saveSessions()
    }

    func updateSession(_ session: IngestSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasRunning = processes[session.id] != nil
        if wasRunning {
            stop(sessionID: session.id)
        }
        sessions[index] = session
        saveSessions()
        if wasRunning && session.isEnabled {
            start(sessionID: session.id)
        }
    }

    func removeSession(id: UUID) {
        stop(sessionID: id)
        sessions.removeAll { $0.id == id }
        saveSessions()
    }

    // MARK: - Start / Stop

    func start(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        stop(sessionID: sessionID)

        logs[sessionID] = []
        startTimes[sessionID] = Date()
        updateSnapshot(sessionID: sessionID, status: .starting)

        guard let ffmpegURL = ffmpegService.ffmpegURL else {
            appendLog(sessionID: sessionID, "[error] Bundled ffmpeg binary not found")
            updateSnapshot(sessionID: sessionID, status: .error, error: "Bundled ffmpeg not found")
            return
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = buildArguments(for: session)
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["FFMPEG_FORCE_COLOR"] = "0"

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }
            Task { @MainActor in
                self.appendLog(sessionID: sessionID, line)
            }
        }

        // Read stderr (FFmpeg logs here)
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }
            Task { @MainActor in
                self.appendLog(sessionID: sessionID, line)
                self.detectStatus(from: line, sessionID: sessionID)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let wasRunning = self.processes[sessionID] != nil
                self.processes.removeValue(forKey: sessionID)
                if wasRunning {
                    self.appendLog(sessionID: sessionID, "[info] FFmpeg exited")
                    let snapshot = self.snapshots[sessionID]
                    if snapshot?.status != .error {
                        self.updateSnapshot(sessionID: sessionID, status: .stopped)
                    }
                    if session.autoRestart && session.isEnabled {
                        self.appendLog(sessionID: sessionID, "[info] Auto-restarting in 2s...")
                        self.tasks[sessionID]?.cancel()
                        self.tasks[sessionID] = Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            self.start(sessionID: sessionID)
                        }
                    }
                }
            }
        }

        do {
            try process.run()
            processes[sessionID] = process
            appendLog(sessionID: sessionID, "[info] Started FFmpeg: \(process.processIdentifier)")
            appendLog(sessionID: sessionID, "[info] URL: \(session.inputURL)")
            updateSnapshot(sessionID: sessionID, status: .listening, pid: process.processIdentifier)
        } catch {
            appendLog(sessionID: sessionID, "[error] Failed to start FFmpeg: \(error.localizedDescription)")
            updateSnapshot(sessionID: sessionID, status: .error, error: error.localizedDescription)
        }
    }

    func stop(sessionID: UUID) {
        tasks[sessionID]?.cancel()
        tasks.removeValue(forKey: sessionID)
        guard let process = processes[sessionID] else { return }
        let pid = process.processIdentifier
        processes.removeValue(forKey: sessionID)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        appendLog(sessionID: sessionID, "[info] Stopped")
        updateSnapshot(sessionID: sessionID, status: .stopped)
    }

    func stopAll() {
        for id in processes.keys {
            stop(sessionID: id)
        }
    }

    func clearLogs(sessionID: UUID) {
        logs[sessionID] = []
        if var snapshot = snapshots[sessionID] {
            snapshot = IngestRuntimeSnapshot(
                sessionID: snapshot.sessionID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: [],
                error: snapshot.error,
                bytesReceived: snapshot.bytesReceived,
                duration: snapshot.duration
            )
            snapshots[sessionID] = snapshot
        }
    }

    // MARK: - Arguments

    private func buildArguments(for session: IngestSession) -> [String] {
        var args = ["-hide_banner", "-loglevel", "info", "-i", session.inputURL]
        if session.saveToFile, let dir = session.outputDirectory, !dir.isEmpty {
            let outputURL = URL(fileURLWithPath: dir)
                .appendingPathComponent("ingest_\(session.id.uuidString.prefix(8))_\(ISO8601DateFormatter().string(from: Date()))")
                .appendingPathExtension("mkv")
            args += ["-c", "copy", "-f", "matroska", outputURL.path]
        } else {
            // Discard output while keeping the listener alive.
            args += ["-c", "copy", "-f", "null", "-"]
        }
        return args
    }

    // MARK: - Log / Status

    private func appendLog(sessionID: UUID, _ line: String) {
        var list = logs[sessionID] ?? []
        list.append(line)
        if list.count > 500 { list.removeFirst(list.count - 500) }
        logs[sessionID] = list

        if var snapshot = snapshots[sessionID] {
            snapshot = IngestRuntimeSnapshot(
                sessionID: snapshot.sessionID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: list,
                error: snapshot.error,
                bytesReceived: snapshot.bytesReceived,
                duration: snapshot.duration
            )
            snapshots[sessionID] = snapshot
        }
    }

    private func updateSnapshot(sessionID: UUID, status: IngestStatus, pid: Int32? = nil, error: String? = nil) {
        let existing = snapshots[sessionID]
        let duration: TimeInterval? = {
            guard let start = startTimes[sessionID] else { return nil }
            return Date().timeIntervalSince(start)
        }()
        snapshots[sessionID] = IngestRuntimeSnapshot(
            sessionID: sessionID,
            status: status,
            pid: pid ?? existing?.pid,
            logs: existing?.logs ?? [],
            error: error,
            bytesReceived: existing?.bytesReceived,
            duration: duration
        )
    }

    private func detectStatus(from line: String, sessionID: UUID) {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") {
            updateSnapshot(sessionID: sessionID, status: .error)
        } else if lower.contains("stream #") && lower.contains("input") {
            updateSnapshot(sessionID: sessionID, status: .receiving)
        } else if lower.contains("configuration:") || lower.contains("built with") {
            // Startup banner; ignore.
            return
        }
        // TODO: parse bitrate/size/duration from FFmpeg progress lines.
    }
}
