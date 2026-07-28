import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tiling Drop Delegate

/// Drop delegate attached to each tile. It provides continuous hover feedback
/// (drop zone + neon preview) and finalizes the move into the binary tree.
@MainActor
struct TilingDropDelegate: DropDelegate {
    let targetKind: WorkspacePanelKind
    let layout: WorkspaceLayoutState
    let dragState: TilingDragState
    let tileSize: CGSize

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard !layout.isLocked else { return DropProposal(operation: .forbidden) }
        guard let source = dragState.draggedKind else { return DropProposal(operation: .forbidden) }
        guard source != targetKind || layout.isFloating(targetKind) else { return DropProposal(operation: .forbidden) }

        let zone = TilingDropZoneGeometry.zone(for: info.location, in: tileSize)
        dragState.updateTarget(kind: targetKind, zone: zone)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dragState.updateTarget(kind: nil, zone: nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard !layout.isLocked else { return false }
        guard let source = dragState.draggedKind else { return false }
        guard source != targetKind || layout.isFloating(targetKind) else { return false }

        let zone = TilingDropZoneGeometry.zone(for: info.location, in: tileSize)
        layout.movePanel(source, to: targetKind, zone: zone)
        dragState.endDrag()
        return true
    }
}

// MARK: - NSItemProvider Convenience

extension NSItemProvider {
    /// Returns a provider carrying a JSON-encoded `WorkspacePanelKind`.
    static func workspacePanel(_ kind: WorkspacePanelKind) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(kind)) ?? Data()
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.workspacePanel.identifier)
        return provider
    }
}
