import SwiftUI
import AppKit

// MARK: - Sunburst chart + list

/// OpenDisk-style interactive rings (sunburst) chart for the Storage Map.
/// Ported from WOODSEE-DIGI/OpenDisk's baobab-style chart.
///
/// - Each concentric ring is one directory depth level.
/// - Angle is proportional to size; small items are dropped at build time.
/// - Color is determined by angular position around the palette.
/// - Tapping a segment drills into that folder; tapping the center goes up.
/// - The side list shows the same children with matching colors.
struct StorageMapSunburstChart: View {
    let node: StorageMapNode
    var viewModel: DAMViewModel
    var rescanningPath: String?
    let onSelect: (StorageMapNode) -> Void
    let onCenterTap: () -> Void

    private let maxDisplayDepth = 5
    private let minVisibleFraction = 0.0015

    private var chartItem: SMChartItem {
        SMChartItem.build(
            from: node,
            maxDepth: maxDisplayDepth,
            minVisibleFraction: minVisibleFraction
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            sideList
                .frame(width: 280)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Chart

    private var chart: some View {
        SMRingsChartView(
            root: chartItem,
            onSelectDirectory: { path in
                if let selected = findNode(in: node, path: path) {
                    onSelect(selected)
                }
            },
            onSelectCenter: onCenterTap
        )
    }

    private func findNode(in node: StorageMapNode, path: String) -> StorageMapNode? {
        if node.path == path { return node }
        for child in node.children {
            if let found = findNode(in: child, path: path) {
                return found
            }
        }
        return nil
    }

    // MARK: - Side list

    @State private var topFiles: [DAMStorageMapService.FileSizeItem] = []
    @State private var loadingTopFiles = false

    private var sideList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Folders")
                    .font(.headline)
                Spacer()
                Text("\(node.children.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            let sortedChildren = node.children.sorted { $0.size > $1.size }

            if sortedChildren.isEmpty {
                ContentUnavailableView(
                    "No subfolders",
                    systemImage: "folder.badge.minus",
                    description: Text("This folder has no further subfolders.")
                )
                .frame(maxHeight: .infinity)
            } else {
                let layout = SMRingsChartLayout.layout(
                    root: chartItem,
                    in: CGSize(width: 800, height: 800)
                )
                List(sortedChildren) { child in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorForChild(child, in: layout))
                            .frame(width: 8, height: 8)

                        Text(child.name)
                            .font(.body)
                            .lineLimit(1)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(formatBytes(child.size))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(percentage(child.size))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .opacity(rescanningPath == child.path ? 0.5 : 1.0)
                    .onTapGesture {
                        onSelect(child)
                    }
                    .contextMenu {
                        sunburstContextMenu(child: child)
                    }
                }
                .listStyle(.inset)
            }

            if loadingTopFiles || !topFiles.isEmpty {
                Divider()

                HStack {
                    Text("Top files")
                        .font(.headline)
                    Spacer()
                    if loadingTopFiles {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("\(topFiles.count) files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                List(topFiles) { file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 8)

                        Text(file.name)
                            .font(.body)
                            .lineLimit(1)

                        Spacer()

                        Text(formatBytes(file.size))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        } label: {
                            Label("Show in Finder", systemImage: "arrow.right.circle")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: node.path) {
            loadingTopFiles = true
            topFiles = await DAMStorageMapService.shared.topFiles(
                in: URL(fileURLWithPath: node.path),
                limit: 100
            )
            loadingTopFiles = false
        }
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func sunburstContextMenu(child: StorageMapNode) -> some View {
        Button {
            viewModel.selectedFolder = child.path
            viewModel.workspace = .home
        } label: {
            Label("Show in MaestroDAM", systemImage: "folder")
        }

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: child.path)])
        } label: {
            Label("Show in Finder", systemImage: "arrow.right.circle")
        }

        Button {
            DAMCleanupListStore.shared.add(path: child.path)
        } label: {
            Label("Add to cleanup list", systemImage: "trash")
        }
    }

    // MARK: - Helpers

    private func percentage(_ size: Int64) -> String {
        let total = max(1, Double(node.size))
        return String(format: "%.1f%%", Double(size) / total * 100)
    }

    private func colorForChild(
        _ child: StorageMapNode,
        in layout: SMRingsChartLayout.Layout
    ) -> Color {
        guard let segment = layout.segments.first(where: {
            $0.path == child.path && $0.depth == 1
        }) else {
            return .secondary
        }
        return SMChartPalette.fill(
            position: segment.colorPosition,
            depth: segment.depth,
            highlighted: false
        ).color
    }
}

// MARK: - OpenDisk chart tree model

/// One node of the rings chart's model: a depth-limited, noise-filtered
/// slice of a `StorageMapNode` tree.
///
/// Geometry-independent: `relStart`/`relSize` are percentages within the
/// parent, which the rings chart maps to angles.
private struct SMChartItem: Equatable, Identifiable, Sendable {

