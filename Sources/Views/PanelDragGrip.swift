import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

// MARK: - Panel Drag Grip
//
// AppKit-backed drag source for workspace panels. SwiftUI's `.draggable`
// provides no drag-start/end callbacks, which the tiling system needs in
// order to: dim the source tile, forbid dropping a tile onto itself, show
// "droppable here" affordances on every valid tile, and — critically —
// clear all drag state when a drag is cancelled (Escape) instead of leaking
// a stale highlight. Owning the `NSDraggingSession` directly makes that
// lifecycle exact. The pasteboard payload is identical to the old
// `.draggable(WorkspacePanelTransfer)` payload (JSON-encoded
// `WorkspacePanelKind` under `UTType.workspacePanel`), so every existing
// drop destination keeps working unchanged.
struct PanelDragGrip: NSViewRepresentable {
    let kind: WorkspacePanelKind
    let title: String
    let accent: Color
    var toolTip: String = "Drag to move this panel"

    func makeNSView(context: Context) -> PanelDragGripView {
        let view = PanelDragGripView()
        view.kind = kind
        view.title = title
        view.toolTip = toolTip
        view.updateAppearance(accent: accent)
        return view
    }

    func updateNSView(_ nsView: PanelDragGripView, context: Context) {
        nsView.kind = kind
        nsView.title = title
        nsView.toolTip = toolTip
        nsView.updateAppearance(accent: accent)
    }
}

// MARK: - Grip NSView

final class PanelDragGripView: NSView, NSDraggingSource {
    var kind: WorkspacePanelKind?
    var title: String = "Panel"

    private let imageView = NSImageView()
    private var accent: NSColor = .controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        imageView.image = NSImage(
            systemSymbolName: "circle.grid.2x2",
            accessibilityDescription: "Drag grip"
        )?.withSymbolConfiguration(config)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func updateAppearance(accent color: Color) {
        accent = NSColor(color)
        imageView.contentTintColor = accent.withAlphaComponent(0.85)
    }

    /// The grip must never drag the window itself — especially important in
    /// the floating panel window, where a header drag would otherwise move
    /// the whole window instead of starting a docking drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let kind, !WorkspaceLayoutState.shared.isLocked,
                  let data = try? JSONEncoder().encode(kind) else {
                super.mouseDown(with: event)
                return
            }

            let item = NSPasteboardItem()
            item.setData(
                data,
                forType: NSPasteboard.PasteboardType(UTType.workspacePanel.identifier)
            )
            let draggingItem = NSDraggingItem(pasteboardWriter: item)

            // Chip-style drag image (icon + panel title) centered on the
            // cursor, so it's obvious WHAT is being dragged.
            let dragImage = makeDragImage()
            let mouse = convert(event.locationInWindow, from: nil)
            let frame = NSRect(
                x: mouse.x - dragImage.size.width / 2,
                y: mouse.y - dragImage.size.height / 2,
                width: dragImage.size.width,
                height: dragImage.size.height
            )
            draggingItem.setDraggingFrame(frame, contents: dragImage)

            let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Panel moves only make sense inside SwiftMaestro itself.
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated {
            guard let kind else { return }
            TilingDragState.shared.beginDrag(kind)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Fires on successful drops AND on cancel (Escape) — the single,
        // reliable place guaranteeing drag state never leaks.
        MainActor.assumeIsolated {
            TilingDragState.shared.endDrag()
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    // MARK: - Drag image

    /// Renders a small rounded chip — panel icon + title on an accent
    /// background — used as the image that follows the cursor mid-drag.
    private func makeDragImage() -> NSImage {
        let iconSize: CGFloat = 13
        let padding: CGFloat = 9
        let spacing: CGFloat = 6

        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white,
        ]
        let trimmed = title.count > 24 ? String(title.prefix(22)) + "…" : title
        let titleString = NSAttributedString(string: trimmed, attributes: titleAttrs)
        let titleSize = titleString.size()

        let chipHeight: CGFloat = 28
        let chipWidth = padding + iconSize + spacing + titleSize.width + padding
        let size = NSSize(width: ceil(chipWidth), height: chipHeight)

        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 8,
            yRadius: 8
        )
        accent.withAlphaComponent(0.92).setFill()
        path.fill()
        accent.withAlphaComponent(1.0).setStroke()
        path.lineWidth = 1
        path.stroke()

        if let kind,
           let icon = NSImage(
               systemSymbolName: kind.icon,
               accessibilityDescription: nil
           )?.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
           ) {
            let tinted = icon.tinted(with: .white)
            let iconRect = NSRect(
                x: padding,
                y: (chipHeight - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            tinted.draw(in: iconRect)
        }

        titleString.draw(at: NSPoint(
            x: padding + iconSize + spacing,
            y: (chipHeight - titleSize.height) / 2
        ))

        image.unlockFocus()
        return image
    }
}

private extension NSImage {
    /// Returns a copy of the image rendered in a single tint color.
    func tinted(with color: NSColor) -> NSImage {
        guard let copy = self.copy() as? NSImage else { return self }
        copy.isTemplate = false
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}
#endif
