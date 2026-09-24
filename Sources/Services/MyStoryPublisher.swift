import Foundation

/// Publishes a MyStory episode from a PocketBase record through media processing
/// to a Hugo site and deploys it.
///
/// The pipeline assumes the source video referenced by `episode.sourceAssetPath`
/// is accessible on the local machine. It:
/// 1. Copies/transcodes the source video into the website's `static/videos/` folder.
/// 2. Generates a poster image from the first frame.
/// 3. Extracts audio and transcribes it with WhisperKit.
/// 4. Writes `transcript.txt` next to the video.
/// 5. Creates a Hugo content file under `content/mystory/`.
/// 6. Commits and runs the website's deploy script.
actor MyStoryPublisher {

    enum PublishingError: LocalizedError {
        case missingLocalRepo
        case missingSourceAsset
        case missingDeployScript
        case invalidOutputURL
        case ffmpegFailure(String)
        case whisperFailure(String)
        case gitFailure(String)
        case deployFailure(String)

        var errorDescription: String? {
            switch self {
            case .missingLocalRepo: return "Website has no local repo path configured."
            case .missingSourceAsset: return "Episode has no source asset path configured."
            case .missingDeployScript: return "Website has no deploy script configured."
            case .invalidOutputURL: return "Could not construct output URL."
            case .ffmpegFailure(let msg): return "FFmpeg error: \(msg)"
            case .whisperFailure(let msg): return "Whisper error: \(msg)"
            case .gitFailure(let msg): return "Git error: \(msg)"
            case .deployFailure(let msg): return "Deploy error: \(msg)"
            }
        }
    }

    struct PublishedArtifact {
        let contentFile: URL
        let videoFile: URL
        let posterFile: URL
        let transcriptFile: URL
        let commitHash: String?
    }

    private let ffmpeg = FFmpegService()

    /// Publishes an episode to the configured website.
    func publish(
        episode: PBMyStoryEpisode,
        website: PBWebsite,
        progress: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws -> PublishedArtifact {
        guard let repoPath = website.localRepoPath, !repoPath.isEmpty else {
            throw PublishingError.missingLocalRepo
        }
        guard let sourcePath = episode.sourceAssetPath, !sourcePath.isEmpty else {
            throw PublishingError.missingSourceAsset
        }

        let repoURL = URL(fileURLWithPath: repoPath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let slug = episode.slug.isEmpty ? makeSlug(from: episode.title) : episode.slug

        progress("Preparing output directories…")
        let videoOutputURL = repoURL
            .appendingPathComponent("static", isDirectory: true)
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent("mystory", isDirectory: true)
            .appendingPathComponent("\(slug).mp4")
        let posterOutputURL = videoOutputURL.deletingPathExtension().appendingPathExtension("jpg")
        let transcriptOutputURL = videoOutputURL.deletingPathExtension().appendingPathExtension("txt")
        let contentOutputURL = repoURL
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent("mystory", isDirectory: true)
            .appendingPathComponent("\(slug).md")

        try FileManager.default.createDirectory(at: videoOutputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contentOutputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        progress("Copying video asset…")
        if sourceURL.pathExtension.lowercased() == "mp4" {
            _ = try await ffmpeg.runFFmpeg(arguments: [
                "-y", "-i", sourceURL.path,
                "-c", "copy",
                "-movflags", "+faststart",
                videoOutputURL.path
            ])
        } else {
            _ = try await ffmpeg.runFFmpeg(arguments: [
                "-y", "-i", sourceURL.path,
                "-c:v", "libx264", "-crf", "23", "-preset", "medium",
                "-c:a", "aac", "-b:a", "128k",
                "-movflags", "+faststart",
                videoOutputURL.path
            ])
        }

        progress("Generating poster…")
        _ = try await ffmpeg.runFFmpeg(arguments: [
            "-y", "-i", videoOutputURL.path,
            "-ss", "00:00:01.000", "-vframes", "1",
            "-q:v", "2",
            posterOutputURL.path
        ])

        progress("Transcribing audio…")
        let transcriptText = try await transcribeVideo(at: videoOutputURL)
        try transcriptText.write(to: transcriptOutputURL, atomically: true, encoding: .utf8)

        progress("Writing Hugo content…")
        let videoWebPath = "/videos/mystory/\(slug).mp4"
        let posterWebPath = "/videos/mystory/\(slug).jpg"
        let transcriptWebPath = "/videos/mystory/\(slug).txt"
        let markdown = makeMarkdown(episode: episode, slug: slug, videoWebPath: videoWebPath, posterWebPath: posterWebPath, transcriptWebPath: transcriptWebPath)
        try markdown.write(to: contentOutputURL, atomically: true, encoding: .utf8)

        progress("Committing changes…")
        let commitHash = try await commitChanges(in: repoURL, slug: slug)

        progress("Deploying…")
        try await deployWebsite(website: website, repoURL: repoURL)

        return PublishedArtifact(
            contentFile: contentOutputURL,
            videoFile: videoOutputURL,
            posterFile: posterOutputURL,
            transcriptFile: transcriptOutputURL,
            commitHash: commitHash
        )
    }

    // MARK: - Helpers

    private func transcribeVideo(at videoURL: URL) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("audio.wav")
        let (_, stderr) = try await ffmpeg.runFFmpeg(arguments: [
            "-y", "-i", videoURL.path,
            "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
            audioURL.path
        ])

        let output = try await WhisperKitService.shared.transcribeAudioFile(at: audioURL)
        return output
    }

    private func makeMarkdown(
        episode: PBMyStoryEpisode,
        slug: String,
        videoWebPath: String,
        posterWebPath: String,
        transcriptWebPath: String
    ) -> String {
        var frontmatter = "---\n"
        frontmatter += "title: \"\(escapeYAML(episode.title))\"\n"
        frontmatter += "slug: \"\(slug)\"\n"
        frontmatter += "date: \(episode.publishDate ?? iso8601Now())\n"
        frontmatter += "draft: \(episode.status == "draft" ? "true" : "false")\n"
        frontmatter += "layout: mystory\n"
        frontmatter += "video: \"\(videoWebPath)\"\n"
        frontmatter += "poster: \"\(posterWebPath)\"\n"
        frontmatter += "transcript: \"\(transcriptWebPath)\"\n"
        if let duration = episode.durationSeconds, duration > 0 {
            frontmatter += "duration: \(Int(duration))\n"
        }
        if let tags = episode.tags, !tags.isEmpty {
            frontmatter += "tags: [\(tags.map { "\"\(escapeYAML($0))\"" }.joined(separator: ", "))]\n"
        }
        frontmatter += "---\n\n"
        let body = episode.body ?? episode.description ?? ""
        return frontmatter + body
    }

    private func commitChanges(in repoURL: URL, slug: String) async throws -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["add", "."]
        task.currentDirectoryURL = repoURL
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw PublishingError.gitFailure("git add failed")
        }

        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        let message = "Publish MyStory episode: \(slug)"
        commit.arguments = ["commit", "-m", message]
        commit.currentDirectoryURL = repoURL
        try commit.run()
        commit.waitUntilExit()
        guard commit.terminationStatus == 0 else {
            throw PublishingError.gitFailure("git commit failed (maybe nothing to commit)")
        }

        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        log.arguments = ["rev-parse", "--short", "HEAD"]
        log.currentDirectoryURL = repoURL
        let pipe = Pipe()
        log.standardOutput = pipe
        try log.run()
        log.waitUntilExit()
        let hash = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash?.isEmpty == false ? hash : nil
    }

    private func deployWebsite(website: PBWebsite, repoURL: URL) async throws {
        guard let scriptPath = website.deployScriptPath, !scriptPath.isEmpty else {
            throw PublishingError.missingDeployScript
        }
        let scriptURL = URL(fileURLWithPath: scriptPath)
        let task = Process()
        task.executableURL = scriptURL
        task.currentDirectoryURL = repoURL
        task.arguments = []
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw PublishingError.deployFailure("\(scriptPath) exited with status \(task.terminationStatus)")
        }
    }

    private func makeSlug(from title: String) -> String {
        let lowered = title.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "- "))
        let sanitized = lowered.unicodeScalars.filter { allowed.contains($0) }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
        return String(sanitized.prefix(64))
    }

    private func escapeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
    }
}
