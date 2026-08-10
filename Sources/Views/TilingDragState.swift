import SwiftUI
import UniformTypeIdentifiers

// MARK: - Custom UTType

extension UTType {
    /// Drag type for a SwiftMaestro workspace panel being moved between tiles.
    /// Declared as an exported UTI in `Info.plist`. Drag sources
    /// (`PanelDragGrip`) write a JSON-encoded `WorkspacePanelKind` under this
    /// type; drop destinations decode the same payload.
    static var workspacePanel: UTType {
        UTType(exportedAs: "com.woodseedigi.swiftmaestro.workspace-panel")
    }
}

// MARK: - Drag State

/// Shared state for the current drag-and-drop tiling operation. Lives outside
/// any single view so nested tiles can all read and update the same drop
/// target and preview zone.
@Observable
@MainActor
final class TilingDragState {
    static let shared = TilingDragState()

    /// The panel currently being dragged, if any.
    private(set) var draggedKind: WorkspacePanelKind?

    /// The panel currently under the drag cursor.
    private(set) var targetKind: WorkspacePanelKind?

    /// The drop zone relative to `targetKind` currently being previewed.
    private(set) var targetZone: TilingDropZone?

    /// Called by a tile when the drag enters, moves within, or leaves the tile.
    /// `zone` is `nil` when the drag leaves the tile.
    func updateTarget(kind: WorkspacePanelKind?, zone: TilingDropZone?) {
        if let kind, targetKind != kind {
            targetKind = kind
            targetZone = zone
        } else if targetKind == kind {
            targetZone = zone
        } else {
            targetKind = nil
            targetZone = nil
        }
    }

    /// Called by a tile the drag has left. Only clears the target when the
    /// exited tile IS the current target — entering tile B before tile A's
    /// exit event fires (the normal event order crossing a boundary) must not
    /// wipe B's fresh preview, and A's exit arriving after must not clear B.
    /// This is what prevented stale/overlapping highlights on tile edges.
    func clearTarget(ifCurrent kind: WorkspacePanelKind) {
        guard targetKind == kind else { return }
        targetKind = nil
        targetZone = nil
    }

    /// Called when the drag begins.
    func beginDrag(_ kind: WorkspacePanelKind) {
        draggedKind = kind
        targetKind = nil
        targetZone = nil
    }

    /// Called when the drag ends or is dropped.
    func endDrag() {
        draggedKind = nil
        targetKind = nil
        targetZone = nil
    }

    /// Whether the tile for `kind` should show a drop preview.
    func isPreviewing(kind: WorkspacePanelKind, zone: TilingDropZone) -> Bool {
        targetKind == kind && targetZone == zone
    }
}

// MARK: - Drop Zone Geometry

/// Computes the drop zone for a point inside a tile of the given size.
/// Layout: a center "stack here" rect plus a fixed-thickness band along each
/// of the four edges. Uniform bands matter: pure nearest-edge (Voronoi)
/// zoning made the left/right bands vanishingly thin on short row tiles, so
/// sub-columns ("2 apps side by side under 1") became almost impossible to
/// target once rows got short; and an earlier inverted axis comparison had
/// made top/bottom rows unreachable. Bands keep every direction easy to hit
/// regardless of the tile's aspect ratio; corners resolve by nearest edge.
enum TilingDropZoneGeometry {
    /// Fraction of the tile reserved for the center "stack here" region.
    static let centerFraction: CGFloat = 0.35

    /// Thickness of each edge's drop band, as a fraction of the tile's
    /// width (left/right) or height (top/bottom).
    static let edgeFraction: CGFloat = 0.28

    static func zone(for point: CGPoint, in size: CGSize) -> TilingDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let centerWidth = size.width * centerFraction
        let centerHeight = size.height * centerFraction
        let centerRect = CGRect(
            x: (size.width - centerWidth) / 2,
            y: (size.height - centerHeight) / 2,
            width: centerWidth,
            height: centerHeight
        )
        if centerRect.contains(point) { return .center }

        let inLeft = point.x < size.width * edgeFraction
        let inRight = point.x > size.width * (1 - edgeFraction)
        let inTop = point.y < size.height * edgeFraction
        let inBottom = point.y > size.height * (1 - edgeFraction)

        // Unambiguous single-band hits.
        if inLeft, !inTop, !inBottom { return .left }
        if inRight, !inTop, !inBottom { return .right }
        if inTop, !inLeft, !inRight { return .top }
        if inBottom, !inLeft, !inRight { return .bottom }

        // Corner overlap or the ring between band and center: nearest edge
        // wins. dx/dy are distances to the closest vertical (left/right) and
        // horizontal (top/bottom) edges — dx < dy means a vertical edge is
        // closer (this comparison was inverted originally, which confined
        // .top/.bottom to tiny corner triangles and made rows unstackable).
        let dx = min(point.x, size.width - point.x)
        let dy = min(point.y, size.height - point.y)
        if dx < dy {
            return point.x < size.width / 2 ? .left : .right
        } else {
            return point.y < size.height / 2 ? .top : .bottom
        }
    }

    /// The preview rectangle for `zone` within a tile of `size`.
    static func previewRect(for zone: TilingDropZone, in size: CGSize) -> CGRect {
        switch zone {
        case .center:
            let centerWidth = size.width * centerFraction
            let centerHeight = size.height * centerFraction
            return CGRect(
                x: (size.width - centerWidth) / 2,
                y: (size.height - centerHeight) / 2,
                width: centerWidth,
                height: centerHeight
            )
        case .left:
            return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:
            return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

