import SwiftUI

/// Right-side panel that displays one-click macro buttons for the current
/// agent. Built-in macros cannot be deleted; user macros can be edited or
/// removed. Includes an inline editor for creating and updating macros.
struct ChatMacrosPanel: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(MacroStore.self) private var macroStore
    let agent: AgentRecord
    let onRun: (AgentMacro) -> Void

    @State private var editingMacro: AgentMacro?
    @State private var showingAddSheet = false

    private var visibleMacros: [AgentMacro] {
        macroStore.macros(for: agent.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Text("\(visibleMacros.count)")
                    .font(.caption)
                    .foregroundStyle(theme.macrosPanelText.opacity(0.65))
                Button { showingAddSheet = true } label: {
                    Label("New Macro", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Create a new macro")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if visibleMacros.isEmpty {
                        Text("No macros for this agent type yet.")
                            .font(.caption)
                            .foregroundStyle(theme.chatSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(visibleMacros) { macro in
                            macroButton(for: macro)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.macrosPanel)
        .sheet(item: $editingMacro) { macro in
            MacroEditorSheet(
                macro: macro,
                isNew: false,
                onSave: { updated in
                    macroStore.update(
                        id: updated.id,
                        title: updated.title,
                        icon: updated.icon,
                        prompt: updated.prompt,
                        agentKinds: updated.agentKinds,
                        colorName: updated.colorName)
                    editingMacro = nil
                },
                onDelete: {
                    macroStore.delete(id: macro.id)
                    editingMacro = nil
                }
            )
        }
        .sheet(isPresented: $showingAddSheet) {
            MacroEditorSheet(
                macro: AgentMacro(title: "", icon: "bolt.fill", prompt: "", agentKinds: [agent.kind]),
                isNew: true,
                onSave: { newMacro in
                    macroStore.add(
                        title: newMacro.title,
                        icon: newMacro.icon,
                        prompt: newMacro.prompt,
                        agentKinds: newMacro.agentKinds)
                    showingAddSheet = false
                },
                onDelete: nil
            )
        }
    }

    private func macroButton(for macro: AgentMacro) -> some View {
        Button {
            onRun(macro)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: macro.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(macroColor(for: macro))
                    .frame(width: 18)
                Text(macro.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.macrosCardText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.macrosCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(macroColor(for: macro).opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Macro…") {
                editingMacro = macro
            }
            if !macro.isBuiltIn {
                Divider()
                Button("Delete", role: .destructive) {
                    macroStore.delete(id: macro.id)
                }
            }
        }
        .help(macro.prompt)
    }

    private func macroColor(for macro: AgentMacro) -> Color {
        guard let name = macro.colorName else { return theme.accent }
        switch name {
        case "blue": return .blue
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "cyan": return .cyan
        case "yellow": return .yellow
        default: return theme.accent
        }
    }
}

// MARK: - Macro Editor Sheet

struct MacroEditorSheet: View {
    let macro: AgentMacro
    let isNew: Bool
    let onSave: (AgentMacro) -> Void
    let onDelete: (() -> Void)?

    @Environment(ThemeStore.self) private var theme
    @State private var title: String = ""
    @State private var icon: String = "bolt.fill"
    @State private var prompt: String = ""
    @State private var selectedKinds: Set<AgentKind> = []
    @State private var colorName: String = "default"
    @Environment(\.dismiss) private var dismiss

    private let colorOptions = [
        ("default", "Default"),
        ("blue", "Blue"),
        ("green", "Green"),
        ("red", "Red"),
        ("orange", "Orange"),
        ("purple", "Purple"),
        ("pink", "Pink"),
        ("cyan", "Cyan"),
        ("yellow", "Yellow"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Macro" : "Edit Macro")
                .font(.title3.bold())

            Form {
                TextField("Title", text: $title)
                TextField("SF Symbol icon", text: $icon)
                Picker("Color", selection: $colorName) {
                    ForEach(colorOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .pickerStyle(.menu)

                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.chatSecondaryText.opacity(0.2), lineWidth: 1)
                    )

                Section("Show for agent kinds") {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Toggle(kind.displayName, isOn: Binding(
                            get: { selectedKinds.contains(kind) },
                            set: { isOn in
                                if isOn { selectedKinds.insert(kind) }
                                else { selectedKinds.remove(kind) }
                            }
                        ))
                    }
                }
            }

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var updated = macro
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.agentKinds = Array(selectedKinds)
                    updated.colorName = colorName == "default" ? nil : colorName
                    onSave(updated)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity)
        .frame(minHeight: 420)
        .onAppear {
            title = macro.title
            icon = macro.icon
            prompt = macro.prompt
            selectedKinds = Set(macro.agentKinds)
            colorName = macro.colorName ?? "default"
        }
    }
}

private extension AgentKind {
    var displayName: String {
        switch self {
        case .navigator: return "Maestro"
        case .project: return "Project agents"
        case .swiftHelper: return "Swift Helper"
        case .coder: return "Local Coder"
        case .onlineCoder: return "Online Coder"
        case .search: return "Searcher"
        }
    }
}

private extension AgentKind {
    static var allCases: [AgentKind] {
        [.navigator, .project, .swiftHelper, .coder, .onlineCoder, .search]
    }
}