    enum Kind: Equatable, Sendable {
        case file
        case directory
        case synthetic
    }

    var id: String { path }

    let name: String
    let path: String
    let size: Int64
    let depth: Int
    let relStart: Double
    let relSize: Double
    let fractionOfRoot: Double
    let kind: Kind
    let hasHiddenChildren: Bool
    let children: [SMChartItem]

    static func build(
        from node: StorageMapNode,
        maxDepth: Int,
        minVisibleFraction: Double
    ) -> SMChartItem {
        buildItem(
            node: node,
            name: node.name,
            path: node.path,
            depth: 0,
            relStart: 0,
            relSize: 100,
            fractionOfRoot: 1,
            maxDepth: maxDepth,
            minVisibleFraction: minVisibleFraction
        )
    }

    private static func buildItem(
        node: StorageMapNode,
        name: String,
        path: String,
        depth: Int,
        relStart: Double,
        relSize: Double,
        fractionOfRoot: Double,
        maxDepth: Int,
        minVisibleFraction: Double
    ) -> SMChartItem {
        let totalSize = node.size
        let parentSize = max(totalSize, 1)
        let hasChildren = node.isDirectory && !node.children.isEmpty
        var children: [SMChartItem] = []
        var cursor = 0.0

        if hasChildren && depth < maxDepth {
            let sorted = node.children.sorted { $0.size > $1.size }
            for child in sorted {
                let childSize = child.size
                guard childSize > 0 else { break }
                let share = Double(childSize) / Double(parentSize) * 100
                let childFraction = fractionOfRoot * share / 100
                guard childFraction >= minVisibleFraction else { break }
                children.append(buildItem(
                    node: child,
                    name: child.name,
                    path: child.path,
                    depth: depth + 1,
                    relStart: cursor,
                    relSize: share,
                    fractionOfRoot: childFraction,
                    maxDepth: maxDepth,
                    minVisibleFraction: minVisibleFraction
                ))
                cursor += share
            }
        }

        return SMChartItem(
            name: name,
            path: path,
            size: totalSize,
            depth: depth,
            relStart: relStart,
            relSize: relSize,
            fractionOfRoot: fractionOfRoot,
            kind: node.isDirectory ? .directory : .file,
            hasHiddenChildren: hasChildren && depth >= maxDepth,
            children: children
        )
    }
}

// MARK: - OpenDisk chart palette

/// Chart coloring following GNOME baobab's scheme: six palette hues
/// interpolated by an item's position, dimmed with depth, and brightened
/// to full saturation when highlighted.
private enum SMChartPalette {

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    static let hues: [RGB] = [
        RGB(red: 0xE0 / 255.0, green: 0x1B / 255.0, blue: 0x24 / 255.0),
        RGB(red: 0xFF / 255.0, green: 0x78 / 255.0, blue: 0x00 / 255.0),
        RGB(red: 0xF6 / 255.0, green: 0xD3 / 255.0, blue: 0x2D / 255.0),
        RGB(red: 0x33 / 255.0, green: 0xD1 / 255.0, blue: 0x7A / 255.0),
        RGB(red: 0x35 / 255.0, green: 0x84 / 255.0, blue: 0xE4 / 255.0),
        RGB(red: 0x91 / 255.0, green: 0x41 / 255.0, blue: 0xAC / 255.0),
    ]

