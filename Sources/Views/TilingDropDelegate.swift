import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tiling Drop Delegate

/// Drop delegate attached to each tile. It provides continuous hover feedback
/// (drop zone + neon preview) and finalizes the move into the binary tree.
///
/// Same-process drags (the normal case — every drag starts at a
/// `PanelDragGrip`) record their source in `TilingDragState`, so the drop is
/// applied synchronously and the panel docks exactly where the neon preview
/// was showing. The pasteboard decode path is kept only as a defensive
/// fallback for drags whose source we never saw.
@MainActor
struct TilingDropDelegate: DropDelegate {
    let targetKind: WorkspacePanelKind
    let layout: WorkspaceLayoutState
    let dragState: TilingDragState
    let tileSize: CGSize

    /// Only a panel drag is valid here, and only when the workspace is
    /// unlocked. A tile dropped onto itself is meaningless — forbidden so the
    /// cursor shows the no-entry badge and no highlight appears (only
    /// knowable for same-process drags, which record their source).
    func validateDrop(info: DropInfo) -> Bool {
        guard !layout.isLocked, info.hasItemsConforming(to: [UTType.workspacePanel]) else {
            return false
        }
        if dragState.draggedKind == targetKind { return false }
        return true
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
        // Capture the source and the LAST HIGHLIGHTED zone before clearing
        // drag state — the panel must dock where the neon preview was, which
        // can differ by a pixel from wherever the mouse happens to be
        // released (e.g. released right on a zone boundary).
        let source = dragState.draggedKind
        let zone = (dragState.targetKind == targetKind ? dragState.targetZone : nil)
            ?? TilingDropZoneGeometry.zone(for: info.location, in: tileSize)
        dragState.endDrag()

        guard validateDrop(info: info) else { return false }

        // Same-process drag: the payload is already known, so mutate the tree
        // synchronously — the dock is visible the instant the mouse is
        // released, not after an async pasteboard round-trip.
        if let source {
            guard source != targetKind || layout.isFloating(source) else { return false }
            layout.movePanel(source, to: targetKind, zone: zone)
            return true
        }

        // Defensive fallback: a drag whose source was never recorded (should
        // not happen now that the grip owns the session). Decode the payload
        // off the pasteboard; the tree mutation runs in the completion.
        let providers = info.itemProviders(for: [UTType.workspacePanel])
        guard let provider = providers.first else { return false }

        // Hoist into Sendable locals so the @Sendable completion handler
        // doesn't capture `self` (whose members are non-Sendable).
        let target = targetKind
        provider.loadDataRepresentation(forTypeIdentifier: UTType.workspacePanel.identifier) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(WorkspacePanelKind.self, from: data)
            else { return }
            Task { @MainActor in
                let layout = WorkspaceLayoutState.shared
                guard payload != target || layout.isFloating(target) else { return }
                layout.movePanel(payload, to: target, zone: zone)
            }
        }
        return true
    }
}

// MARK: - Workspace Background Drop Delegate

/// Drop delegate for the workspace background itself. Only accepts drops when
/// the workspace is EMPTY (every panel is floating): dropping anywhere docks
/// the dragged panel as the new root tile. With a non-empty layout the tiles
/// tile the whole area and handle their own drops, so the background forbids.
@MainActor
struct WorkspaceBackgroundDropDelegate: DropDelegate {
    let layout: WorkspaceLayoutState
    let dragState: TilingDragState

    func validateDrop(info: DropInfo) -> Bool {
        !layout.isLocked
            && layout.root == nil
            && info.hasItemsConforming(to: [UTType.workspacePanel])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Capture the source before clearing drag state. `endDrag` here is a
        // no-op when the grip's session already ended, but keeps the state
        // machine correct if this drop is routed without one.
        let source = dragState.draggedKind
        dragState.endDrag()

        guard validateDrop(info: info), let source else { return false }
        layout.dockAsRoot(source)
        return true
    }
}
