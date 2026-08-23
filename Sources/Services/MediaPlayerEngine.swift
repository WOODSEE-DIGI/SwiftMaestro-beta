import AVFoundation
import Combine

// MARK: - Media Player Engine
//
// Core playback engine wrapping AVPlayer. Provides play/pause/seek, time
// observation, and format detection. Designed as a singleton so the MediaPlayer
// panel, menu bar controls, and keyboard shortcuts all share one player.

@Observable
@MainActor
final class MediaPlayerEngine {
    static let shared = MediaPlayerEngine()

    // MARK: - State

    /// The underlying AVPlayer instance.
    private var player = AVPlayer()

    /// Whether the player is currently playing.
    var isPlaying = false

    /// Current playback position (seconds).
    var currentTime: Double = 0

    /// Total duration of the loaded item (seconds). nil if unknown.
    var duration: Double?

    /// Current playback rate (1.0 = normal).
    var rate: Float = 1.0

    /// Volume (0.0 ... 1.0).
    var volume: Double = 0.8 {
        didSet {
            player.volume = Float(volume)
        }
    }

    /// Whether output is muted.
    var isMuted = false {
        didSet {
            player.isMuted = isMuted
        }
    }

    /// The currently loaded media URL, if any.
    var currentURL: URL?

    /// Metadata extracted from the current item.
    var mediaInfo = MediaInfo()

    /// Whether the player has a loaded item.
    var hasItem: Bool { currentURL != nil }

    /// Whether the player is seeking (for UI feedback).
    var isSeeking = false

    /// Audio tap for real-time spectrum visualization.
    private let audioTap = MediaPlayerAudioTap()

    /// FFmpeg fallback for formats AVKit cannot decode.
    private let transcoder = MediaPlayerTranscoder()

    /// The temp file produced by an FFmpeg conversion for the current item,
    /// if any. Deleted on stop so transcodes never accumulate.
    private var convertedTempURL: URL?

    /// True while a format is being probed/remuxed/transcoded for playback.
    var isPreparingMedia = false

    /// Last preparation failure (unsupported codec, corrupt file, …).
    var preparationError: String?

    /// Read-only access to the shared player for the video surface.
    var playerForVideo: AVPlayer { player }

    /// Latest spectrum snapshot (24 bands, 0…1). Updated periodically from the UI timer.
    var spectrumBands: [Float] = Array(repeating: 0, count: 24)
    var spectrumCaps: [Float] = Array(repeating: 0, count: 24)

    // MARK: - Private

    private var timeObserver: Any?
    private var itemObserver: AnyCancellable?
    private var statusObservation: AnyCancellable?

    private init() {
        setupTimeObserver()
        player.volume = Float(volume)
    }

    deinit {
        // Note: deinit is nonisolated; we cannot reference self properties.
        // The time observer is cleaned up by the player deallocation.
    }

