import Foundation
import SwiftUI
import CoreML
import CoreAudio
@preconcurrency import WhisperKit
import ArgmaxCore

typealias WKModelState = ArgmaxCore.ModelState

/// Manages WhisperKit speech-to-text: model lifecycle, microphone recording,
/// and real-time streaming transcription. Lazy-loaded on first use to avoid
/// slowing app startup or competing with MLX model loads for memory.
@Observable
@MainActor
final class WhisperKitService: @unchecked Sendable {
    var modelState: WKModelState = .unloaded
    var isRecording: Bool = false
    var currentText: String = ""
    var confirmedText: String = ""
    var unconfirmedText: String = ""
    var liveTranscription: String = ""
    var bufferEnergy: [Float] = []
    var errorMessage: String?
    /// Tracks download progress (nil when not downloading, 0.0–1.0 during download).
    var downloadProgress: Double?

    /// The transcribed text ready to be consumed by the chat input field.
    /// Set after recording stops; the consumer clears it after use.
    var pendingTranscription: String?

    private var whisperKit: WhisperKit?
    private var streamer: AudioStreamTranscriber?
    private var loadTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var silenceMonitorTask: Task<Void, Never>?
    private var lastVoiceDate: Date?
    private var voiceDetectedInRecording: Bool = false

    // MARK: - Settings (persisted via UserDefaults)

    private static let defaultsPrefix = "settings.whisperkit"

