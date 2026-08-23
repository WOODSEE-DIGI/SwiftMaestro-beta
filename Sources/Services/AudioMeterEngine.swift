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

    // MARK: - DSP buffers (flat class properties — preallocated at start,
    // written only by the tap thread while it holds the lock; exclusivity
    // checker sees each as distinct storage)

    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []
    private var windowed: [Float] = []
    private var splitRe: [Float] = []
    private var splitIm: [Float] = []
    private var magnitudes: [Float] = []
    private var bandBins: [[Int]] = []

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
        fftSetup = fft
        self.window = window
        windowed = [Float](repeating: 0, count: n)
        splitRe = [Float](repeating: 0, count: n / 2)
        splitIm = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
        self.bandBins = bandBins
        lock.unlock()
    }

    // MARK: - Tap processing (realtime audio thread)
    //
    // Everything the FFT touches is a flat class property (distinct storage
    // per property), so the nested withUnsafe* scopes never overlap on one
    // aggregate's storage — that overlap was the exclusivity crash.

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard isRunning, let fftSetup else {
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
            windowed[i] = s * window[i]
            sumSquares += s * s
            if abs(s) > peak { peak = abs(s) }
        }
        for i in frames..<bufferSize { windowed[i] = 0 }
        let rms = min(1, sqrt(sumSquares / Float(frames)) * 3)

        windowed.withUnsafeBufferPointer { srcPtr in
            splitRe.withUnsafeMutableBufferPointer { rePtr in
                splitIm.withUnsafeMutableBufferPointer { imPtr in
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
            let re = splitRe[bin]
            let im = splitIm[bin]
            magnitudes[bin] = re * re + im * im
        }

        var bands = [Float](repeating: 0, count: 24)
        for (band, bins) in bandBins.enumerated() {
            var sum: Float = 0
            for bin in bins { sum += magnitudes[bin] }
            let mean = sum / Float(max(1, bins.count))
            let db = 10 * log10(max(mean, 1e-12))
            bands[band] = max(0, min(1, (db + 60) / 60))
        }
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
    }
}
