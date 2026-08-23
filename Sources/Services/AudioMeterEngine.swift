import Foundation
@preconcurrency import AVFoundation
import Accelerate

// MARK: - Audio Meter Engine
//
// Standalone live-input monitor behind the retro meters: an AVAudioEngine tap
// on the selected microphone, computing per-buffer RMS/peak plus a 24-band
// log-spaced spectrum (Accelerate vDSP FFT, all buffers preallocated — the
// real-time tap thread never allocates). METERING ONLY: nothing is played
// back, so there is zero feedback risk.
//
// Used by the Audio Control panel's Live Monitor section. Voice Notes keeps
// its own recording engine (its tap feeds the retro level meter + applies
// the shared EQ).

@Observable
@MainActor
final class AudioMeterEngine {

    static let shared = AudioMeterEngine()

    // MARK: Published meter state

    private(set) var isRunning = false
    /// Smoothed RMS level 0…1 (drives the segmented level bar).
    private(set) var level: Float = 0
    /// Peak-hold with slow decay (the floating cap on the level bar).
    private(set) var peakLevel: Float = 0
    /// 24 log-spaced band magnitudes 0…1, lows left → highs right.
    private(set) var spectrum: [Float] = Array(repeating: 0, count: 24)

    // MARK: Engine

    private var engine: AVAudioEngine?
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []
    private var windowed: [Float] = []
    private var splitRe: [Float] = []
    private var splitIm: [Float] = []
    private var magnitudes: [Float] = []
    /// Band → [fft bin indices] map (log-spaced edges, computed at tap time
    /// because the hardware sample rate isn't known until then).
    private var bandBins: [[Int]] = []

    private let bufferSize = 2048

    private init() {}

    // MARK: - Start / stop

    func start() {
        guard !isRunning else { return }
        let engine = AVAudioEngine()

        // Match Voice Notes: apply the user's chosen mic when set (validated —
        // stale IDs crash AVAudioEngine). The Whisper settings persist the
        // selection in UserDefaults (no singleton on the service), so read the
        // same key directly.
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
            guard let self else { return }
            let (rms, peak, bands) = self.process(buffer)
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.level = rms
                self.peakLevel = max(peak, self.peakLevel * 0.985)  // slow decay
                self.spectrum = bands
            }
        }

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            NSLog("[AudioMeter] engine start failed: \(error)")
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
        peakLevel = 0
        spectrum = Array(repeating: 0, count: 24)
    }

    // MARK: - DSP (tap thread — never allocate here)

    private func prepareDSP(sampleRate: Float) {
        let n = bufferSize
        fftSetup = vDSP.FFT(log2n: UInt(log2(Float(n))), radix: .radix2,
                            ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self,
                             usingSequence: .hanningDenormalized,
                             count: n, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: n)
        splitRe = [Float](repeating: 0, count: n / 2)
        splitIm = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)

        // 24 log-spaced bands 20 Hz → 20 kHz → FFT bin index groups.
        let binHz = sampleRate / Float(n)
        bandBins = (0..<24).map { band in
            let lo = 20.0 * pow(1000.0, Double(band) / 24.0)
            let hi = 20.0 * pow(1000.0, Double(band + 1) / 24.0)
            let loBin = max(1, Int(lo / Double(binHz)))
            let hiBin = min(n / 2 - 1, max(loBin + 1, Int(hi / Double(binHz))))
            return Array(loBin..<hiBin)
        }
    }

    /// RMS + peak + band magnitudes for one tap buffer. Runs on the audio
    /// thread; everything it touches was preallocated in prepareDSP.
    private func process(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float, bands: [Float]) {
        let frames = min(Int(buffer.frameLength), bufferSize)
        guard frames > 0, let channelData = buffer.floatChannelData,
              let fftSetup else { return (0, 0, spectrum) }

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

        // Forward FFT, then squared magnitudes bin-by-bin (a manual 1024-iter
        // loop — microseconds of work, no Accelerate signature surprises on
        // the real-time thread).
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

        // Band-average magnitudes → 0…1 with a −60 dB noise floor.
        var bands = [Float](repeating: 0, count: 24)
        for (band, bins) in bandBins.enumerated() {
            var sum: Float = 0
            for bin in bins { sum += magnitudes[bin] }
            let mean = sum / Float(max(1, bins.count))
            let db = 10 * log10(max(mean, 1e-12))
            bands[band] = max(0, min(1, (db + 60) / 60))
        }
        return (rms, peak, bands)
    }
}
