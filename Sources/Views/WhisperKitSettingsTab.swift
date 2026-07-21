import SwiftUI
import WhisperKit
import CoreAudio
import AppKit

struct WhisperKitSettingsTab: View {
    @Environment(WhisperKitService.self) private var whisper
    @State private var showReloadAlert = false
    @State private var pendingModel = ""
    @State private var inputDevices: [AudioDevice] = []
    @State private var outputDevices: [AudioDevice] = []
    @State private var effectManager = AudioEffectManager()

    private let modelOptions = [
        "openai_whisper-tiny",
        "openai_whisper-base",
        "openai_whisper-small",
        "openai_whisper-medium",
        "openai_whisper-large-v2",
        "openai_whisper-large-v3",
    ]

    private let languageOptions: [(name: String, code: String)] = [
        ("English", "en"),
        ("Chinese", "zh"),
        ("German", "de"),
        ("Spanish", "es"),
        ("French", "fr"),
        ("Japanese", "ja"),
        ("Korean", "ko"),
        ("Portuguese", "pt"),
        ("Russian", "ru"),
        ("Arabic", "ar"),
        ("Hindi", "hi"),
        ("Italian", "it"),
        ("Dutch", "nl"),
        ("Polish", "pl"),
        ("Turkish", "tr"),
        ("Vietnamese", "vi"),
        ("Swedish", "sv"),
        ("Indonesian", "id"),
        ("Thai", "th"),
        ("Czech", "cs"),
        ("Danish", "da"),
        ("Finnish", "fi"),
        ("Greek", "el"),
        ("Hebrew", "he"),
        ("Hungarian", "hu"),
        ("Norwegian", "no"),
        ("Romanian", "ro"),
        ("Ukrainian", "uk"),
        ("Croatian", "hr"),
        ("Bulgarian", "bg"),
        ("Catalan", "ca"),
        ("Malay", "ms"),
        ("Slovak", "sk"),
        ("Tamil", "ta"),
        ("Urdu", "ur"),
    ]

    var body: some View {
        Form {
            modelSection
            languageSection
            deviceSection
            audioSection
            saveSection
            effectSection
            computeSection
            statusSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert("Reload Model", isPresented: $showReloadAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reload") {
                Task { await whisper.reloadModel(pendingModel) }
            }
        } message: {
            Text("Changing the model requires downloading and loading the new weights. This may take a moment.")
        }
        .task {
            inputDevices = AudioDeviceManager.shared.inputDevices
            outputDevices = AudioDeviceManager.shared.outputDevices
            // Device IDs can become invalid when hardware is unplugged or the system
            // reboots. Normalize any stale persisted selection to a currently valid device.
            if let valid = AudioDeviceManager.shared.validInputDeviceID(whisper.selectedInputDeviceID) {
                whisper.selectedInputDeviceID = valid
            } else {
                whisper.selectedInputDeviceID = nil
            }
            if let valid = AudioDeviceManager.shared.validOutputDeviceID(whisper.selectedOutputDeviceID) {
                whisper.selectedOutputDeviceID = valid
            } else {
                whisper.selectedOutputDeviceID = nil
            }
        }
    }

    // MARK: - Sections