    static let level = RGB(red: 0xD3 / 255.0, green: 0xD6 / 255.0, blue: 0xD1 / 255.0)
    static let levelHighlighted = RGB(red: 0xE0 / 255.0, green: 0xE2 / 255.0, blue: 0xDD / 255.0)

    private static let bandWidth = 100.0 / 3.0

    static func fill(position: Double, depth: Int, highlighted: Bool) -> RGB {
        guard depth > 0 else { return highlighted ? levelHighlighted : level }

        let clamped = position.isFinite ? min(max(position, 0), 199.999) : 0
        let band = Int(clamped / bandWidth)
        let t = (clamped - Double(band) * bandWidth) / bandWidth
        let from = hues[band % hues.count]
        let to = hues[(band + 1) % hues.count]
        var rgb = RGB(
            red: from.red + (to.red - from.red) * t,
            green: from.green + (to.green - from.green) * t,
            blue: from.blue + (to.blue - from.blue) * t
        )

        let intensity = 1.0 - (Double(depth - 1) * 0.3) / 5.0
        rgb.red *= intensity
        rgb.green *= intensity
        rgb.blue *= intensity

        if highlighted {
            let peak = max(rgb.red, max(rgb.green, rgb.blue))
            if peak > 0 {
                rgb.red /= peak
                rgb.green /= peak
                rgb.blue /= peak
            }
        }
        return rgb
    }
}

// MARK: - OpenDisk rings chart layout

/// Pure geometry for the rings chart (baobab-style sunburst): concentric
/// rings, one per depth level, each item an annular sector whose sweep is
/// proportional to its share of the whole.
///
/// Angles are in radians, measured with `atan2(dy, dx)` semantics in a
/// y-down coordinate space: 0 points east and angles grow toward the
/// visually clockwise direction.
private enum SMRingsChartLayout {

    static let itemMinAngle = 0.03
    static let continuedEdgeWidth: CGFloat = 3
    static let continuedEdgeGap: CGFloat = 4
    static let borderWidth: CGFloat = 1
    static let padding: CGFloat = 10

    struct Segment: Equatable {
        let path: String
        let name: String
        let size: Int64
        let kind: SMChartItem.Kind
        let depth: Int
        let fractionOfRoot: Double
        let hasHiddenChildren: Bool
        let startAngle: Double
        let sweep: Double
        let innerRadius: CGFloat
        let outerRadius: CGFloat
        let colorPosition: Double
    }

    struct Layout: Equatable {
        let center: CGPoint
        let ringThickness: CGFloat
        let segments: [Segment]

        func segment(at point: CGPoint) -> Segment? {
            let dx = point.x - center.x
            let dy = point.y - center.y
            let radius = (dx * dx + dy * dy).squareRoot()
            guard let root = segments.first else { return nil }
            if radius <= root.outerRadius { return root }
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            return segments.first { segment in
                segment.depth > 0
                    && radius > segment.innerRadius && radius <= segment.outerRadius
                    && angle >= segment.startAngle
                    && angle < segment.startAngle + segment.sweep
            }
        }
    }

    static func layout(root: SMChartItem, in size: CGSize) -> Layout {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(min(size.width, size.height) / 2 - padding, 1)
        // Root (depth 0) + maxDisplayDepth rings.
        let ringCount = 5 + 1
        let thickness = maxRadius / CGFloat(ringCount)

        var segments: [Segment] = []
        appendSegments(
            of: root,
            startAngle: 0,
            sweep: 2 * .pi,
            thickness: thickness,
            into: &segments
        )
        return Layout(center: center, ringThickness: thickness, segments: segments)
    }

