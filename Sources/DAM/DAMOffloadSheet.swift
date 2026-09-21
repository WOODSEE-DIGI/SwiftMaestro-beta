import SwiftUI

// MARK: - Offload sheet

struct DAMOffloadSheet: View {
    @Bindable var viewModel: DAMViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var options = DAMOffloadOptions()
    @State private var showingResult = false
    @State private var offloadStartDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                destinationSection
                namingSection
                optionsSection

                if viewModel.isOffloading {
                    offloadProgressSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Offload Media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if viewModel.isOffloading {
                            viewModel.cancelOffload()
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Offload") {
                        viewModel.startOffload(options: options)
                    }
                    .disabled(!options.isValid || viewModel.isOffloading)
                }
            }
            .alert("Offload Complete", isPresented: $showingResult) {
                Button("Done") {
                    dismiss()
                }
            } message: {
                if let result = viewModel.offloadResult {
                    Text(resultMessage(for: result))
                }
            }
            .onChange(of: viewModel.isOffloading) { _, offloading in
                if offloading {
                    offloadStartDate = Date()
                }
                if !offloading, viewModel.offloadResult != nil {
                    showingResult = true
                }
            }
            .frame(minWidth: 520, minHeight: 540)
        }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        Section("Source") {
            HStack {
                Text(options.sourceURL?.path ?? "No source selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    chooseFolder(canChooseFiles: false) { url in
                        options.sourceURL = url
                    }
                }
            }
        }
    }

    private var destinationSection: some View {
        Section("Destinations") {
            HStack {
                Text(options.primaryDestinationURL?.path ?? "No primary destination selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    chooseFolder(canChooseFiles: false) { url in
                        options.primaryDestinationURL = url
                    }
                }
            }

            HStack {
                Text(options.backupDestinationURL?.path ?? "No backup destination (optional)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(options.backupDestinationURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") {
                    chooseFolder(canChooseFiles: false) { url in
                        options.backupDestinationURL = url
                    }
                }
                if options.backupDestinationURL != nil {
                    Button("Clear") {
                        options.backupDestinationURL = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var namingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Subfolder Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. {date}/{camera}", text: $options.subfolderTemplate)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Filename Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. {date}_{seq}_{camera}.{ext}", text: $options.filenameTemplate)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sequence Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Start", value: $options.sequenceStart, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Padding")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Padding", value: $options.sequencePadding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            templateTokens
        } header: {
            Text("Naming")
        }
    }

    private var templateTokens: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Available tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("{original}, {name}, {ext}, {date}, {date:FORMAT}, {time}, {seq}, {camera}, {cameramake}, {cameramodel}, {folder}")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Verify SHA-256 checksums", isOn: $options.verifyChecksums)
            Toggle("Import into catalog", isOn: $options.importIntoCatalog)
            Toggle("Eject source when done", isOn: $options.ejectSourceWhenDone)
        }
    }

    private var offloadProgressSection: some View {
        Section("Progress") {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    DAMThemeProgressOverlay(
                        message: viewModel.offloadProgress.phase.rawValue,
                        fraction: viewModel.offloadProgress.total > 0
                            ? viewModel.offloadProgress.fraction
                            : nil,
                        countText: viewModel.offloadProgress.total > 0
                            ? "\(viewModel.offloadProgress.completed) / \(viewModel.offloadProgress.total)"
                            : nil,
                        etaText: nil,
                        elapsedSeconds: context.date.timeIntervalSince(offloadStartDate),
                        currentItem: viewModel.offloadProgress.currentFile.isEmpty
                            ? nil
                            : viewModel.offloadProgress.currentFile,
                        secondaryFraction: nil,
                        secondaryCountText: nil,
                        secondaryEtaText: nil
                    )
                }

                Button("Cancel Offload", role: .destructive) {
                    viewModel.cancelOffload()
                }
                .disabled(!viewModel.isOffloading)
            }
        }
    }

    // MARK: - Helpers

    private func chooseFolder(canChooseFiles: Bool, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    private func resultMessage(for result: DAMOffloadResult) -> String {
        var parts: [String] = []
        parts.append("Copied \(result.copied) file(s).")
        if result.imported > 0 {
            parts.append("Imported \(result.imported) into the catalog.")
        }
        if !result.failed.isEmpty {
            parts.append("\(result.failed.count) failed:")
            for failure in result.failed.prefix(5) {
                parts.append("• \(failure.source.lastPathComponent): \(failure.error)")
            }
            if result.failed.count > 5 {
                parts.append("… and \(result.failed.count - 5) more.")
            }
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Preview

#Preview {
    DAMOffloadSheet(viewModel: DAMViewModel())
}
