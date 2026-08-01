import SwiftUI
import AppKit

struct StudioSceneView: View {
    @StateObject private var service = StudioSceneService.shared
    @StateObject private var outputService = SceneOutputService.shared
    @State private var isAddingLayer = false
    @State private var isShowingOutputSheet = false
    @State private var selectedLayerID: UUID? = nil
    @State private var transformLayerID: UUID? = nil

    var body: some View {
        HStack(spacing: 0) {
            sceneList
                .frame(minWidth: 160, maxWidth: 220)

            Divider()

            canvasPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            layerSidebar
                .frame(minWidth: 260, maxWidth: 320)
        }
        .onChange(of: selectedLayerID) { _, newValue in
            // Keep the transform overlay and inspector in sync with the selected
            // layer so clicking a different layer moves the handles to it.
            transformLayerID = newValue
        }
    }

    @State private var layerListHeight: CGFloat = 200
    @State private var inspectorHeight: CGFloat = 280

    private var layerSidebar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                layerList
                    .frame(height: layerListHeight)

                if selectedLayerID != nil {
                    ResizableDivider(
                        axis: .vertical,
                        leadingLength: $layerListHeight,
                        leadingMin: 120,
                        leadingMax: max(130, geometry.size.height - 140),
                        trailingLength: $inspectorHeight,
                        trailingMin: 120,
                        trailingMax: max(130, geometry.size.height - 140)
                    )

                    if let scene = service.selectedScene, let layerID = selectedLayerID,
                       let layer = scene.layers.first(where: { $0.id == layerID }) {
                        layerInspector(layer: layer, scene: scene)
                            .frame(height: inspectorHeight)
                    }
                } else {
                    Spacer()
                }
            }
            .onAppear {
                if layerListHeight + inspectorHeight > geometry.size.height {
                    layerListHeight = max(120, geometry.size.height / 2)
                    inspectorHeight = max(120, geometry.size.height / 2)
                }
            }
        }
    }

    // MARK: - Scene List

    private var sceneList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scenes")
                    .font(.headline)
                Spacer()
                Button {
                    let newScene = StudioScene(name: "Scene \(service.scenes.count + 1)")
                    service.addScene(newScene)
                } label: {
                    Image(systemName: "plus")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List(selection: $service.selectedSceneID) {
                ForEach(service.scenes) { scene in
                    HStack {
                        Text(scene.name)
                        Spacer()
                        Button {
                            service.removeScene(id: scene.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete scene")
                    }
                    .tag(scene.id)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            service.removeScene(id: scene.id)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        service.removeScene(id: service.scenes[index].id)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Canvas Preview

    private var canvasPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(service.selectedScene?.name ?? "No Scene")
                    .font(.headline)
                Spacer()
                if let scene = service.selectedScene {
                    Text("\(scene.width) × \(scene.height)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    outputStatusBadge(for: scene)
                }
            }
            .padding()

            GeometryReader { geometry in
                if let scene = service.selectedScene {
                    ZStack {
                        Color.black
                        ForEach(scene.layers.sorted(by: { $0.zIndex < $1.zIndex })) { layer in
                            layerPreview(layer, in: geometry.size, scene: scene)
                        }
                        if let transformLayer = scene.layers.first(where: { $0.id == transformLayerID }) {
                            transformOverlayLayer(for: transformLayer, in: geometry.size, scene: scene)
                        }
                        MouseTrackingCanvas(
                            onMouseDown: { point in canvasMouseDown(at: point, scene: scene, containerSize: geometry.size) },
                            onMouseDragged: { point in canvasMouseDragged(at: point, scene: scene, containerSize: geometry.size) },
                            onMouseUp: { point in canvasMouseUp(at: point, scene: scene, containerSize: geometry.size) },
                            onDoubleClick: { point in canvasDoubleClick(at: point, scene: scene, containerSize: geometry.size) }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ContentUnavailableView(
                        "No Scene Selected",
                        systemImage: "rectangle.stack",
                        description: Text("Create a scene to start layering sources.")
                    )
                }
            }
            .background(Color.gray.opacity(0.1))

            if let scene = service.selectedScene {
                outputToolbar(for: scene)
            }
        }
    }

    private func outputStatusBadge(for scene: StudioScene) -> some View {
        let snapshot = outputService.snapshots[scene.id]
        let status = snapshot?.status ?? .idle
        return Text(status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(status).opacity(0.2))
            .foregroundStyle(statusColor(status))
            .cornerRadius(6)
    }

    private func outputToolbar(for scene: StudioScene) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                outputTargetLabel(for: scene)
                Spacer()
                Button {
                    isShowingOutputSheet = true
                } label: {
                    Label("Output", systemImage: "arrow.up.forward")
                }
                .help("Choose broadcast destination or mixer route")

                if outputService.isLive(sceneID: scene.id) {
                    Button {
                        outputService.stop(sceneID: scene.id)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        outputService.start(sceneID: scene.id)
                    } label: {
                        Label("Go Live", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(scene.outputTarget == .none)
                }
            }
            .padding()
        }
        .sheet(isPresented: $isShowingOutputSheet) {
            SceneOutputSheet(scene: scene)
        }
    }

    private func outputTargetLabel(for scene: StudioScene) -> some View {
        switch scene.outputTarget {
        case .broadcast(let id):
            let name = BroadcastService.shared.sessions.first(where: { $0.id == id })?.name ?? "Unknown"
            return Label("→ \(name)", systemImage: "arrow.up.circle")
        case .mixerRoute(let id):
            let name = StreamMixerService.shared.routes.first(where: { $0.id == id })?.name ?? "Unknown"
            return Label("→ \(name)", systemImage: "arrow.triangle.merge")
        case .none:
            return Label("No output", systemImage: "exclamationmark.triangle")
        }
    }

    private func statusColor(_ status: SceneOutputStatus) -> Color {
        switch status {
        case .idle: return .secondary
        case .starting: return .orange
        case .live: return .red
        case .stopped: return .secondary
        case .error: return .red
        }
    }



    // MARK: - Canvas Layer Drag

    @State private var canvasDrag: CanvasDragState? = nil
    @State private var mouseDragStart: CGPoint? = nil
    @State private var mouseDragMoved: Bool = false
    @State private var reassignCameraLayer: SceneLayer? = nil

    private struct CanvasDragState {
        let layerID: UUID
        let startX: Double
        let startY: Double
        let startWidth: Double
        let startHeight: Double
        let startCropX: Double
        let startCropY: Double
        let startCropWidth: Double
        let startCropHeight: Double
        let handle: DragHandle
    }

    private enum DragHandle: Equatable {
        case body
        case transform(TransformHandle)
        case crop(CropHandle)
    }

    private enum TransformHandle: Equatable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    private enum CropHandle: Equatable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func scenePoint(at viewPoint: CGPoint, containerSize: CGSize, scene: StudioScene) -> CGPoint {
        let scaleX = Double(containerSize.width) / Double(scene.width)
        let scaleY = Double(containerSize.height) / Double(scene.height)
        return CGPoint(x: Double(viewPoint.x) / scaleX, y: Double(viewPoint.y) / scaleY)
    }

    private func startDragState(at viewPoint: CGPoint, scene: StudioScene, containerSize: CGSize) -> Bool {
        let point = scenePoint(at: viewPoint, containerSize: containerSize, scene: scene)
        let sorted = scene.layers.sorted(by: { $0.zIndex < $1.zIndex })
        let layer: SceneLayer?
        let handle: DragHandle
        if let transformID = transformLayerID,
           let tLayer = scene.layers.first(where: { $0.id == transformID }),
           tLayer.isVisible {
            if let h = handleAt(point, for: tLayer) {
                layer = tLayer
                handle = h
            } else if layerRect(tLayer).contains(point) {
                layer = tLayer
                handle = .body
            } else if let top = findTopLayer(at: point, in: sorted) {
                transformLayerID = nil
                layer = top
                handle = handleAt(point, for: top) ?? .body
            } else {
                transformLayerID = nil
                selectedLayerID = nil
                return false
            }
        } else {
            if let top = findTopLayer(at: point, in: sorted) {
                layer = top
                handle = handleAt(point, for: top) ?? .body
            } else {
                selectedLayerID = nil
                return false
            }
        }
        guard let startLayer = layer else { return false }
        canvasDrag = CanvasDragState(
            layerID: startLayer.id,
            startX: startLayer.x,
            startY: startLayer.y,
            startWidth: startLayer.width,
            startHeight: startLayer.height,
            startCropX: startLayer.crop.x,
            startCropY: startLayer.crop.y,
            startCropWidth: startLayer.crop.width,
            startCropHeight: startLayer.crop.height,
            handle: handle
        )
        selectedLayerID = startLayer.id
        return true
    }

    private func canvasMouseDown(at viewPoint: CGPoint, scene: StudioScene, containerSize: CGSize) {
        mouseDragStart = viewPoint
        mouseDragMoved = false
        _ = startDragState(at: viewPoint, scene: scene, containerSize: containerSize)
    }

    private func canvasMouseDragged(at viewPoint: CGPoint, scene: StudioScene, containerSize: CGSize) {
        guard let start = mouseDragStart else { return }
        let threshold: CGFloat = 3
        if !mouseDragMoved, hypot(viewPoint.x - start.x, viewPoint.y - start.y) < threshold {
            return
        }
        mouseDragMoved = true
        if canvasDrag == nil {
            guard startDragState(at: start, scene: scene, containerSize: containerSize) else { return }
        }
        guard let state = canvasDrag,
              let layer = scene.layers.first(where: { $0.id == state.layerID }) else { return }

        let deltaX = Double(viewPoint.x - start.x) / (Double(containerSize.width) / Double(scene.width))
        let deltaY = Double(viewPoint.y - start.y) / (Double(containerSize.height) / Double(scene.height))

        let updated = layerAfterDrag(
            layer: layer,
            state: state,
            deltaX: deltaX,
            deltaY: deltaY
        )
        service.updateLayer(in: scene.id, layer: updated, save: false)
    }

    private func canvasMouseUp(at viewPoint: CGPoint, scene: StudioScene, containerSize: CGSize) {
        if mouseDragMoved, let state = canvasDrag,
           let layer = scene.layers.first(where: { $0.id == state.layerID }) {
            let start = mouseDragStart ?? viewPoint
            let deltaX = Double(viewPoint.x - start.x) / (Double(containerSize.width) / Double(scene.width))
            let deltaY = Double(viewPoint.y - start.y) / (Double(containerSize.height) / Double(scene.height))
            let updated = layerAfterDrag(
                layer: layer,
                state: state,
                deltaX: deltaX,
                deltaY: deltaY
            )
            service.updateLayer(in: scene.id, layer: updated)
        } else if !mouseDragMoved, let start = mouseDragStart {
            let point = scenePoint(at: start, containerSize: containerSize, scene: scene)
            let sorted = scene.layers.sorted(by: { $0.zIndex < $1.zIndex })
            if let layer = findTopLayer(at: point, in: sorted) {
                selectedLayerID = layer.id
            } else {
                selectedLayerID = nil
                transformLayerID = nil
            }
        }
        canvasDrag = nil
        mouseDragStart = nil
        mouseDragMoved = false
    }

    private func canvasDoubleClick(at viewPoint: CGPoint, scene: StudioScene, containerSize: CGSize) {
        let point = scenePoint(at: viewPoint, containerSize: containerSize, scene: scene)
        let sorted = scene.layers.sorted(by: { $0.zIndex < $1.zIndex })
        if let layer = findTopLayer(at: point, in: sorted) {
            transformLayerID = layer.id
            selectedLayerID = layer.id
        }
        canvasDrag = nil
        mouseDragStart = nil
        mouseDragMoved = false
    }

    private func layerAfterDrag(layer: SceneLayer, state: CanvasDragState, deltaX: Double, deltaY: Double) -> SceneLayer {
        var updated = layer
        switch state.handle {
        case .body:
            updated.x = round(state.startX + deltaX)
            updated.y = round(state.startY + deltaY)
        case .transform(let transform):
            let size = applyTransformHandle(transform, to: layer, state: state, deltaX: deltaX, deltaY: deltaY)
            updated.x = size.x
            updated.y = size.y
            updated.width = size.width
            updated.height = size.height
        case .crop(let crop):
            let cropRect = applyCropHandle(crop, to: layer, state: state, deltaX: deltaX, deltaY: deltaY)
            updated.crop = cropRect
        }
        return updated
    }

    private func applyTransformHandle(
        _ handle: TransformHandle,
        to layer: SceneLayer,
        state: CanvasDragState,
        deltaX: Double,
        deltaY: Double
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        var x = state.startX
        var y = state.startY
        var width = state.startWidth
        var height = state.startHeight

        let minDimension: Double = 10

        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Corner handles scale the layer proportionally by distance from the
            // opposite (anchored) corner, so width and height always scale by the
            // same factor while keeping the anchored corner fixed.
            let signX: Double
            let signY: Double
            let anchorX: Double
            let anchorY: Double
            let anchorIsLeft: Bool
            let anchorIsTop: Bool
            switch handle {
            case .topLeft:
                signX = -1
                signY = -1
                anchorX = state.startX + state.startWidth
                anchorY = state.startY + state.startHeight
                anchorIsLeft = false
                anchorIsTop = false
            case .topRight:
                signX = 1
                signY = -1
                anchorX = state.startX
                anchorY = state.startY + state.startHeight
                anchorIsLeft = true
                anchorIsTop = false
            case .bottomLeft:
                signX = -1
                signY = 1
                anchorX = state.startX + state.startWidth
                anchorY = state.startY
                anchorIsLeft = false
                anchorIsTop = true
            case .bottomRight:
                signX = 1
                signY = 1
                anchorX = state.startX
                anchorY = state.startY
                anchorIsLeft = true
                anchorIsTop = true
            default:
                fatalError("Non-corner transform handle routed into corner branch")
            }
            let startDiagonal = sqrt(state.startWidth * state.startWidth + state.startHeight * state.startHeight)
            let currentDiagonal = sqrt(
                (state.startWidth + signX * deltaX) * (state.startWidth + signX * deltaX) +
                (state.startHeight + signY * deltaY) * (state.startHeight + signY * deltaY)
            )
            let minScale = max(minDimension / state.startWidth, minDimension / state.startHeight)
            let scale = max(currentDiagonal / startDiagonal, minScale)
            width = state.startWidth * scale
            height = state.startHeight * scale
            x = anchorIsLeft ? anchorX : anchorX - width
            y = anchorIsTop ? anchorY : anchorY - height

        case .top:
            y = state.startY + deltaY
            height = state.startHeight - deltaY
        case .bottom:
            height = state.startHeight + deltaY
        case .left:
            x = state.startX + deltaX
            width = state.startWidth - deltaX
        case .right:
            width = state.startWidth + deltaX
        }

        if width < minDimension {
            x = layer.x + (layer.width - minDimension) / 2
            width = minDimension
        }
        if height < minDimension {
            y = layer.y + (layer.height - minDimension) / 2
            height = minDimension
        }
        return (round(x), round(y), round(width), round(height))
    }

    private func applyCropHandle(
        _ handle: CropHandle,
        to layer: SceneLayer,
        state: CanvasDragState,
        deltaX: Double,
        deltaY: Double
    ) -> SceneLayerCrop {
        var x = state.startCropX
        var y = state.startCropY
        var width = state.startCropWidth
        var height = state.startCropHeight

        let dx = deltaX / layer.width
        let dy = deltaY / layer.height

        switch handle {
        case .topLeft:
            x = state.startCropX + dx
            y = state.startCropY + dy
            width = state.startCropWidth - dx
            height = state.startCropHeight - dy
        case .topRight:
            y = state.startCropY + dy
            width = state.startCropWidth + dx
            height = state.startCropHeight - dy
        case .bottomLeft:
            x = state.startCropX + dx
            width = state.startCropWidth - dx
            height = state.startCropHeight + dy
        case .bottomRight:
            width = state.startCropWidth + dx
            height = state.startCropHeight + dy
        }

        width = max(0.01, width)
        height = max(0.01, height)

        if x < 0 {
            width += x
            x = 0
        }
        if y < 0 {
            height += y
            y = 0
        }
        if x + width > 1 {
            width = 1 - x
        }
        if y + height > 1 {
            height = 1 - y
        }

        return SceneLayerCrop(x: round(x * 1000) / 1000, y: round(y * 1000) / 1000, width: round(width * 1000) / 1000, height: round(height * 1000) / 1000)
    }

    private func findTopLayer(at point: CGPoint, in layers: [SceneLayer]) -> SceneLayer? {
        layers.reversed().first { layer in
            guard layer.isVisible else { return false }
            return layerRect(layer).contains(point)
        }
    }

    private func layerRect(_ layer: SceneLayer) -> CGRect {
        CGRect(x: layer.x, y: layer.y, width: layer.width, height: layer.height)
    }

    private func handleAt(_ point: CGPoint, for layer: SceneLayer) -> DragHandle? {
        let handleSize: Double = 24
        let half = handleSize / 2

        // Check transform handles first so the yellow layer transform dots win
        // over crop handles when they overlap (e.g. default full-frame crop).
        let positions: [(TransformHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: layer.x, y: layer.y)),
            (.top, CGPoint(x: layer.x + layer.width / 2, y: layer.y)),
            (.topRight, CGPoint(x: layer.x + layer.width, y: layer.y)),
            (.left, CGPoint(x: layer.x, y: layer.y + layer.height / 2)),
            (.right, CGPoint(x: layer.x + layer.width, y: layer.y + layer.height / 2)),
            (.bottomLeft, CGPoint(x: layer.x, y: layer.y + layer.height)),
            (.bottom, CGPoint(x: layer.x + layer.width / 2, y: layer.y + layer.height)),
            (.bottomRight, CGPoint(x: layer.x + layer.width, y: layer.y + layer.height))
        ]
        for (handle, center) in positions {
            let rect = CGRect(x: center.x - half, y: center.y - half, width: handleSize, height: handleSize)
            if rect.contains(point) {
                return .transform(handle)
            }
        }

        if let crop = cropHandleAt(point, for: layer, handleSize: handleSize) {
            return .crop(crop)
        }
        return nil
    }

    private func cropHandleAt(_ point: CGPoint, for layer: SceneLayer, handleSize: Double) -> CropHandle? {
        let half = handleSize / 2
        let cropRect = CGRect(
            x: layer.x + layer.crop.x * layer.width,
            y: layer.y + layer.crop.y * layer.height,
            width: layer.crop.width * layer.width,
            height: layer.crop.height * layer.height
        )
        let positions: [(CropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: cropRect.minX, y: cropRect.minY)),
            (.topRight, CGPoint(x: cropRect.maxX, y: cropRect.minY)),
            (.bottomLeft, CGPoint(x: cropRect.minX, y: cropRect.maxY)),
            (.bottomRight, CGPoint(x: cropRect.maxX, y: cropRect.maxY))
        ]
        for (handle, center) in positions {
            let rect = CGRect(x: center.x - half, y: center.y - half, width: handleSize, height: handleSize)
            if rect.contains(point) {
                return handle
            }
        }
        return nil
    }

    // MARK: - Layer Preview

    private func layerPreview(_ layer: SceneLayer, in containerSize: CGSize, scene: StudioScene) -> some View {
        let scaleX = containerSize.width / CGFloat(scene.width)
        let scaleY = containerSize.height / CGFloat(scene.height)
        let x = layer.x * Double(scaleX)
        let y = layer.y * Double(scaleY)
        let width = layer.width * Double(scaleX)
        let height = layer.height * Double(scaleY)
        let isSelected = selectedLayerID == layer.id

        return SceneLayerPreviewView(layer: layer, sceneSize: CGSize(width: scene.width, height: scene.height))
            .frame(width: width, height: height)
            .position(x: x + width / 2, y: y + height / 2)
            .border(isSelected ? Color.yellow : (layer.isVisible ? Color.accentColor : Color.clear), width: isSelected ? 2 : 1)
    }

    @ViewBuilder
    private func transformOverlayLayer(for layer: SceneLayer, in containerSize: CGSize, scene: StudioScene) -> some View {
        let scaleX = containerSize.width / CGFloat(scene.width)
        let scaleY = containerSize.height / CGFloat(scene.height)
        let x = layer.x * Double(scaleX)
        let y = layer.y * Double(scaleY)
        let width = layer.width * Double(scaleX)
        let height = layer.height * Double(scaleY)
        let cropX = layer.crop.x * width
        let cropY = layer.crop.y * height
        let cropW = layer.crop.width * width
        let cropH = layer.crop.height * height

        ZStack {
            // Outer transform border
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)

            // Crop box
            Rectangle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: max(0, cropW), height: max(0, cropH))
                .position(x: cropX + cropW / 2, y: cropY + cropH / 2)

            // Transform handles
            transformHandle(.topLeft, at: CGPoint(x: 0, y: 0))
            transformHandle(.top, at: CGPoint(x: width / 2, y: 0))
            transformHandle(.topRight, at: CGPoint(x: width, y: 0))
            transformHandle(.left, at: CGPoint(x: 0, y: height / 2))
            transformHandle(.right, at: CGPoint(x: width, y: height / 2))
            transformHandle(.bottomLeft, at: CGPoint(x: 0, y: height))
            transformHandle(.bottom, at: CGPoint(x: width / 2, y: height))
            transformHandle(.bottomRight, at: CGPoint(x: width, y: height))

            // Crop handles
            cropHandle(.topLeft, at: CGPoint(x: cropX, y: cropY))
            cropHandle(.topRight, at: CGPoint(x: cropX + cropW, y: cropY))
            cropHandle(.bottomLeft, at: CGPoint(x: cropX, y: cropY + cropH))
            cropHandle(.bottomRight, at: CGPoint(x: cropX + cropW, y: cropY + cropH))
        }
        .frame(width: width, height: height)
        .position(x: x + width / 2, y: y + height / 2)
        .allowsHitTesting(false)
    }

    private func transformHandle(_ handle: TransformHandle, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.yellow)
            .frame(width: 10, height: 10)
            .position(point)
    }

    private func cropHandle(_ handle: CropHandle, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .position(point)
    }

    // MARK: - Layer List

    private var layerList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingLayer = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(service.selectedScene == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let scene = service.selectedScene {
                List(selection: $selectedLayerID) {
                    ForEach(scene.layers.sorted(by: { $0.zIndex < $1.zIndex })) { layer in
                        layerRow(layer, scene: scene)
                            .tag(layer.id)
                    }
                    .onMove { indices, newOffset in
                        moveLayers(in: scene, from: indices, to: newOffset)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let layer = scene.layers.sorted(by: { $0.zIndex < $1.zIndex })[index]
                            service.removeLayer(from: scene.id, layerID: layer.id)
                            if selectedLayerID == layer.id { selectedLayerID = nil }
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                Spacer()
            }
        }
        .sheet(isPresented: $isAddingLayer) {
            if let scene = service.selectedScene {
                AddLayerSheet(sceneID: scene.id, service: service)
            }
        }
    }

    private func layerRow(_ layer: SceneLayer, scene: StudioScene) -> some View {
        HStack {
            Image(systemName: icon(for: layer.source))
                .foregroundStyle(layer.isVisible ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.headline)
                Text("\(Int(layer.width))×\(Int(layer.height)) @ (\(Int(layer.x)), \(Int(layer.y)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding(for: layer, in: scene, keyPath: \.isVisible))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit") { selectedLayerID = layer.id }
            Button("Delete") {
                service.removeLayer(from: scene.id, layerID: layer.id)
                if selectedLayerID == layer.id { selectedLayerID = nil }
            }
        }
    }

    // MARK: - Layer Inspector

    private func layerInspector(layer: SceneLayer, scene: StudioScene) -> some View {
        Form {
            Section("Layer") {
                TextField("Name", text: binding(for: layer, in: scene, keyPath: \.name))

                HStack {
                    Text("Opacity")
                    Slider(value: binding(for: layer, in: scene, keyPath: \.opacity), in: 0...1)
                    Text("\(Int(layer.opacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 36)
                }

                HStack {
                    Text("Z-Index")
                    Button("Back") {
                        moveLayerRelative(in: scene, layer: layer, direction: -1)
                    }
                    .disabled(layer.zIndex == 0)
                    Button("Forward") {
                        moveLayerRelative(in: scene, layer: layer, direction: 1)
                    }
                    .disabled(layer.zIndex == scene.layers.map(\.zIndex).max() ?? 0)
                }

                if case .camera(let sourceID) = layer.source {
                    HStack {
                        Text("Camera")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(sourceID.isEmpty ? "None" : sourceID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Reassign…") {
                            reassignCameraLayer = layer
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Transform") {
                HStack {
                    Text("X")
                    DragNumberField(title: "X", value: binding(for: layer, in: scene, keyPath: \.x), step: 1, sensitivity: 1, format: "%.0f")
                    Text("Y")
                    DragNumberField(title: "Y", value: binding(for: layer, in: scene, keyPath: \.y), step: 1, sensitivity: 1, format: "%.0f")
                }
                HStack {
                    Text("Width")
                    DragNumberField(title: "Width", value: binding(for: layer, in: scene, keyPath: \.width), step: 1, sensitivity: 1, format: "%.0f")
                    Text("Height")
                    DragNumberField(title: "Height", value: binding(for: layer, in: scene, keyPath: \.height), step: 1, sensitivity: 1, format: "%.0f")
                }
                HStack {
                    Button("Fit Scene") {
                        fitLayerToScene(in: scene, layer: layer)
                    }
                    Button("Reset") {
                        resetLayerTransform(in: scene, layer: layer)
                    }
                }
            }

            Section("Crop") {
                HStack {
                    Text("X")
                    DragNumberField(title: "Crop X", value: cropBinding(for: layer, in: scene, keyPath: \.x), step: 0.01, sensitivity: 0.005, format: "%.2f")
                    Text("Y")
                    DragNumberField(title: "Crop Y", value: cropBinding(for: layer, in: scene, keyPath: \.y), step: 0.01, sensitivity: 0.005, format: "%.2f")
                }
                HStack {
                    Text("W")
                    DragNumberField(title: "Crop W", value: cropBinding(for: layer, in: scene, keyPath: \.width), step: 0.01, sensitivity: 0.005, format: "%.2f")
                    Text("H")
                    DragNumberField(title: "Crop H", value: cropBinding(for: layer, in: scene, keyPath: \.height), step: 0.01, sensitivity: 0.005, format: "%.2f")
                }
                Button("Reset Crop") {
                    resetLayerCrop(in: scene, layer: layer)
                }
            }

            Section {
                Button("Delete Layer", role: .destructive) {
                    service.removeLayer(from: scene.id, layerID: layer.id)
                    selectedLayerID = nil
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(maxHeight: 320)
        .sheet(item: $reassignCameraLayer) { layerToReassign in
            ReassignCameraSheet(layer: layerToReassign)
        }
    }

    private func moveLayerRelative(in scene: StudioScene, layer: SceneLayer, direction: Int) {
        var updated = layer
        updated.zIndex += direction
        service.updateLayer(in: scene.id, layer: updated)
    }

    private func fitLayerToScene(in scene: StudioScene, layer: SceneLayer) {
        var updated = layer
        updated.x = 0
        updated.y = 0
        updated.width = Double(scene.width)
        updated.height = Double(scene.height)
        service.updateLayer(in: scene.id, layer: updated)
    }

    private func resetLayerTransform(in scene: StudioScene, layer: SceneLayer) {
        var updated = layer
        updated.x = 0
        updated.y = 0
        updated.width = 320
        updated.height = 180
        updated.opacity = 1
        service.updateLayer(in: scene.id, layer: updated)
    }

    private func resetLayerCrop(in scene: StudioScene, layer: SceneLayer) {
        var updated = layer
        updated.crop = .full
        service.updateLayer(in: scene.id, layer: updated)
    }

    private func cropBinding(for layer: SceneLayer, in scene: StudioScene, keyPath: WritableKeyPath<SceneLayerCrop, Double>) -> Binding<Double> {
        Binding {
            layer.crop[keyPath: keyPath]
        } set: { newValue in
            var updated = layer
            updated.crop[keyPath: keyPath] = newValue
            service.updateLayer(in: scene.id, layer: updated)
        }
    }

    private func moveLayers(in scene: StudioScene, from indices: IndexSet, to newOffset: Int) {
        var sorted = scene.layers.sorted(by: { $0.zIndex < $1.zIndex })
        sorted.move(fromOffsets: indices, toOffset: newOffset)
        for (index, layer) in sorted.enumerated() {
            var updated = layer
            updated.zIndex = index
            service.updateLayer(in: scene.id, layer: updated)
        }
    }

    private func binding(for layer: SceneLayer, in scene: StudioScene, keyPath: WritableKeyPath<SceneLayer, Bool>) -> Binding<Bool> {
        Binding {
            layer[keyPath: keyPath]
        } set: { newValue in
            var updated = layer
            updated[keyPath: keyPath] = newValue
            service.updateLayer(in: scene.id, layer: updated)
        }
    }

    private func binding(for layer: SceneLayer, in scene: StudioScene, keyPath: WritableKeyPath<SceneLayer, String>) -> Binding<String> {
        Binding {
            layer[keyPath: keyPath]
        } set: { newValue in
            var updated = layer
            updated[keyPath: keyPath] = newValue
            service.updateLayer(in: scene.id, layer: updated)
        }
    }

    private func binding(for layer: SceneLayer, in scene: StudioScene, keyPath: WritableKeyPath<SceneLayer, Double>) -> Binding<Double> {
        Binding {
            layer[keyPath: keyPath]
        } set: { newValue in
            var updated = layer
            updated[keyPath: keyPath] = newValue
            service.updateLayer(in: scene.id, layer: updated)
        }
    }

    private func icon(for source: SceneSource) -> String {
        switch source {
        case .camera: return "camera.fill"
        case .ndi: return "network.badge.shield.half.filled"
        case .image: return "photo"
        case .text: return "textformat"
        case .color: return "paintpalette"
        case .screen: return "display"
        }
    }
}

// MARK: - Add Layer Sheet

private struct AddLayerSheet: View {
    let sceneID: UUID
    let service: StudioSceneService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sourceType: SceneSourceType = .camera

    @State private var cameraService = TetheringService.shared
    @StateObject private var ndiService = NDIBrowserService.shared
    @State private var selectedCameraSourceID: String = ""
    @State private var selectedNDISource: String = ""
    @State private var imageURL: String = ""
    @State private var textContent: String = "Text"
    @State private var textFontSize: Double = 48
    @State private var textColor: Color = .white
    @State private var textBackgroundColor: Color? = nil
    @State private var fillColor: Color = .black

    enum SceneSourceType: String, CaseIterable, Identifiable {
        case camera
        case ndi
        case image
        case text
        case color
        case screen

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .camera: return "Camera"
            case .ndi: return "NDI Source"
            case .image: return "Image"
            case .text: return "Text"
            case .color: return "Color"
            case .screen: return "Screen Capture"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Layer")
                .font(.title3.bold())

            Form {
                TextField("Name", text: $name)

                Picker("Source Type", selection: $sourceType) {
                    ForEach(SceneSourceType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                sourceSpecificFields
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let source = makeSource()
                    let layer = SceneLayer(name: name.isEmpty ? sourceType.displayName : name, source: source)
                    service.addLayer(to: sceneID, layer: layer)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || !isSourceValid)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            name = "New Layer"
            if let first = ndiService.sources.first {
                selectedNDISource = first.endpoint
            }
        }
        .task {
            await cameraService.discover()
            await MainActor.run {
                setDefaultCameraSelection()
            }
            if ndiService.sources.isEmpty && !ndiService.isScanning {
                ndiService.startScan()
            }
        }
    }

    @ViewBuilder
    private var sourceSpecificFields: some View {
        switch sourceType {
        case .camera:
            HStack {
                Picker("Camera", selection: $selectedCameraSourceID) {
                    ForEach(Array(cameraService.availableSources.enumerated()), id: \.offset) { _, source in
                        Text(source.name).tag(source.id.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Button(action: {
                    Task {
                        await cameraService.discover()
                        await MainActor.run { setDefaultCameraSelection() }
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(cameraService.isDiscovering)
            }
        case .ndi:
            Picker("NDI Source", selection: $selectedNDISource) {
                ForEach(ndiService.sources) { source in
                    Text(source.name).tag(source.endpoint)
                }
            }
            .pickerStyle(.menu)
            if ndiService.sources.isEmpty && !ndiService.isScanning {
                Button("Scan") { ndiService.startScan() }
            }
        case .image:
            TextField("Image URL", text: $imageURL)
            Button("Choose File…") {
                selectImageFile()
            }
        case .text:
            TextField("Text", text: $textContent)
            Slider(value: $textFontSize, in: 12...240, step: 1) {
                Text("Font Size: \(Int(textFontSize))")
            }
            ColorPicker("Text Color", selection: $textColor)
            Toggle("Background", isOn: Binding(
                get: { textBackgroundColor != nil },
                set: { textBackgroundColor = $0 ? Color.black : nil }
            ))
            if textBackgroundColor != nil {
                ColorPicker("Background Color", selection: Binding(
                    get: { textBackgroundColor ?? Color.black },
                    set: { textBackgroundColor = $0 }
                ))
            }
        case .color:
            ColorPicker("Color", selection: $fillColor)
        case .screen:
            Text("Screen capture requires the system screen recording permission. (Placeholder)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isSourceValid: Bool {
        switch sourceType {
        case .camera:
            return !selectedCameraSourceID.isEmpty
        case .ndi:
            return !selectedNDISource.isEmpty
        case .image:
            return !imageURL.isEmpty
        case .text:
            return !textContent.isEmpty
        case .color:
            return true
        case .screen:
            return true
        }
    }

    private func setDefaultCameraSelection() {
        if !selectedCameraSourceID.isEmpty,
           cameraService.availableSources.contains(where: { $0.id.rawValue == selectedCameraSourceID }) {
            return
        }
        if let selectedID = cameraService.selectedSourceID?.rawValue,
           cameraService.availableSources.contains(where: { $0.id.rawValue == selectedID }) {
            selectedCameraSourceID = selectedID
        } else if let first = cameraService.availableSources.first {
            selectedCameraSourceID = first.id.rawValue
        } else {
            selectedCameraSourceID = ""
        }
    }

    private func makeSource() -> SceneSource {
        switch sourceType {
        case .camera:
            return .camera(sourceID: selectedCameraSourceID)
        case .ndi:
            return .ndi(endpoint: selectedNDISource)
        case .image:
            return .image(url: imageURL)
        case .text:
            return .text(
                content: textContent,
                fontSize: textFontSize,
                foregroundColor: SceneColor(textColor),
                backgroundColor: textBackgroundColor.map(SceneColor.init)
            )
        case .color:
            return .color(SceneColor(fillColor))
        case .screen:
            return .screen(descriptor: "")
        }
    }

    private func selectImageFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        if panel.runModal() == .OK, let url = panel.url {
            imageURL = url.absoluteString
        }
    }
}

// MARK: - Drag-to-Adjust Number Field

private struct DragNumberField: View {
    let title: String
    @Binding var value: Double
    let step: Double
    let sensitivity: Double
    let format: String

    @State private var dragStartValue: Double? = nil
    @State private var isDragging = false

    var body: some View {
        TextField(title, value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 44)
            .onHover { isInside in
                if isInside { NSCursor.resizeLeftRight.push() } else { NSCursor.resizeLeftRight.pop() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            dragStartValue = value
                        }
                        let delta = Double(gesture.translation.width) * sensitivity
                        value = dragStartValue! + delta
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                    }
            )
    }
}

// MARK: - Scene Output Sheet

private struct SceneOutputSheet: View {
    let scene: StudioScene
    @Environment(\.dismiss) private var dismiss
    @StateObject private var broadcastService = BroadcastService.shared
    @StateObject private var mixerService = StreamMixerService.shared
    @State private var selectedTarget: SceneOutputTarget = .none
    @State private var showLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scene Output")
                .font(.title3.bold())

            Text("Choose where the composited scene video will be sent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Output", selection: $selectedTarget) {
                Text("None").tag(SceneOutputTarget.none)
                Divider()
                ForEach(broadcastService.sessions) { session in
                    Text("Broadcast: \(session.name)").tag(SceneOutputTarget.broadcast(session.id))
                }
                ForEach(mixerService.routes) { route in
                    Text("Mixer: \(route.name)").tag(SceneOutputTarget.mixerRoute(route.id))
                }
            }
            .pickerStyle(.menu)
            .onAppear {
                selectedTarget = scene.outputTarget
            }

            HStack {
                Button("View Logs") {
                    showLogs.toggle()
                }
                .disabled(SceneOutputService.shared.snapshots[scene.id] == nil)

                Spacer()

                Button("Cancel") { dismiss() }
                Button("Save") {
                    var updated = scene
                    switch selectedTarget {
                    case .broadcast(let id):
                        updated.outputBroadcastSessionID = id
                        updated.outputMixerRouteID = nil
                    case .mixerRoute(let id):
                        updated.outputBroadcastSessionID = nil
                        updated.outputMixerRouteID = id
                    case .none:
                        updated.outputBroadcastSessionID = nil
                        updated.outputMixerRouteID = nil
                    }
                    StudioSceneService.shared.updateScene(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            if showLogs, let snapshot = SceneOutputService.shared.snapshots[scene.id] {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.logs, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(logColor(line))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 200)
                .background(Color.black.opacity(0.2))
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func logColor(_ line: String) -> Color {
        if line.lowercased().contains("error") { return .red }
        if line.lowercased().contains("warning") { return .yellow }
        if line.hasPrefix("[info]") { return .cyan }
        return .primary
    }
}

// MARK: - Reassign Camera Sheet

private struct ReassignCameraSheet: View {
    let layer: SceneLayer
    @Environment(\.dismiss) private var dismiss
    @State private var service = TetheringService.shared
    @State private var selectedSourceID: String = ""

    private var sourceID: String {
        if case .camera(let id) = layer.source { return id }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reassign Camera")
                .font(.title3.bold())

            Picker("Camera", selection: $selectedSourceID) {
                ForEach(Array(service.availableSources.enumerated()), id: \.offset) { _, source in
                    Text(source.name).tag(source.id.rawValue)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Reassign") {
                    NotificationCenter.default.post(
                        name: .reassignCameraLayer,
                        object: nil,
                        userInfo: ["oldSourceID": sourceID, "newSourceID": selectedSourceID]
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSourceID.isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
        .task {
            await service.discover()
            if selectedSourceID.isEmpty, let first = service.availableSources.first {
                selectedSourceID = first.id.rawValue
            }
        }
    }
}

// MARK: - Mouse Tracking Canvas

/// A transparent AppKit-backed overlay that forwards mouse events to SwiftUI
/// so the scene canvas gets precise double-click / drag handling without
/// fighting SwiftUI gesture conflicts.
private struct MouseTrackingCanvas: NSViewRepresentable {
    let onMouseDown: (CGPoint) -> Void
    let onMouseDragged: (CGPoint) -> Void
    let onMouseUp: (CGPoint) -> Void
    let onDoubleClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> MouseTrackingView {
        let view = MouseTrackingView()
        view.onMouseDown = onMouseDown
        view.onMouseDragged = onMouseDragged
        view.onMouseUp = onMouseUp
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: MouseTrackingView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseDragged = onMouseDragged
        nsView.onMouseUp = onMouseUp
        nsView.onDoubleClick = onDoubleClick
    }

    final class MouseTrackingView: NSView {
        var onMouseDown: ((CGPoint) -> Void)?
        var onMouseDragged: ((CGPoint) -> Void)?
        var onMouseUp: ((CGPoint) -> Void)?
        var onDoubleClick: ((CGPoint) -> Void)?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if event.clickCount == 2 {
                onDoubleClick?(point)
            } else {
                onMouseDown?(point)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMouseDragged?(point)
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMouseUp?(point)
        }
    }
}

#Preview {
    StudioSceneView()
}