    private static func appendSegments(
        of item: SMChartItem,
        startAngle: Double,
        sweep: Double,
        thickness: CGFloat,
        into segments: inout [Segment]
    ) {
        guard item.depth == 0 || sweep >= itemMinAngle else { return }

        let innerRadius = CGFloat(item.depth) * thickness
        segments.append(Segment(
            path: item.path,
            name: item.name,
            size: item.size,
            kind: item.kind,
            depth: item.depth,
            fractionOfRoot: item.fractionOfRoot,
            hasHiddenChildren: item.hasHiddenChildren,
            startAngle: startAngle,
            sweep: sweep,
            innerRadius: innerRadius,
            outerRadius: innerRadius + thickness,
            colorPosition: (startAngle + sweep / 2) / (2 * .pi) * 200
        ))

        for child in item.children {
            appendSegments(
                of: child,
                startAngle: startAngle + sweep * child.relStart / 100,
                sweep: sweep * child.relSize / 100,
                thickness: thickness,
                into: &segments
            )
        }
    }
}

// MARK: - OpenDisk rings chart view

/// Baobab-style rings chart (sunburst): the viewed directory as a center
/// disk, each depth level a concentric ring, sector sweep proportional to
/// size.
///
/// Split into two stacked canvases so pointer movement stays cheap: the
/// static layer repaints only when a new snapshot or resize produces a new
/// layout, and a thin hover overlay repaints the single highlighted segment
/// plus the tip.
private struct SMRingsChartView: View {
    let root: SMChartItem
    let onSelectDirectory: (String) -> Void
    let onSelectCenter: () -> Void

    @State private var layout: SMRingsChartLayout.Layout?
    @State private var hoveredPath: String?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let layout {
                    SMStaticChartLayer(layout: layout)
                    Canvas { context, size in
                        drawHoverOverlay(layout: layout, in: &context, bounds: size)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    hoveredPath = layout?.segment(at: location)?.path
                case .ended:
                    hoveredPath = nil
                }
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    guard let segment = layout?.segment(at: value.location) else { return }
                    if segment.depth == 0 {
                        onSelectCenter()
                    } else if segment.kind == .directory {
                        onSelectDirectory(segment.path)
                    }
                }
            )
            .onChange(of: root, initial: true) {
                layout = SMRingsChartLayout.layout(root: root, in: geometry.size)
            }
            .onChange(of: geometry.size) {
                layout = SMRingsChartLayout.layout(root: root, in: geometry.size)
            }
        }
    }

    private func drawHoverOverlay(
        layout: SMRingsChartLayout.Layout,
        in context: inout GraphicsContext,
        bounds: CGSize
    ) {
        guard let hoveredPath,
              let segment = layout.segments.first(where: { $0.path == hoveredPath }) else {
            return
        }
        SMChartDrawing.draw(segment, layout: layout, highlighted: true, in: &context)
        SMChartTipRenderer.draw(
            name: segment.name,
            size: segment.size,
            fractionOfRoot: segment.fractionOfRoot,
            near: hoverLocation,
            in: &context,
            bounds: bounds
        )
    }
}

private struct SMStaticChartLayer: View, Equatable {
    let layout: SMRingsChartLayout.Layout

    var body: some View {
        Canvas { context, _ in
            for segment in layout.segments {
                SMChartDrawing.draw(segment, layout: layout, highlighted: false, in: &context)
            }
        }
    }
}

// MARK: - OpenDisk chart drawing

private enum SMChartDrawing {

    static func draw(
        _ segment: SMRingsChartLayout.Segment,
        layout: SMRingsChartLayout.Layout,
        highlighted: Bool,
        in context: inout GraphicsContext
    ) {
        let border = GraphicsContext.Shading.color(.black.opacity(0.35))
        let fill = SMChartPalette.fill(
            position: segment.colorPosition,
            depth: segment.depth,
            highlighted: highlighted
        ).color

        if segment.depth == 0 {
            let disk = Path(ellipseIn: CGRect(
                x: layout.center.x - segment.outerRadius,
                y: layout.center.y - segment.outerRadius,
                width: segment.outerRadius * 2,
                height: segment.outerRadius * 2
            ))
            context.fill(disk, with: .color(fill))
            context.stroke(disk, with: border, lineWidth: SMRingsChartLayout.borderWidth)
            drawCenterLabel(for: segment, layout: layout, in: &context)
            return
        }

        let sector = sectorPath(for: segment, center: layout.center)
        context.fill(sector, with: .color(fill))
        context.stroke(sector, with: border, lineWidth: SMRingsChartLayout.borderWidth)
        drawSectorLabel(for: segment, layout: layout, in: &context)

        if segment.hasHiddenChildren {
            var edge = Path()
            edge.addArc(
                center: layout.center,
                radius: segment.outerRadius + SMRingsChartLayout.continuedEdgeGap,
                startAngle: .radians(segment.startAngle),
                endAngle: .radians(segment.startAngle + segment.sweep),
                clockwise: false
            )
            context.stroke(edge, with: .color(fill), lineWidth: SMRingsChartLayout.continuedEdgeWidth)
        }
    }

