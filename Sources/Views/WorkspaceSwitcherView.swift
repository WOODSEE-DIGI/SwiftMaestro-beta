import SwiftUI

/// Hyprland-style workspace switcher: numbered buttons (1–0) in the toolbar.
/// Each button recalls the layout preset assigned to that slot.
/// Keyboard shortcuts: Cmd+1 through Cmd+9, Cmd+0 for the 10th slot.
struct WorkspaceSwitcherView: View {
    @Environment(ThemeStore.self) private var theme
    private let presetStore = WorkspaceLayoutPresetStore.shared

    private static let slotCount = 10

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...Self.slotCount, id: \.self) { slot in
                slotButton(slot)
            }
        }
    }

    @ViewBuilder
    private func slotButton(_ slot: Int) -> some View {
        let preset = presetStore.preset(forSlot: slot)
        let isActive = preset.map { presetStore.activePresetID == $0.id } ?? false
        let label = slot == 10 ? "0" : "\(slot)"

        Button {
            if let preset {
                presetStore.recall(preset.id)
            }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(isActive ? .white : theme.sidebarText)
                .frame(width: 22, height: 22)
                .background(
                    isActive
                        ? AnyShapeStyle(theme.accent)
                        : AnyShapeStyle(Color.secondary.opacity(0.12))
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(preset?.name ?? "Empty slot — save a layout here")
        .contextMenu {
            if let preset {
                Text(preset.name)
                Divider()
                Button("Overwrite with Current Layout") {
                    presetStore.saveToSlot(slot, name: preset.name)
                }
                Button("Rename…") {
                    // TODO: rename sheet
                }
                if !preset.isBuiltIn {
                    Button("Delete", role: .destructive) {
                        presetStore.delete(preset.id)
                    }
                }
            } else {
                Text("Empty Slot")
                Button("Save Current Layout Here…") {
                    presetStore.saveToSlot(slot)
                }
            }
        }
        .keyboardShortcut(
            KeyboardShortcut(
                KeyEquivalent(Character("\(slot == 10 ? 0 : slot)")),
                modifiers: [.command]
            )
        )
    }
}
