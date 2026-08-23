import Foundation
@preconcurrency import AVFoundation
import Accelerate

// MARK: - Audio Meter Engine
//
// Standalone live-input monitor behind the retro meters: an AVAudioEngine tap
// on the selected microphone, computing per-buffer RMS/peak plus a 24-band
// log-spaced spectrum (Accelerate vDSP FFT).
//
// THREADING MODEL (rewritten after the RealtimeMessenger assertion crash):
// this engine is NOT actor-isolated. All RT-shared state lives in one
// lock-guarded State struct; the audio tap thread touches state only under
// the lock, and UI receives per-buffer frames through @Sendable observer
// callbacks that hop to MainActor themselves. Previous version ran the FFT
// on the MainActor and called into it from the realtime audio thread — an
// actor violation that tripped CoreAudio's RealtimeMessenger queue assert.
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

    // MARK: - Thread-safe state

    private struct State {
        var isRunning = false
        var engine: AVAudioEngine?
        // DSP (all preallocated at start; the tap thread never allocates)
        var fftSetup: vDSP.FFT<DSPSplitComplex>?
        var window: [Float] = []
        var windowed: [Float] = []
        var splitRe: [Float] = []
        var splitIm: [Float] = []
        var magnitudes: [Float] = []
        var bandBins: [[Int]] = []
        // Latest measurements
        var level: Float = 0
        var peakLevel: Float = 0
        var spectrum: [Float] = Array(repeating: 0, count: 24)
        // Observers (UI) — called with a frame per processed buffer
        var observers: [UUID: @Sendable (MeterFrame) -> Void] = [:]
    }

    private var state = State()
    private let lock = NSLock()

    private let bufferSize = 2048

    private init() {}

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.isRunning
    }

    // MARK: - Observers

    @discardableResult
    func addObserver(_ observer: @escaping @Sendable (MeterFrame) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); state.observers[id] = observer; lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock(); state.observers[id] = nil; lock.unlock()
    }

    // MARK: - Start / stop

    func start() {
        lock.lock()
        guard !state.isRunning else { lock.unlock(); return }
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

        prepareDSP(sampleRate: Float(hwFormat.sampleRate))

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
        state.engine = engine
        state.isRunning = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let engine = state.engine
        state.engine = nil
        state.isRunning = false
        state.level = 0
        state.peakLevel = 0
        state.spectrum = Array(repeating: 0, count: 24)
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    // MARK: - DSP prep (called on the starting thread, before the tap exists)

    private func prepareDSP(sampleRate: Float) {
        let n = bufferSize
        let fft = vDSP.FFT(log2n: UInt(log2(Float(n))), radix: .radix2,
                           ofType: DSPSplitComplex.self)
        let window = vDSP.window(ofType: Float.self,
                                 usingSequence: .hanningDenormalized,
                                 count: n, isHalfWindow: false)
        let binHz = sampleRate / Float(n)
        let bandBins: [[Int]] = (0..<24).map { band in
            let lo = 20.0 * pow(1000.0, Double(band) / 24.0)
            let hi = 20.0 * pow(1000.0, Double(band + 1) / 24.0)
            let loBin = max(1, Int(lo / Double(binHz)))
            let hiBin = min(n / 2 - 1, max(loBin + 1, Int(hi / Double(binHz))))
            return Array(loBin..<hiBin)
        }
        lock.lock()
        state.fftSetup = fft
        state.window = window
        state.windowed = [Float](repeating: 0, count: n)
        state.splitRe = [Float](repeating: 0, count: n / 2)
        state.splitIm = [Float](repeating: 0, count: n / 2)
        state.magnitudes = [Float](repeating: 0, count: n / 2)
        state.bandBins = bandBins
        lock.unlock()
    }

    // MARK: - Tap processing (realtime audio thread — lock-guarded, no allocs)

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard state.isRunning, let fftSetup = state.fftSetup else {
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
            let s = channelData[0][i * stride]
            state.windowed[i] = s * state.window[i]
            sumSquares += s * s
            if abs(s) > peak { peak = abs(s) }
        }
        for i in frames..<bufferSize { state.windowed[i] = 0 }
        let rms = min(1, sqrt(sumSquares / Float(frames)) * 3)

        state.windowed.withUnsafeBufferPointer { srcPtr in
            state.splitRe.withUnsafeMutableBufferPointer { rePtr in
                state.splitIm.withUnsafeMutableBufferPointer { imPtr in
                    var split = DSPSplitComplex(realp: rePtr.baseAddress!, imagp: imPtr.baseAddress!)
                    srcPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frames / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(frames / 2))
                    }
                    fftSetup.forward(input: split, output: &split)
                }
            }
        }
        let binCount = bufferSize / 2
        for bin in 0..<binCount {
            let re = state.splitRe[bin]
            let im = state.splitIm[bin]
            state.magnitudes[bin] = re * re + im * im
        }

        var bands = [Float](repeating: 0, count: 24)
        for (band, bins) in state.bandBins.enumerated() {
            var sum: Float = 0
            for bin in bins { sum += state.magnitudes[bin] }
            let mean = sum / Float(max(1, bins.count))
            let db = 10 * log10(max(mean, 1e-12))
            bands[band] = max(0, min(1, (db + 60) / 60))
        }
        state.level = rms
        state.peakLevel = max(peak, state.peakLevel * 0.985)
        state.spectrum = bands
        let frame = MeterFrame(level: rms, peak: state.peakLevel, spectrum: bands)
        let observers = Array(state.observers.values)
        lock.unlock()

        for observer in observers { observer(frame) }
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
    private(set) var isRunning = false

    private var observerID: UUID?

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        if observerID == nil {
            observerID = AudioMeterEngine.shared.addObserver { frame in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.level = frame.level
                    self.peak = frame.peak
                    self.spectrum = frame.spectrum
                }
            }
        }
        AudioMeterEngine.shared.start()
        isRunning = AudioMeterEngine.shared.isRunning
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
    }
}
