import XCTest
@testable import SwiftMaestro

/// Tests for the split-tree layout semantics behind stacking a 3rd row.
///
/// The drop-zone hit-testing and drag-state tests that used to live here
/// covered `TilingDropZoneGeometry` / `TilingDragState`, both removed with
/// the canvas/tiling system (panels are floating windows only now).
/// `LayoutNode` and `TilingDropZone` remain: they back the persisted legacy
/// tree blob and the `open_panel` zone parameter.
@MainActor
final class LayoutNodeTests: XCTestCase {

    // MARK: - LayoutNode: stacking a 3rd row in a column

    func testRemoveThenInsertBottomProducesThreeRows() {
        // Mirror the user's layout: right column = WhatsApp on top, then
        // Bluesky | Patreon side by side. Drag Patreon to .bottom of Bluesky.
        let bluesky = WorkspacePanelKind.plugin("bluesky")
        let patreon = WorkspacePanelKind.plugin("patreon")
        let tree = LayoutNode.split(
            axis: .vertical, ratio: 0.6,
            first: .leaf(.whatsapp),
            second: .split(axis: .horizontal, ratio: 0.5,
                           first: .leaf(bluesky), second: .leaf(patreon))
        )

        guard let removed = tree.removing(patreon) else {
            XCTFail("removing Patreon should leave a non-empty tree")
            return
        }
        // Removal collapses the now-single-child horizontal split.
        guard let blueskyPath = removed.path(to: bluesky) else {
            XCTFail("Bluesky must still be in the tree after Patreon's removal")
            return
        }
        let result = removed.inserting(patreon, at: blueskyPath, zone: .bottom)

        guard case .split(.vertical, _, let first, let second) = result else {
            XCTFail("expected the column's vertical split at the root, got \(result)")
            return
        }
        XCTAssertEqual(first, .leaf(.whatsapp), "WhatsApp stays on top")
        guard case .split(.vertical, _, let rowFirst, let rowSecond) = second else {
            XCTFail("expected Bluesky/Patreon stacked vertically, got \(second)")
            return
        }
        XCTAssertEqual(rowFirst, .leaf(bluesky), "Bluesky is the middle row")
        XCTAssertEqual(rowSecond, .leaf(patreon), "Patreon is the new bottom row")
    }

    func testDraggedPanelIsFirstSemantics() {
        XCTAssertEqual(TilingDropZone.top.draggedPanelIsFirst, true)
        XCTAssertEqual(TilingDropZone.bottom.draggedPanelIsFirst, false)
        XCTAssertEqual(TilingDropZone.left.draggedPanelIsFirst, true)
        XCTAssertEqual(TilingDropZone.right.draggedPanelIsFirst, false)
        XCTAssertNil(TilingDropZone.center.draggedPanelIsFirst)
    }
}
