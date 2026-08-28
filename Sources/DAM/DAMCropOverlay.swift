import AppKit
import SwiftUI

// MARK: - Drag-to-crop overlay
//
// Interactive crop rect drawn on top of the fitted preview image: drag on
// empty area to draw a new rect, drag inside to move it, drag the corner
// handles to resize. Coordinates are normalized 0…1 in the DISPLAYED image
// frame (the same frame the recipe's crop uses — the renderer applies
// rotation/straighten before crop, so the overlay matches what you see).
//
// This is a MODAL tool: DAMEditView only installs the overlay while the
// crop tool is armed (and renders the preview with the crop stripped while
// armed), so clicking the photo outside crop mode never draws a rectangle
// and the crop frame can never drift out of sync with the rendered image.

struct DAMCropOverlay: View {
    /// The current crop recipe (normalized 0…1), or nil for full frame.
    @Binding var crop: DAMEditState.CropRect?
    /// The pixel size of the rendered image (for aspect + fitted-rect math).
    let imageSize: CGSize
    /// Called on every drag frame with the updated crop.
    let onChange: () -> Void
    /// Called once when a drag gesture ends (persist + re-render here, not per frame).
    let onEnd: () -> Void

    /// Handle hit-target size (view points).
    private let handleSize: CGFloat = 18

    /// Tracks the crosshair cursor push so pop is always balanced.
    @State private var cursorPushed = false

    /// What the current drag is doing — decided ONCE from the gesture's
    /// start point. Deciding per-event against the live (moving) rect can
    /// flip modes mid-drag at clamp edges.
    @State private var dragMode: DragMode?
    /// The crop rect captured when a move drag STARTED. Delta is applied to
    /// this origin — never to the live rect, which would accumulate the
    /// full drag distance on every event and fling the rect to an edge.
    @State private var moveOrigin: DAMEditState.CropRect?

    private enum DragMode {
        case draw, move
    }

