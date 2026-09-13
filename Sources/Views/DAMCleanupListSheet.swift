import SwiftUI
import AppKit

/// Sheet for reviewing and acting on the MaestroDAM cleanup queue.
struct DAMCleanupListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DAMCleanupListStore.shared
    @State private var selection: Set<UUID> = []
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup list")
                        .font(.title3.weight(.semibold))
                    Text("\(store.count) item(s) · \(formatBytes(store.totalSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(store.items.isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if store.items.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No items queued",
                    systemImage: "trash",
                    description: Text("Add folders from Storage Map to free up space.")
                )
                Spacer()
            } else {
                List(store.items, selection: $selection) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((item.path as NSString).lastPathComponent)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text(item.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(formatBytes(item.size))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Button {
                            revealInFinder(path: item.path)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")

                        Button {
                            store.remove(id: item.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove from list")
                    }
                    .tag(item.id)
                    .contextMenu {
                        Button("Show in Finder") { revealInFinder(path: item.path) }
                        Button("Remove") { store.remove(id: item.id) }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { items in
                    Button("Remove selected") {
                        store.remove(items: items)
                    }
                } primaryAction: { _ in }

                HStack {
                    Button("Clear list") {
                        store.clear()
                    }
                    .disabled(store.items.isEmpty)

                    Spacer()

                    Text("Total: \(formatBytes(store.totalSize))")
                        .font(.caption.weight(.semibold))
                }
                .padding()
            }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 320, idealHeight: 480)
        .confirmationDialog(
            "Move \(store.count) item(s) to Trash?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                moveAllToTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will free up \(formatBytes(store.totalSize)). You can still restore items from Trash.")
        }
    }

    private func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func moveAllToTrash() {
        let urls = store.items.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.recycle(urls) { _, error in
            DispatchQueue.main.async {
                if let error {
                    // Keep items so the user can retry; surface the error via a future alert.
                    NSLog("[DAMCleanupList] recycle failed: %@", error.localizedDescription)
                } else {
                    store.clear()
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    DAMCleanupListSheet()
}
