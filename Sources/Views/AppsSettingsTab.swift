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
                    Text("Choose which apps appear in the Apps launcher panel. Turn off a whole category to hide its section, or turn off individual apps you don't use. Security: disabling an Apple app revokes the agent's access to that app's data and actions — the agent cannot read, create, or modify anything in it. It won't close panels that are already open. Non-Apple app tools are managed under Rules and MCP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                ForEach(AppCategory.allCases, id: \.self) { category in
                    if !category.isHidden {
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
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        // Built-in native panels grouped under Plugins in the
                        // launcher (WhatsApp, Discord) share the plugin
                        // toggles, keyed by themeStorageKey.
                        ForEach(AppCategory.builtInPluginKinds, id: \.self) { kind in
                            Toggle(
                                kind.staticDisplayName ?? kind.themeStorageKey,
                                isOn: enablement.pluginBinding(for: kind.themeStorageKey)
                            )
                            .toggleStyle(.switch)
                            .disabled(!enablement.pluginsSectionEnabled)
                        }
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
