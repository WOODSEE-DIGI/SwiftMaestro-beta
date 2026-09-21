import SwiftUI

// MARK: - Resizable sidebar section
//
// Capture One-style sidebar section: header with collapse/expand, content
// clipped to an adjustable height, and a draggable divider below it.

struct DAMSidebarSection<HeaderActions: View, Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    /// Fixed content height; nil makes the content fill available space.
    var height: CGFloat?
    let headerActions: HeaderActions
    let content: Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        height: CGFloat?,
        @ViewBuilder headerActions: () -> HeaderActions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.height = height
        self.headerActions = headerActions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    headerActions
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let height {
                    content
                        .frame(height: max(40, height))
                        .clipped()
                } else {
                    content
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Draggable divider

/// Horizontal divider that can be dragged up/down to resize adjacent sidebar
/// sections. Uses a translucent track with a visible handle so it feels like
/// Capture One / Xcode's inspector dividers.
struct DAMSidebarDivider: View {
    let onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.secondary.opacity(0.35) : Color.secondary.opacity(0.15))
            .frame(height: isHovering ? 3 : 1)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let delta = value.translation.height - lastTranslation
                        lastTranslation = value.translation.height
                        guard delta != 0 else { return }
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        lastTranslation = 0
                    }
            )
            .cursor(.resizeUpDown)
    }
}

// MARK: - Cursor modifier

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { isHovering in
            if isHovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        DAMSidebarSection(title: "Catalog", isExpanded: .constant(true), height: 120) {
            List {
                Text("All Assets")
                Text("Folder A")
                Text("Folder B")
            }
            .listStyle(.sidebar)
        }

        DAMSidebarDivider { _ in }

        DAMSidebarSection(title: "Volumes", isExpanded: .constant(true), height: 80) {
            List {
                Text("Macintosh HD")
                Text("External")
            }
            .listStyle(.sidebar)
        }
    }
    .frame(width: 240)
}
