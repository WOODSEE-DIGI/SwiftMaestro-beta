import Foundation
@preconcurrency import AVFoundation
import Accelerate

// MARK: - Audio Meter Engine
//
// Standalone live-input monitor behind the retro meters: an AVAudioEngine tap
// on the selected microphone, computing per-buffer RMS/peak plus a 24-band
// log-spaced spectrum (Accelerate vDSP FFT).
//
// THREADING + EXCLUSIVITY MODEL (two crashes shaped this):
//  1. Not actor-isolated (running DSP on a @MainActor class from the RT audio
//     thread tripped CoreAudio's RealtimeMessenger queue assert).
//  2. DSP buffers are FLAT class properties, never a struct member accessed
//     inside another member's withUnsafe* scope — nested accesses on one
//     struct's storage trip Swift's exclusivity checker
//     ("Simultaneous accesses … modification requires exclusive access").
//  3. Cross-thread traffic is minimal: the tap thread computes under a lock;
//     UI receives immutable MeterFrames via @Sendable observers that hop to
//     MainActor themselves.
//
// METERING ONLY: nothing is played back, so there is zero feedback risk.

/// One per-buffer measurement pushed to observers.
struct MeterFrame: Sendable {
    var level: Float
    var peak: Float
    var spectrum: [Float]
}

final class AudioMeterEngine: @unchecked Sendable {

    static let shared = AudioMeterEngine()

    // MARK: - Lock-guarded control state (small; never accessed in nested
    // withUnsafe* scopes — measurements go out via value-type MeterFrames)

    private var isRunning = false
    private var engine: AVAudioEngine?
    private var observers: [UUID: @Sendable (MeterFrame) -> Void] = [:]
    private var peakLevel: Float = 0
    private let lock = NSLock()

    // MARK: - DSP (shared analyzer — preallocated at start, tap-thread only)

    private var analyzer: SpectrumAnalyzer?

    private let bufferSize = 2048

    private init() {}

    var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning
    }

    // MARK: - Observers

    @discardableResult
    func addObserver(_ observer: @escaping @Sendable (MeterFrame) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = observer; lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    // MARK: - Start / stop

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        lock.unlock()

        let engine = AVAudioEngine()

        // Apply the user's chosen mic when set (validated — stale IDs crash
        // AVAudioEngine). Whisper settings persist the selection in
        // UserDefaults (no singleton on the service), so read the key directly.
        let storedMic = UserDefaults.standard.integer(
            forKey: "settings.whisperkit.inputDeviceID")
        let micID: AudioDeviceID? = storedMic == 0 ? nil : AudioDeviceID(storedMic)
        if let deviceID = AudioDeviceManager.shared.validInputDeviceID(micID),
           let audioUnit = engine.inputNode.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                audioUnit,
                AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { return }

        let analyzer = SpectrumAnalyzer(bandCount: 24, bufferSize: bufferSize)
        analyzer.prepare(sampleRate: Float(hwFormat.sampleRate))
        lock.lock()
        self.analyzer = analyzer
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: UInt32(bufferSize), format: hwFormat) {
            [weak self] buffer, _ in
            self?.processTapBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NSLog("[AudioMeter] engine start failed: \(error)")
            return
        }
        lock.lock()
        self.engine = engine
        isRunning = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        isRunning = false
        peakLevel = 0
        let currentObservers = Array(observers.values)
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // Push one zeroed frame so UI meters fall to idle immediately.
        let zero = MeterFrame(level: 0, peak: 0, spectrum: Array(repeating: 0, count: 24))
        for observer in currentObservers { observer(zero) }
    }

    // MARK: - Tap processing (realtime audio thread)
    //
    // Everything the FFT touches is a flat class property (distinct storage
    // per property), so the nested withUnsafe* scopes never overlap on one
    // aggregate's storage — that overlap was the exclusivity crash.

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard isRunning, let analyzer else {
            lock.unlock()
            return
        }
        let frames = min(Int(buffer.frameLength), bufferSize)
        guard frames > 0, let channelData = buffer.floatChannelData else {
            lock.unlock()
            return
        }

        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<frames {
            let sample = channelData[0][i * stride]
            sumSquares += sample * sample
            if abs(sample) > peak { peak = abs(sample) }
        }
        let rms = min(1, sqrt(sumSquares / Float(frames)) * 3)
        let bands = analyzer.process(buffer)

        peakLevel = max(peak, peakLevel * 0.985)
        let frame = MeterFrame(level: rms, peak: peakLevel, spectrum: bands)
        let currentObservers = Array(observers.values)
        lock.unlock()

        for observer in currentObservers { observer(frame) }
    }
}

// MARK: - Meter Display (UI bridge)
//
// The @Observable @MainActor face of the engine for SwiftUI: registers as an
// engine observer, receives MeterFrames (hopping to MainActor), and republishes
// them as observable properties. Keeps the engine itself free of any actor
// isolation — the fix for the RealtimeMessenger assertion.

@Observable
@MainActor
final class MeterDisplay {

    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    private(set) var spectrum: [Float] = Array(repeating: 0, count: 24)
    /// Per-band falling peak caps (the white marker above each bar).
    private(set) var spectrumCaps: [Float] = Array(repeating: 0, count: 24)
    private(set) var isRunning = false

    private var observerID: UUID?

    /// VU ballistics: fast attack, slow release — meters breathe like analog
    /// instead of stepping per frame. Applied UI-side so the engine stays raw.
    private func applyBallistics(_ frame: MeterFrame) {
        // Level: instant rise, eased fall.
        if frame.level > level {
            level = frame.level
        } else {
            level = max(frame.level, level - 0.04)
        }
        if frame.peak > peak {
            peak = frame.peak
        } else {
            peak = max(frame.peak, peak - 0.012)
        }
        // Bands + caps.
        var smoothed = spectrum
        var caps = spectrumCaps
        for i in 0..<min(frame.spectrum.count, smoothed.count) {
            let newValue = frame.spectrum[i]
            if newValue > smoothed[i] {
                smoothed[i] = newValue            // attack: instant
            } else {
                smoothed[i] = max(newValue, smoothed[i] - 0.035)  // release
            }
            if newValue > caps[i] {
                caps[i] = newValue                // cap jumps to peak
            } else {
                caps[i] = max(0, caps[i] - 0.008) // cap falls slowly
            }
        }
        spectrum = smoothed
        spectrumCaps = caps
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        if observerID == nil {
            observerID = AudioMeterEngine.shared.addObserver { frame in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.applyBallistics(frame)
                }
            }
        }
        AudioMeterEngine.shared.start()
        isRunning = AudioMeterEngine.shared.running
    }

    func stop() {
        AudioMeterEngine.shared.stop()
        if let observerID {
            AudioMeterEngine.shared.removeObserver(observerID)
            self.observerID = nil
        }
        isRunning = false
        level = 0
        peak = 0
        spectrum = Array(repeating: 0, count: 24)
        spectrumCaps = Array(repeating: 0, count: 24)
    }
}
