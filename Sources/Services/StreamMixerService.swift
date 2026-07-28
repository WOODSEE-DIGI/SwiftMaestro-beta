import Foundation
import Combine

/// Routes media sources to destinations via FFmpeg. Each route is a separate
/// FFmpeg process. The mixer can bridge Stream Ingest endpoints to Broadcast
/// destinations, or copy arbitrary URLs.
@MainActor
final class StreamMixerService: ObservableObject {
    static let shared = StreamMixerService()

    @Published private(set) var routes: [MixerRoute] = []
    @Published private(set) var snapshots: [UUID: MixerRouteSnapshot] = [:]
    @Published var selectedRouteID: UUID? = nil

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var processes: [UUID: Process] = [:]
    private var logs: [UUID: [String]] = [:]
    private var startTimes: [UUID: Date] = [:]
    private var ffmpegService = FFmpegService()

    private init() {
        loadRoutes()
    }

    // MARK: - Persistence

    private var saveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SwiftMaestro/StreamMixer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("routes.json")
    }

    private func loadRoutes() {
        guard let data = try? Data(contentsOf: saveURL),
              let saved = try? JSONDecoder().decode([MixerRoute].self, from: data) else {
            routes = [MixerRoute.default()]
            return
        }
        routes = saved
    }

    private func saveRoutes() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    // MARK: - Route CRUD

    func addRoute(_ route: MixerRoute) {
        routes.append(route)
        saveRoutes()
    }

    func updateRoute(_ route: MixerRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        let wasRunning = processes[route.id] != nil
        if wasRunning { stop(routeID: route.id) }
        routes[index] = route
        saveRoutes()
        if wasRunning && route.isEnabled {
            start(routeID: route.id)
        }
    }

    func removeRoute(id: UUID) {
        stop(routeID: id)
        routes.removeAll { $0.id == id }
        saveRoutes()
    }

    // MARK: - Start / Stop

    func start(routeID: UUID) {
        guard let route = routes.first(where: { $0.id == routeID }) else { return }
        stop(routeID: routeID)

        logs[routeID] = []
        startTimes[routeID] = Date()
        updateSnapshot(routeID: routeID, status: .starting)

        guard let ffmpegURL = ffmpegService.ffmpegURL else {
            appendLog(routeID: routeID, "[error] Bundled ffmpeg binary not found")
            updateSnapshot(routeID: routeID, status: .error, error: "Bundled ffmpeg not found")
            return
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = buildArguments(for: route)
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
                self.appendLog(routeID: routeID, line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }
            Task { @MainActor in
                self.appendLog(routeID: routeID, line)
                self.detectStatus(from: line, routeID: routeID)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let wasRunning = self.processes[routeID] != nil
                self.processes.removeValue(forKey: routeID)
                if wasRunning {
                    self.appendLog(routeID: routeID, "[info] FFmpeg exited")
                    let snapshot = self.snapshots[routeID]
                    if snapshot?.status != .error {
                        self.updateSnapshot(routeID: routeID, status: .stopped)
                    }
                    if route.isEnabled {
                        self.appendLog(routeID: routeID, "[info] Auto-reconnecting in 5s...")
                        self.tasks[routeID]?.cancel()
                        self.tasks[routeID] = Task {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled else { return }
                            self.start(routeID: routeID)
                        }
                    }
                }
            }
        }

        do {
            try process.run()
            processes[routeID] = process
            appendLog(routeID: routeID, "[info] Started FFmpeg: \(process.processIdentifier)")
            appendLog(routeID: routeID, "[info] Source: \(route.sourceURL)")
            appendLog(routeID: routeID, "[info] Destination: \(route.destinationURL)")
            updateSnapshot(routeID: routeID, status: .active, pid: process.processIdentifier)
        } catch {
            appendLog(routeID: routeID, "[error] Failed to start FFmpeg: \(error.localizedDescription)")
            updateSnapshot(routeID: routeID, status: .error, error: error.localizedDescription)
        }
    }

    func stop(routeID: UUID) {
        tasks[routeID]?.cancel()
        tasks.removeValue(forKey: routeID)
        guard let process = processes[routeID] else { return }
        let pid = process.processIdentifier
        processes.removeValue(forKey: routeID)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        appendLog(routeID: routeID, "[info] Stopped")
        updateSnapshot(routeID: routeID, status: .stopped)
    }

    func stopAll() {
        for id in processes.keys { stop(routeID: id) }
    }

    func clearLogs(routeID: UUID) {
        logs[routeID] = []
        if var snapshot = snapshots[routeID] {
            snapshot = MixerRouteSnapshot(
                routeID: snapshot.routeID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: [],
                error: snapshot.error,
                duration: snapshot.duration
            )
            snapshots[routeID] = snapshot
        }
    }

    // MARK: - Arguments

    private func buildArguments(for route: MixerRoute) -> [String] {
        var args = ["-hide_banner", "-loglevel", "info", "-re", "-i", route.sourceURL]
        if route.transcode {
            args += [
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-tune", "zerolatency",
                "-b:v", route.videoBitrate,
                "-maxrate", "\(route.videoBitrate)",
                "-bufsize", "\(Int((Double(route.videoBitrate.dropLast()) ?? 0) * 2))k",
                "-g", "60",
                "-c:a", "aac",
                "-b:a", route.audioBitrate,
                "-ar", "44100"
            ]
        } else {
            args += ["-c", "copy"]
        }
        args += [route.destinationURL]
        return args
    }

    // MARK: - Log / Status

    private func appendLog(routeID: UUID, _ line: String) {
        var list = logs[routeID] ?? []
        list.append(line)
        if list.count > 500 { list.removeFirst(list.count - 500) }
        logs[routeID] = list

        if var snapshot = snapshots[routeID] {
            snapshot = MixerRouteSnapshot(
                routeID: snapshot.routeID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: list,
                error: snapshot.error,
                duration: snapshot.duration
            )
            snapshots[routeID] = snapshot
        }
    }

    private func updateSnapshot(routeID: UUID, status: MixerRouteStatus, pid: Int32? = nil, error: String? = nil) {
        let existing = snapshots[routeID]
        let duration: TimeInterval? = {
            guard let start = startTimes[routeID] else { return nil }
            return Date().timeIntervalSince(start)
        }()
        snapshots[routeID] = MixerRouteSnapshot(
            routeID: routeID,
            status: status,
            pid: pid ?? existing?.pid,
            logs: existing?.logs ?? [],
            error: error,
            duration: duration
        )
    }

    private func detectStatus(from line: String, routeID: UUID) {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") {
            updateSnapshot(routeID: routeID, status: .error)
        } else if lower.contains("stream mapping") || lower.contains("press [q]") {
            updateSnapshot(routeID: routeID, status: .active)
        }
    }
}
