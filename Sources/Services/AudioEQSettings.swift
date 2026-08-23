import Foundation
@preconcurrency import AVFoundation

// MARK: - Shared EQ Settings
//
// The 8-band graphic EQ edited in the Audio Control panel's retro slider bank
// and applied to the Voice Notes recording chain. Persisted to UserDefaults as
// JSON. Band frequencies follow classic console spacing with a voice-friendly
// middle.

@Observable
@MainActor
final class AudioEQSettings {

    static let shared = AudioEQSettings()

    /// Band center frequencies (Hz) — console-style spacing, voice in the middle.
    /// Constant table: nonisolated so the EQ unit builder (off-actor) can read it.
    nonisolated static let bandFrequencies: [Float] = [60, 150, 400, 1000, 2400, 6000, 12000, 15000]

    /// Gain per band in dB, clamped ±12.
    var gains: [Float] {
        didSet { persist() }
    }
    /// Master bypass (EQ node stays in the chain but passes audio through).
    var isBypassed: Bool {
        didSet { persist() }
    }

    private let key = "audioEQ.settings.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: "audioEQ.settings.v1"),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            gains = decoded.gains
            isBypassed = decoded.isBypassed
        } else {
            gains = Array(repeating: 0, count: Self.bandFrequencies.count)
            isBypassed = false
        }
    }

    private struct Persisted: Codable {
        var gains: [Float]
        var isBypassed: Bool
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(
            Persisted(gains: gains, isBypassed: isBypassed)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Presets

    enum Preset: String, CaseIterable, Sendable {
        case flat = "Flat"
        case voiceBoost = "Voice Boost"
        case warm = "Warm"
        case bright = "Bright"
        case radio = "Radio"

        /// Gains per band (dB) matching bandFrequencies.
        var gains: [Float] {
            switch self {
            case .flat:       return [0, 0, 0, 0, 0, 0, 0, 0]
            case .voiceBoost: return [-4, -2, 0, +3, +4, +2, 0, -2]   // presence 1–2.4k
            case .warm:       return [+4, +3, +1, 0, -1, -2, -3, -4]  // lows up, highs down
            case .bright:     return [-3, -1, 0, +1, +2, +4, +4, +3]  // air up top
            case .radio:      return [-12, -6, +2, +4, +3, -2, -8, -12] // midrange honk
            }
        }
    }

    func apply(_ preset: Preset) {
        gains = preset.gains
        if preset != .flat { isBypassed = false }
    }

    // MARK: - AVAudioUnitEQ construction

    /// Sendable snapshot for crossing the actor boundary (EQ units are
    /// non-Sendable and must be built off the main actor).
    struct EQSnapshot: Sendable {
        var gains: [Float]
        var isBypassed: Bool
    }

    var snapshot: EQSnapshot { EQSnapshot(gains: gains, isBypassed: isBypassed) }

    /// Build a parametric EQ unit from a snapshot — nonisolated so the
    /// non-Sendable AU never crosses the actor boundary. Insert between the
    /// input node and the tap/writer so meters show the EQ'd signal.
    nonisolated static func makeEQUnit(from snapshot: EQSnapshot) -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
        for (index, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.bandFrequencies[index]
            band.bandwidth = 1.0   // ~1 octave — console-like
            band.gain = snapshot.isBypassed ? 0 : snapshot.gains[index]
            band.bypass = snapshot.isBypassed
        }
        eq.globalGain = 0
        return eq
    }
}