    private static func sectorPath(
        for segment: SMRingsChartLayout.Segment,
        center: CGPoint
    ) -> Path {
        var path = Path()
        let a0 = segment.startAngle
        let a1 = segment.startAngle + segment.sweep
        path.move(to: CGPoint(
            x: center.x + cos(a0) * segment.innerRadius,
            y: center.y + sin(a0) * segment.innerRadius
        ))
        path.addArc(
            center: center,
            radius: segment.outerRadius,
            startAngle: .radians(a0),
            endAngle: .radians(a1),
            clockwise: false
        )
        path.addLine(to: CGPoint(
            x: center.x + cos(a1) * segment.innerRadius,
            y: center.y + sin(a1) * segment.innerRadius
        ))
        path.addArc(
            center: center,
            radius: segment.innerRadius,
            startAngle: .radians(a1),
            endAngle: .radians(a0),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }

    private static func drawSectorLabel(
        for segment: SMRingsChartLayout.Segment,
        layout: SMRingsChartLayout.Layout,
        in context: inout GraphicsContext
    ) {
        let midRadius = (segment.innerRadius + segment.outerRadius) / 2
        let thickness = segment.outerRadius - segment.innerRadius
        let arcLength = CGFloat(segment.sweep) * midRadius
        guard thickness >= 12, arcLength >= 30 else { return }

        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40)
        var glyphs: [GraphicsContext.ResolvedText] = []
        glyphs.reserveCapacity(segment.name.count)
        for character in segment.name {
            glyphs.append(context.resolve(
                Text(String(character))
                    .font(.caption2)
                    .foregroundColor(.black.opacity(0.75))
            ))
        }

        let glyphWidths: [CGFloat] = glyphs.map { $0.measure(in: unbounded).width }
        let totalWidth: CGFloat = glyphWidths.reduce(0, +)
        let lineHeight: CGFloat = glyphs.first?.measure(in: unbounded).height ?? 12
        guard totalWidth <= arcLength * 0.85, lineHeight <= thickness * 0.85 else { return }

        let bisector = segment.startAngle + segment.sweep / 2
        let readsReversed = sin(bisector) > 0
        let totalAngle = Double(totalWidth / midRadius)
        var cursor = readsReversed ? bisector + totalAngle / 2 : bisector - totalAngle / 2

        for (index, glyph) in glyphs.enumerated() {
            let glyphAngle = Double(glyphWidths[index] / midRadius)
            let angle = readsReversed ? cursor - glyphAngle / 2 : cursor + glyphAngle / 2
            var glyphContext = context
            glyphContext.translateBy(
                x: layout.center.x + cos(angle) * midRadius,
                y: layout.center.y + sin(angle) * midRadius
            )
            glyphContext.rotate(by: .radians(readsReversed ? angle - .pi / 2 : angle + .pi / 2))
            glyphContext.draw(glyph, at: .zero)
            cursor += readsReversed ? -glyphAngle : glyphAngle
        }
    }

    private static func drawCenterLabel(
        for segment: SMRingsChartLayout.Segment,
        layout: SMRingsChartLayout.Layout,
        in context: inout GraphicsContext
    ) {
        let name = context.resolve(
            Text(segment.name).font(.caption).fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.75))
        )
        let size = context.resolve(
            Text(formatBytes(segment.size)).font(.caption2)
                .foregroundColor(.black.opacity(0.6))
        )
        let maxWidth = segment.outerRadius * 1.7
        let nameSize = name.measure(in: CGSize(width: maxWidth, height: 40))
        let sizeSize = size.measure(in: CGSize(width: maxWidth, height: 40))
        guard nameSize.width <= maxWidth else {
            context.draw(size, at: layout.center)
            return
        }
        context.draw(name, at: CGPoint(x: layout.center.x, y: layout.center.y - sizeSize.height / 2 - 1))
        context.draw(size, at: CGPoint(x: layout.center.x, y: layout.center.y + nameSize.height / 2 + 1))
    }
}

