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

    /// Only a panel drag is valid here, and only when the workspace is unlocked.
    /// Checking `hasItemsConforming` (rather than relying on shared drag state set
    /// at drag-start) makes the drop robust regardless of how the drag began.
    func validateDrop(info: DropInfo) -> Bool {
        !layout.isLocked && info.hasItemsConforming(to: [UTType.workspacePanel])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }

        let zone = TilingDropZoneGeometry.zone(for: info.location, in: tileSize)
        dragState.updateTarget(kind: targetKind, zone: zone)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dragState.updateTarget(kind: nil, zone: nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Clear the drop highlight immediately, before any validation, so it can
        // never linger after the mouse is released — even if the drop is rejected
        // (locked workspace, wrong payload) or routed here instead of a tile.
        dragState.endDrag()

        guard validateDrop(info: info) else { return false }

        let zone = TilingDropZoneGeometry.zone(for: info.location, in: tileSize)
        let providers = info.itemProviders(for: [UTType.workspacePanel])
        guard let provider = providers.first else { return false }

        // Hoist into Sendable locals so the @Sendable completion handler doesn't
        // capture `self` (whose `layout`/`dragState` members are non-Sendable).
        let target = targetKind

        // The payload is a JSON-encoded `WorkspacePanelKind` produced by the
        // `.draggable(WorkspacePanelTransfer)` drag source. Loading it is async,
        // so the actual tree mutation runs in the completion handler.
        provider.loadDataRepresentation(forTypeIdentifier: UTType.workspacePanel.identifier) { data, _ in
            guard let data,
                  let source = try? JSONDecoder().decode(WorkspacePanelKind.self, from: data)
            else { return }
            Task { @MainActor in
                let layout = WorkspaceLayoutState.shared
                guard source != target || layout.isFloating(target) else { return }
                layout.movePanel(source, to: target, zone: zone)
            }
        }
        return true
    }
}
