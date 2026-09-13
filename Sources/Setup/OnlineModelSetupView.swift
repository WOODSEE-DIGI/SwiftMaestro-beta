import SwiftUI

struct OnlineModelSetupView: View {
    var onDone: () -> Void

    @State private var kind: MainAppRemoteProvider.Kind = .lmStudio
    @State private var presetID: String = ""
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var modelIDs: String = ""
    @State private var apiKey: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect a model source (optional)")
                .font(.headline)

            Text("If you already have a server or API key, enter it now and SwiftMaestro will be ready to use after install. You can also do this later in Settings → Models.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Provider kind", selection: $kind) {
                Text("LM Studio").tag(MainAppRemoteProvider.Kind.lmStudio)
                Text("Ollama").tag(MainAppRemoteProvider.Kind.ollama)
                Text("Online").tag(MainAppRemoteProvider.Kind.online)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { applyDefaults() }

            if kind == .online {
                Picker("Preset", selection: $presetID) {
                    Text("Custom").tag("")
                    ForEach(MainAppRemoteProviderPreset.presets) { Text($0.name).tag($0.id) }
                }
                .onChange(of: presetID) { _, newID in
                    guard let preset = MainAppRemoteProviderPreset.presets.first(where: { $0.id == newID }) else { return }
                    name = preset.name
                    baseURL = preset.baseURL
                    if modelIDs.isEmpty {
                        modelIDs = preset.suggestedModels.joined(separator: ", ")
                    }
                }
                if let preset = MainAppRemoteProviderPreset.presets.first(where: { $0.id == presetID }) {
                    Text(preset.keyHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField(baseURLPlaceholder, text: $baseURL)
                .textFieldStyle(.roundedBorder)

            TextField("Model IDs (comma separated)", text: $modelIDs)
                .textFieldStyle(.roundedBorder)

            SecureField(apiKeyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Text(apiKeyHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                }
            }

            Spacer()

            HStack {
                Button("Skip") {
                    onDone()
                }
                Spacer()
                Button("Save & Finish") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || baseURL.isEmpty || modelIDs.isEmpty || (kind == .online && apiKey.isEmpty))
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { applyDefaults() }
    }

    private var baseURLPlaceholder: String {
        switch kind {
        case .lmStudio: return "http://localhost:1234"
        case .ollama: return "http://localhost:11434"
        case .online: return "https://api.example.com/v1"
        }
    }

    private var apiKeyPlaceholder: String {
        switch kind {
        case .lmStudio: return "API key (optional — only if LM Studio server requires auth)"
        case .ollama: return "API key (optional — only if Ollama server requires auth)"
        case .online: return "API key"
        }
    }

    private var apiKeyHelp: String {
        switch kind {
        case .lmStudio, .ollama:
            return "Most local servers need no key. If yours requires authentication, the key is stored in the macOS Keychain and SwiftMaestro will use it automatically."
        case .online:
            if let preset = MainAppRemoteProviderPreset.presets.first(where: { $0.id == presetID }) {
                return "\(preset.keyHelp) The key is stored in the macOS Keychain."
            }
            return "For online providers, paste your API key here. It is stored in the macOS Keychain and used automatically."
        }
    }

    private func applyDefaults() {
        let presetNames = Set(MainAppRemoteProviderPreset.presets.map(\.name))
        let defaultNames = Set(["LM Studio", "Ollama", "Online (OpenAI-compatible)"] + Array(presetNames))
        if name.isEmpty || defaultNames.contains(name) {
            name = kind.rawValue
        }

        switch kind {
        case .lmStudio:
            if baseURL.isEmpty || baseURL == "http://localhost:11434" || isPresetBaseURL(baseURL) {
                baseURL = "http://localhost:1234"
            }
        case .ollama:
            if baseURL.isEmpty || baseURL == "http://localhost:1234" || isPresetBaseURL(baseURL) {
                baseURL = "http://localhost:11434"
            }
        case .online:
            if baseURL == "http://localhost:1234" || baseURL == "http://localhost:11434" || isPresetBaseURL(baseURL) {
                baseURL = ""
            }
            presetID = ""
        }
    }

    private func isPresetBaseURL(_ url: String) -> Bool {
        MainAppRemoteProviderPreset.presets.contains { $0.baseURL == url }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let ids = modelIDs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            errorMessage = "Enter at least one model ID."
            return
        }
        guard URL(string: trimmedURL) != nil else {
            errorMessage = "Enter a valid base URL."
            return
        }

        var apiKeyRef: String?
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            do {
                let secretName = "remote-\(trimmedName.lowercased().replacingOccurrences(of: " ", with: "-"))-api-key"
                apiKeyRef = try SetupSecretsStore.store(
                    name: secretName,
                    value: trimmedKey,
                    note: "API key for remote provider \(trimmedName)"
                )
            } catch {
                errorMessage = "Could not save API key to Keychain: \(error.localizedDescription)"
                return
            }
        }

        let provider = MainAppRemoteProvider(
            name: trimmedName,
            kind: kind,
            baseURL: trimmedURL,
            modelIDs: ids,
            apiKeyRef: apiKeyRef
        )
        do {
            try provider.writeToMainApp()
            onDone()
        } catch {
            errorMessage = "Could not save provider config: \(error.localizedDescription)"
        }
    }
}
