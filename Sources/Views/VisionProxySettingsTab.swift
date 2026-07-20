import SwiftUI

struct VisionProxySettingsTab: View {
    @Environment(VisionProxyService.self) private var visionProxy
    @Environment(MLXInferenceEngine.self) private var engine

    @State private var testCaption = ""
    @State private var testStatus = ""
    @State private var isTesting = false
    @State private var pythonServerRunning = false

    private var providerOptions: [ModelCatalog.VisionProxyConfiguration.Provider] {
        ModelCatalog.VisionProxyConfiguration.Provider.allCases
    }

    var body: some View {
        @Bindable var visionProxy = visionProxy
        Form {
            Section {
                Toggle("Enable Vision Proxy", isOn: $visionProxy.config.isEnabled)
                    .help("Let non-vision models understand images by describing them through a vision model first.")

                Picker("Provider", selection: $visionProxy.config.provider) {
                    ForEach(providerOptions, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .help("In-Process MLX loads the configured vision model inside SwiftMaestro. Python Server runs the embedded vision proxy server as a subprocess.")
            } header: {
                Text("Vision Proxy")
            } footer: {
                Text("When enabled, images attached to a non-vision model are first routed through an MLX vision-language model (default: Qwen3-VL-8B-Instruct-4bit) to produce a text description. The description is then given to the chosen model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if visionProxy.config.provider == .inProcess {
                Section("In-Process Model") {
                    HStack {
                        TextField("Model path", text: $visionProxy.config.inProcessModelPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            pickInProcessModelPath()
                        }
                        .controlSize(.small)
                    }
                    .help("Path to a local MLX vision-language model (e.g., mlx-community/Qwen3-VL-8B-Instruct-4bit).")

                    HStack {
                        Text("Status")
                        Spacer()
                        let resolved = visionProxy.resolveModelPath()
                        let exists = resolved != nil
                        Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(exists ? .green : .yellow)
                        Text(exists ? "Model found at \(resolved!)" : "Model not found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Section("Python Server") {
                    HStack {
                        TextField("Server script", text: $visionProxy.config.serverScriptPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            pickServerScriptPath()
                        }
                        .controlSize(.small)
                    }
                    .help("Path to the embedded vision proxy server script.")

                    HStack {
                        TextField("Model path", text: $visionProxy.config.serverModelPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            pickServerModelPath()
                        }
                        .controlSize(.small)
                    }
                    .help("Path to the MLX vision-language model (e.g., mlx-community/Qwen3-VL-8B-Instruct-4bit).")

                    HStack {
                        Text("Host")
                        TextField("Host", text: $visionProxy.config.serverHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Text("Port")
                        TextField("Port", value: $visionProxy.config.serverPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    HStack {
                        Spacer()
                        Button(pythonServerRunning ? "Server Running" : "Start Server") {
                            Task { try? await visionProxy.startPythonServer() }
                        }
                        .disabled(pythonServerRunning)
                        .controlSize(.small)
                    }
                }
            }

            Section("Captioning") {
                TextEditor(text: $visionProxy.config.captionPrompt)
                    .frame(minHeight: 60)
                    .help("Prompt sent to the vision model for each image. Keep it short and specific for faster captions.")

                VStack(alignment: .leading) {
                    HStack {
                        Text("Max caption tokens")
                        Spacer()
                        Text("\(visionProxy.config.maxCaptionTokens)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(visionProxy.config.maxCaptionTokens) },
                            set: { visionProxy.config.maxCaptionTokens = Int($0) }
                        ),
                        in: 32...512,
                        step: 16
                    )
                }
            }

            Section("Test") {
                HStack {
                    Button("Select test image…") {
                        runTestCaption()
                    }
                    .disabled(isTesting)
                    .controlSize(.small)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !testStatus.isEmpty {
                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(testStatus.hasPrefix("Error") ? .red : .secondary)
                }

                if !testCaption.isEmpty {
                    TextEditor(text: .constant(testCaption))
                        .frame(minHeight: 80)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { checkServerStatus() }
        .onChange(of: visionProxy.config.provider) { _, _ in checkServerStatus() }
        .onChange(of: visionProxy.config.serverPort) { _, _ in checkServerStatus() }
        .onChange(of: visionProxy.config.serverHost) { _, _ in checkServerStatus() }
    }

    private func checkServerStatus() {
        Task {
            pythonServerRunning = await visionProxy.isPythonServerRunning
        }
    }

    // MARK: - Path pickers

    private func pickInProcessModelPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Model Directory"
        if panel.runModal() == .OK, let url = panel.url {
            visionProxy.config.inProcessModelPath = url.path
        }
    }

    private func pickServerScriptPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select vision proxy server script"
        if panel.runModal() == .OK, let url = panel.url {
            visionProxy.config.serverScriptPath = url.path
        }
    }

    private func pickServerModelPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select vision model directory"
        if panel.runModal() == .OK, let url = panel.url {
            visionProxy.config.serverModelPath = url.path
        }
    }

    // MARK: - Test caption

    private func runTestCaption() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Image"
        panel.allowedContentTypes = [.png, .jpeg, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            isTesting = true
            testCaption = ""
            testStatus = "Captioning…"
            defer { isTesting = false }

            do {
                let data = try Data(contentsOf: url)
                if let caption = try await visionProxy.caption(imageData: data) {
                    testCaption = caption
                    testStatus = "Caption ready."
                } else {
                    testStatus = "Vision proxy is disabled."
                }
            } catch {
                testStatus = "Error: \(error.localizedDescription)"
            }
        }
    }
}
