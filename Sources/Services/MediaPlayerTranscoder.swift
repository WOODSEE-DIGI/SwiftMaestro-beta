import AVFoundation
import Foundation

// MARK: - Media Player Transcoder
//
// FFmpeg fallback for formats macOS AVKit cannot decode (MKV, WebM, AVI,
// Ogg/Opus, DTS, WMA, …). Probes streams with ffprobe and picks the cheapest
// route:
//
//   • Audio-only anything → transcode to AAC .m4a (fast, universal).
//   • Video with MP4-compatible codecs (H.264/HEVC + AAC/MP3/AC3/E-AC-3)
//     → container REMUX (`-c copy`) into .mp4 — seconds, no quality loss.
//   • Anything else (VP9/AV1 video, DTS/TrueHD/Opus audio in a video, …)
//     → full transcode to H.264 (veryfast, CRF 23) + AAC .mp4.
//
// Output lives in a per-run temp directory; the engine deletes the active
// temp file on stop and sweeps stale files (>24 h) on every install, so
// crashed sessions never accumulate gigabytes of transcodes.

struct MediaPlayerTranscoder: Sendable {

    enum TranscodeError: LocalizedError {
        case probeFailed(String)
        case noStreams
        case ffmpegFailed(String)

        var errorDescription: String? {
            switch self {
            case .probeFailed(let detail): return "ffprobe failed: \(detail)"
            case .noStreams: return "No audio or video streams found in the file."
            case .ffmpegFailed(let detail): return "FFmpeg conversion failed: \(detail)"
            }
        }
    }

    private let ffmpeg = FFmpegService()

    /// Directory holding converted temp files for this app install.
    static var tempDirectory: URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SwiftMaestroMediaPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Probed stream codecs for one media file.
    struct StreamInfo: Sendable {
        var videoCodec: String?
        var audioCodec: String?
        var hasVideo: Bool { videoCodec != nil }
    }

    // MARK: - Public API

    /// Return a URL AVPlayer can play. Native formats pass through untouched;
    /// FFmpeg formats are remuxed or transcoded into the temp directory.
    /// Reuses an existing fresh conversion for the same source file when the
    /// source hasn't changed (same size + mtime), so replaying a track does
    /// not re-transcode.
    func playableURL(for source: URL) async throws -> URL {
        guard MediaPlayerFormat.needsFFmpeg(source) else { return source }

        sweepStaleTempFiles()

        let info = try await probe(source)

        // Reuse an existing conversion of this exact source content.
        if let cached = existingConversion(for: source) {
            return cached
        }

        if !info.hasVideo {
            // Audio-only: straight to AAC .m4a.
            return try await convert(
                source: source,
                extension: "m4a",
                arguments: ["-vn", "-sn", "-dn", "-c:a", "aac", "-b:a", "256k"]
            )
        }

        let remuxableVideo: Set<String> = ["h264", "hevc"]
        let remuxableAudio: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac"]
        let vOK = info.videoCodec.map { remuxableVideo.contains($0) } ?? false
        let aOK = info.audioCodec.map { remuxableAudio.contains($0) } ?? true // no audio stream is fine

        if vOK && aOK {
            do {
                // HEVC in MP4 must carry the hvc1 tag (parameter sets in the
                // sample description) — ffmpeg writes hev1 by default, which
                // AVPlayer cannot decode (plays audio-only with the QuickTime
                // placeholder). h264 must NOT be re-tagged (it wants avc1).
                var args = ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
                            "-sn", "-dn", "-avoid_negative_ts", "make_zero",
                            "-movflags", "+faststart"]
                if info.videoCodec == "hevc" {
                    args.append(contentsOf: ["-tag:v", "hvc1"])
                }
                return try await convert(source: source, extension: "mp4",
                                         arguments: args, expectVideo: true)
            } catch {
                // Remux rejected (e.g. weird timebase) — fall through to a
                // full transcode rather than failing the file outright.
            }
        }

