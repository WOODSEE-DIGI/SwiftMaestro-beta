import XCTest
@testable import SwiftMaestro

/// Tests for tiling drag-and-drop: drop-zone hit-testing (the inverted
/// dominant-axis bug that made top/bottom rows unreachable) and the
/// LayoutNode remove/insert semantics behind stacking a 3rd row.
@MainActor
final class TilingDropZoneGeometryTests: XCTestCase {

    private let size = CGSize(width: 350, height: 430)

    // MARK: - Zone hit-testing (regression: inverted dominant axis)

    func testBottomCenterReturnsBottom() {
        // The user's exact gesture: dragging to the bottom of a tile to stack
        // a new row underneath. Used to return .right (a side-by-side split).
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: size.width / 2, y: size.height - 8), in: size)
        XCTAssertEqual(zone, .bottom)
    }

    func testTopCenterReturnsTop() {
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: size.width / 2, y: 8), in: size)
        XCTAssertEqual(zone, .top)
    }

    func testLeftMiddleReturnsLeft() {
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: 6, y: size.height / 2), in: size)
        XCTAssertEqual(zone, .left)
    }

    func testRightMiddleReturnsRight() {
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: size.width - 6, y: size.height / 2), in: size)
        XCTAssertEqual(zone, .right)
    }

    func testCenterReturnsCenter() {
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
        XCTAssertEqual(zone, .center)
    }

    func testBottomCenterOnWideShortTile() {
        // Wide tile: bottom-middle must still be .bottom, not .left/.right.
        let wide = CGSize(width: 900, height: 220)
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: 450, y: 210), in: wide)
        XCTAssertEqual(zone, .bottom)
    }

    func testBottomCenterOnNarrowTallTile() {
        let tall = CGSize(width: 180, height: 600)
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: 90, y: 590), in: tall)
        XCTAssertEqual(zone, .bottom)
    }

    // MARK: - Sub-columns on short row tiles ("2 apps under 1")
    //
    // Uniform edge bands keep left/right reachable no matter how short a row
    // tile gets — pure nearest-edge zoning shrank the side bands to nothing
    // on short tiles, so sub-columns were effectively removed.

    func testSubColumnLeftEdgeOnShortRowTile() {
        let rowTile = CGSize(width: 600, height: 180)
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: 20, y: 90), in: rowTile)
        XCTAssertEqual(zone, .left)
    }

    func testSubColumnRightEdgeOnShortRowTile() {
        let rowTile = CGSize(width: 600, height: 180)
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: 580, y: 90), in: rowTile)
        XCTAssertEqual(zone, .right)
    }

    func testRowStillWorksOnShortRowTile() {
        // Bottom of a short row tile must still stack a new row below.
        let rowTile = CGSize(width: 600, height: 180)
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: 300, y: 170), in: rowTile)
        XCTAssertEqual(zone, .bottom)
    }

    func testCornerResolvesToNearestEdge() {
        // Bottom-left corner of a wide tile: bottom edge is nearer than left.
        let size = CGSize(width: 900, height: 220)
        let zone = TilingDropZoneGeometry.zone(
            for: CGPoint(x: 30, y: 215), in: size)
        XCTAssertEqual(zone, .bottom)
    }

    func testZeroSizeFallsBackToCenter() {
        let zone = TilingDropZoneGeometry.zone(for: CGPoint(x: 5, y: 5), in: .zero)
        XCTAssertEqual(zone, .center)
    }

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

    // MARK: - Drag state: boundary-crossing race

    func testClearTargetOnlyClearsTheCurrentTile() {
        let state = TilingDragState()
        let tileA = WorkspacePanelKind.plugin("bluesky")
        let tileB = WorkspacePanelKind.plugin("patreon")

        state.beginDrag(.whatsapp)
        state.updateTarget(kind: tileB, zone: .bottom)
        // Tile A's exit event arrives AFTER B became the target — must not
        // wipe B's preview (the old updateTarget(nil) behavior did).
        state.clearTarget(ifCurrent: tileA)
        XCTAssertEqual(state.targetKind, tileB)
        XCTAssertEqual(state.targetZone, .bottom)

        // B's own exit clears as expected.
        state.clearTarget(ifCurrent: tileB)
        XCTAssertNil(state.targetKind)
        XCTAssertNil(state.targetZone)
    }
}
