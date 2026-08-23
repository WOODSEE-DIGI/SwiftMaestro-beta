import AVFoundation
import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Media Player tools
//
// Agent control over the Media Player panel so the user can say "play the
// keynote recording from yesterday" and the agent drives the shared
// MediaPlayerEngine + MediaPlayerQueue. Follows the registerPomodoroTools
// pattern; engine and queue are @MainActor so handlers hop over.
//
// Path arguments go through the same authorized-folders enforcement as the
// file tools (resolveAbsolute + isAllowed against authorizedRoots).

extension MaestroTools {

    static func registerMediaPlayerTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "play_media", spec: mediaPlayerToolSpecs[0],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { call in await playMedia(call) }),
            ToolDefinition(
                name: "pause_media", spec: mediaPlayerToolSpecs[1],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { _ in await pauseMedia() }),
            ToolDefinition(
                name: "resume_media", spec: mediaPlayerToolSpecs[2],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { _ in await resumeMedia() }),
            ToolDefinition(
                name: "seek_media", spec: mediaPlayerToolSpecs[3],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { call in await seekMedia(call) }),
            ToolDefinition(
                name: "set_volume", spec: mediaPlayerToolSpecs[4],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { call in await setVolume(call) }),
            ToolDefinition(
                name: "list_media_queue", spec: mediaPlayerToolSpecs[5],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { _ in await listMediaQueue() }),
            ToolDefinition(
                name: "add_to_queue", spec: mediaPlayerToolSpecs[6],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { call in await addToQueue(call) }),
            ToolDefinition(
                name: "media_diagnose", spec: mediaPlayerToolSpecs[7],
                category: ToolCategory.mediaPlayer.rawValue,
                handler: { call in await mediaDiagnose(call) }),
        ])
    }

    static var mediaPlayerToolSpecs: [ToolSpec] {
        [
            rawSpec("play_media",
                "Play a media file in the Media Player panel. With 'path', loads "
                + "that file and starts playback (non-native formats like MKV/WebM "
                + "are converted via the bundled FFmpeg automatically). Without "
                + "'path', resumes whatever is loaded. The path must be inside an "
                + "authorized folder.",
                properties: [
                    "path": ["type": "string", "description": "Optional absolute or working-directory-relative path to an audio/video file."],
                ],
                required: []),
            rawSpec("pause_media",
                "Pause Media Player playback.",
                properties: [:],
                required: []),
            rawSpec("resume_media",
                "Resume Media Player playback after a pause.",
                properties: [:],
                required: []),
            rawSpec("seek_media",
                "Seek in the Media Player. 'seconds' is an absolute position; "
                + "'relative_seconds' jumps forward/back from the current position "
                + "(e.g. -15 or 30). Exactly one must be given.",
                properties: [
                    "seconds": ["type": "number", "description": "Absolute position in seconds from the start."],
                    "relative_seconds": ["type": "number", "description": "Relative jump in seconds (negative = back)."],
                ],
                required: []),
            rawSpec("set_volume",
                "Set Media Player volume, 0.0 (mute) to 1.0 (full).",
                properties: [
                    "level": ["type": "number", "description": "Volume level 0.0–1.0."],
                ],
                required: ["level"]),
            rawSpec("list_media_queue",
                "Show the Media Player queue: entries with index, title/artist when "
                + "known, duration, which entry is current, plus shuffle/repeat state "
                + "and now-playing status.",
                properties: [:],
                required: []),
            rawSpec("add_to_queue",
                "Append a media file to the Media Player queue without interrupting "
                + "current playback. The path must be inside an authorized folder.",
                properties: [
                    "path": ["type": "string", "description": "Absolute or working-directory-relative path to an audio/video file."],
                    "play_next": ["type": "boolean", "description": "Insert directly after the current entry instead of appending."],
                ],
                required: ["path"]),
            rawSpec("media_diagnose",
                "Diagnose why a media file won't play in the Media Player. Returns: "
                + "the file's streams/codecs (ffprobe), whether it plays natively or "
                + "needs FFmpeg conversion (and which route: remux vs transcode), "
                + "whether a cached conversion exists and is valid, and an actual "
                + "AVFoundation load test result. Use this FIRST when a user reports "
                + "playback problems, before guessing. The path must be inside an "
                + "authorized folder.",
                properties: [
                    "path": ["type": "string", "description": "Absolute or working-directory-relative path to the media file."],
                ],
                required: ["path"]),
        ]
    }

    // MARK: - Handlers

    private struct PlayArgs: Codable { let path: String? }
    private struct SeekArgs: Codable {
        let seconds: Double?
        let relative_seconds: Double?
    }
    private struct VolumeArgs: Codable { let level: Double? }
    private struct QueueAddArgs: Codable {
        let path: String?
        let play_next: Bool?
    }

    private static func playMedia(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: PlayArgs.self)

        guard let path = args?.path, !path.isEmpty else {
            // No path: resume whatever is loaded.
            return await MainActor.run {
                let engine = MediaPlayerEngine.shared
                guard engine.hasItem else {
                    return "Media Player: nothing is loaded. Provide a 'path' to play a file."
                }
                engine.play()
                return "Media Player: resumed '\(engine.mediaInfo.displayTitle)'."
            }
        }

        guard let url = authorizedMediaURL(path) else {
            return "Error: path is empty, does not resolve, or is outside the authorized folders (Settings → Context)."
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: no file at '\(url.path)'."
        }
        guard MediaPlayerFormat.canPlay(url) else {
            return "Error: '.\(url.pathExtension)' is not a supported media format."
        }

        return await MainActor.run {
            let engine = MediaPlayerEngine.shared
            Task { @MainActor in
                await engine.load(url: url)
                if engine.preparationError == nil {
                    engine.play()
                }
            }
            return "Media Player: loading '\(url.lastPathComponent)'"
                + (MediaPlayerFormat.needsFFmpeg(url) ? " (converting via FFmpeg first — starts in a moment)" : "")
                + "."
        }
    }

    private static func pauseMedia() async -> String {
        await MainActor.run {
            let engine = MediaPlayerEngine.shared
            engine.pause()
            return "Media Player: paused at \(formatTime(engine.currentTime))."
        }
    }

    private static func resumeMedia() async -> String {
        await MainActor.run {
            let engine = MediaPlayerEngine.shared
            guard engine.hasItem else { return "Media Player: nothing is loaded." }
            engine.play()
            return "Media Player: resumed '\(engine.mediaInfo.displayTitle)'."
        }
    }

    private static func seekMedia(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SeekArgs.self) else {
            return "Error: provide 'seconds' (absolute) or 'relative_seconds' (jump)."
        }
        return await MainActor.run {
            let engine = MediaPlayerEngine.shared
            guard engine.hasItem else { return "Media Player: nothing is loaded." }
            if let relative = args.relative_seconds {
                engine.seekRelative(relative)
                return "Media Player: jumped \(relative >= 0 ? "+" : "")\(Int(relative))s → \(formatTime(engine.currentTime))."
            }
            guard let seconds = args.seconds else {
                return "Error: provide 'seconds' (absolute) or 'relative_seconds' (jump)."
            }
            engine.seek(to: max(0, seconds))
            return "Media Player: seeking to \(formatTime(max(0, seconds)))."
        }
    }

    private static func setVolume(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: VolumeArgs.self), let level = args.level else {
            return "Error: level (0.0–1.0) is required."
        }
        let clamped = min(1, max(0, level))
        return await MainActor.run {
            MediaPlayerEngine.shared.volume = clamped
            return "Media Player: volume set to \(Int(clamped * 100))%."
        }
    }

    private static func listMediaQueue() async -> String {
        await MainActor.run {
            let queue = MediaPlayerQueue.shared
            let engine = MediaPlayerEngine.shared

            var lines: [String] = []
            if engine.hasItem {
                let state = engine.isPlaying ? "playing" : "paused"
                lines.append("Now \(state): \(engine.mediaInfo.displayTitle) — \(engine.mediaInfo.displayArtist) [\(formatTime(engine.currentTime))/\(formatTime(engine.duration ?? 0))] vol \(Int(engine.volume * 100))%")
            } else {
                lines.append("Nothing loaded.")
            }
            lines.append("Queue (\(queue.entries.count) entr\(queue.entries.count == 1 ? "y" : "ies"), shuffle \(queue.shuffleEnabled ? "on" : "off"), repeat \(queue.repeatMode.rawValue)):")
            for (index, entry) in queue.entries.enumerated() {
                let marker = index == queue.currentIndex ? "▶" : " "
                let title = entry.title.isEmpty
                    ? entry.url.deletingPathExtension().lastPathComponent
                    : entry.title
                let artist = entry.artist.map { " — \($0)" } ?? ""
                let duration = entry.duration.map { " [\(formatTime($0))]" } ?? ""
                lines.append("\(marker) \(index + 1). \(title)\(artist)\(duration)")
            }
            if queue.entries.isEmpty {
                lines.append("  (empty — use add_to_queue or play_media)")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func addToQueue(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: QueueAddArgs.self),
              let path = args.path, !path.isEmpty else {
            return "Error: path is required."
        }
        guard let url = authorizedMediaURL(path) else {
            return "Error: path is empty, does not resolve, or is outside the authorized folders (Settings → Context)."
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: no file at '\(url.path)'."
        }
        guard MediaPlayerFormat.canPlay(url) else {
            return "Error: '.\(url.pathExtension)' is not a supported media format."
        }

        return await MainActor.run {
            let queue = MediaPlayerQueue.shared
            if args.play_next == true {
                queue.insertNext(url: url)
                return "Media Player: queued '\(url.lastPathComponent)' to play next."
            }
            queue.append(url: url)
            return "Media Player: queued '\(url.lastPathComponent)' (position \(queue.entries.count))."
        }
    }

    // MARK: - Diagnostics

    private struct DiagnoseArgs: Codable { let path: String? }

    private static func mediaDiagnose(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DiagnoseArgs.self),
              let path = args.path, !path.isEmpty else {
            return "Error: path is required."
        }
        guard let url = authorizedMediaURL(path) else {
            return "Error: path is empty, does not resolve, or is outside the authorized folders (Settings → Context)."
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: no file at '\(url.path)'."
        }

        var report: [String] = ["Media diagnosis: \(url.lastPathComponent)"]

        // 1. Codec/container probe.
        let ffmpeg = FFmpegService()
        var probedVideo: String?
        var probedAudio: String?
        if let result = try? await ffmpeg.runFFprobe(arguments: [
            "-v", "error",
            "-show_entries", "stream=codec_type,codec_name,codec_tag_string:format=format_name,duration",
            "-of", "csv=p=0", url.path,
        ]) {
            let lines = String(decoding: result.stdout, as: UTF8.self)
                .split(separator: "\n").map(String.init)
            for line in lines {
                let parts = line.split(separator: ",").map(String.init)
                if parts.first == "video" { probedVideo = parts.dropFirst().first.map { String($0) } }
                if parts.first == "audio" && probedAudio == nil { probedAudio = parts.dropFirst().first.map { String($0) } }
            }
            let container = lines.last?.split(separator: ",").first.map(String.init) ?? "unknown"
            report.append("Probe: container=\(container), video=\(probedVideo ?? "none"), audio=\(probedAudio ?? "none")")
        } else {
            report.append("Probe: ffprobe FAILED to read the file (corrupt or unreadable).")
        }

        // 2. Playback route decision.
        if MediaPlayerFormat.needsFFmpeg(url) {
            let remuxableVideo: Set<String> = ["h264", "hevc"]
            let remuxableAudio: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac"]
            let route = (probedVideo.map { remuxableVideo.contains($0) } ?? false)
                && (probedAudio.map { remuxableAudio.contains($0) } ?? true)
                ? "FFmpeg remux (fast, lossless, hvc1-tagged)" : "FFmpeg full transcode (H.264/AAC — slow)"
            report.append("Route: not native to AVKit → \(route)")
        } else {
            report.append("Route: native AVKit playback (no conversion)")
        }

        // 3. Conversion cache state.
        let tempDir = MediaPlayerTranscoder.tempDirectory.path
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: tempDir))?
            .filter { $0.hasPrefix("conv-") } ?? []
        report.append("Conversion cache: \(cached.isEmpty ? "empty" : cached.joined(separator: ", "))")

        // 4. The decisive test: can AVFoundation actually load it?
        let asset = AVURLAsset(url: url)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            report.append("AVFoundation load: OK — \(videoTracks.count) video, \(audioTracks.count) audio track(s), \(Int(duration.seconds))s")
        } catch {
            report.append("AVFoundation load: FAILED — \(error.localizedDescription)")
            report.append("Recommendation: if this file is native-listed but fails here, convert it via FFmpeg (play_media will do this automatically once re-routed).")
        }

        let engineError = await MainActor.run { MediaPlayerEngine.shared.preparationError }
        report.append("Engine state: \(engineError ?? "no active error")")
        return report.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Resolve and authorize a media path the same way the file tools do.
    private static func authorizedMediaURL(_ path: String) -> URL? {
        guard let resolved = resolveAbsolute(path),
              isAllowed(resolved, roots: authorizedRoots()) else {
            return nil
        }
        return URL(fileURLWithPath: resolved)
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
