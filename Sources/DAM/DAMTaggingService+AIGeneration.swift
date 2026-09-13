import AppKit
import AVFoundation
import Foundation
import OSLog

private let taggingLogger = Logger(subsystem: "com.woodseedigi.swiftmaestro", category: "DAMTagging")


import NaturalLanguage
import SwiftMaestroKit
import Vision

// MARK: - DAMTaggingService: generative AI tagging
//
// Targeted tag generation for individual assets, folders, and collections
// using the shared vision-language proxy. Unlike the learn-as-you-tag
// propagation path, this asks a VLM to describe the image and then applies
// the resulting keywords directly (source `ai`).

extension DAMTaggingService {

    struct GenerateProgress: Sendable {
        var current: Int
        var total: Int
        var currentFile: String
    }

    struct GenerateResult: Sendable {
        var processed: Int
        var tagged: Int
        var skipped: Int
        var failed: Int
    }

    /// When true, audio transcripts are summarized by the local LLM instead of
    /// the fast on-device NLP tag extractor. Slower but produces polished
    /// captions and better tags. Persisted in UserDefaults.
    static var useLLMForAudioCaptions: Bool {
        get { UserDefaults.standard.bool(forKey: "dam.tagging.audioUseLLM") }
        set { UserDefaults.standard.set(newValue, forKey: "dam.tagging.audioUseLLM") }
    }