        return try await convert(
            source: source,
            extension: "mp4",
            arguments: [
                "-map", "0:v:0", "-map", "0:a:0?",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
                "-sn", "-dn",
                "-max_muxing_queue_size", "4096",
                "-movflags", "+faststart",
            ],
            expectVideo: true
        )
    }

    /// Delete a converted temp file, if the URL is one of ours.
    func removeConvertedFile(_ url: URL?) {
        guard let url,
              url.path.hasPrefix(Self.tempDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Probing

    private func probe(_ url: URL) async throws -> StreamInfo {
        var info = StreamInfo()

        // FFmpegService.runProcess resumes with whatever the process printed
        // regardless of exit status — so stream presence is judged by output.
        let video = try? await ffmpeg.runFFprobe(arguments: [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
            "-of", "csv=p=0",
            url.path,
        ])
        if let video {
            let codec = String(decoding: video.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !codec.isEmpty { info.videoCodec = codec.lowercased() }
        }

        let audio = try? await ffmpeg.runFFprobe(arguments: [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=codec_name",
            "-of", "csv=p=0",
            url.path,
        ])
        if let audio {
            let codec = String(decoding: audio.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !codec.isEmpty { info.audioCodec = codec.lowercased() }
        }

        if info.videoCodec == nil && info.audioCodec == nil {
            throw TranscodeError.noStreams
        }
        return info
    }

    // MARK: - Conversion

    private func convert(source: URL, extension ext: String, arguments: [String], expectVideo: Bool = false) async throws -> URL {
        let destination = destinationURL(for: source, extension: ext)
        try? FileManager.default.removeItem(at: destination)

        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
        args.append(contentsOf: arguments)
        args.append(destination.path)

        let result = try await ffmpeg.runFFmpeg(arguments: args)

        // Success = the destination exists and is non-empty (the service
        // wrapper does not surface exit codes).
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw TranscodeError.ffmpegFailed(stderrString(result).suffix(400).description)
        }

        // …and the output must actually contain what the source promised:
        // a non-zero duration, and a video stream when the source had one.
        // (ffmpeg can "succeed" with a half-muxed file when a subtitle or
        // data stream errors mid-conversion; without this check AVPlayer
        // gets a broken file and shows the QuickTime placeholder.)
        let probeResult = try? await ffmpeg.runFFprobe(arguments: [
            "-v", "error",
            "-show_entries", "format=duration",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            destination.path,
        ])
        let probeOut = probeResult.map { String(decoding: $0.stdout, as: UTF8.self) } ?? ""
        let hasVideoOut = probeOut.contains("video")
        let hasDuration = probeOut.contains("duration=")
            && !probeOut.contains("duration=0.000000")
            && !probeOut.contains("duration=N/A")
        guard hasDuration, (!expectVideo || hasVideoOut) else {
            try? FileManager.default.removeItem(at: destination)
            throw TranscodeError.ffmpegFailed("conversion output failed validation (missing \(!hasDuration ? "duration" : "video stream"))")
        }
        return destination
    }

    /// Deterministic temp name from source path + content stamp, so the same
    /// unchanged file maps to the same conversion across plays. The converter
    /// version invalidates conversions made by older, buggier argument sets
    /// (v1 = pre-hvc1/pre-validation remuxes that could be unplayable).
    private static let converterVersion = "v2"

    private func destinationURL(for source: URL, extension ext: String) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(Self.converterVersion)#\(source.path)#\(size)#\(Int(mtime))"
        let name = String(key.unicodeScalars.map { $0.value }.reduce(into: UInt32(5381)) { $0 = $0 &* 33 &+ $1 }, radix: 16)
        return Self.tempDirectory.appendingPathComponent("conv-\(name).\(ext)")
    }

    private func existingConversion(for source: URL) -> URL? {
        for ext in ["m4a", "mp4"] {
            let candidate = destinationURL(for: source, extension: ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Delete converted temp files older than 24 hours.
    private func sweepStaleTempFiles() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.tempDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("conv-") {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - FFmpegService result conveniences

private func stderrString(_ result: (stdout: Data, stderr: Data)) -> String {
    String(decoding: result.stderr, as: UTF8.self)
}
