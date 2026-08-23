import AVFoundation

// MARK: - Media Player Audio Tap
//
// Feeds the SpectrumAnalyzer with the currently playing item's audio so the
// Media Player panel shows a REAL spectrum — not a simulation.
//
// Why AVAssetReader: on macOS there is no supported way to tap AVPlayer's
// rendered audio. `AVAudioMixInputParameters.audioTapProcessorID`
// (MTAudioProcessingTap) is iOS-only — it is not declared in the macOS SDK at
// all — and `AVPlayerItemAudioOutput` likewise exists only on iOS. (Verified
// against the Xcode 26 macOS SDK headers + swiftinterface, 2026-08-23.)
//
// So instead we decode the same asset's audio track on a background queue,
// staying within ~0.5 s of the live playhead (self-clocked: the decode loop
// pauses whenever it runs further ahead than that). The UI timer calls
// `pump(currentTime:isPlaying:)` to publish the playhead and fetch the latest
// bands. Seeks re-prime the reader at the new position; pause decays the
// bands toward silence. Playback itself is untouched — AVPlayer renders audio
// exactly as before, this is a read-only side channel.
//
// Thread discipline (learned the hard way in AudioMeterEngine):
//   • All published state crosses threads behind `lock` — nothing else is
//     shared between the decode queue and the main actor.
//   • The analyzer lives entirely on the decode queue ("the single tap
//     thread that owns this analyzer" per SpectrumAnalyzer.process docs).
//   • Buffers are flat class properties, never members of one struct —
//     nested withUnsafe* scopes stay exclusivity-safe.

final class MediaPlayerAudioTap: @unchecked Sendable {

    // MARK: - Published state (lock-guarded)

    private let lock = NSLock()
    private var spectrum: [Float] = Array(repeating: 0, count: 24)
    private var caps: [Float] = Array(repeating: 0, count: 24)
    private var capDecay: [Float] = Array(repeating: 0, count: 24)

    /// Playhead + playing flag, published by the main actor each pump.
    private var playhead: Double = 0
    private var playing: Bool = false

    // MARK: - Decode-queue state (single owner)

    private let decodeQueue = DispatchQueue(label: "com.woodseedigi.swiftmaestro.mediaplayer.audiotap", qos: .userInitiated)
    private let analyzer = SpectrumAnalyzer(bandCount: 24, bufferSize: 2048)

    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var pcmBuffer: AVAudioPCMBuffer?

    /// End time (seconds) of the last consumed chunk — the decode position.
    private var decodePosition: Double = 0

    /// Monotonic token: bumped on install/uninstall/resync so stale decode
    /// loops from a previous item/position exit instead of feeding the UI
    /// spectrum from the wrong audio.
    private var generation: UInt64 = 0

    /// How far ahead of the playhead the decoder may run before pausing.
    private let lookAheadSeconds: Double = 0.5

    /// Loop cadence when idle/ahead (seconds).
    private let idleSleep: UInt32 = 30_000 // microseconds

    // MARK: - Lifecycle (main actor, alongside the engine's item mutations)

