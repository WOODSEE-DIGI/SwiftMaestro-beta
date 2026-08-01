import Foundation
import Combine

/// Manages FFmpeg broadcast (publisher) sessions. Each session takes an input
/// stream/file and pushes it to an RTMP/SRT/RTMPS endpoint.
@MainActor
final class BroadcastService: ObservableObject {
    static let shared = BroadcastService()

    @Published private(set) var sessions: [BroadcastSession] = []
    @Published private(set) var snapshots: [UUID: BroadcastRuntimeSnapshot] = [:]
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
        let dir = appSupport.appendingPathComponent("SwiftMaestro/Broadcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private func loadSessions() {
        guard let data = try? Data(contentsOf: saveURL),
              let saved = try? JSONDecoder().decode([BroadcastSession].self, from: data),
              !saved.isEmpty else {
            sessions = BroadcastSession.presets
            return
        }
        sessions = saved
    }

    private func saveSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    // MARK: - Session CRUD

    func addSession(_ session: BroadcastSession) {
        sessions.append(session)
        saveSessions()
    }

    func updateSession(_ session: BroadcastSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasRunning = processes[session.id] != nil
        if wasRunning { stop(sessionID: session.id) }
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

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }
            Task { @MainActor in
                self.appendLog(sessionID: sessionID, line)
            }
        }

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
                    if session.isEnabled {
                        self.appendLog(sessionID: sessionID, "[info] Auto-reconnecting in 5s...")
                        self.tasks[sessionID]?.cancel()
                        self.tasks[sessionID] = Task {
                            try? await Task.sleep(for: .seconds(5))
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
            appendLog(sessionID: sessionID, "[info] Input: \(session.inputURL)")
            appendLog(sessionID: sessionID, "[info] Output: \(session.outputURL)")
            updateSnapshot(sessionID: sessionID, status: .live, pid: process.processIdentifier)
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
        for id in processes.keys { stop(sessionID: id) }
    }

    func clearLogs(sessionID: UUID) {
        logs[sessionID] = []
        if var snapshot = snapshots[sessionID] {
            snapshot = BroadcastRuntimeSnapshot(
                sessionID: snapshot.sessionID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: [],
                error: snapshot.error,
                duration: snapshot.duration
            )
            snapshots[sessionID] = snapshot
        }
    }

    // MARK: - Arguments

    private func buildArguments(for session: BroadcastSession) -> [String] {
        var args = ["-hide_banner", "-loglevel", "info", "-re", "-i", session.inputURL]
        // Re-encode with reasonable defaults for live streaming.
        args += [
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-tune", "zerolatency",
            "-b:v", "2500k",
            "-maxrate", "3000k",
            "-bufsize", "6000k",
            "-g", "60",
            "-c:a", "aac",
            "-b:a", "128k",
            "-ar", "44100",
            "-f", session.broadcastProtocol == .srt ? "mpegts" : "flv",
            session.outputURL
        ]
        return args
    }

    // MARK: - Log / Status

    private func appendLog(sessionID: UUID, _ line: String) {
        var list = logs[sessionID] ?? []
        list.append(line)
        if list.count > 500 { list.removeFirst(list.count - 500) }
        logs[sessionID] = list

        if var snapshot = snapshots[sessionID] {
            snapshot = BroadcastRuntimeSnapshot(
                sessionID: snapshot.sessionID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: list,
                error: snapshot.error,
                duration: snapshot.duration
            )
            snapshots[sessionID] = snapshot
        }
    }

    private func updateSnapshot(sessionID: UUID, status: BroadcastStatus, pid: Int32? = nil, error: String? = nil) {
        let existing = snapshots[sessionID]
        let duration: TimeInterval? = {
            guard let start = startTimes[sessionID] else { return nil }
            return Date().timeIntervalSince(start)
        }()
        snapshots[sessionID] = BroadcastRuntimeSnapshot(
            sessionID: sessionID,
            status: status,
            pid: pid ?? existing?.pid,
            logs: existing?.logs ?? [],
            error: error,
            duration: duration
        )
    }

    private func detectStatus(from line: String, sessionID: UUID) {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") {
            updateSnapshot(sessionID: sessionID, status: .error)
        } else if lower.contains("stream mapping") || lower.contains("press [q]") {
            updateSnapshot(sessionID: sessionID, status: .live)
        }
    }
}
