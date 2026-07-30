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
/// The tile is divided into a center square plus four edge/corner regions.
/// The center region is 40% of the tile; the remainder is split among the four
/// cardinal directions, making the preview feel crisp and quadrant-like.
enum TilingDropZoneGeometry {
    /// Fraction of the tile reserved for the center "stack here" region.
    static let centerFraction: CGFloat = 0.35

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

        // Outside the center: decide by the dominant axis.
        let dx = min(point.x, size.width - point.x)
        let dy = min(point.y, size.height - point.y)
        if dx > dy {
            // Closer to a vertical edge -> left/right.
            return point.x < size.width / 2 ? .left : .right
        } else {
            // Closer to a horizontal edge -> top/bottom.
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