    /// Begin decoding the given asset's first audio track.
    @MainActor
    func install(asset: AVAsset) {
        uninstall()
        lock.lock()
        generation &+= 1
        let token = generation
        lock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.primeReader(asset: asset, startTime: 0, token: token)
            self.decodeLoop(token: token)
        }
    }

    /// Re-prime the decoder at a new playhead position (after a seek).
    @MainActor
    func resync(to time: Double, asset: AVAsset?) {
        lock.lock()
        generation &+= 1
        let token = generation
        playhead = time
        lock.unlock()

        guard let asset else { return }

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.primeReader(asset: asset, startTime: time, token: token)
            self.decodeLoop(token: token)
        }
    }

    /// Stop decoding and zero the published state.
    @MainActor
    func uninstall() {
        lock.lock()
        generation &+= 1
        lock.unlock()
        reader?.cancelReading()
        reader = nil
        trackOutput = nil

        lock.lock()
        spectrum = Array(repeating: 0, count: 24)
        caps = Array(repeating: 0, count: 24)
        capDecay = Array(repeating: 0, count: 24)
        playing = false
        lock.unlock()
    }

    // MARK: - Pump (main actor, ~16–20 Hz from the engine's UI timer)

    /// Publish the current playhead and return the latest spectrum snapshot.
    /// When playback is paused, bands decay smoothly toward silence.
    @MainActor
    func pump(currentTime: Double, isPlaying: Bool) -> (spectrum: [Float], caps: [Float]) {
        lock.lock()
        playhead = currentTime
        playing = isPlaying
        if !isPlaying {
            for i in 0..<spectrum.count {
                spectrum[i] *= 0.90
                capDecay[i] *= 0.90
                caps[i] = capDecay[i]
            }
        }
        let s = spectrum
        let c = caps
        lock.unlock()
        return (s, c)
    }

    // MARK: - Reader priming (decode queue)

    private func primeReader(asset: AVAsset, startTime: Double, token: UInt64) {
        guard isCurrent(token) else { return }

        reader?.cancelReading()
        reader = nil
        trackOutput = nil
        pcmBuffer = nil

        guard let audioTrack = asset.tracks(withMediaType: .audio).first else { return }

        do {
            let newReader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsNonInterleaved: true,
                ]
            )
            guard newReader.canAdd(output) else { return }
            newReader.add(output)
            if startTime > 0 {
                newReader.timeRange = CMTimeRange(
                    start: CMTime(seconds: startTime, preferredTimescale: 600),
                    duration: .positiveInfinity
                )
            }
            guard newReader.startReading() else { return }

            reader = newReader
            trackOutput = output
            decodePosition = startTime
        } catch {
            return
        }
    }

    // MARK: - Decode loop (decode queue)

    /// Consumes PCM chunks, keeping within `lookAheadSeconds` of the playhead.
    /// Runs until the generation token goes stale, the track ends, or the
    /// reader errors.
    private func decodeLoop(token: UInt64) {
        while isCurrent(token) {
            lock.lock()
            let head = playhead
            let isPlaying = playing
            lock.unlock()

            // Paused: hold position, let the UI decay the display.
            guard isPlaying else {
                usleep(idleSleep * 3)
                continue
            }

            // Ahead of the playhead window: wait for playback to catch up.
            guard decodePosition <= head + lookAheadSeconds else {
                usleep(idleSleep)
                continue
            }

            guard let sampleBuffer = trackOutput?.copyNextSampleBuffer() else {
                // End of track or reader failure — park until resync/uninstall.
                usleep(idleSleep * 10)
                continue
            }

            consume(sampleBuffer)
        }
    }

    /// FFT one decoded chunk and publish its bands.
    private func consume(_ sampleBuffer: CMSampleBuffer) {
        defer { analyzerPublishedAdvance(sampleBuffer) }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let sampleRate = Float(asbd.pointee.mSampleRate)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(max(1, asbd.pointee.mChannelsPerFrame)),
            interleaved: false
        ) else { return }

        if pcmBuffer == nil || pcmBuffer!.frameCapacity < frames || pcmBuffer!.format != format {
            pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 4096))
        }
        guard let pcm = pcmBuffer else { return }

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return }
        pcm.frameLength = frames

        if analyzerIsPrepared != true {
            analyzer.prepare(sampleRate: sampleRate)
            analyzerIsPrepared = true
        }

        let bands = analyzer.process(pcm)

        lock.lock()
        spectrum = bands
        for i in 0..<bands.count {
            if bands[i] > capDecay[i] {
                capDecay[i] = bands[i]
            } else {
                capDecay[i] *= 0.995 // Slow fall
            }
            caps[i] = capDecay[i]
        }
        lock.unlock()
    }

    private var analyzerIsPrepared: Bool = false

    /// Advance the decode position past the chunk we just consumed.
    private func analyzerPublishedAdvance(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)
        guard pts.isNumeric else { return }
        let end = pts.seconds + (dur.isNumeric ? dur.seconds : 0)
        decodePosition = max(decodePosition, end)
    }

    /// Whether this work item's generation token is still the live one.
    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        let current = generation == token
        lock.unlock()
        return current
    }
}