    var selectedModel: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "\(Self.defaultsPrefix).model")
            // Migrate old short names to full HuggingFace folder names
            switch stored {
            case "tiny": return "openai_whisper-tiny"
            case "base": return "openai_whisper-base"
            case "small": return "openai_whisper-small"
            case "medium": return "openai_whisper-medium"
            case "large-v2": return "openai_whisper-large-v2"
            case "large-v3": return "openai_whisper-large-v3"
            case .some(let v) where v.hasPrefix("openai_"): return v
            default: return "openai_whisper-large-v3"
            }
        }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).model") }
    }

    var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: "\(Self.defaultsPrefix).language") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).language") }
    }

    var silenceThreshold: Float {
        get { UserDefaults.standard.object(forKey: "\(Self.defaultsPrefix).silenceThreshold") != nil
            ? UserDefaults.standard.float(forKey: "\(Self.defaultsPrefix).silenceThreshold")
            : 0.3 }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).silenceThreshold") }
    }

    var useVAD: Bool {
        get { UserDefaults.standard.object(forKey: "\(Self.defaultsPrefix).useVAD") != nil
            ? UserDefaults.standard.bool(forKey: "\(Self.defaultsPrefix).useVAD")
            : true }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).useVAD") }
    }

    var encoderComputeUnits: String {
        get { UserDefaults.standard.string(forKey: "\(Self.defaultsPrefix).encoderCompute") ?? "neuralEngine" }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).encoderCompute") }
    }

    // MARK: - Audio Device Settings

    var selectedInputDeviceID: AudioDeviceID? {
        get {
            let value = UserDefaults.standard.integer(forKey: "\(Self.defaultsPrefix).inputDeviceID")
            return value == 0 ? nil : AudioDeviceID(value)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue), forKey: "\(Self.defaultsPrefix).inputDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "\(Self.defaultsPrefix).inputDeviceID")
            }
        }
    }

    var selectedOutputDeviceID: AudioDeviceID? {
        get {
            let value = UserDefaults.standard.integer(forKey: "\(Self.defaultsPrefix).outputDeviceID")
            return value == 0 ? nil : AudioDeviceID(value)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue), forKey: "\(Self.defaultsPrefix).outputDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "\(Self.defaultsPrefix).outputDeviceID")
            }
        }
    }

    // MARK: - Save Location Settings

    var saveTranscriptionsToNotes: Bool {
        get { UserDefaults.standard.object(forKey: "\(Self.defaultsPrefix).saveTranscriptionsToNotes") != nil
            ? UserDefaults.standard.bool(forKey: "\(Self.defaultsPrefix).saveTranscriptionsToNotes")
            : true }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).saveTranscriptionsToNotes") }
    }

    var saveAudioRecordings: Bool {
        get { UserDefaults.standard.bool(forKey: "\(Self.defaultsPrefix).saveAudioRecordings") }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).saveAudioRecordings") }
    }

    // MARK: - Voice input automation

    var autoStopAfterSilence: Bool {
        get { UserDefaults.standard.object(forKey: "\(Self.defaultsPrefix).autoStopAfterSilence") != nil
            ? UserDefaults.standard.bool(forKey: "\(Self.defaultsPrefix).autoStopAfterSilence")
            : true }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).autoStopAfterSilence") }
    }

    var autoStopSilenceSeconds: Double {
        get { UserDefaults.standard.object(forKey: "\(Self.defaultsPrefix).autoStopSilenceSeconds") != nil
            ? UserDefaults.standard.double(forKey: "\(Self.defaultsPrefix).autoStopSilenceSeconds")
            : 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).autoStopSilenceSeconds") }
    }

    var autoSendTranscription: Bool {
        get { UserDefaults.standard.object(forKey: "\(Self.defaultsPrefix).autoSendTranscription") != nil
            ? UserDefaults.standard.bool(forKey: "\(Self.defaultsPrefix).autoSendTranscription")
            : true }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).autoSendTranscription") }
    }

    // MARK: - Push to talk

    /// Virtual key code for the global push-to-talk hotkey (e.g. kVK_F13 = 105).
    /// 0 means disabled.
    var pushToTalkKeyCode: UInt16 {
        get { UInt16(UserDefaults.standard.integer(forKey: "\(Self.defaultsPrefix).pushToTalkKeyCode")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "\(Self.defaultsPrefix).pushToTalkKeyCode") }
    }

    var transcriptionsFolderName: String {
        get { UserDefaults.standard.string(forKey: "\(Self.defaultsPrefix).transcriptionsFolderName") ?? "Transcriptions" }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).transcriptionsFolderName") }
    }

    var recordingsFolderName: String {
        get { UserDefaults.standard.string(forKey: "\(Self.defaultsPrefix).recordingsFolderName") ?? "Recordings" }
        set { UserDefaults.standard.set(newValue, forKey: "\(Self.defaultsPrefix).recordingsFolderName") }
    }

    var recordingsSaveURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "\(Self.defaultsPrefix).recordingsPath"), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.path, forKey: "\(Self.defaultsPrefix).recordingsPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "\(Self.defaultsPrefix).recordingsPath")
            }
        }
    }

    /// Set by the host so transcribed notes can be saved to the SwiftMaestro internal Notes.md vault.
    var notesVaultURL: URL?

    /// Persistent AUv3 effect chain applied to saved recordings.
    var effectChain: [AudioEffectUnit] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "\(Self.defaultsPrefix).effectChain"),
                  let units = try? JSONDecoder().decode([AudioEffectUnit].self, from: data)
            else { return [] }
            return units
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "\(Self.defaultsPrefix).effectChain")
            }
        }
    }

    private var recordingWriter: AudioRecordingWriter?

    // MARK: - Model Loading

    /// Lazily load the WhisperKit model on first use. Subsequent calls are no-ops.
    /// On first run (model not on disk), downloads with progress tracking so the
    /// UI can show a setup dialog. On subsequent runs, loads silently.
    func ensureModelLoaded() {
        guard modelState == .unloaded else { return }
        guard loadTask == nil || loadTask?.isCancelled == true else { return }

        loadTask = Task {
            do {
                let needsDownload = !isModelDownloaded
                if needsDownload {
                    modelState = .downloading
                    downloadProgress = 0
                } else {
                    modelState = .loading
                }

                let computeOptions = ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: computeUnits(from: encoderComputeUnits),
                    textDecoderCompute: .cpuAndNeuralEngine,
                    prefillCompute: .cpuOnly
                )

                if needsDownload {
                    // Manual download with progress callback
                    let folder = try await WhisperKit.download(
                        variant: selectedModel,
                        progressCallback: { @Sendable [weak self] progress in
                            Task { @MainActor [weak self] in
                                self?.downloadProgress = progress.fractionCompleted
                            }
                        }
                    )
                    self.downloadProgress = nil

                    let config = WhisperKitConfig(
                        model: selectedModel,
                        modelFolder: folder.path,
                        computeOptions: computeOptions,
                        verbose: false,
                        logLevel: .error,
                        prewarm: false,
                        load: true,
                        download: false
                    )
                    let kit = try await WhisperKit(config)
                    self.whisperKit = kit
                } else {
                    // Already on disk — resolve the local folder path
                    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                        .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
                    let modelPath = base?.appendingPathComponent(selectedModel).path

                    let config = WhisperKitConfig(
                        model: selectedModel,
                        modelFolder: modelPath,
                        computeOptions: computeOptions,
                        verbose: false,
                        logLevel: .error,
                        prewarm: false,
                        load: true,
                        download: false
                    )
                    let kit = try await WhisperKit(config)
                    self.whisperKit = kit
                }

                self.modelState = .loaded
            } catch {
                self.modelState = .unloaded
                self.downloadProgress = nil
                let msg = "Failed to load WhisperKit model '\(selectedModel)': \(error.localizedDescription)"
                self.errorMessage = msg
                NSLog("[WhisperKit] \(msg)")
            }
        }
    }

    /// Force-reload with a different model. Unloads the current one first.
    func reloadModel(_ model: String) async {
        if let kit = whisperKit {
            await kit.unloadModels()
            self.whisperKit = nil
        }
        modelState = .unloaded
        selectedModel = model
        ensureModelLoaded()
        // Wait for load to finish
        await loadTask?.value
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        modelState = .unloaded
        errorMessage = "Download cancelled."
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard modelState == .loaded, let kit = whisperKit else {
            ensureModelLoaded()
            // Wait for model to finish loading, then start recording.
            Task { [weak self] in
                guard let self else { return }
                await self.loadTask?.value
                guard self.modelState == .loaded else {
                    self.errorMessage = "Model failed to load"
                    return
                }
                await MainActor.run { self.startRecording() }
            }
            return
        }

        // Clear any previous pending transcription
        pendingTranscription = nil

        Task {
            guard await AudioProcessor.requestRecordPermission() else {
                self.errorMessage = "Microphone access denied."
                return
            }

            let decodingOptions = DecodingOptions(
                task: .transcribe,
                language: selectedLanguage,
                skipSpecialTokens: true,
                wordTimestamps: true,
                chunkingStrategy: .vad
            )

            // Device IDs can change across reboots or when hardware is unplugged.
            // Passing an invalid ID to WhisperKit causes an AVAudioEngine crash
            // inside installTap (IsFormatSampleRateAndChannelCountValid).
            let validatedInputDeviceID = AudioDeviceManager.shared.validInputDeviceID(selectedInputDeviceID)
            if selectedInputDeviceID != nil, validatedInputDeviceID == nil {
                NSLog("[WhisperKit] Saved input device ID \(selectedInputDeviceID!) is no longer available; falling back to default input device.")
            }

            let streamer = AudioStreamTranscriber(
                audioEncoder: kit.audioEncoder,
                featureExtractor: kit.featureExtractor,
                segmentSeeker: kit.segmentSeeker,
                textDecoder: kit.textDecoder,
                tokenizer: kit.tokenizer!,
                audioProcessor: kit.audioProcessor,
                decodingOptions: decodingOptions,
                requiredSegmentsForConfirmation: 2,
                silenceThreshold: silenceThreshold,
                useVAD: useVAD,
                inputDeviceID: validatedInputDeviceID,
                audioBufferHandler: { [weak self] samples in
                    guard let self else { return }
                    Task {
                        try? await self.recordingWriter?.append(samples: samples)
                    }
                }
            ) { @Sendable [weak self] _, newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.bufferEnergy = newState.bufferEnergy

                    // Voice-activity tracking for auto-stop-on-silence.
                    if self.isRecording, let lastEnergy = newState.bufferEnergy.last, lastEnergy >= self.silenceThreshold {
                        self.voiceDetectedInRecording = true
                        self.lastVoiceDate = Date()
                    }

                    // Capture live text from progress (cleared after each window)
                    if !newState.currentText.isEmpty && newState.currentText != "Waiting for speech..." {
                        self.liveTranscription = newState.currentText
                    }

                    // Capture confirmed segments
                    let confirmed = newState.confirmedSegments.map { $0.text }.joined(separator: " ")
                    if !confirmed.isEmpty {
                        self.confirmedText = confirmed
                    }

                    // For short recordings, text lives in unconfirmed segments
                    let unconfirmed = newState.unconfirmedSegments.map { $0.text }.joined(separator: " ")
                    if !unconfirmed.isEmpty {
                        self.unconfirmedText = unconfirmed
                    }
                }
            }

            self.streamer = streamer
            self.isRecording = true
            self.currentText = ""
            self.confirmedText = ""
            self.unconfirmedText = ""
            self.liveTranscription = ""
            self.recordingStartTime = Date()
            self.lastVoiceDate = nil
            self.voiceDetectedInRecording = false
            self.startRecordingWriter()
            self.startSilenceMonitor()

            do {
                try await streamer.startStreamTranscription()
            } catch {
                self.isRecording = false
                self.errorMessage = error.localizedDescription
                NSLog("[WhisperKit] Recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        Task {
            await streamer?.stopStreamTranscription()
            self.isRecording = false

            // Prefer the longest text source — liveTranscription often contains
            // the full text (superset of confirmed+unconfirmed), so joining all
            // three causes duplication.
            let candidates = [confirmedText, unconfirmedText, liveTranscription]
                .filter { !$0.isEmpty && $0 != "Waiting for speech..." }
            let finalText = candidates
                .max(by: { $0.count < $1.count })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !finalText.isEmpty {
                self.pendingTranscription = finalText
                if self.saveTranscriptionsToNotes {
                    self.saveTranscriptionToNotes(finalText)
                }
            }

            if let writer = self.recordingWriter {
                let recordedURL = writer.fileURL
                try? await writer.close()
                self.recordingWriter = nil
                if !self.effectChain.isEmpty {
                    let processedURL = recordedURL.deletingPathExtension().appendingPathExtension("processed.wav")
                    do {
                        try await AudioEffectManager.process(inputURL: recordedURL, outputURL: processedURL, chain: self.effectChain)
                        try? FileManager.default.removeItem(at: recordedURL)
                        try? FileManager.default.moveItem(at: processedURL, to: recordedURL)
                    } catch {
                        self.errorMessage = "Audio effect processing failed: \(error.localizedDescription)"
                    }
                }
            }

            self.currentText = ""
            self.confirmedText = ""
            self.unconfirmedText = ""
            self.liveTranscription = ""
            self.streamer = nil
        }
    }

    // MARK: - Silence monitor

    private func startSilenceMonitor() {
        guard autoStopAfterSilence, autoStopSilenceSeconds > 0 else { return }
        silenceMonitorTask?.cancel()
        silenceMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
                guard await MainActor.run(body: { self.isRecording }) else { return }

                let shouldStop = await MainActor.run { () -> Bool in
                    guard self.voiceDetectedInRecording else { return false }
                    guard let lastVoice = self.lastVoiceDate else { return false }
                    return Date().timeIntervalSince(lastVoice) >= self.autoStopSilenceSeconds
                }

                if shouldStop {
                    await MainActor.run { self.stopRecording() }
                    return
                }
            }
        }
    }

    // MARK: - Saving

    private var defaultRecordingsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    private func startRecordingWriter() {
        guard saveAudioRecordings else { return }
        let baseURL = recordingsSaveURL ?? defaultRecordingsURL
        let folder = baseURL.appendingPathComponent(recordingsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let fileName = "Recording \(formatter.string(from: Date()))".replacingOccurrences(of: ":", with: "-") + ".wav"
        let fileURL = folder.appendingPathComponent(fileName)

        recordingWriter = AudioRecordingWriter(fileURL: fileURL, sampleRate: Double(WhisperKit.sampleRate))
        Task { try? await recordingWriter?.open() }
    }

    private func saveTranscriptionToNotes(_ text: String) {
        guard let vaultURL = notesVaultURL else { return }
        let folder = vaultURL.appendingPathComponent(transcriptionsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let title = "Transcription \(formatter.string(from: Date()))"
        let fileName = title.replacingOccurrences(of: ":", with: "-") + ".md"
        let fileURL = folder.appendingPathComponent(fileName)

        let content = "# \(title)\n\n\(text)\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Consume the pending transcription (clears it after reading).
    func consumeTranscription() -> String? {
        let text = pendingTranscription
        pendingTranscription = nil
        return text
    }

    // MARK: - Helpers

    private func computeUnits(from key: String) -> MLComputeUnits {
        switch key {
        case "cpu": return .cpuOnly
        case "gpu": return .cpuAndGPU
        case "neuralEngine": return .cpuAndNeuralEngine
        default: return .cpuAndNeuralEngine
        }
    }

    /// Unload models to free memory (e.g. before loading the 122B Qwen model).
    func unloadModels() async {
        if let kit = whisperKit {
            await kit.unloadModels()
        }
        whisperKit = nil
        streamer = nil
        modelState = .unloaded
    }

    /// Check if the model files exist on disk (already downloaded).
    var isModelDownloaded: Bool {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        guard let modelFolder = base?.appendingPathComponent(selectedModel) else { return false }
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        return required.allSatisfy { FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path) }
    }
}
