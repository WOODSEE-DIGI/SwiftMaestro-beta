import Foundation
@preconcurrency import AVFoundation
import Accelerate

// MARK: - Spectrum Analyzer
//
// Shared 24-band log-spaced spectrum computation (Accelerate vDSP FFT) used by
// both AudioMeterEngine (live monitor) and VoiceNotesStore (recording). All
// buffers are preallocated in prepare(); process() never allocates.
//
// NOT thread-safe by design: each owner calls process() from exactly one
// realtime tap thread. Do not share an instance across engines.

final class SpectrumAnalyzer: @unchecked Sendable {

    let bandCount: Int
    private let bufferSize: Int

    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []
    private var windowed: [Float] = []
    private var splitRe: [Float] = []
    private var splitIm: [Float] = []
    private var magnitudes: [Float] = []
    private var bandBins: [[Int]] = []

    init(bandCount: Int = 24, bufferSize: Int = 2048) {
        self.bandCount = bandCount
        self.bufferSize = bufferSize
    }

    /// Preallocate buffers and compute the log-spaced band-to-bin map.
    /// Call once per engine build, on the setup thread, before taps run.
    func prepare(sampleRate: Float) {
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

        // Log-spaced band edges 20 Hz to 20 kHz mapped to FFT bin index groups.
        let binHz = sampleRate / Float(n)
        bandBins = (0..<bandCount).map { band in
            let lo = 20.0 * pow(1000.0, Double(band) / Double(bandCount))
            let hi = 20.0 * pow(1000.0, Double(band + 1) / Double(bandCount))
            let loBin = max(1, Int(lo / Double(binHz)))
            let hiBin = min(n / 2 - 1, max(loBin + 1, Int(hi / Double(binHz))))
            return Array(loBin..<hiBin)
        }
    }

    /// Per-buffer band magnitudes, normalized 0...1 with a -60 dB floor.
    /// Call from the single tap thread that owns this analyzer.
    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = min(Int(buffer.frameLength), bufferSize)
        guard frames > 0, let channelData = buffer.floatChannelData,
              let fftSetup else {
            return Array(repeating: 0, count: bandCount)
        }

        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        for i in 0..<frames {
            windowed[i] = channelData[0][i * stride] * window[i]
        }
        for i in frames..<bufferSize { windowed[i] = 0 }

        // Flat per-property storage (never members of one struct) — nested
        // withUnsafe* scopes stay exclusivity-safe.
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

        var bands = [Float](repeating: 0, count: bandCount)
        for (band, bins) in bandBins.enumerated() {
            var sum: Float = 0
            for bin in bins { sum += magnitudes[bin] }
            let mean = sum / Float(max(1, bins.count))
            let db = 10 * log10(max(mean, 1e-12))
            bands[band] = max(0, min(1, (db + 60) / 60))
        }
        return bands
    }
}
