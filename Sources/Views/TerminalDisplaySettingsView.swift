import SwiftUI

// MARK: - Terminal Display Settings
//
// iTerm2-style appearance controls for the Live Terminal, shown from the
// shell tab strip's "Display…" button. Presets for one-click looks, plus
// individual font/size/color controls. Everything applies live to all open
// shells and persists via TerminalSettings.

struct TerminalDisplaySettingsView: View {
    @Bindable var settings: TerminalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Presets
            HStack {
                Text("Preset")
                    .frame(width: 90, alignment: .leading)
                Menu {
                    ForEach(TerminalSettings.presets, id: \.name) { preset in
                        Button(preset.name) {
                            settings.apply(preset)
                        }
                    }
                } label: {
                    Text("Choose…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 190)
            }

            Divider()

            // Font family + size
            HStack {
                Text("Font")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $settings.fontName) {
                    ForEach(TerminalSettings.availableMonospaceFonts, id: \.self) { family in
                        let psName = TerminalSettings.postScriptName(forFamily: family, size: settings.fontSize)
                        Text(family).tag(psName)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Stepper(value: Binding(
                    get: { settings.fontSize },
                    set: { settings.fontSize = min(24, max(9, $0)) }
                ), in: 9...24, step: 1) {
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Colors
            colorRow("Text", hex: Binding(
                get: { settings.foregroundHex },
                set: { settings.foregroundHex = $0 }
            ))
            colorRow("Background", hex: Binding(
                get: { settings.backgroundHex },
                set: { settings.backgroundHex = $0 }
            ))
            colorRow("Cursor", hex: Binding(
                get: { settings.cursorHex },
                set: { settings.cursorHex = $0 }
            ))

            Divider()

            // Live preview
            VStack(alignment: .leading, spacing: 2) {
                Text("$ swift run swiftmaestro")
                    .foregroundStyle(Color(nsColor: settings.foregroundColor))
                Text("BUILD SUCCEEDED — 24 band spectrum online")
                    .foregroundStyle(Color(nsColor: settings.foregroundColor).opacity(0.75))
                Text("block cursor █")
                    .foregroundStyle(Color(nsColor: settings.cursorColor))
            }
            .font(Font(settings.font))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: settings.backgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(14)
        .frame(width: 380)
    }

    private func colorRow(_ label: String, hex: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 90, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: TerminalSettings.nsColor(fromHex: hex.wrappedValue) ?? .white) },
                set: { hex.wrappedValue = TerminalSettings.hex(from: NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            Spacer()
        }
    }
}
