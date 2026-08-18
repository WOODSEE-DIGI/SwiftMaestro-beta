import SwiftUI
import AppKit

// MARK: - Resizable Panel Host
//
// A pure-SwiftUI, native replacement for nested `NavigationSplitView`s.
// `NavigationSplitView` is designed to be used exactly once per window; nesting
// a second one inside another's detail pane confuses macOS's column
// width/visibility negotiation and produces unstable, occasionally
// wildly-oversized panes (see AppleNotesView/NotesView history). This host
// lays out a fixed sequence of panes along one axis — `.horizontal` for a row
// of columns, `.vertical` for a stack of rows — with real, drag-resizable
// dividers and no ambiguous nested navigation state. The caller owns size
// state directly via `Binding<CGFloat>`, so there's a single source of truth
// at all times. Two hosts can be nested (a vertical host of rows, each row
// itself a horizontal host of columns) to build a 2-D tiling grid — see
// `WorkspaceLayoutState`/`ContentView` for the top-level workspace grid.
//
// Contract: every pane except (optionally) the last must have a bound length.
// At most one trailing pane may be flexible (`length == nil`), and it always
// fills whatever space remains — mirroring how Xcode/Finder-style split areas
// behave (fixed sidebars + one flexible content area).

/// One pane inside a `ResizablePanelHost`.
struct ResizablePane: Identifiable {
    let id: AnyHashable
    /// `nil` means this pane is flexible and fills remaining space. Only the
    /// last pane in the sequence should be flexible. Width for a `.horizontal`
    /// host, height for a `.vertical` one.
    var length: Binding<CGFloat>?
    var minLength: CGFloat
    var maxLength: CGFloat
    var view: AnyView

    init<V: View>(
        id: AnyHashable,
        length: Binding<CGFloat>?,
        minLength: CGFloat = 160,
        maxLength: CGFloat = 600,
        @ViewBuilder view: () -> V
    ) {
        self.id = id
        self.length = length
        self.minLength = minLength
        self.maxLength = maxLength
        self.view = AnyView(view())
    }
}

/// Hosts an ordered sequence of `ResizablePane`s along `axis`, separated by
/// draggable dividers. No `NavigationSplitView` anywhere.
struct ResizablePanelHost: View {
    var axis: Axis = .horizontal
    let panes: [ResizablePane]

    var body: some View {
        stack {
            ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                pane.view
                    .frame(
                        width: axis == .horizontal ? pane.length?.wrappedValue : nil,
                        height: axis == .vertical ? pane.length?.wrappedValue : nil
                    )
                    .frame(
                        // Primary axis: only the flexible (nil-length) pane
                        // stretches. Cross axis: every pane always stretches
                        // to fill the host's other dimension (e.g. every
                        // column in a horizontal row fills its row's height).
                        maxWidth: axis == .horizontal ? (pane.length == nil ? .infinity : nil) : .infinity,
                        maxHeight: axis == .vertical ? (pane.length == nil ? .infinity : nil) : .infinity
                    )
                    .clipped()

                if index < panes.count - 1 {
                    let next = panes[index + 1]
                    ResizableDivider(
                        axis: axis,
                        leadingLength: pane.length,
                        leadingMin: pane.minLength,
                        leadingMax: pane.maxLength,
                        trailingLength: next.length,
                        trailingMin: next.minLength,
                        trailingMax: next.maxLength
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// `HStack` for `.horizontal`, `VStack` for `.vertical` — both zero-spacing
    /// since the divider itself provides the visual gap.
    @ViewBuilder
    private func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        switch axis {
        case .horizontal:
            HStack(spacing: 0, content: content)
        case .vertical:
            VStack(spacing: 0, content: content)
        }
    }
}

// MARK: - Resizable Divider

/// A draggable divider between two adjacent panes. Resizes the leading pane
/// (and, if the trailing pane also has a bound length, the trailing pane too —
/// conserving their combined length, exactly like a real split view divider).
/// If the trailing pane is flexible (`nil` length), only the leading pane's
/// length changes; the flexible pane simply absorbs whatever space is left.
struct ResizableDivider: View {
    var axis: Axis = .horizontal
    /// `nil` only when the leading pane itself is flexible, which should never
    /// happen in a well-formed pane sequence (flexible panes must be last, and
    /// there is no divider after the last pane) — guarded defensively anyway.
    var leadingLength: Binding<CGFloat>?
    let leadingMin: CGFloat
    let leadingMax: CGFloat
    var trailingLength: Binding<CGFloat>?
    let trailingMin: CGFloat
    let trailingMax: CGFloat

    @State private var dragStartLeading: CGFloat?
    @State private var dragStartTrailing: CGFloat?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.55) : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.12)))
                .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
        }
        .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
        .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged(handleDragChanged)
                .onEnded { _ in
                    dragStartLeading = nil
                    dragStartTrailing = nil
                }
        )
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        guard let leadingLength else { return }

        if dragStartLeading == nil {
            dragStartLeading = leadingLength.wrappedValue
            dragStartTrailing = trailingLength?.wrappedValue
        }
        let startLeading = dragStartLeading ?? leadingLength.wrappedValue
        let delta = axis == .horizontal ? value.translation.width : value.translation.height

        if let trailingLength, let startTrailing = dragStartTrailing {
            // Paired resize: conserve the combined length of the two panes so
            // dragging the divider only trades space between direct neighbors,
            // never touching anything further down the sequence.
            let total = startLeading + startTrailing
            let lowerBound = max(leadingMin, total - trailingMax)
            let upperBound = min(leadingMax, total - trailingMin)
            let newLeading = min(max(startLeading + delta, lowerBound), upperBound)
            leadingLength.wrappedValue = newLeading
            trailingLength.wrappedValue = total - newLeading
        } else {
            // Trailing pane is flexible — it absorbs whatever the leading
            // pane doesn't take, so only clamp the leading pane itself.
            leadingLength.wrappedValue = min(max(startLeading + delta, leadingMin), leadingMax)
        }
    }
}
