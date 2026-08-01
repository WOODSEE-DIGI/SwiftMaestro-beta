import Foundation
import Combine

/// Renders a live StudioScene to a single video output via FFmpeg. This is the
/// Phase 3 bridge between the Scenes panel and Broadcast/Stream Mixer outputs.
@MainActor
final class SceneOutputService: ObservableObject {
    static let shared = SceneOutputService()

    @Published private(set) var activeSceneIDs: Set<UUID> = []
    @Published private(set) var snapshots: [UUID: SceneOutputSnapshot] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var processes: [UUID: Process] = [:]
    private var logs: [UUID: [String]] = [:]
    private var ffmpegService = FFmpegService()
    private var sceneService = StudioSceneService.shared

    private init() {}

    var isAnySceneLive: Bool { !activeSceneIDs.isEmpty }

    func isLive(sceneID: UUID) -> Bool { activeSceneIDs.contains(sceneID) }

    func start(sceneID: UUID) {
        guard let scene = sceneService.scenes.first(where: { $0.id == sceneID }) else { return }
        guard scene.outputTarget != .none else {
            appendLog(sceneID: sceneID, "[error] No output target selected for scene \(scene.name)")
            return
        }
        stop(sceneID: sceneID)

        activeSceneIDs.insert(sceneID)
        logs[sceneID] = []
        updateSnapshot(sceneID: sceneID, status: .starting)

        guard let ffmpegURL = ffmpegService.ffmpegURL else {
            appendLog(sceneID: sceneID, "[error] Bundled ffmpeg binary not found")
            updateSnapshot(sceneID: sceneID, status: .error, error: "Bundled ffmpeg not found")
            activeSceneIDs.remove(sceneID)
            return
        }

        let targetURL: String
        switch scene.outputTarget {
        case .broadcast(let sessionID):
            guard let session = BroadcastService.shared.sessions.first(where: { $0.id == sessionID }) else {
                appendLog(sceneID: sceneID, "[error] Broadcast session not found")
                updateSnapshot(sceneID: sceneID, status: .error, error: "Broadcast session not found")
                activeSceneIDs.remove(sceneID)
                return
            }
            targetURL = session.outputURL
        case .mixerRoute(let routeID):
            guard let route = StreamMixerService.shared.routes.first(where: { $0.id == routeID }) else {
                appendLog(sceneID: sceneID, "[error] Mixer route not found")
                updateSnapshot(sceneID: sceneID, status: .error, error: "Mixer route not found")
                activeSceneIDs.remove(sceneID)
                return
            }
            targetURL = route.destinationURL
        case .none:
            return
        }

        guard let arguments = buildArguments(for: scene, targetURL: targetURL) else {
            appendLog(sceneID: sceneID, "[error] Could not build FFmpeg command for scene")
            updateSnapshot(sceneID: sceneID, status: .error, error: "Could not build FFmpeg command")
            activeSceneIDs.remove(sceneID)
            return
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
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
                self.appendLog(sceneID: sceneID, line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }
            Task { @MainActor in
                self.appendLog(sceneID: sceneID, line)
                self.detectStatus(from: line, sceneID: sceneID)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let wasRunning = self.processes[sceneID] != nil
                self.processes.removeValue(forKey: sceneID)
                if wasRunning {
                    self.appendLog(sceneID: sceneID, "[info] FFmpeg exited")
                    let snapshot = self.snapshots[sceneID]
                    if snapshot?.status != .error {
                        self.updateSnapshot(sceneID: sceneID, status: .stopped)
                    }
                    self.activeSceneIDs.remove(sceneID)
                }
            }
        }

        do {
            try process.run()
            processes[sceneID] = process
            appendLog(sceneID: sceneID, "[info] Started FFmpeg: \(process.processIdentifier)")
            appendLog(sceneID: sceneID, "[info] Target: \(targetURL)")
            updateSnapshot(sceneID: sceneID, status: .live, pid: process.processIdentifier)
        } catch {
            appendLog(sceneID: sceneID, "[error] Failed to start FFmpeg: \(error.localizedDescription)")
            updateSnapshot(sceneID: sceneID, status: .error, error: error.localizedDescription)
            activeSceneIDs.remove(sceneID)
        }
    }

    func stop(sceneID: UUID) {
        tasks[sceneID]?.cancel()
        tasks.removeValue(forKey: sceneID)
        guard let process = processes[sceneID] else { return }
        let pid = process.processIdentifier
        processes.removeValue(forKey: sceneID)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        appendLog(sceneID: sceneID, "[info] Stopped")
        updateSnapshot(sceneID: sceneID, status: .stopped)
        activeSceneIDs.remove(sceneID)
    }

    func clearLogs(sceneID: UUID) {
        logs[sceneID] = []
        if var snapshot = snapshots[sceneID] {
            snapshot = SceneOutputSnapshot(
                sceneID: snapshot.sceneID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: [],
                error: snapshot.error
            )
            snapshots[sceneID] = snapshot
        }
    }

    // MARK: - Command builder

