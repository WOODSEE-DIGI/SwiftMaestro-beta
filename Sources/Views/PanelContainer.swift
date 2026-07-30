import SwiftUI

// MARK: - Panel Container

/// Wraps each panel with a consistent header bar containing:
/// - Drag handle for reordering
/// - Panel title + icon
/// - Context menu (Move Left/Right, Pop Out, Hide)
/// - Close button
struct PanelContainer<Content: View>: View {

    let panelType: PanelType
    let agentId: UUID?
    @ViewBuilder let content: () -> Content
    var onClose: (() -> Void)? = nil
    var onFloat: ((PanelType) -> Void)? = nil

    @State private var layoutState = PanelLayoutState.shared
    @State private var isDragHovering = false
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isDragHovering ? Color.accentColor : Color.white.opacity(0.08),
                    lineWidth: isDragHovering ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 6) {
            // Drag handle
            Image(systemName: "circle.grid.2x2")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .onDrag {
                    NSItemProvider(object: panelType.rawValue as NSString)
                } preview: {
                    Text(panelType.displayName)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

            Image(systemName: panelType.icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(panelType.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            // Context menu
            Menu {
                contextMenuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)))
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        // Move actions
        if let idx = layoutState.mainSlots.firstIndex(where: { $0.type == panelType }) {
            if idx > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutState.movePanel(panelType, to: idx - 1)
                    }
                } label: {
                    Label("Move Left", systemImage: "arrow.left")
                }
            }
            if idx < layoutState.mainSlots.count - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutState.movePanel(panelType, to: idx + 2)
                    }
                } label: {
                    Label("Move Right", systemImage: "arrow.right")
                }
            }
        }

        Divider()

        // Pop out / dock
        if panelType.supportsFloat {
            if layoutState.isFloating(panelType) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutState.dock(panelType)
                    }
                } label: {
                    Label("Dock to Main Window", systemImage: "rectangle.on.rectangle")
                }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutState.float(panelType)
                        onFloat?(panelType)
                    }
                } label: {
                    Label("Pop Out to Window", systemImage: "rectangle.expand.vertical")
                }
            }
        }

        Divider()

        // Hide (only for non-essential panels)
        if panelType != .chat {
            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    layoutState.toggleVisibility(panelType)
                }
            } label: {
                Label("Hide Panel", systemImage: "eye.slash")
            }
        }
    }
}

// MARK: - Floating Panel Window

/// A standalone floating window for a popped-out panel.
struct FloatingPanelView<Content: View>: View {

    let panelType: PanelType
    @ViewBuilder let content: () -> Content
    @State private var layoutState = PanelLayoutState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header with dock button
            HStack(spacing: 6) {
                Image(systemName: panelType.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(panelType.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutState.dock(panelType)
                    }
                } label: {
                    Label("Dock", systemImage: "rectangle.on.rectangle")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Dock back to main window")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)))

            content()
        }
        .frame(minWidth: 300, minHeight: 300)
        .background(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)))
    }
}
