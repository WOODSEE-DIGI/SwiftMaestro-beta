import SwiftUI

/// Settings tab for managing user-created SwiftBrowser plugins.
/// Plugins include sidebar panels, toolbar-button extensions, and content scripts.
/// They live in `~/Library/Application Support/SwiftMaestro/BrowserExtensions/`
/// so they survive SwiftMaestro app updates.
struct PluginsSettingsTab: View {
    @Environment(ThemeStore.self) private var theme
    @State private var service = BrowserExtensionService.shared
    @State private var confirmUninstall: PluginManifest?
    @State private var showingInstallSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let error = service.lastError, !error.isEmpty {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if service.extensions.isEmpty {
                    emptyState
                } else {
                    extensionsList
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingInstallSheet) {
            BrowserExtensionInstallSheet()
                .frame(minWidth: 600, minHeight: 500)
        }
        .alert("Uninstall plugin?", isPresented: Binding(
            get: { confirmUninstall != nil },
            set: { if !$0 { confirmUninstall = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
            Button("Uninstall", role: .destructive) {
                if let ext = confirmUninstall {
                    _ = service.uninstall(id: ext.id)
                }
                confirmUninstall = nil
            }
        } message: {
            if let ext = confirmUninstall {
                Text("Remove \"\(ext.name)\" (\(ext.id))? This cannot be undone.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SwiftBrowser Plugins")
                .font(.title2.bold())

            Text("These plugins run inside SwiftBrowser only. They include toolbar buttons, content scripts, and browser sidebar panels. They are stored outside the app bundle so they survive SwiftMaestro updates. Agents can install them with the `install_browser_extension` tool.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(service.extensionsDir.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    NSWorkspace.shared.open(service.extensionsDir)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Button {
                    service.reload()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }

                Button {
                    showingInstallSheet = true
                } label: {
                    Label("Plugin Guide", systemImage: "plus")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Plugins",
            systemImage: "puzzlepiece.extension",
            description: Text("Ask Maestro to add a SwiftBrowser plugin, or drop a folder into the BrowserExtensions directory. Sidebar plugins like WhatsApp are managed separately.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var extensionsList: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(service.extensions) { manifest in
                ExtensionRow(
                    manifest: manifest,
                    service: service,
                    onUninstall: { confirmUninstall = manifest }
                )
            }
        }
    }
}

// MARK: - Row

private struct ExtensionRow: View {
    let manifest: PluginManifest
    let service: BrowserExtensionService
    let onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: manifest.host?.toolbar?.icon ?? manifest.icon)
                    .font(.title3)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name)
                        .font(.headline)
                    Text(manifest.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(manifest.type.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())

                Button(role: .destructive) {
                    onUninstall()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Uninstall extension")
            }

            HStack(spacing: 16) {
                LabeledValue(label: "Version", value: manifest.version)
                LabeledValue(label: "Entry", value: manifest.entry)
                if let path = manifest.contentRootURL?.path {
                    LabeledValue(label: "Path", value: path)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !manifest.capabilities.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(manifest.capabilities, id: \.self) { cap in
                        Text(cap.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }

            if let scripts = manifest.contentScripts, !scripts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content scripts")
                        .font(.caption.bold())
                    ForEach(scripts.indices, id: \.self) { i in
                        let script = scripts[i]
                        Text(script.matches.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !script.js.isEmpty {
                            Text("JS: \(script.js.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let css = script.css, !css.isEmpty {
                            Text("CSS: \(css.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Directory helper

private extension BrowserExtensionService {
    var extensionsDir: URL {
        SwiftMaestroPaths.browserExtensionsDir
    }
}

// MARK: - Install sheet (markdown guide)

private struct BrowserExtensionInstallSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var guideText: AttributedString {
        guard let url = Bundle.main.url(forResource: "BrowserExtensionGuide", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let attributed = try? AttributedString(
                markdown: raw,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else {
            return AttributedString("Could not load the extension guide.")
        }
        return attributed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SwiftBrowser Plugin Guide")
                    .font(.title2.bold())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                Text(guideText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 700, idealWidth: 800, maxWidth: .infinity,
               minHeight: 500, idealHeight: 700, maxHeight: .infinity)
    }
}

#Preview {
    PluginsSettingsTab()
        .environment(ThemeStore())
}
