import SwiftUI

// MARK: - Terminal Triggers View
//
// iTerm2-style trigger management: regex rules matched against completed
// lines of terminal output (shells and serial tabs alike), each firing a
// beep and/or a badge on the tab chip. Persisted via TerminalTriggerEngine.

struct TerminalTriggersView: View {
    @Bindable var engine: TerminalTriggerEngine

    @State private var newName = ""
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Triggers")
                .font(.headline)
            Text("When a line of terminal output matches a rule's regex, SwiftMaestro beeps and/or badges the tab until you focus it. ANSI colors are stripped before matching — write patterns against plain text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if engine.triggers.isEmpty {
                Text("No triggers yet. Common starters:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    starterButton("Errors", pattern: "(?i)\\berror\\b")
                    starterButton("Build failed", pattern: "BUILD FAILED")
                    starterButton("Test failures", pattern: "(?i)failed.*test|test.*failed")
                }
            } else {
                ForEach($engine.triggers) { $trigger in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $trigger.isEnabled)
                            .labelsHidden()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trigger.name).font(.subheadline)
                            Text(trigger.pattern)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Toggle("Beep", isOn: $trigger.beep)
                            .controlSize(.small)
                        Toggle("Badge", isOn: $trigger.badge)
                            .controlSize(.small)
                        Button(role: .destructive) {
                            engine.triggers.removeAll { $0.id == trigger.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .help("Delete this trigger")
                    }
                }
            }

            Divider()

            // Add rule
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name (e.g. Compile errors)", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("Regex pattern (e.g. (?i)\\berror\\b)", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                HStack {
                    if !newPattern.isEmpty && (try? NSRegularExpression(pattern: newPattern)) == nil {
                        Text("Invalid regex")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Add Trigger") {
                        let name = newName.isEmpty ? newPattern : newName
                        engine.triggers.append(TerminalTrigger(name: name, pattern: newPattern))
                        newName = ""
                        newPattern = ""
                    }
                    .disabled(newPattern.isEmpty || (try? NSRegularExpression(pattern: newPattern)) == nil)
                }
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    private func starterButton(_ name: String, pattern: String) -> some View {
        Button {
            engine.triggers.append(TerminalTrigger(name: name, pattern: pattern))
        } label: {
            HStack {
                Image(systemName: "plus.circle")
                Text("\(name) — \(pattern)")
                    .font(.caption.monospaced())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}
