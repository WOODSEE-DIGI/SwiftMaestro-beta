import SwiftUI

// MARK: - OSINT Tool Settings Tab

/// Configuration UI for the local OSINT tools integrated from
/// `~/GitHub/OSINT-Cybersecurity`.
struct OSINTToolSettingsTab: View {
    @Environment(ThemeStore.self) private var theme

    @State private var config = ExternalOSINTToolConfig.load()
    @State private var toolStatuses: [ExternalOSINTTool: ToolStatus] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                ForEach(ExternalOSINTTool.allCases.filter(\.isSupported)) { tool in
                    toolRow(tool)
                }

                Spacer()
            }
            .padding()
        }
        .background(theme.chatBackground)
        .onAppear(perform: refreshStatuses)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OSINT Tools")
                .font(.title2.bold())

            Text("Configure paths to the local OSINT tools in ~/GitHub/OSINT-Cybersecurity. Disabled tools are hidden from the OSINT agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tool row

    private func toolRow(_ tool: ExternalOSINTTool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tool.displayName)
                        .font(.headline)

                    Spacer()

                    Toggle("Enabled", isOn: bindingEnabled(for: tool))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Text(tool.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("Path", text: bindingPath(for: tool))
                        .textFieldStyle(.roundedBorder)

                    Button {
                        choosePath(for: tool)
                    } label: {
                        Label("Choose…", systemImage: "folder")
                    }

                    statusBadge(for: tool)
                }

                if tool.requiresAuth {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .font(.caption2)
                        Text("Requires one-time login via Terminal: \(authCommand(for: tool))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }

    private func statusBadge(for tool: ExternalOSINTTool) -> some View {
        let status = toolStatuses[tool] ?? .unknown
        return Text(status.label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.18))
            .foregroundStyle(status.color)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Bindings

    private func bindingEnabled(for tool: ExternalOSINTTool) -> Binding<Bool> {
        Binding(
            get: { config.isEnabled(tool) },
            set: { enabled in
                if enabled {
                    config.disabled.remove(tool)
                } else {
                    config.disabled.insert(tool)
                }
                config.save()
                refreshStatus(for: tool)
            }
        )
    }

    private func bindingPath(for tool: ExternalOSINTTool) -> Binding<String> {
        Binding(
            get: { config.paths[tool] ?? tool.defaultPath },
            set: { newPath in
                let trimmed = newPath.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == tool.defaultPath {
                    config.paths.removeValue(forKey: tool)
                } else {
                    config.paths[tool] = trimmed
                }
                config.save()
                refreshStatus(for: tool)
            }
        )
    }

    // MARK: - Path picker

    private func choosePath(for tool: ExternalOSINTTool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = tool.isServer || tool == .socialAnalyzer
        panel.canChooseFiles = !panel.canChooseDirectories
        panel.message = "Select \(tool.displayName)"

        let current = (config.paths[tool] ?? tool.defaultPath) as NSString
        let expanded = current.expandingTildeInPath as NSString
        panel.directoryURL = URL(fileURLWithPath: expanded.deletingLastPathComponent)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.paths[tool] = url.path
        config.save()
        refreshStatus(for: tool)
    }

    // MARK: - Status refresh

    private func refreshStatuses() {
        for tool in ExternalOSINTTool.allCases.filter(\.isSupported) {
            refreshStatus(for: tool)
        }
    }

    private func refreshStatus(for tool: ExternalOSINTTool) {
        guard config.isEnabled(tool) else {
            toolStatuses[tool] = .disabled
            return
        }
        let path = (config.resolvedPath(for: tool) as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

        if tool == .socialAnalyzer {
            // social-analyzer can be a directory containing the Python package.
            toolStatuses[tool] = exists ? .found : .notFound
            return
        }

        if tool.isServer {
            toolStatuses[tool] = exists ? .found : .notFound
            return
        }

        if tool.rawValue == "gitfive" || tool.rawValue == "ghunt" {
            // These are expected to be on PATH (e.g. pipx-installed).
            toolStatuses[tool] = commandExistsOnPath(path) ? .found : .notFound
            return
        }

        toolStatuses[tool] = exists && !isDir.boolValue ? .found : .notFound
    }

    private func commandExistsOnPath(_ command: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [command]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return task.terminationStatus == 0 && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private func authCommand(for tool: ExternalOSINTTool) -> String {
        switch tool {
        case .gitfive: return "gitfive login"
        case .ghunt: return "ghunt login"
        default: return ""
        }
    }
}

// MARK: - Status model

private enum ToolStatus: Sendable {
    case found
    case notFound
    case disabled
    case unknown

    var label: String {
        switch self {
        case .found: return "Found"
        case .notFound: return "Not found"
        case .disabled: return "Disabled"
        case .unknown: return "Checking…"
        }
    }

    var color: Color {
        switch self {
        case .found: return .green
        case .notFound: return .red
        case .disabled: return .secondary
        case .unknown: return .orange
        }
    }
}
