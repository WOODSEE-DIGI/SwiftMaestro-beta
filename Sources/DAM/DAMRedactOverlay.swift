import AppKit
import SwiftUI

// MARK: - Redaction overlay
//
// Multi-box redaction editor drawn over the fitted preview: drag on empty
// area to draw a box of the current kind (blackout/blur), tap a box to
// select it, drag inside to move it, corner handles on the SELECTED box to
// resize. Modal like the crop tool — DAMEditView installs it only while the
// Redact tool is armed, so ordinary clicks never draw boxes. Coordinates
// are normalized 0…1 in the DISPLAYED frame (same top-left-origin space as
// the crop rect — the renderer flips y when mapping into CIImage).

struct DAMRedactOverlay: View {
    /// The recipe's redaction boxes (live-edited during drags).
    @Binding var boxes: [DAMEditState.RedactionBox]
    /// The pixel size of the rendered image (for aspect + fitted-rect math).
    let imageSize: CGSize
    /// The kind applied to newly drawn boxes.
    let kind: DAMEditState.RedactionBox.Kind
    /// The selected box — shared with the Edit controls (Delete key/button).
    @Binding var selectedID: UUID?
    /// Called on every drag frame with the updated boxes.
    let onChange: () -> Void
    /// Called once when a drag ends (persist + re-render here, not per frame).
    let onEnd: () -> Void

    /// In-progress drag-to-draw rect (not yet committed to `boxes`).
    @State private var draftStart: CGPoint?
    @State private var draftRect: DAMEditState.CropRect?

    /// The box rect captured when a move drag STARTED. The drag delta is
    /// applied to this origin — never to the live rect. Applying the full
    /// delta to the live (already-moved) rect on every event compounds the
    /// movement and flings the box to an edge — that was the "box jumps
    /// erratically" bug.
    @State private var moveOrigin: (id: UUID, rect: DAMEditState.CropRect)?

    /// Handle hit-target size (view points).
    private let handleSize: CGFloat = 18
    /// Minimum box size (fraction of frame) — redactions can be small.
    private let minSize = 0.02

    var body: some View {
        GeometryReader { proxy in
            let fitted = DAMCropOverlay.fittedRect(imageSize: imageSize, in: proxy.size)
            ZStack(alignment: .topLeading) {
                // Background: drag draws a new box; tap deselects.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = nil }
                    .gesture(drawGesture(fitted: fitted))

                // Committed boxes.
                ForEach(boxes) { box in
                    if let rect = DAMCropOverlay.viewRect(for: box.rect, fitted: fitted) {
                        boxView(box, rect: rect, fitted: fitted)
                    }
                }

                // Live draft while drawing.
                if let draft = draftRect,
                   let rect = DAMCropOverlay.viewRect(for: draft, fitted: fitted) {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Box view (fill per kind, stroke, selection handles)

    private func boxView(
        _ box: DAMEditState.RedactionBox,
        rect: CGRect,
        fitted: CGRect
    ) -> some View {
        let isSelected = box.id == selectedID
        return ZStack {
            // Live fill stands in for the render until the drag ends and the
            // recipe bakes the real treatment into the preview.
            RoundedRectangle(cornerRadius: 2)
                .fill(box.kind == .blackout
                      ? Color.black.opacity(0.6)
                      : Color.white.opacity(0.28))
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.white.opacity(0.8),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2 : 1,
                        dash: box.kind == .blur ? [4, 3] : []))
        }
        .frame(width: rect.width, height: rect.height)
        // ORDER MATTERS: contentShape must come BEFORE .position. Position
        // wraps the view in an invisible FULL-AREA frame; a contentShape
        // applied after it spans the whole overlay, so every drag hits this
        // box (the "can't add boxes, always reselects the first" bug).
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
        .onTapGesture { selectedID = box.id }
        .gesture(moveGesture(box, fitted: fitted))
        // Corner handles only on the selected box. The overlay sits on the
        // positioned wrapper (full area), so handles take VIEW-space points.
        .overlay {
            if isSelected {
                ForEach(HandleCorner.allCases, id: \.self) { corner in
                    Color.clear
                        .frame(width: handleSize, height: handleSize)
                        .overlay(
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                        )
                        .contentShape(Circle())
                        .position(corner.point(in: rect))
                        .gesture(resizeGesture(box, corner: corner, fitted: fitted))
                }
            }
        }
    }

    // MARK: - Gestures

    /// Drag on empty space: draw a new box of the current kind.
    private func drawGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = normalize(value.startLocation, in: fitted)
                let current = normalize(value.location, in: fitted)
                if draftStart == nil { draftStart = start }
                draftRect = rectFrom(start: start, to: current)
            }
            .onEnded { _ in
                if var rect = draftRect {
                    rect = clamped(rect)
                    let box = DAMEditState.RedactionBox(rect: rect, kind: kind)
                    boxes.append(box)
                    selectedID = box.id
                }
                draftStart = nil
                draftRect = nil
                onEnd()
            }
    }

