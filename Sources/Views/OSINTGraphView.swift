import SwiftUI

// MARK: - Graph View

/// Obsidian-style relationship graph for OSINT profiles. Renders profiles and
/// their findings as nodes, with edges for profile ownership and inferred
/// cross-profile links (shared emails, phones, usernames, domains).
struct OSINTGraphView: View {
    let profiles: [OSINTProfile]

    @Environment(ThemeStore.self) private var theme
    @State private var layout = OSINTGraphLayout()
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var selectedNodeID: UUID?
    @State private var dragNodeID: UUID?
    @State private var lastDragTranslation: CGSize = .zero

    private var hasContent: Bool {
        !profiles.isEmpty && profiles.contains { !$0.findings.isEmpty }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(theme.background)
                    .ignoresSafeArea()

                if hasContent {
                    Canvas { context, size in
                        drawGraph(in: &context, size: size)
                    }
                    .gesture(magnificationGesture)
                    .simultaneousGesture(dragGesture)
                    .simultaneousGesture(tapGesture(in: geometry))

                    overlayControls
                } else {
                    emptyState
                }
            }
            .onAppear {
                layout.buildGraph(from: profiles, bounds: geometry.size)
            }
            .onChange(of: profiles) { _, newProfiles in
                layout.buildGraph(from: newProfiles, bounds: geometry.size)
            }
        }
    }

    // MARK: - Drawing

    private func drawGraph(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let tx = center.x + offset.width
        let ty = center.y + offset.height

        // Edges first so nodes draw on top.
        for edge in layout.edges {
            guard let source = layout.node(id: edge.source),
                  let target = layout.node(id: edge.target) else { continue }

            let isHighlighted = selectedNodeID == edge.source || selectedNodeID == edge.target
            let isDimmed = selectedNodeID != nil && !isHighlighted
            let lineColor = edge.label == "shared" ? theme.accent : Color.secondary
            let lineOpacity = isDimmed ? 0.15 : (isHighlighted ? 0.9 : 0.45)
            let lineWidth = isHighlighted ? 2.0 : 1.0

            let ax = source.position.x * scale + tx
            let ay = source.position.y * scale + ty
            let bx = target.position.x * scale + tx
            let by = target.position.y * scale + ty

            let path = Path { p in
                p.move(to: CGPoint(x: ax, y: ay))
                p.addLine(to: CGPoint(x: bx, y: by))
            }
            context.stroke(path, with: .color(lineColor.opacity(lineOpacity)), lineWidth: lineWidth)
        }

        // Nodes.
        for node in layout.nodes {
            let isSelected = selectedNodeID == node.id
            let isDimmed = selectedNodeID != nil && !isSelected && !isConnected(to: node.id)
            let px = node.position.x * scale + tx
            let py = node.position.y * scale + ty
            let radius = node.isProfileNode ? 18.0 : 10.0
            let color = nodeColor(node)

            if isSelected {
                let glowRect = CGRect(
                    x: px - radius - 6,
                    y: py - radius - 6,
                    width: (radius + 6) * 2,
                    height: (radius + 6) * 2
                )
                let glow = Path(ellipseIn: glowRect)
                context.fill(glow, with: .color(color.opacity(0.25)))
            }

            let circleRect = CGRect(
                x: px - radius,
                y: py - radius,
                width: radius * 2,
                height: radius * 2
            )
            let circle = Path(ellipseIn: circleRect)
            context.fill(circle, with: .color(color.opacity(isDimmed ? 0.25 : 1.0)))
            context.stroke(circle, with: .color(Color.primary.opacity(isDimmed ? 0.2 : 0.8)), lineWidth: 1.5)

            let label = node.isProfileNode ? node.label : (node.value.isEmpty ? node.label : node.value)
            let truncated = String(label.prefix(40))
            let fontSize: CGFloat = node.isProfileNode ? 12 : 10
            let text = Text(truncated)
                .font(.system(size: fontSize, weight: node.isProfileNode ? .semibold : .regular))
                .foregroundColor(Color.primary.opacity(isDimmed ? 0.4 : 1.0))
            context.draw(text, at: CGPoint(x: px, y: py + radius + 10))
        }
    }

    private func nodeColor(_ node: OSINTGraphNode) -> Color {
        if node.isProfileNode { return theme.accent }
        switch node.entityType {
        case .account: return .blue
        case .email: return .green
        case .phone: return .orange
        case .website: return .purple
        case .organization: return .pink
        case .name: return .cyan
        case .location, .address: return .yellow
        case .document: return .indigo
        case .relationship: return .red
        case .image: return .mint
        case .alias: return .teal
        case .other: return .gray
        }
    }

    private func isConnected(to nodeID: UUID) -> Bool {
        guard let selected = selectedNodeID else { return false }
        return layout.edges.contains { edge in
            (edge.source == selected && edge.target == nodeID)
            || (edge.target == selected && edge.source == nodeID)
        }
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(0.3, min(4.0, scale * value))
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if let nodeID = dragNodeID {
                    let dx = (value.translation.width - lastDragTranslation.width) / scale
                    let dy = (value.translation.height - lastDragTranslation.height) / scale
                    layout.moveNode(id: nodeID, by: CGSize(width: dx, height: dy))
                    lastDragTranslation = value.translation
                } else {
                    let dx = value.translation.width - lastDragTranslation.width
                    let dy = value.translation.height - lastDragTranslation.height
                    offset.width += dx
                    offset.height += dy
                    lastDragTranslation = value.translation
                }
            }
            .onEnded { _ in
                dragNodeID = nil
                lastDragTranslation = .zero
            }
    }

    private func tapGesture(in geometry: GeometryProxy) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                let location = value.location
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let tx = center.x + offset.width
                let ty = center.y + offset.height

                if let node = layout.nodes.reversed().first(where: { node in
                    let px = node.position.x * scale + tx
                    let py = node.position.y * scale + ty
                    let radius = node.isProfileNode ? 22.0 : 14.0
                    let dx = location.x - px
                    let dy = location.y - py
                    return (dx * dx + dy * dy) <= (radius * radius)
                }) {
                    selectedNodeID = node.id
                    dragNodeID = node.id
                } else {
                    selectedNodeID = nil
                }
            }
    }

    // MARK: - Overlays

    private var overlayControls: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Button { scale = min(4.0, scale * 1.2) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Button { scale = max(0.3, scale / 1.2) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Button {
                        scale = 1.0
                        offset = .zero
                        layout.resetPositions()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(8)
            }
            Spacer()
            if let selected = selectedNodeID, let node = layout.node(id: selected) {
                nodeDetailCard(node)
                    .padding(12)
            }
        }
    }

    private func nodeDetailCard(_ node: OSINTGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: node.isProfileNode ? "person.crop.rectangle.stack" : node.entityType.icon)
                    .foregroundStyle(nodeColor(node))
                Text(node.isProfileNode ? "Profile" : node.entityType.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(node.displayTitle)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
            if !node.value.isEmpty, node.value != node.label {
                Text(node.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let profileName = node.profileName, !node.isProfileNode {
                Text("Profile: \(profileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(theme.secondaryBackground.opacity(0.9))
        .cornerRadius(10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("No graph data yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Record findings to build a relationship graph.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Graph Layout

/// Runs a simple force-directed simulation and exposes node positions.
@Observable
final class OSINTGraphLayout {

    private(set) var nodes: [OSINTGraphNode] = []
    private(set) var edges: [OSINTGraphEdge] = []

    func buildGraph(from profiles: [OSINTProfile], bounds: CGSize) {
        let result = OSINTGraphBuilder.graph(for: profiles)
        self.nodes = result.nodes
        self.edges = result.edges
        runSimulation(bounds: bounds)
    }

    func node(id: UUID) -> OSINTGraphNode? {
        nodes.first { $0.id == id }
    }

    func moveNode(id: UUID, by delta: CGSize) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].position.x += delta.width
        nodes[index].position.y += delta.height
    }

    func resetPositions() {
        for index in nodes.indices {
            nodes[index].position = CGPoint(
                x: Double.random(in: -50...50),
                y: Double.random(in: -50...50)
            )
        }
        runSimulation(bounds: CGSize(width: 800, height: 600))
    }

    // MARK: - Force simulation

    private func runSimulation(bounds: CGSize, iterations: Int = 400) {
        guard nodes.count > 1 else { return }

        let width = max(bounds.width, 400)
        let height = max(bounds.height, 400)
        let center = CGPoint(x: width / 2, y: height / 2)

        for _ in 0..<iterations {
            var forces: [CGPoint] = Array(repeating: .zero, count: nodes.count)

            // Repulsion between all pairs.
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let dx = nodes[i].position.x - nodes[j].position.x
                    let dy = nodes[i].position.y - nodes[j].position.y
                    var dist = sqrt(dx * dx + dy * dy)
                    if dist < 1 { dist = 1 }
                    let force = 8000.0 / (dist * dist)
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    forces[i].x += fx
                    forces[i].y += fy
                    forces[j].x -= fx
                    forces[j].y -= fy
                }
            }

            // Spring attraction along edges.
            for edge in edges {
                guard let i = nodes.firstIndex(where: { $0.id == edge.source }),
                      let j = nodes.firstIndex(where: { $0.id == edge.target }) else { continue }
                let dx = nodes[j].position.x - nodes[i].position.x
                let dy = nodes[j].position.y - nodes[i].position.y
                let dist = sqrt(dx * dx + dy * dy)
                let targetLength = edge.label == "shared" ? 40.0 : 90.0
                let strength = 0.03 * edge.strength
                let displacement = (dist - targetLength) * strength
                let fx = (dx / max(dist, 1)) * displacement
                let fy = (dy / max(dist, 1)) * displacement
                forces[i].x += fx
                forces[i].y += fy
                forces[j].x -= fx
                forces[j].y -= fy
            }

            // Center gravity.
            for i in 0..<nodes.count {
                let dx = center.x - nodes[i].position.x
                let dy = center.y - nodes[i].position.y
                forces[i].x += dx * 0.005
                forces[i].y += dy * 0.005
            }

            // Profile nodes are heavier (more stable anchors).
            for i in 0..<nodes.count {
                let mass = nodes[i].isProfileNode ? 3.0 : 1.0
                nodes[i].position.x += forces[i].x / mass
                nodes[i].position.y += forces[i].y / mass
            }
        }
    }
}
