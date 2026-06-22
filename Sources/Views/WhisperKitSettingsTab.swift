import SwiftUI
import WhisperKit

struct WhisperKitSettingsTab: View {
    @Environment(WhisperKitService.self) private var whisper
    @State private var showReloadAlert = false
    @State private var pendingModel = ""

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
            audioSection
            computeSection
            statusSection
        }
        .formStyle(.grouped)
        .alert("Reload Model", isPresented: $showReloadAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reload") {
                Task { await whisper.reloadModel(pendingModel) }
            }
        } message: {
            Text("Changing the model requires downloading and loading the new weights. This may take a moment.")
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