    private var modelSection: some View {
        Section("Model") {
            Picker("Whisper Model", selection: Binding(
                get: { whisper.selectedModel },
                set: { (newValue: String) in
                    if newValue != whisper.selectedModel {
                        pendingModel = newValue
                        showReloadAlert = true
                    }
                }
            )) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                switch whisper.modelState {
                case .unloaded:
                    Button(whisper.isModelDownloaded ? "Load" : "Download & Load") {
                        whisper.ensureModelLoaded()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                case .loading, .downloading:
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        whisper.cancelLoad()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                case .loaded:
                    Button("Unload") {
                        Task { await whisper.unloadModels() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Transcription Language", selection: Binding(
                get: { whisper.selectedLanguage },
                set: { (newValue: String) in whisper.selectedLanguage = newValue }
            )) {
                ForEach(languageOptions, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Voice Activity Detection (VAD)", isOn: Binding(
                get: { whisper.useVAD },
                set: { (newValue: Bool) in whisper.useVAD = newValue }
            ))
            .help("Skip silent audio chunks to save compute")

            VStack(alignment: .leading) {
                HStack {
                    Text("Silence Threshold")
                    Spacer()
                    Text(String(format: "%.2f", whisper.silenceThreshold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(whisper.silenceThreshold) },
                        set: { (newValue: Double) in whisper.silenceThreshold = Float(newValue) }
                    ),
                    in: 0.1...0.9,
                    step: 0.05
                )
            }
        }
    }

    private var deviceSection: some View {
        Section("Audio Devices") {
            Picker("Input Device", selection: Binding(
                get: { whisper.selectedInputDeviceID },
                set: { (newValue: AudioDeviceID?) in whisper.selectedInputDeviceID = newValue }
            )) {
                Text("System Default").tag(AudioDeviceID?.none)
                ForEach(inputDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .pickerStyle(.menu)
            .help("Microphone used for Whisper transcription")

            Picker("Output Device", selection: Binding(
                get: { whisper.selectedOutputDeviceID },
                set: { (newValue: AudioDeviceID?) in whisper.selectedOutputDeviceID = newValue }
            )) {
                Text("System Default").tag(AudioDeviceID?.none)
                ForEach(outputDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .pickerStyle(.menu)
            .help("Playback device used for audio output")

            Button("Refresh Devices") {
                inputDevices = AudioDeviceManager.shared.inputDevices
                outputDevices = AudioDeviceManager.shared.outputDevices
            }
            .controlSize(.small)
        }
    }

    private var saveSection: some View {
        Section("Save Locations") {
            Toggle("Save transcriptions to Notes.md", isOn: Binding(
                get: { whisper.saveTranscriptionsToNotes },
                set: { (newValue: Bool) in whisper.saveTranscriptionsToNotes = newValue }
            ))

            if whisper.saveTranscriptionsToNotes {
                TextField("Transcriptions folder", text: Binding(
                    get: { whisper.transcriptionsFolderName },
                    set: { (newValue: String) in whisper.transcriptionsFolderName = newValue }
                ))
            }

            Toggle("Save audio recordings", isOn: Binding(
                get: { whisper.saveAudioRecordings },
                set: { (newValue: Bool) in whisper.saveAudioRecordings = newValue }
            ))

            if whisper.saveAudioRecordings {
                TextField("Recordings folder", text: Binding(
                    get: { whisper.recordingsFolderName },
                    set: { (newValue: String) in whisper.recordingsFolderName = newValue }
                ))

                HStack {
                    Text("Location")
                    Spacer()
                    Text(pathPreview)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Choose recordings folder…") {
                    chooseRecordingsFolder()
                }
                .controlSize(.small)
            }
        }
    }

    private var effectSection: some View {
        Section("Audio Effect Chain (AUv3)") {
            if effectManager.availableEffects.isEmpty {
                HStack {
                    Text("No AUv3 effects discovered yet.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan") {
                        effectManager.loadEffects()
                    }
                    .controlSize(.small)
                }
            } else {
                if whisper.effectChain.isEmpty {
                    Text("No effects in chain. The original recording is saved.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(whisper.effectChain) { unit in
                        HStack {
                            Text(unit.name)
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") {
                                whisper.effectChain.removeAll { $0.id == unit.id }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                Menu("Add Effect…") {
                    ForEach(effectManager.availableEffects) { effect in
                        Button(effect.name) {
                            var unit = effect
                            unit.id = UUID()
                            whisper.effectChain.append(unit)
                        }
                    }
                }
                .controlSize(.small)
                .disabled(effectManager.availableEffects.isEmpty)
            }
        }
        .task {
            effectManager.loadEffects()
        }
    }

    private var computeSection: some View {
        Section("Compute") {
            Picker("Encoder Acceleration", selection: Binding(
                get: { whisper.encoderComputeUnits },
                set: { (newValue: String) in whisper.encoderComputeUnits = newValue }
            )) {
                Text("Neural Engine (Fastest)").tag("neuralEngine")
                Text("GPU").tag("gpu")
                Text("CPU Only").tag("cpu")
            }
            .pickerStyle(.menu)
        }
    }

    private var statusSection: some View {
        Section {
            if let error = whisper.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: - Helpers

    private var pathPreview: String {
        let base = whisper.recordingsSaveURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(whisper.recordingsFolderName).path
    }

    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save audio recordings"
        if panel.runModal() == .OK, let url = panel.url {
            whisper.recordingsSaveURL = url
        }
    }

    private var stateIcon: String {
        switch whisper.modelState {
        case .loaded: return "checkmark.circle.fill"
        case .loading, .downloading: return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private var stateColor: Color {
        switch whisper.modelState {
        case .loaded: return .green
        case .loading, .downloading: return .yellow
        default: return .secondary
        }
    }

    private var stateLabel: String {
        switch whisper.modelState {
        case .loaded: return "Model ready"
        case .loading: return "Loading model…"
        case .downloading: return "Downloading model…"
        case .prewarming: return "Prewarming model…"
        case .unloading: return "Unloading model…"
        case .unloaded: return "Model not loaded"
        case .prewarmed: return "Model prewarmed"
        case .downloaded: return "Model downloaded"
        @unknown default: return "Unknown state"
        }
    }
}