    // MARK: - Time Observer

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600) // 20 fps
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let cmTime = time as CMTime?, cmTime.isNumeric else { return }
            Task { @MainActor in
                self.currentTime = cmTime.seconds
            }
        }
    }

    // MARK: - Playback Controls

    /// Load a media file and prepare it for playback. Non-native formats are
    /// remuxed/transcoded via the FFmpeg fallback first.
    func load(url: URL) async {
        stop()

        // Route through the FFmpeg fallback when the format is one AVKit
        // cannot decode (MKV, WebM, Ogg/Opus, DTS, …). Native formats pass
        // through untouched.
        isPreparingMedia = true
        preparationError = nil
        let playable: URL
        do {
            playable = try await transcoder.playableURL(for: url)
        } catch {
            isPreparingMedia = false
            preparationError = error.localizedDescription
            return
        }
        isPreparingMedia = false
        if playable != url {
            convertedTempURL = playable
        }

        let asset = AVURLAsset(url: playable)
        let item = AVPlayerItem(asset: asset)

        currentURL = url
        extractMetadata(from: asset)

        // Observe item status for duration.
        statusObservation = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .readyToPlay {
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : nil
                }
            }

        // Observe item end.
        itemObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = 0
            }

        player.replaceCurrentItem(with: item)

        // Start the side-channel decoder for live spectrum visualization.
        audioTap.install(asset: asset)
    }

    /// Toggle play/pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Start or resume playback.
    func play() {
        guard currentURL != nil else { return }
        player.play()
        player.rate = rate
        isPlaying = true
    }

    /// Pause playback.
    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Stop playback and reset position.
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        audioTap.uninstall()
        isPlaying = false
        currentTime = 0
        duration = nil
        currentURL = nil
        mediaInfo = MediaInfo()
        spectrumBands = Array(repeating: 0, count: 24)
        spectrumCaps = Array(repeating: 0, count: 24)
        itemObserver = nil
        statusObservation = nil
        preparationError = nil
        // Delete the FFmpeg conversion for the stopped item, if any.
        transcoder.removeConvertedFile(convertedTempURL)
        convertedTempURL = nil
    }

    /// Seek to a specific time (seconds).
    func seek(to time: Double) {
        guard let item = player.currentItem else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        isSeeking = true
        item.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                self.audioTap.resync(to: time, asset: self.player.currentItem?.asset)
            }
        }
    }

    /// Seek relative to current position (e.g., skip ±15 seconds).
    func seekRelative(_ delta: Double) {
        let target = max(0, min(currentTime + delta, duration ?? currentTime + delta))
        seek(to: target)
    }

    /// Set playback rate (0.5, 1.0, 1.5, 2.0, etc.).
    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying {
            player.rate = newRate
        }
    }

    /// Skip to the beginning of the next track. If at the end, stops.
    func skipForward() {
        // Handled by queue — engine just provides the seek primitive.
        seek(to: duration ?? 0)
    }

    /// Skip to the beginning of the previous track, or restart current.
    func skipBackward() {
        if currentTime > 3 {
            seek(to: 0)
        } else {
            seek(to: 0)
        }
    }

    // MARK: - Visualization

    /// Refresh spectrum data from the audio tap. Call from UI timer.
    func refreshSpectrum() {
        let snapshot = audioTap.pump(currentTime: currentTime, isPlaying: isPlaying)
        spectrumBands = snapshot.spectrum
        spectrumCaps = snapshot.caps
    }

    // MARK: - Metadata Extraction

    private func extractMetadata(from asset: AVAsset) {
        Task {
            var info = MediaInfo()
            info.title = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue
            info.artist = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue
            info.album = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyAlbumName })?.stringValue

            if let artwork = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue {
                info.artwork = NSImage(data: artwork)
            }

            // Extract technical info from tracks.
            if let videoTracks = try? await asset.loadTracks(withMediaType: .video) {
                for track in videoTracks {
                    if let formatDesc = try? await track.load(.formatDescriptions),
                       let desc = formatDesc.first {
                        let cmDesc = desc as! CMFormatDescription
                        let dims = CMVideoFormatDescriptionGetDimensions(cmDesc)
                        info.videoWidth = Int(dims.width)
                        info.videoHeight = Int(dims.height)
                        info.hasVideo = true
                    }
                }
            }

            if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
                for track in audioTracks {
                    if let formatDesc = try? await track.load(.formatDescriptions),
                       let desc = formatDesc.first {
                        let cmDesc = desc as! CMFormatDescription
                        let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(cmDesc)
                        if let streamDesc {
                            info.sampleRate = Int(streamDesc.pointee.mSampleRate)
                            info.channels = Int(streamDesc.pointee.mChannelsPerFrame)
                        }
                    }
                }
            }

            // File size.
            let assetURL = currentURL
            if let resourceValues = try? await assetURL?.resourceValues(forKeys: [.fileSizeKey]) {
                info.fileSize = resourceValues.fileSize
            }

            // Format from URL extension.
            info.format = assetURL?.pathExtension.uppercased()

            self.mediaInfo = info
        }
    }
}

// MARK: - Media Info

/// Technical metadata about the currently loaded media.
struct MediaInfo {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: NSImage?
    var format: String?
    var fileSize: Int?
    var videoWidth: Int?
    var videoHeight: Int?
    var hasVideo: Bool = false
    var sampleRate: Int?
    var channels: Int?

    var displayTitle: String {
        title ?? String(localized: "Unknown Track")
    }

    var displayArtist: String {
        artist ?? String(localized: "Unknown Artist")
    }

    var displayFormat: String {
        format ?? "—"
    }

    var displayFileSize: String {
        guard let fileSize else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    var displayResolution: String {
        guard let w = videoWidth, let h = videoHeight else { return "—" }
        return "\(w)×\(h)"
    }

    var displaySampleRate: String {
        guard let sampleRate else { return "—" }
        return "\(sampleRate) Hz"
    }

    var displayChannels: String {
        guard let channels else { return "—" }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(channels)ch"
        }
    }
}