// MARK: - OpenDisk hover tip

private enum SMChartTipRenderer {

    private static let padding = CGSize(width: 8, height: 5)
    private static let pointerOffset = CGPoint(x: 14, y: -28)

    static func draw(
        name: String,
        size: Int64,
        fractionOfRoot: Double,
        near location: CGPoint,
        in context: inout GraphicsContext,
        bounds: CGSize
    ) {
        let title = context.resolve(
            Text(name).font(.caption).fontWeight(.semibold)
                .foregroundStyle(.white)
        )
        let percent = String(format: "%.1f", fractionOfRoot * 100)
        let detail = context.resolve(
            Text("\(formatBytes(size)) · \(percent)%")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        )

        let maxTextWidth = min(280, bounds.width - padding.width * 2)
        let titleSize = title.measure(in: CGSize(width: maxTextWidth, height: 40))
        let detailSize = detail.measure(in: CGSize(width: maxTextWidth, height: 40))
        let pill = CGSize(
            width: max(titleSize.width, detailSize.width) + padding.width * 2,
            height: titleSize.height + detailSize.height + 2 + padding.height * 2
        )

        var origin = CGPoint(
            x: location.x + pointerOffset.x,
            y: location.y + pointerOffset.y - pill.height / 2
        )
        if origin.x + pill.width > bounds.width - 4 {
            origin.x = location.x - pointerOffset.x - pill.width
        }
        origin.x = min(max(origin.x, 4), max(bounds.width - pill.width - 4, 4))
        origin.y = min(max(origin.y, 4), max(bounds.height - pill.height - 4, 4))

        let rect = CGRect(origin: origin, size: pill)
        context.fill(
            Path(roundedRect: rect, cornerRadius: 6, style: .continuous),
            with: .color(.black.opacity(0.8))
        )
        context.draw(title, at: CGPoint(
            x: rect.minX + padding.width + titleSize.width / 2,
            y: rect.minY + padding.height + titleSize.height / 2
        ))
        context.draw(detail, at: CGPoint(
            x: rect.minX + padding.width + detailSize.width / 2,
            y: rect.minY + padding.height + titleSize.height + 2 + detailSize.height / 2
        ))
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Preview

#Preview {
    StorageMapSunburstChart(
        node: StorageMapNode(
            name: "Macintosh HD",
            path: "/",
            size: 4_000_000_000_000,
            children: [
                StorageMapNode(name: "Users", path: "/Users", size: 2_000_000_000_000, children: [
                    StorageMapNode(name: "user", path: "/Users/user", size: 1_800_000_000_000, children: [
                        StorageMapNode(name: "Movies", path: "/Users/user/Movies", size: 1_000_000_000_000, children: [], isDirectory: true),
                        StorageMapNode(name: "Music", path: "/Users/user/Music", size: 300_000_000_000, children: [], isDirectory: true)
                    ], isDirectory: true),
                    StorageMapNode(name: "Shared", path: "/Users/Shared", size: 200_000_000_000, children: [], isDirectory: true)
                ], isDirectory: true),
                StorageMapNode(name: "System", path: "/System", size: 1_000_000_000_000, children: [
                    StorageMapNode(name: "Library", path: "/System/Library", size: 800_000_000_000, children: [], isDirectory: true),
                    StorageMapNode(name: "Applications", path: "/System/Applications", size: 200_000_000_000, children: [], isDirectory: true)
                ], isDirectory: true),
                StorageMapNode(name: "Applications", path: "/Applications", size: 800_000_000_000, children: [
                    StorageMapNode(name: "Xcode", path: "/Applications/Xcode.app", size: 500_000_000_000, children: [], isDirectory: true)
                ], isDirectory: true)
            ],
            isDirectory: true
        ),
        viewModel: DAMViewModel(),
        rescanningPath: nil,
        onSelect: { _ in },
        onCenterTap: {}
    )
    .frame(width: 800, height: 500)
}