    /// Drag inside a box: move it (and select it).
    private func moveGesture(_ box: DAMEditState.RedactionBox, fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let index = boxes.firstIndex(where: { $0.id == box.id }) else { return }
                if selectedID != box.id { selectedID = box.id }
                if moveOrigin?.id != box.id { moveOrigin = (box.id, boxes[index].rect) }
                guard let origin = moveOrigin, origin.id == box.id else { return }
                let start = normalize(value.startLocation, in: fitted)
                let current = normalize(value.location, in: fitted)
                boxes[index].rect = origin.rect.movedBy(
                    dx: current.x - start.x, dy: current.y - start.y)
                onChange()
            }
            .onEnded { _ in
                moveOrigin = nil
                onEnd()
            }
    }

    /// Drag a corner handle of the selected box: resize it.
    private func resizeGesture(
        _ box: DAMEditState.RedactionBox,
        corner: HandleCorner,
        fitted: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let index = boxes.firstIndex(where: { $0.id == box.id }) else { return }
                let current = normalize(value.location, in: fitted)
                boxes[index].rect = clamped(
                    corner.dragging(boxes[index].rect, to: current, minSize: minSize))
                onChange()
            }
            .onEnded { _ in onEnd() }
    }

    // MARK: - Geometry helpers

    private func normalize(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - fitted.minX) / fitted.width, 0), 1),
            y: min(max((point.y - fitted.minY) / fitted.height, 0), 1)
        )
    }

    private func rectFrom(start: CGPoint, to: CGPoint) -> DAMEditState.CropRect {
        DAMEditState.CropRect(
            x: min(start.x, to.x), y: min(start.y, to.y),
            width: abs(to.x - start.x), height: abs(to.y - start.y))
    }

    /// Clamp into 0…1 with the redaction minimum size (2% — smaller than
    /// the crop overlay's 5%, redactions target small regions like text).
    private func clamped(_ rect: DAMEditState.CropRect) -> DAMEditState.CropRect {
        let w = min(max(rect.width, minSize), 1)
        let h = min(max(rect.height, minSize), 1)
        return DAMEditState.CropRect(
            x: min(max(rect.x, 0), 1 - w),
            y: min(max(rect.y, 0), 1 - h),
            width: w, height: h)
    }

    // MARK: - Corners

    private enum HandleCorner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        func dragging(
            _ rect: DAMEditState.CropRect,
            to point: CGPoint,
            minSize: Double
        ) -> DAMEditState.CropRect {
            var out = rect
            switch self {
            case .topLeft:
                let nx = min(point.x, rect.x + rect.width - minSize)
                let ny = min(point.y, rect.y + rect.height - minSize)
                out.width = rect.width + (rect.x - nx)
                out.height = rect.height + (rect.y - ny)
                out.x = nx; out.y = ny
            case .topRight:
                let ny = min(point.y, rect.y + rect.height - minSize)
                out.width = max(point.x - rect.x, minSize)
                out.height = rect.height + (rect.y - ny); out.y = ny
            case .bottomLeft:
                let nx = min(point.x, rect.x + rect.width - minSize)
                out.width = rect.width + (rect.x - nx); out.x = nx
                out.height = max(point.y - rect.y, minSize)
            case .bottomRight:
                out.width = max(point.x - rect.x, minSize)
                out.height = max(point.y - rect.y, minSize)
            }
            return out
        }
    }
}
