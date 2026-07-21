import Foundation
@preconcurrency import AVFoundation

/// Discovers available AUv3 audio effects on the system and applies a chain of
/// them to an audio file. The plugin list is driven by the standard macOS
/// AudioUnit component manager, so any installed AUv3 plugin (including effects
/// from the App Store or built-in Apple units) is usable without custom code.
@Observable
@MainActor
final class AudioEffectManager {
    private(set) var availableEffects: [AudioEffectUnit] = []
    private(set) var error: String?

    /// Load the list of available effects. This is synchronous on the component
    /// manager but may take a moment the first time it runs.
    func loadEffects() {
        let components = AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
        availableEffects = components.map { component in
            AudioEffectUnit(
                name: component.name,
                componentDescription: component.audioComponentDescription
            )
        }
    }

    /// Apply a chain of effects to an audio file, producing a new WAV file.
    /// Returns the output URL. The chain is processed in series.
    static func process(inputURL: URL, outputURL: URL, chain: [AudioEffectUnit]) async throws {
        guard !chain.isEmpty else {
            // No effects: just copy the input to the output.
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: inputURL, to: outputURL)
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let inputFile = try AVAudioFile(forReading: inputURL)
        let format = inputFile.processingFormat

        engine.attach(player)
        var previousNode: AVAudioNode = player
        var effectNodes: [AVAudioUnitEffect] = []

        for unit in chain {
            let effect = try await instantiateEffect(unit)
            effectNodes.append(effect)
            engine.attach(effect)
            engine.connect(previousNode, to: effect, format: format)
            previousNode = effect
        }

        engine.connect(previousNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: inputFile.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        engine.prepare()
        try engine.start()

        player.scheduleFile(inputFile, at: nil, completionCallbackType: .dataPlayedBack) { _ in }
        player.play()

        while engine.isRunning && player.isPlaying {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            let status = try engine.renderOffline(1024, to: buffer)
            if status == .success, buffer.frameLength > 0 {
                try outputFile.write(from: buffer)
            } else if status == .error {
                break
            }
        }

        player.stop()
        engine.stop()
    }

    // MARK: - Private

    private static func instantiateEffect(_ unit: AudioEffectUnit) async throws -> AVAudioUnitEffect {
        let description = unit.audioUnitDescription
        return try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
            AVAudioUnitEffect.instantiate(with: description, options: .loadOutOfProcess) { effect, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let effect = effect as? AVAudioUnitEffect else {
                    continuation.resume(throwing: AudioEffectManagerError.instantiationFailed(unit.name))
                    return
                }
                for (parameterID, value) in unit.parameters {
                    if let parameter = effect.auAudioUnit.parameterTree?.allParameters.first(where: { $0.address == parameterID }) {
                        parameter.value = AUValue(value)
                    } else if let parameter = effect.auAudioUnit.parameterTree?.parameter(withAddress: parameterID) {
                        parameter.value = AUValue(value)
                    }
                }
                continuation.resume(returning: effect)
            }
        }
    }
}

enum AudioEffectManagerError: Error, LocalizedError {
    case instantiationFailed(String)

    var errorDescription: String? {
        switch self {
        case .instantiationFailed(let name):
            return "Could not instantiate audio effect '\(name)'."
        }
    }
}