    /// Master switch for visual frame tagging of videos. When off, videos are
    /// tagged from audio/filename only. Persisted in UserDefaults.
    static var useVisionForVideoTags: Bool {
        get {
            if UserDefaults.standard.object(forKey: "dam.tagging.useVisionForVideoTags") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "dam.tagging.useVisionForVideoTags")
        }
        set { UserDefaults.standard.set(newValue, forKey: "dam.tagging.useVisionForVideoTags") }
    }

    /// Default prompt tuned for photo-library keywords. The model is asked
    /// to return ONLY a comma-separated list so downstream parsing is robust.
    static let defaultTagPrompt =
        "Generate a concise comma-separated list of 5–15 descriptive keywords "
        + "for this image. Focus on visible subjects, scenes, objects, text topics, "
        + "colors, and style. Return ONLY the comma-separated list, with no extra "
        + "sentences, numbering, or explanation."

    /// Generate AI tags for a single asset and apply them (source `ai`).
    /// Returns the tags that were applied.
    @discardableResult
    func generateTags(for asset: DAMAsset, prompt: String? = nil) async throws -> [String] {
        guard let assetId = asset.id else { return [] }
        guard Self.isImageAsset(asset) else { return [] }

        return try await DAMResourceLimiter.shared.withHeavyTask(
            name: "Image AI tagging",
            timeout: .infinity
        ) {
            let imageData = try await self.imageDataForGeneration(path: asset.path)
            guard !imageData.isEmpty else {
                throw DAMTaggingError.generationFailed("Could not decode image for tagging.")
            }

            let timeout = await DAMResourceLimiter.shared.currentLimit.operationTimeoutSeconds
            let captionPrompt = prompt ?? Self.defaultTagPrompt
            let rawCaption = try await DAMResourceLimiter.shared.withTimeout(
                seconds: timeout
            ) {
                try await VisionProxyService.shared.caption(
                    imageData: imageData, prompt: captionPrompt)
            }
            guard let rawCaption else {
                throw DAMTaggingError.visionProxyDisabled
            }

            let trimmed = rawCaption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            let tags = Self.parseTagList(from: trimmed).prefix(15).map { $0 }
            guard !tags.isEmpty else { return [] }

            let database = DAMDatabase.shared
            try await database.dbQueue.write { db in
                guard var row = try DAMAsset.fetchOne(db, key: assetId) else { return }
                let oldCaption = row.aiCaption
                let oldKeywords = row.aiKeywords
                row.aiCaption = trimmed
                row.aiKeywords = tags.joined(separator: ", ")
                try row.update(db)
                if oldCaption != trimmed {
                    try database.recordAudit(
                        db, assetId: assetId, field: "aiCaption",
                        oldValue: oldCaption, newValue: trimmed,
                        source: DAMTagSource.ai.rawValue)
                }
                if oldKeywords != row.aiKeywords {
                    try database.recordAudit(
                        db, assetId: assetId, field: "aiKeywords",
                        oldValue: oldKeywords, newValue: row.aiKeywords,
                        source: DAMTagSource.ai.rawValue)
                }
            }

            for tag in tags {
                _ = try database.applyTag(name: tag, to: assetId, source: .ai)
            }

            // Make sure the newly-tagged asset is indexed so it can act as an
            // exemplar for future learn-as-you-tag propagation.
            _ = try await self.indexAsset(asset)

            return tags
        }
    }

    /// Generate tags for a list of assets. Progress is reported per item.
    @discardableResult
    func generateTags(
        for assets: [DAMAsset],
        prompt: String? = nil,
        progress: (@Sendable (GenerateProgress) -> Void)? = nil
    ) async throws -> GenerateResult {
        var result = GenerateResult(processed: 0, tagged: 0, skipped: 0, failed: 0)
        let total = assets.count
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            progress?(GenerateProgress(
                current: index + 1, total: total, currentFile: asset.filename))
            guard asset.id != nil else {
                result.processed += 1
                result.skipped += 1
                continue
            }
            do {
                let tags: [String]
                if Self.isImageAsset(asset) {
                    tags = try await generateTags(for: asset, prompt: prompt)
                } else if Self.isAudioAsset(asset) {
                    tags = try await generateAudioTags(for: asset)
                } else if Self.isVideoAsset(asset) {
                    tags = try await generateVideoTags(for: asset)
                } else {
                    result.processed += 1
                    result.skipped += 1
                    continue
                }
                result.processed += 1
                if !tags.isEmpty { result.tagged += 1 }
            } catch {
                result.processed += 1
                result.failed += 1
                // Configuration-level failures should stop the whole batch so
                // the user sees the real reason instead of a vague fail count.
                if let taggingError = error as? DAMTaggingError,
                   taggingError == .visionProxyDisabled
                    || taggingError == .visionProxyUnavailable {
                    throw error
                }
                if error is CancellationError { throw error }
            }
        }
        progress?(GenerateProgress(current: total, total: total, currentFile: ""))
        return result
    }

    /// Generate tags for every image asset in a folder (recursive by default).
    @discardableResult
    func generateTags(
        forFolder path: String,
        recursive: Bool = true,
        prompt: String? = nil,
        progress: (@Sendable (GenerateProgress) -> Void)? = nil
    ) async throws -> GenerateResult {
        let assets = (try? DAMDatabase.shared.assets(inFolder: path, recursive: recursive)) ?? []
        return try await generateTags(for: assets, prompt: prompt, progress: progress)
    }

    /// Generate tags for every image asset in a collection/album.
    @discardableResult
    func generateTags(
        forCollectionId collectionId: Int64,
        prompt: String? = nil,
        progress: (@Sendable (GenerateProgress) -> Void)? = nil
    ) async throws -> GenerateResult {
        let assets = (try? DAMDatabase.shared.assets(inCollectionId: collectionId)) ?? []
        return try await generateTags(for: assets, prompt: prompt, progress: progress)
    }

    // MARK: - Helpers

    /// True for standard raster images and camera RAW files that the vision
    /// proxy can decode.
    static func isImageAsset(_ asset: DAMAsset) -> Bool {
        let url = URL(fileURLWithPath: asset.path)
        return DAMFileKind.isStandardImage(url) || DAMFileKind.isCameraRAW(url)
    }

    /// True for audio files that WhisperKit can transcribe.
    static func isAudioAsset(_ asset: DAMAsset) -> Bool {
        DAMFileKind.isAudio(URL(fileURLWithPath: asset.path))
    }

    /// True for video files from which we can extract an audio track for
    /// WhisperKit transcription.
    static func isVideoAsset(_ asset: DAMAsset) -> Bool {
        DAMFileKind.isVideo(URL(fileURLWithPath: asset.path))
    }

    /// Generate AI tags for a single audio asset by transcribing it with
    /// WhisperKit and extracting nouns / named entities from the transcript.
    /// The full transcript is stored in `ocrText` for search.
    @discardableResult
    func generateAudioTags(for asset: DAMAsset) async throws -> [String] {
        guard Self.isAudioAsset(asset) else { return [] }
        return try await generateAudioTags(for: asset, audioURL: URL(fileURLWithPath: asset.path))
    }

    /// Generate AI tags from an audio file (the asset's own file, or an
    /// extracted audio track from a video). Shared implementation for audio
    /// and video assets.
    private func generateAudioTags(for asset: DAMAsset, audioURL: URL) async throws -> [String] {
        guard let assetId = asset.id else { return [] }

        // WhisperKitService is @MainActor; the `await` hops to it for the
        // transcription call (it loads the model lazily and caches it).
        let transcription: String?
        do {
            transcription = try await WhisperKitService.shared.transcribeAudioFile(at: audioURL)
        } catch {
            // Decode failures, no-speech, or missing model all fall back to
            // filename/folder context so short stems and SFX are still tagged.
            taggingLogger.error("WhisperKit failed for \(asset.filename, privacy: .public): \(error.localizedDescription)")
            transcription = nil
        }

        let usefulTranscription = transcription.flatMap { Self.isUsefulTranscript($0) ? $0 : nil }
        let isTranscribed = usefulTranscription != nil
        let sourceText: String
        if let usefulTranscription {
            sourceText = usefulTranscription
        } else {
            // Non-speech audio (e.g. stems, beeps, sound effects) or video
            // with no usable audio: derive context from filename and folders.
            sourceText = Self.sourceTextForAudioAsset(asset)
        }
        guard !sourceText.isEmpty else { return [] }

        let caption: String
        let tags: [String]
        if isTranscribed, Self.useLLMForAudioCaptions,
           let summary = try await Self.summarizeTranscriptWithLLM(sourceText) {
            caption = summary.caption
            tags = summary.tags.prefix(15).map { $0 }
        } else {
            tags = Self.extractTags(from: sourceText).prefix(15).map { $0 }
            caption = isTranscribed ? Self.audioCaption(from: sourceText) : sourceText
        }
        guard !tags.isEmpty else { return [] }

        let database = DAMDatabase.shared
        try await database.dbQueue.write { db in
            guard var row = try DAMAsset.fetchOne(db, key: assetId) else { return }
            let oldCaption = row.aiCaption
            let oldKeywords = row.aiKeywords
            let oldOCR = row.ocrText
            row.aiCaption = caption
            row.aiKeywords = tags.joined(separator: ", ")
            let updatedOCR = [oldOCR, transcription].compactMap { $0 }.joined(separator: "\n")
            row.ocrText = updatedOCR
            try row.update(db)
            if oldCaption != caption {
                try database.recordAudit(
                    db, assetId: assetId, field: "aiCaption",
                    oldValue: oldCaption, newValue: caption,
                    source: DAMTagSource.ai.rawValue)
            }
            if oldKeywords != row.aiKeywords {
                try database.recordAudit(
                    db, assetId: assetId, field: "aiKeywords",
                    oldValue: oldKeywords, newValue: row.aiKeywords,
                    source: DAMTagSource.ai.rawValue)
            }
            if oldOCR != updatedOCR {
                try database.recordAudit(
                    db, assetId: assetId, field: "ocrText",
                    oldValue: oldOCR, newValue: updatedOCR,
                    source: DAMTagSource.ai.rawValue)
            }
        }

        for tag in tags {
            _ = try database.applyTag(name: tag, to: assetId, source: .ai)
        }

        return tags
    }

    // MARK: - Video visual tagging configuration

    /// Config for how many frames to sample from a video. Defaults to one frame
    /// per minute, with a minimum of 3 frames (for short clips) and a maximum
    /// of 60 frames so very long videos don't spend minutes in the VLM.
    struct VideoTaggingConfig: Sendable, Equatable {
        var frameIntervalMinutes: Double
        var maxFrames: Int
        var minFrames: Int

        static let `default` = VideoTaggingConfig(
            frameIntervalMinutes: 1.0,
            maxFrames: 60,
            minFrames: 3
        )
    }

    static var videoTaggingConfig: VideoTaggingConfig {
        get {
            let defaults = UserDefaults.standard
            var config = VideoTaggingConfig.default
            if defaults.object(forKey: "dam.tagging.videoFrameIntervalMinutes") != nil {
                config.frameIntervalMinutes = defaults.double(forKey: "dam.tagging.videoFrameIntervalMinutes")
            }
            if defaults.object(forKey: "dam.tagging.videoMaxFrames") != nil {
                config.maxFrames = defaults.integer(forKey: "dam.tagging.videoMaxFrames")
            }
            if defaults.object(forKey: "dam.tagging.videoMinFrames") != nil {
                config.minFrames = defaults.integer(forKey: "dam.tagging.videoMinFrames")
            }
            return config
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.frameIntervalMinutes, forKey: "dam.tagging.videoFrameIntervalMinutes")
            defaults.set(newValue.maxFrames, forKey: "dam.tagging.videoMaxFrames")
            defaults.set(newValue.minFrames, forKey: "dam.tagging.videoMinFrames")
        }
    }

    /// Computes the number of frames to extract from a video based on its
    /// duration and the current `videoTaggingConfig`.
    private static func frameCount(for asset: DAMAsset) -> Int {
        let config = videoTaggingConfig
        guard let duration = asset.duration, duration > 0 else {
            return config.minFrames
        }
        let intervalSeconds = config.frameIntervalMinutes * 60.0
        let count = Int(ceil(duration / intervalSeconds))
        return max(config.minFrames, min(config.maxFrames, count))
    }

    /// Generate AI tags for a single video asset using both its audio track
    /// (WhisperKit transcription) and representative video frames (on-device
    /// Vision proxy). The two sources run in parallel and their tags/captions
    /// are merged so silent videos and talking-head videos both get useful
    /// keywords.
    @discardableResult
    func generateVideoTags(for asset: DAMAsset) async throws -> [String] {
        guard let assetId = asset.id else { return [] }
        guard Self.isVideoAsset(asset) else { return [] }

        let videoURL = URL(fileURLWithPath: asset.path)

        // Run audio and visual tagging concurrently.
        let audioTask = Task { () -> (tags: [String], caption: String?, transcript: String?) in
            do {
                let audioURL = try await extractAudioTrack(from: videoURL)
                defer { try? FileManager.default.removeItem(at: audioURL) }
                return try await generateVideoAudioSummary(for: asset, audioURL: audioURL)
            } catch {
                taggingLogger.error("Audio tagging failed for \(asset.filename, privacy: .public): \(error.localizedDescription)")
                return (tags: [], caption: nil, transcript: nil)
            }
        }

        let visualTask = Task { () -> (tags: [String], caption: String?) in
            guard Self.useVisionForVideoTags else { return (tags: [], caption: nil) }
            do {
                return try await generateVideoVisualTags(for: asset, videoURL: videoURL)
            } catch {
                taggingLogger.error("Visual tagging failed for \(asset.filename, privacy: .public): \(error.localizedDescription)")
                return (tags: [], caption: nil)
            }
        }

        let audio = await audioTask.value
        let visual = await visualTask.value

        var allTags = Set(audio.tags)
        allTags.formUnion(visual.tags)
        guard !allTags.isEmpty else { return [] }

        // Build a combined caption from both sources.
        var captionParts: [String] = []
        if let audioCaption = audio.caption, !audioCaption.isEmpty {
            captionParts.append(audioCaption)
        }
        if let visualCaption = visual.caption, !visualCaption.isEmpty {
            captionParts.append(visualCaption)
        }
        let caption = String(captionParts.joined(separator: " | ").prefix(500))

        try await updateVideoAIData(
            assetId: assetId,
            caption: caption,
            tags: Array(allTags).sorted(),
            transcript: audio.transcript
        )

        return Array(allTags)
    }

    /// Returns tags and a caption derived from a video's audio track, without
    /// writing to the database. Used by the combined video tagger.
    private func generateVideoAudioSummary(
        for asset: DAMAsset,
        audioURL: URL
    ) async throws -> (tags: [String], caption: String?, transcript: String?) {
        guard Self.isVideoAsset(asset) else {
            return (tags: [], caption: nil, transcript: nil)
        }

        let transcription: String?
        do {
            transcription = try await WhisperKitService.shared.transcribeAudioFile(at: audioURL)
        } catch {
            taggingLogger.error("WhisperKit failed for \(asset.filename, privacy: .public): \(error.localizedDescription)")
            transcription = nil
        }

        let usefulTranscription = transcription.flatMap { Self.isUsefulTranscript($0) ? $0 : nil }
        let isTranscribed = usefulTranscription != nil
        let sourceText: String
        if let usefulTranscription {
            sourceText = usefulTranscription
        } else {
            sourceText = Self.sourceTextForAudioAsset(asset)
        }

        guard !sourceText.isEmpty else { return (tags: [], caption: nil, transcript: transcription) }

        let caption: String
        let tags: [String]
        if isTranscribed, Self.useLLMForAudioCaptions,
           let summary = try await Self.summarizeTranscriptWithLLM(sourceText) {
            caption = summary.caption
            tags = summary.tags.prefix(15).map { $0 }
        } else {
            tags = Self.extractTags(from: sourceText).prefix(15).map { $0 }
            caption = isTranscribed ? Self.audioCaption(from: sourceText) : sourceText
        }

        return (tags: tags, caption: caption, transcript: transcription)
    }

    /// Extracts representative frames from a video, captions each one with the
    /// on-device Vision proxy, and returns merged tags plus a combined caption.
    /// Does not write to the database — the caller merges audio+visual results
    /// and writes once. Gated by `DAMResourceLimiter` with dynamic frame caps
    /// and per-frame timeouts.
    private func generateVideoVisualTags(
        for asset: DAMAsset,
        videoURL: URL
    ) async throws -> (tags: [String], caption: String?) {
        guard Self.isVideoAsset(asset) else { return (tags: [], caption: nil) }

        // Honour the resource limiter's dynamic cap (memory/thermal) but never
        // go below the user's configured minimum.
        let requestedCount = Self.frameCount(for: asset)
        let cappedCount = await DAMResourceLimiter.shared.videoFrameCap(userMaxFrames: requestedCount)

        let frameData = try await extractVideoFrames(from: videoURL, count: cappedCount)
        guard !frameData.isEmpty else { return (tags: [], caption: nil) }

        return try await DAMResourceLimiter.shared.withHeavyTask(
            name: "Video visual tagging",
            timeout: .infinity
        ) {
            let timeout = await DAMResourceLimiter.shared.currentLimit.operationTimeoutSeconds

            var allTags = Set<String>()
            var frameCaptions: [String] = []
            let prompt = Self.videoFrameTagPrompt

            for data in frameData {
                try Task.checkCancellation()
                guard !data.isEmpty else { continue }

                let caption = try await DAMResourceLimiter.shared.withTimeout(
                    seconds: timeout
                ) {
                    try await VisionProxyService.shared.caption(
                        imageData: data, prompt: prompt
                    )
                }
                guard let caption else { continue }
                frameCaptions.append(caption)
                let tags = Self.parseTagList(from: caption)
                allTags.formUnion(tags)
            }

            guard !allTags.isEmpty else { return (tags: [], caption: nil) }

            let visualCaption = String(frameCaptions.joined(separator: " ").prefix(500))
            return (tags: Array(allTags).sorted(), caption: visualCaption)
        }
    }

    /// Prompt used when captioning video frames. Asks for keywords so the
    /// response can be parsed the same way as still-image tagging.
    private static let videoFrameTagPrompt =
        "Describe what is visible in this video frame. Return a concise comma-separated list of 5–15 keywords focusing on subjects, scenes, objects, actions, colors, and style. Return ONLY the comma-separated list."

    /// Extracts `count` evenly-spaced representative frames from a video as
    /// PNG data. Returns an empty array if no frames could be generated.
    private func extractVideoFrames(from videoURL: URL, count: Int) async throws -> [Data] {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration > .zero else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)

        var frames: [Data] = []
        for index in 1...count {
            try Task.checkCancellation()
            let fraction = Float64(index) / Float64(count + 1)
            let time = CMTimeMultiplyByFloat64(duration, multiplier: fraction)
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                if let data = cgImage.pngData() {
                    frames.append(data)
                }
            } catch {
                taggingLogger.error("Frame extraction failed at \(fraction) for \(videoURL.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            }
        }
        return frames
    }

    /// Writes the combined audio+visual caption, keywords, and transcript for
    /// a video asset in one database transaction.
    private func updateVideoAIData(
        assetId: Int64,
        caption: String,
        tags: [String],
        transcript: String?
    ) async throws {
        let database = DAMDatabase.shared
        try await database.dbQueue.write { db in
            guard var row = try DAMAsset.fetchOne(db, key: assetId) else { return }
            let oldCaption = row.aiCaption
            let oldKeywords = row.aiKeywords
            let oldOCR = row.ocrText
            row.aiCaption = caption
            row.aiKeywords = tags.joined(separator: ", ")
            let updatedOCR = [oldOCR, transcript].compactMap { $0 }.joined(separator: "\n")
            row.ocrText = updatedOCR
            try row.update(db)
            if oldCaption != caption {
                try database.recordAudit(
                    db, assetId: assetId, field: "aiCaption",
                    oldValue: oldCaption, newValue: caption,
                    source: DAMTagSource.ai.rawValue)
            }
            if oldKeywords != row.aiKeywords {
                try database.recordAudit(
                    db, assetId: assetId, field: "aiKeywords",
                    oldValue: oldKeywords, newValue: row.aiKeywords,
                    source: DAMTagSource.ai.rawValue)
            }
            if oldOCR != updatedOCR {
                try database.recordAudit(
                    db, assetId: assetId, field: "ocrText",
                    oldValue: oldOCR, newValue: updatedOCR,
                    source: DAMTagSource.ai.rawValue)
            }
        }

        for tag in tags {
            _ = try database.applyTag(name: tag, to: assetId, source: .ai)
        }
    }

    /// Extracts the audio track from a video into a temporary M4A file using
    /// AVAssetExportSession. The caller is responsible for deleting the temp
    /// file when done.
    private func extractAudioTrack(from videoURL: URL) async throws -> URL {
        let asset = AVAsset(url: videoURL)
        guard try await asset.load(.isExportable) else {
            throw DAMTaggingError.generationFailed("Video is not exportable")
        }
        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        guard let session else {
            throw DAMTaggingError.generationFailed("Could not create audio export session")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        session.outputURL = outputURL
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        await session.export()
        switch session.status {
        case .completed:
            return outputURL
        default:
            throw session.error ?? DAMTaggingError.generationFailed("Audio export failed with status \(session.status.rawValue)")
        }
    }

    /// Decode an image for the vision proxy at a size that balances detail
    /// and throughput. Uses the same `loadCGImage` path as indexing so RAW
    /// files are handled consistently.
    private func imageDataForGeneration(path: String) async throws -> Data {
        guard let cgImage = await Self.loadCGImage(path: path, maxPixel: 1280) else {
            return Data()
        }
        return cgImage.pngData() ?? Data()
    }

    /// Parse a model response into a clean list of lowercase keywords.
    /// Handles comma/newline/semicolon separators and common list markers.
    static func parseTagList(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n;")
        let trimSet = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-•·0123456789."))
        var tags: [String] = []
        var seen = Set<String>()
        for raw in text.components(separatedBy: separators) {
            let cleaned = raw.trimmingCharacters(in: trimSet)
            let lower = cleaned.lowercased()
            guard lower.count > 1,
                  !seen.contains(lower),
                  !Self.generationStopWords.contains(lower) else { continue }
            seen.insert(lower)
            tags.append(lower)
        }
        return tags
    }

    /// Tokens that are too generic or meta to be useful tags on their own.
    private static let generationStopWords: Set<String> = [
        "image", "photo", "picture", "photograph", "shot", "frame",
        "scene", "closeup", "up", "of", "and", "with", "the", "a", "an",
        "in", "on", "at", "to", "for", "from", "as", "is", "are", "was",
        "this", "that", "these", "those", "no", "yes", "none", "unknown",
        "insufficient", "data", "error", "single", "word", "incomplete",
        "transcript", "metadata", "failure", "provided", "input", "context",
        "summary", "unable", "cannot", "generate", "speech", "short", "too",
    ]

    /// Extract keyword-like tokens from a transcript using on-device NLP.
    /// Keeps nouns and named entities (people, places, organizations) while
    /// dropping pronouns, verbs, and filler words.
    static func extractTags(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        var tags: [String] = []
        var seen = Set<String>()

        for scheme in [NLTagScheme.lexicalClass, .nameType] {
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word,
                scheme: scheme,
                options: options
            ) { tag, range in
                guard let tag else { return true }
                let keep: Bool
                switch tag {
                case .noun, .personalName, .placeName, .organizationName:
                    keep = true
                default:
                    keep = false
                }
                guard keep else { return true }

                let raw = String(text[range])
                    .lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•·0123456789."))
                guard raw.count > 1,
                      !seen.contains(raw),
                      !Self.audioStopWords.contains(raw) else { return true }
                seen.insert(raw)
                tags.append(raw)
                return true
            }
        }
        return tags
    }

    /// Derives searchable text from a non-speech audio asset. Uses the
    /// filename plus surrounding folder names and duration hints so stems,
    /// one-shots, loops, and sound effects get useful tags even when there
    /// is no speech to transcribe.
    private static func sourceTextForAudioAsset(_ asset: DAMAsset) -> String {
        let url = URL(fileURLWithPath: asset.path)
        var components = url.pathComponents
            .drop(while: { $0 == "/" })
            .filter { $0 != "Volumes" && !$0.isEmpty }
            .map { component -> String in
                (component as NSString).deletingPathExtension
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: ".", with: " ")
                    .replacingOccurrences(of: "[0-9]+", with: " ", options: .regularExpression)
            }
        // Remove common noise segments from the path.
        let noise = Set(["samples", "audio", "sounds", "sound library"])
        components = components.filter { !noise.contains($0.lowercased()) }

        let filename = components.popLast() ?? ""
        let folders = components.joined(separator: " ")
        var text = ([folders, filename] as [String])
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if let duration = asset.duration {
            if duration < 1.0 {
                text += " short one shot sound effect"
            } else if duration < 10.0 {
                text += " short audio sample"
            } else if duration < 60.0 {
                text += " audio loop stem"
            } else {
                text += " long audio stem composition"
            }
        }
        return text
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Treat very short or stop-word-only transcripts as unusable so
    /// percussion, SFX, and WhisperKit hallucinations fall back to filename
    /// and folder-based tags instead of producing junk captions.
    private static func isUsefulTranscript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let words = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }
        let contentWords = words.filter { !Self.audioStopWords.contains($0.lowercased()) }
        return !contentWords.isEmpty
    }

    /// Short caption for an audio asset: first sentence, capped to 240 chars.
    private static func audioCaption(from transcription: String) -> String {
        let first = transcription.split(
            whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" }
        ).first.map(String.init) ?? transcription
        return String(first.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }

    /// Stop words for spoken transcripts.
    private static let audioStopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "with", "this", "that",
        "from", "have", "has", "had", "not", "but", "all", "can", "her",
        "his", "its", "our", "out", "who", "you", "your", "their", "they",
        "them", "then", "than", "when", "what", "will", "would", "could",
        "should", "into", "over", "under", "about", "a", "an", "of", "in",
        "on", "at", "to", "as", "is", "it", "be", "been", "being", "do",
        "does", "did", "done", "i", "me", "my", "we", "us", "he", "she",
        "him", "hers", "there", "here", "where", "why", "how", "so", "if",
        "or", "nor", "yet", "no", "yes", "none", "unknown",
    ]

    // MARK: - LLM-enhanced audio captioning

    /// Ask the local LLM (e.g. Gemma 4) to summarize a transcript into a caption
    /// and tags. Runs on the MainActor because it touches `MaestroTools.engine`
    /// and `MaestroTools.catalog`. Returns nil if the engine/model is unavailable
    /// or the response cannot be parsed, so callers can fall back to NLP.
    @MainActor
    private static func summarizeTranscriptWithLLM(
        _ transcription: String
    ) async throws -> (caption: String, tags: [String])? {
        guard let engine = MaestroTools.engine else { return nil }
        guard let model = MaestroTools.catalog?.selectedModel
               ?? MaestroTools.catalog?.models.first else { return nil }

        let systemPrompt = """
            You are summarizing audio transcripts for a digital asset management library.
            Given a transcript, write a concise one-sentence caption and a comma-separated list of 5-15 tags.
            Respond ONLY in this exact format:

            Caption: <one sentence>
            Tags: <tag1, tag2, tag3>

            Do not add markdown, numbering, or explanation.
            """

        let userPrompt = "Transcript:\n\(transcription)"

        let turns: [ChatTurn] = [
            ChatTurn(role: "system", content: systemPrompt, images: []),
            ChatTurn(role: "user", content: userPrompt, images: [])
        ]

        let (raw, _) = try await engine.generateRound(
            chatTurns: turns,
            toolSchemas: nil,
            model: model,
            sessionKey: "dam-audio-llm-\(UUID().uuidString)",
            temperature: 0.7,
            topP: 0.95,
            thinkingEnabled: false,
            maxTokens: 256,
            onToken: { _ in },
            onInfo: { _ in }
        )

        return parseLLMAudioSummary(raw)
    }

    /// Phrases that indicate the LLM failed to produce a real summary.
    private static let llmFailurePhrases: Set<String> = [
        "insufficient data", "single word", "incomplete transcript",
        "metadata failure", "provided input", "does not provide",
        "enough context", "unable to", "cannot generate", "no speech",
        "too short", "not enough", "error", "none",
    ]

    /// Strip thinking tags and parse the LLM's "Caption:" / "Tags:" lines.
    /// Rejects captions that contain failure/meta phrases so the caller
    /// can fall back to NLP tagging instead of saving junk.
    private static func parseLLMAudioSummary(
        _ raw: String
    ) -> (caption: String, tags: [String])? {
        let clean = ThinkingTagStripper.strip(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var caption: String?
        var tagLine: String?
        for line in clean.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if caption == nil, lower.hasPrefix("caption:") {
                caption = String(trimmed.dropFirst("caption:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if tagLine == nil, lower.hasPrefix("tags:") {
                tagLine = String(trimmed.dropFirst("tags:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        guard let caption, !caption.isEmpty else { return nil }
        let lowerCaption = caption.lowercased()
        guard !Self.llmFailurePhrases.contains(where: { lowerCaption.contains($0) }) else {
            return nil
        }

        let tags = tagLine.map { Self.parseTagList(from: $0) } ?? []
        guard !tags.isEmpty else { return nil }
        return (caption, tags)
    }
}

// MARK: - CGImage → PNG

private extension CGImage {
    /// Render to PNG data; returns nil if the bitmap representation fails.
    func pngData() -> Data? {
        let nsImage = NSImage(
            cgImage: self,
            size: NSSize(width: CGFloat(width), height: CGFloat(height)))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
