import SwiftUI

// MARK: - SwiftWeaver View
//
// Shell for the SwiftWeaver panel: templates rail on the left, the
// Dreamweaver-style editor filling the rest. Clean-room replacement for
// OverlayBuilderView — no overlays, no sliders, no fixed-canvas machinery.

struct SwiftWeaverView: View {
    @State private var store = SwiftWeaverStore.shared

    var body: some View {
        HStack(spacing: 0) {
            templatesRail
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)
            Divider()
            SwiftWeaverEditorView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var templatesRail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("TEMPLATES")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                ForEach(WebsiteTemplates.all) { tpl in
                    Button {
                        store.applyWebsiteTemplate(tpl)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: tpl.icon)
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                Text(tpl.name).font(.subheadline)
                                Spacer()
                            }
                            Text(tpl.description)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .padding(.leading, 28)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }
}
