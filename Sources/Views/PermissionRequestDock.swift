import SwiftUI

// MARK: - Permission Request Dock

/// A dock-style banner that appears when a tool needs runtime approval to
/// access a path outside the authorized folders. Offers Deny, Allow once, and
/// Allow always, matching OpenCode's permission prompt UX.
public struct PermissionRequestDock: View {
    @ObservedObject private var store = PermissionRequestStore.shared

    public init() {}

    public var body: some View {
        Group {
            if let request = store.currentRequest {
                dock(for: request)
            }
        }
    }

    @ViewBuilder
    private func dock(for request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: request.kind))
                    .foregroundStyle(.blue)
                    .imageScale(.large)
                Text(title(for: request))
                    .font(.headline)
                Spacer()
            }

            Text(subtitle(for: request))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let path = request.path, !path.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Path:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            if let root = request.requestedRoot, root != request.path {
                HStack(spacing: 4) {
                    Text("Will authorize:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(root)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 12) {
                Button("Deny") {
                    store.decide(.deny, for: request.id)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Allow Once") {
                    store.decide(.allowOnce, for: request.id)
                }
                .buttonStyle(.borderedProminent)

                Button("Allow Always") {
                    store.decide(.allowAlways, for: request.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(16)
        .background(Color.blue.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.blue, lineWidth: 2)
        )
        .padding(.horizontal)
        .padding(.top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(for request: PermissionRequest) -> String {
        "Folder Access Required"
    }

    private func subtitle(for request: PermissionRequest) -> String {
        let prefix = request.toolName
        switch request.kind {
        case .fileRead, .externalDirectory:
            return "\(prefix) wants to read a file outside the authorized folders."
        case .fileWrite:
            return "\(prefix) wants to write a file outside the authorized folders."
        case .directoryList:
            return "\(prefix) wants to list a directory outside the authorized folders."
        case .directoryCreate:
            return "\(prefix) wants to create a directory outside the authorized folders."
        case .fileDelete:
            return "\(prefix) wants to delete a file outside the authorized folders."
        case .fileCopy, .fileMove:
            return "\(prefix) wants to access files outside the authorized folders."
        case .tool:
            return "\(prefix) requires approval before it can run."
        }
    }

    private func iconName(for kind: PermissionKind) -> String {
        switch kind {
        case .fileRead, .externalDirectory: return "doc.text.fill"
        case .fileWrite: return "square.and.pencil"
        case .directoryList: return "folder.fill"
        case .directoryCreate: return "folder.badge.plus.fill"
        case .fileDelete: return "trash.fill"
        case .fileCopy, .fileMove: return "doc.on.doc.fill"
        case .tool: return "lock.shield.fill"
        }
    }
}

#Preview {
    VStack {
        PermissionRequestDock()
    }
    .frame(width: 600)
}