    var body: some View {
        GeometryReader { proxy in
            let fitted = Self.fittedRect(imageSize: imageSize, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())

                if let rect = Self.viewRect(for: crop, fitted: fitted) {
                    // Dim the outside of the crop.
                    dimOverlay(cropRect: rect, fitted: fitted)

                    // The crop frame.
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    // Corner handles (invisible larger hit target around the dot).
                    ForEach(HandleCorner.allCases, id: \.self) { corner in
                        Color.clear
                            .frame(width: handleSize, height: handleSize)
                            .overlay(
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                            )
                            .contentShape(Circle())
                            .position(corner.point(in: rect))
                            .gesture(resizeGesture(corner: corner, fitted: fitted))
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let start = normalize(value.startLocation, in: fitted)
                        let current = normalize(value.location, in: fitted)
                        if dragMode == nil {
                            dragMode = (crop != nil && contains(crop, normalized: start))
                                ? .move : .draw
                            if dragMode == .move { moveOrigin = crop }
                        }
                        switch dragMode {
                        case .draw, nil:
                            // Draw a fresh rect.
                            crop = rectFrom(start: start, to: current)
                        case .move:
                            // Move by the drag delta applied to the ORIGIN
                            // rect (not the live rect — see moveOrigin note).
                            if let origin = moveOrigin {
                                crop = origin.movedBy(
                                    dx: current.x - start.x, dy: current.y - start.y)
                            }
                        }
                        onChange()
                    }
                    .onEnded { _ in
                        dragMode = nil
                        moveOrigin = nil
                        onEnd()
                    }
            )
            // Crosshair cursor signals the armed crop tool. Push/pop kept
            // balanced via cursorPushed; popped on disappear (tool disarm).
            .onHover { hovering in
                if hovering {
                    guard !cursorPushed else { return }
                    NSCursor.crosshair.push()
                    cursorPushed = true
                } else if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Geometry

    /// Map a normalized 0…1 crop to view-space points inside the fitted rect.
    static func viewRect(for crop: DAMEditState.CropRect?, fitted: CGRect) -> CGRect? {
        guard let crop else { return nil }
        return CGRect(
            x: fitted.minX + crop.x * fitted.width,
            y: fitted.minY + crop.y * fitted.height,
            width: crop.width * fitted.width,
            height: crop.height * fitted.height
        )
    }

    /// The aspect-fit rect of the image inside a container.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0
        else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func normalize(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - fitted.minX) / fitted.width, 0), 1),
            y: min(max((point.y - fitted.minY) / fitted.height, 0), 1)
        )
    }

    private func rectFrom(start: CGPoint, to: CGPoint) -> DAMEditState.CropRect {
        let x = min(start.x, to.x)
        let y = min(start.y, to.y)
        return DAMEditState.CropRect(
            x: x, y: y,
            width: max(abs(to.x - start.x), 0.05),   // clamp a minimum 5% area
            height: max(abs(to.y - start.y), 0.05)
        ).clamped()
    }

    private func contains(_ crop: DAMEditState.CropRect?, normalized p: CGPoint) -> Bool {
        guard let c = crop else { return false }
        return p.x >= c.x && p.x <= c.x + c.width && p.y >= c.y && p.y <= c.y + c.height
    }

    private func resizeGesture(corner: HandleCorner, fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard var c = crop else { return }
                let current = normalize(value.location, in: fitted)
                c = corner.dragging(c, to: current).clamped()
                crop = c
                onChange()
            }
            .onEnded { _ in onEnd() }
    }

    // MARK: - Dim overlay

    private func dimOverlay(cropRect: CGRect, fitted: CGRect) -> some View {
        // Four dimmed rects around the crop frame.
        let dim = Color.black.opacity(0.45)
        return Group {
            Rectangle().fill(dim)
                .frame(width: fitted.width, height: max(cropRect.minY - fitted.minY, 0))
                .position(x: fitted.midX, y: (fitted.minY + cropRect.minY) / 2)
            Rectangle().fill(dim)
                .frame(width: fitted.width, height: max(fitted.maxY - cropRect.maxY, 0))
                .position(x: fitted.midX, y: (cropRect.maxY + fitted.maxY) / 2)
            Rectangle().fill(dim)
                .frame(width: max(cropRect.minX - fitted.minX, 0), height: cropRect.height)
                .position(x: (fitted.minX + cropRect.minX) / 2, y: cropRect.midY)
            Rectangle().fill(dim)
                .frame(width: max(fitted.maxX - cropRect.maxX, 0), height: cropRect.height)
                .position(x: (cropRect.maxX + fitted.maxX) / 2, y: cropRect.midY)
        }
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

        func dragging(_ c: DAMEditState.CropRect, to p: CGPoint) -> DAMEditState.CropRect {
            var out = c
            switch self {
            case .topLeft:
                let nx = min(p.x, c.x + c.width - 0.05), ny = min(p.y, c.y + c.height - 0.05)
                out.width = c.width + (c.x - nx); out.height = c.height + (c.y - ny)
                out.x = nx; out.y = ny
            case .topRight:
                let ny = min(p.y, c.y + c.height - 0.05)
                out.width = max(p.x - c.x, 0.05); out.height = c.height + (c.y - ny); out.y = ny
            case .bottomLeft:
                let nx = min(p.x, c.x + c.width - 0.05)
                out.width = c.width + (c.x - nx); out.x = nx; out.height = max(p.y - c.y, 0.05)
            case .bottomRight:
                out.width = max(p.x - c.x, 0.05); out.height = max(p.y - c.y, 0.05)
            }
            return out
        }
    }
}

// MARK: - Clamping

extension DAMEditState.CropRect {
    /// Clamp into 0…1 with a minimum 5% width/height (never an invisible crop).
    func clamped() -> DAMEditState.CropRect {
        let w = min(max(width, 0.05), 1)
        let h = min(max(height, 0.05), 1)
        return DAMEditState.CropRect(
            x: min(max(x, 0), 1 - w),
            y: min(max(y, 0), 1 - h),
            width: w,
            height: h
        )
    }

    /// Move by a normalized drag delta, clamped into bounds. PURE — the
    /// caller must apply this to the rect captured at gesture START, never
    /// to the live rect (applying the full delta to the live rect on every
    /// drag event accumulates and flings it to an edge).
    func movedBy(dx: Double, dy: Double) -> DAMEditState.CropRect {
        DAMEditState.CropRect(
            x: min(max(x + dx, 0), 1 - width),
            y: min(max(y + dy, 0), 1 - height),
            width: width,
            height: height
        )
    }
}
