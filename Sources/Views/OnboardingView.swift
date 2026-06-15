import SwiftUI

/// First-run welcome shown only when no models are present on disk. Explains the
/// fully on-device model, that the first message downloads the selected model,
/// and where models are stored — then points to Settings.
struct OnboardingView: View {
    @Environment(ModelCatalog.self) private var catalog
    let onDone: () -> Void

    private var recommended: MaestroModel? { catalog.model(forID: ModelCatalog.defaultModelID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to SwiftMaestro").font(.largeTitle.bold())
                Text("A fully on-device AI assistant. Models run locally on your Apple "
                    + "Silicon Mac via Apple MLX — no servers, no accounts, and nothing "
                    + "leaves your machine.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Your first model") {
                VStack(alignment: .leading, spacing: 8) {
                    if let m = recommended {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName).font(.body.bold())
                                Text("Downloads once from Hugging Face on first use.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("~\(m.estimatedMemoryGB) GB").foregroundStyle(.secondary)
                        }
                    }
                    Text("No models are bundled, so your first message downloads the "
                        + "selected model. Smaller options (e.g. a ~3 GB 4B model) are "
                        + "available in Settings if you want a faster first run or have "
                        + "limited disk space.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Where models are stored") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ModelCatalog.modelsRoot)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                    Text("Change this in Settings → Models to reuse an existing model "
                        + "collection (e.g. on an external drive).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                SettingsLink { Text("Open Settings…") }
                Spacer()
                Button("Get Started") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