    private func buildArguments(for scene: StudioScene, targetURL: String) -> [String]? {
        let visibleLayers = scene.layers.filter { $0.isVisible }.sorted(by: { $0.zIndex < $1.zIndex })
        guard let baseLayer = visibleLayers.first(where: { sourceIsBaseVideo($0.source) }) else {
            return nil
        }

        var args: [String] = ["-y", "-hide_banner", "-loglevel", "info"]
        var filterChain = "[0:v]"
        var inputIndex = 0

        // Base input.
        switch baseLayer.source {
        case .camera(let sourceID):
            guard let source = TetheringService.shared.availableSources.first(where: { $0.id.rawValue == sourceID }) else {
                return nil
            }
            args += ["-f", "avfoundation", "-framerate", "30", "-video_size", "1280x720", "-i", source.name]
            inputIndex = 1
        case .color(let color):
            args += ["-f", "lavfi", "-i", "color=c=0x\(color.hex):s=\(scene.width)x\(scene.height):r=30"]
            inputIndex = 1
        case .image:
            args += ["-f", "lavfi", "-i", "color=c=black:s=\(scene.width)x\(scene.height):r=30"]
            inputIndex = 1
        case .text:
            args += ["-f", "lavfi", "-i", "color=c=black:s=\(scene.width)x\(scene.height):r=30"]
            inputIndex = 1
        default:
            args += ["-f", "lavfi", "-i", "testsrc=size=\(scene.width)x\(scene.height):rate=30"]
            inputIndex = 1
        }

        // Scale base to scene size.
        filterChain += "scale=\(scene.width):\(scene.height)[base]"
        var currentLabel = "[base]"

        // Overlays (text, image, color) applied in z-index order.
        var overlayIndex = 0
        for layer in visibleLayers where layer.id != baseLayer.id {
            switch layer.source {
            case .text(let content, let fontSize, let foregroundColor, let backgroundColor):
                let escaped = content
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ":", with: "\\:")
                    .replacingOccurrences(of: "'", with: "\\'\\''")
                let fontFile = "/System/Library/Fonts/Helvetica.ttc"
                var drawText = "drawtext=fontfile='\(fontFile)':text='\(escaped)':fontsize=\(Int(fontSize)):fontcolor=0x\(foregroundColor.hex)"
                if let bg = backgroundColor {
                    drawText += ":box=1:boxcolor=0x\(bg.hex)@\(bg.opacity)"
                }
                drawText += ":x=\(Int(layer.x)):y=\(Int(layer.y))"
                let nextLabel = "[txt\(overlayIndex)]"
                filterChain += ";\(currentLabel)\(drawText)\(nextLabel)"
                currentLabel = nextLabel
                overlayIndex += 1

            case .image(let urlString):
                guard let url = URL(string: urlString), url.isFileURL else { continue }
                let imgIndex = inputIndex
                args += ["-loop", "1", "-i", url.path]
                inputIndex += 1
                let scaled = "[\(imgIndex):v]scale=\(Int(layer.width)):\(Int(layer.height))[img\(overlayIndex)]"
                let nextLabel = "[imgOverlay\(overlayIndex)]"
                filterChain += ";\(scaled);\(currentLabel)[img\(overlayIndex)]overlay=\(Int(layer.x)):\(Int(layer.y))\(nextLabel)"
                currentLabel = nextLabel
                overlayIndex += 1

            case .color(let color):
                let nextLabel = "[colOverlay\(overlayIndex)]"
                filterChain += ";\(currentLabel)color=c=0x\(color.hex)@\(color.opacity):s=\(Int(layer.width))x\(Int(layer.height))[col\(overlayIndex)];\(currentLabel)[col\(overlayIndex)]overlay=\(Int(layer.x)):\(Int(layer.y))\(nextLabel)"
                currentLabel = nextLabel
                overlayIndex += 1

            default:
                break
            }
        }

        args += ["-filter_complex", filterChain]
        args += ["-map", "\(currentLabel.dropFirst().dropLast())"]

        // Output settings.
        args += [
            "-r", "30",
            "-pix_fmt", "yuv420p",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-tune", "zerolatency",
            "-b:v", "4000k",
            "-maxrate", "4000k",
            "-bufsize", "8000k",
            "-g", "60",
            "-f", "flv",
            targetURL
        ]

        return args
    }

    private func sourceIsBaseVideo(_ source: SceneSource) -> Bool {
        switch source {
        case .camera, .ndi, .screen, .image, .color, .text:
            return true
        }
    }

    private func appendLog(sceneID: UUID, _ line: String) {
        logs[sceneID, default: []].append(line)
        if var snapshot = snapshots[sceneID] {
            snapshot = SceneOutputSnapshot(
                sceneID: snapshot.sceneID,
                status: snapshot.status,
                pid: snapshot.pid,
                logs: logs[sceneID] ?? [],
                error: snapshot.error
            )
            snapshots[sceneID] = snapshot
        }
    }

    private func updateSnapshot(sceneID: UUID, status: SceneOutputStatus, pid: Int32? = nil, error: String? = nil) {
        snapshots[sceneID] = SceneOutputSnapshot(
            sceneID: sceneID,
            status: status,
            pid: pid,
            logs: logs[sceneID] ?? [],
            error: error
        )
    }

    private func detectStatus(from line: String, sceneID: UUID) {
        if line.contains("Error") || line.contains("error") {
            updateSnapshot(sceneID: sceneID, status: .error, error: line)
        }
    }
}

enum SceneOutputStatus: String, Sendable {
    case idle = "Idle"
    case starting = "Starting"
    case live = "Live"
    case stopped = "Stopped"
    case error = "Error"
}

struct SceneOutputSnapshot: Sendable {
    let sceneID: UUID
    let status: SceneOutputStatus
    let pid: Int32?
    let logs: [String]
    let error: String?
}

extension SceneColor {
    /// Hex string without the leading `#`.
    var hex: String {
        String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}
