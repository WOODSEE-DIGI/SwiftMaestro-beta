import AVFoundation
import Foundation
import Testing
@testable import SwiftMaestro

struct SpectrumAnalyzerTests {

    /// The 24 bands are laid over a fixed 20 Hz...20 kHz display range while the
    /// magnitude array only reaches Nyquist, so every sub-40 kHz rate used to
    /// invert a band's bin range and trap the process on recording start.
    /// A trap aborts the test run, so this fails loudly if the clamp regresses.
    @Test func prepareSurvivesRealWorldSampleRates() throws {
        let rates: [Float] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 96000]

        for rate in rates {
            let analyzer = SpectrumAnalyzer(bandCount: 24, bufferSize: 2048)
            analyzer.prepare(sampleRate: rate)

            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)
            )
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
            buffer.frameLength = 2048

            let bands = analyzer.process(buffer)
            #expect(bands.count == 24, "band count wrong at \(rate) Hz")
            for (index, level) in bands.enumerated() {
                #expect(level >= 0 && level <= 1, "band \(index) out of range at \(rate) Hz: \(level)")
            }
        }
    }

    /// A rate that can't produce a usable bin map must report silence, not trap.
    @Test func prepareRejectsDegenerateConfiguration() throws {
        for rate in [Float(0), -1, .nan, .infinity] {
            let analyzer = SpectrumAnalyzer(bandCount: 24, bufferSize: 2048)
            analyzer.prepare(sampleRate: rate)

            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
            )
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
            buffer.frameLength = 2048

            let bands = analyzer.process(buffer)
            #expect(bands == [Float](repeating: 0, count: 24), "expected silence for rate \(rate)")
        }
    }

    /// Re-preparing with a bad rate after a good one must not leave stale bands.
    @Test func prepareClearsStateOnFailure() throws {
        let analyzer = SpectrumAnalyzer(bandCount: 24, bufferSize: 2048)
        analyzer.prepare(sampleRate: 48000)
        analyzer.prepare(sampleRate: 0)

        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
        buffer.frameLength = 2048

        #expect(analyzer.process(buffer) == [Float](repeating: 0, count: 24))
    }
}
