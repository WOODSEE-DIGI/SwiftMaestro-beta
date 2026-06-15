import SwiftUI

/// First-run setup shown when no model is present. Instead of just describing
/// the app, it walks the tester through PICKING a model and DOWNLOADING +
/// LOADING it before the first message — so a fresh "hi" responds immediately
/// instead of silently triggering a multi-GB download. The sheet only closes via
/// its own buttons (it can't be dismissed out from under the user).
struct OnboardingView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine
    let onDone: () -> Void

    private enum Phase: Equatable {
        case choose
        case working
        case ready
        case failed(String)
    }

    @State private var selectedID: String = ""
    @State private var phase: Phase = .choose

    private var selectedModel: MaestroModel? { catalog.model(forID: selectedID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch phase {
            case .choose: chooseSection
            case .working: workingSection
            case .ready: readySection
            case .failed(let msg): failedSection(msg)
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled()
        .onAppear {
            if selectedID.isEmpty {
                selectedID = catalog.selectedModelID ?? ModelCatalog.defaultModelID
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to SwiftMaestro").font(.largeTitle.bold())
            Text("A fully on-device AI assistant. Models run locally on your Apple "
                + "Silicon Mac via Apple MLX — no servers, no accounts, and nothing "
                + "leaves your machine.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Choose

    private var chooseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Pick your model") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Model", selection: $selectedID) {
                        ForEach(catalog.models) { m in
                            Text("\(m.displayName) · ~\(m.estimatedMemoryGB) GB").tag(m.id)
                        }
                    }
                    .labelsHidden()
                    if let m = selectedModel {
                        Text("Downloads ~\(m.estimatedMemoryGB) GB once from Hugging Face, "
                            + "then loads into memory. Bigger models need more RAM — pick a "
                            + "smaller one for a faster first run.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Stored in \(ModelCatalog.modelsRoot) — change in Settings → Models.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
            HStack {
                Button("Skip for now") { onDone() }
                Spacer()
                Button("Download & Load") { startLoad() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedModel == nil)
            }
        }
    }

    // MARK: - Working (download + load)

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let progress = engine.downloadProgress {
                        ProgressView(value: progress.fractionCompleted) {
                            Text("Downloading \(selectedModel?.displayName ?? "model")…")
                        }
                        Text("\(Int(progress.fractionCompleted * 100))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView {
                            Text("Loading \(selectedModel?.displayName ?? "model") into memory…")
                        }
                    }
                    Text("Let this finish before sending your first message for an instant reply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Continue in background") { onDone() }
                Spacer()
            }
        }
    }

    // MARK: - Ready

    private var readySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(selectedModel?.displayName ?? "Model") is ready")
                            .font(.body.bold())
                        Text("Loaded into memory — your first message will respond right away.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Start chatting") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Failed

    private func failedSection(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn’t load the model", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Skip for now") { onDone() }
                Spacer()
                Button("Try again") { phase = .choose }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func startLoad() {
        guard let model = selectedModel else { return }
        // Persist the choice so chat uses this model, then download + load it so
        // it is resident before the first message.
        catalog.selectedModelID = model.id
        phase = .working
        Task {
            do {
                _ = try await engine.loadModel(model)
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
