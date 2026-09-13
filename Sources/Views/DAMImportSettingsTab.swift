import SwiftUI
import UniformTypeIdentifiers

/// Settings tab for importing metadata from other applications into MaestroDAM.
struct DAMImportSettingsTab: View {
    @Environment(ThemeStore.self) private var theme
    @StateObject private var importer = DAMFCPXMLImporter.shared

    @State private var showingFilePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import into MaestroDAM")
                    .font(.title2)

                importCard(
                    title: "Final Cut Pro / Premiere Pro (FCPXML)",
                    icon: "film",
                    description: "Both Final Cut Pro and Premiere Pro can export a project as FCPXML. The importer reads clip keywords and favorite/reject ratings, then merges them into the catalog by matching file paths."
                ) {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Choose FCPXML file…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importer.isImporting)
                }

                if importer.isImporting {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Importing…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding()
                    .cardBackground(theme: theme)
                }

                if let summary = importer.lastSummary {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Import complete", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        HStack {
                            Text("Assets matched:")
                            Spacer()
                            Text("\(summary.matched)")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Rows updated:")
                            Spacer()
                            Text("\(summary.updated)")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("New keywords:")
                            Spacer()
                            Text("\(summary.keywords)")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Flags set:")
                            Spacer()
                            Text("\(summary.flags)")
                                .monospacedDigit()
                        }
                        if summary.unmatched > 0 {
                            Divider()
                            Text("\(summary.unmatched) assets in the XML were not found in the catalog. Add their containing folder to MaestroDAM first, then re-import.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .cardBackground(theme: theme)
                }

                if let error = importer.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding()
                        .cardBackground(theme: theme)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "fcpxml") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importer.importFile(at: url) }
            case .failure(let error):
                importer.lastError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func importCard(
        title: String,
        icon: String,
        description: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            action()
        }
        .padding()
        .cardBackground(theme: theme)
    }
}

// MARK: - Card background helper

private struct CardBackground: ViewModifier {
    @Environment(ThemeStore.self) private var theme

    func body(content: Content) -> some View {
        content
            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15))
            )
    }
}

private extension View {
    func cardBackground(theme: ThemeStore) -> some View {
        modifier(CardBackground())
    }
}
