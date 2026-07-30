import SwiftUI

// MARK: - Apps Settings Tab

/// Lets the user choose which apps and app categories appear in the Apps
/// launcher. Everything is on by default; disabling a category hides its whole
/// section, disabling an app hides just that row. This gates launcher
/// VISIBILITY only — it doesn't close already-open panels, and it doesn't
/// change which tools the agent can use (those are managed under Rules / MCP).
struct AppsSettingsTab: View {
    private var enablement = AppEnablementStore.shared
    @Environment(PluginService.self) private var pluginService

    /// Category / Plugins heading font — deliberately large so each section
    /// stands out from the per-app rows beneath it.
    private var categoryHeadingFont: Font { .system(size: 24, weight: .bold) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Apps Launcher") {
                    Text("Choose which apps appear in the Apps launcher panel. Turn off a whole category to hide its section, or turn off individual apps you don't use. This only changes what's shown in the launcher — it won't close panels that are already open, and it doesn't affect which tools the agent can call (those are managed under Rules and MCP).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                ForEach(AppCategory.allCases, id: \.self) { category in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(category.kinds, id: \.self) { kind in
                                Toggle(
                                    kind.staticDisplayName ?? kind.themeStorageKey,
                                    isOn: enablement.appBinding(for: kind)
                                )
                                .toggleStyle(.switch)
                                .disabled(!enablement.isCategoryEnabled(category))
                            }
                        }
                        .padding(8)
                    } label: {
                        HStack {
                            Text(category.title)
                                .font(categoryHeadingFont)
                            Spacer()
                            Toggle("Show \(category.title)", isOn: enablement.categoryBinding(for: category))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }

                if !pluginService.plugins.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pluginService.plugins) { manifest in
                                Toggle(manifest.name, isOn: enablement.pluginBinding(for: manifest.id))
                                    .toggleStyle(.switch)
                                    .disabled(!enablement.pluginsSectionEnabled)
                            }
                        }
                        .padding(8)
                    } label: {
                        HStack {
                            Text("Plugins")
                                .font(categoryHeadingFont)
                            Spacer()
                            Toggle("Show Plugins", isOn: enablement.pluginsSectionBinding())
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Enable All") { enablement.enableAll() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Preview

#Preview {
    AppsSettingsTab()
}
