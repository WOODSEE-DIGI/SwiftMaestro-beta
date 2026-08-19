import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Canvas view

struct CanvasView: View {
    @Environment(CanvasStore.self) private var store

    @State private var board: CanvasBoard?
    @State private var boardData = CanvasBoardData()
    @State private var showNewBoardSheet = false
    @State private var newBoardName = ""
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            boardList
                .frame(width: 220)
            Divider()
            canvasDetail
        }
        .task {
            store.loadBoards()
        }
        .alert("Canvas Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Board list

    private var boardList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Boards")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showNewBoardSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            List {
                ForEach(store.boards) { b in
                    Button {
                        Task { await persistCurrentBoard() }
                        board = b
                        loadBoard(for: b)
                    } label: {
                        Text(b.name)
                            .lineLimit(1)
                            .foregroundStyle(board?.id == b.id ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        board?.id == b.id ? Color.accentColor.opacity(0.15) : Color.clear
                    )
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            deleteBoardItem(b)
                        }
                        Button("Duplicate") {
                            let copy = store.duplicate(b)
                            board = copy
                            loadBoard(for: copy)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .sheet(isPresented: $showNewBoardSheet) {
            newBoardSheet
        }
    }

    private var newBoardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Board").font(.title3.bold())
            TextField("Board name", text: $newBoardName)
            HStack {
                Spacer()
                Button("Cancel") {
                    showNewBoardSheet = false
                    newBoardName = ""
                }
                Button("Create") {
                    let name = newBoardName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    showNewBoardSheet = false
                    newBoardName = ""
                    let newBoard = store.createBoard(name: name)
                    board = newBoard
                    boardData = CanvasBoardData()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBoardName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 360, height: 160)
    }

    // MARK: - Canvas detail

    @ViewBuilder
    private var canvasDetail: some View {
        if let board {
            FreeformCanvasView(boardData: $boardData, boardName: board.name)
                .id(board.id)
                .onDisappear {
                    Task { await persistCurrentBoard() }
                }
        } else {
            ContentUnavailableView(
                "Select or Create a Board",
                systemImage: "rectangle.3.group",
                description: Text("Choose a board from the list or create a new one")
            )
        }
    }

    // MARK: - Board persistence

    private func loadBoard(for board: CanvasBoard?) {
        guard let board, let data = board.markupData else {
            boardData = CanvasBoardData()
            return
        }
        if let decoded = try? JSONDecoder().decode(CanvasBoardData.self, from: data) {
            boardData = decoded
        } else if let strokes = try? JSONDecoder().decode([Stroke].self, from: data) {
            // Legacy format — strokes only
            boardData = CanvasBoardData(strokes: strokes)
        } else {
            boardData = CanvasBoardData()
        }
    }

    private func persistCurrentBoard() async {
        guard var board else { return }
        if let data = try? JSONEncoder().encode(boardData) {
            board.markupData = data
            try? store.save(board)
        }
    }

    // MARK: - Board actions

    private func duplicateBoard(_ board: CanvasBoard) {
        let copy = store.duplicate(board)
        self.board = copy
        loadBoard(for: copy)
    }

    private func deleteBoard(_ board: CanvasBoard) {
        store.delete(board.id)
        if self.board?.id == board.id {
            self.board = nil
            self.boardData = CanvasBoardData()
        }
    }

    private func deleteBoardItem(_ board: CanvasBoard) {
        store.delete(board.id)
        if self.board?.id == board.id {
            self.board = nil
            self.boardData = CanvasBoardData()
        }
    }
}

// MARK: - Freeform canvas

struct FreeformCanvasView: View {
    @Binding var boardData: CanvasBoardData
    let boardName: String
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedObjectID: UUID?
    @State private var currentTool: CanvasTool = .select
    @State private var currentColor: Color = .white
    @State private var currentLineWidth: CGFloat = 3
    @State private var showShapePicker = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var isPanning = false
    @State private var panStart: CGSize = .zero
    @State private var showGrid = true
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            canvasToolbar
            Divider()
            canvasContent
        }
    }

    // MARK: - Toolbar

    private var canvasToolbar: some View {
        HStack(spacing: 6) {
            Text(boardName)
                .font(.headline)

            Divider().frame(height: 20)

            // Object tools
            Button { currentTool = .select } label: {
                Image(systemName: "cursorarrow")
                    .foregroundStyle(currentTool == .select ? .blue : .secondary)
            }
            .help("Select & Move")

            Button { currentTool = .pen } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(currentTool == .pen ? currentColor : .secondary)
            }
            .help("Draw")

            Button { currentTool = .eraser } label: {
                Image(systemName: "eraser")
                    .foregroundStyle(currentTool == .eraser ? .red : .secondary)
            }
            .help("Eraser")

            Divider().frame(height: 16)

            // Insert tools
            Button {
                insertStickyNote()
            } label: {
                Image(systemName: "square.and.line.vertical.and.square")
                    .foregroundStyle(.yellow)
            }
            .help("Add Sticky Note")

            Button {
                insertTextBox()
            } label: {
                Image(systemName: "textformat")
                    .foregroundStyle(.secondary)
            }
            .help("Add Text Box")

            Menu {
                shapeMenu
            } label: {
                Image(systemName: "square.on.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help("Add Shape")

            Button {
                insertImage()
            } label: {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
            .help("Add Image")

            Divider().frame(height: 16)

            // Drawing tools (shown when pen/eraser active)
            if currentTool == .pen || currentTool == .eraser {
                ColorPicker("", selection: $currentColor)
                    .labelsHidden()
                    .frame(width: 28)

                Menu {
                    ForEach([2.0, 3.0, 5.0, 8.0, 12.0], id: \.self) { w in
                        Button {
                            currentLineWidth = w
                        } label: {
                            HStack {
                                Circle().fill(currentColor).frame(width: w * 2, height: w * 2)
                                Text("\(Int(w))pt")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }

            Spacer()

            // Grid toggle
            Button {
                showGrid.toggle()
            } label: {
                Image(systemName: showGrid ? "rectangle.grid.3x2" : "rectangle.dashed")
                    .foregroundStyle(.secondary)
            }
            .help("Toggle Grid")

            // Zoom (anchored to the viewport centre, not the canvas origin)
            HStack(spacing: 4) {
                Button { setZoom(max(0.25, zoomScale - 0.25)) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Text("\(Int(zoomScale * 100))%")
                    .font(.caption)
                    .frame(width: 40)
                Button { setZoom(min(4.0, zoomScale + 0.25)) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button { zoomScale = 1.0; panOffset = .zero } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.circle")
                }
                .help("Reset zoom and pan")
            }

            Divider().frame(height: 16)

            // Undo / Clear
            Button { undoLast() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Undo")

            Button { clearAll() } label: {
                Image(systemName: "trash")
            }
            .help("Clear All")

            Divider().frame(height: 16)

            // Export
            Menu {
                Button { exportBoard(as: .pngTransparent) } label: {
                    Label("PNG (Transparent)", systemImage: "photo")
                }
                Button { exportBoard(as: .pngWhite) } label: {
                    Label("PNG (White Background)", systemImage: "photo")
                }
                Button { exportBoard(as: .jpg) } label: {
                    Label("JPEG", systemImage: "photo")
                }
                Divider()
                Button { exportBoard(as: .pdf) } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button { exportBoard(as: .svg) } label: {
                    Label("SVG", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .help("Export Board")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Shape menu

    @ViewBuilder
    private var shapeMenu: some View {
        Button {
            insertShape(.rectangle)
        } label: {
            Label("Rectangle", systemImage: "rectangle")
        }
        Button {
            insertShape(.roundedRectangle)
        } label: {
            Label("Rounded Rectangle", systemImage: "rectangle.roundedtogether")
        }
        Button {
            insertShape(.circle)
        } label: {
            Label("Circle", systemImage: "circle")
        }
        Button {
            insertShape(.ellipse)
        } label: {
            Label("Ellipse", systemImage: "oval")
        }
        Button {
            insertShape(.diamond)
        } label: {
            Label("Diamond", systemImage: "diamond")
        }
        Button {
            insertShape(.arrow)
        } label: {
            Label("Arrow", systemImage: "arrow.right")
        }
        Button {
            insertShape(.star)
        } label: {
            Label("Star", systemImage: "star")
        }
        Button {
            insertShape(.cloud)
        } label: {
            Label("Cloud", systemImage: "cloud")
        }
        Button {
            insertShape(.heart)
        } label: {
            Label("Heart", systemImage: "heart")
        }
    }

    // MARK: - Canvas content

    private var canvasContent: some View {
        GeometryReader { geo in
            let isDark = colorScheme == .dark
            let bgColor = isDark ? Color(white: 0.12) : Color(white: 0.95)
            let gridDotColor = isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.15)

            ZStack {
                // Background — drag on empty canvas pans the view (in pen/eraser
                // mode the drawing layer on top takes the events instead), tap
                // deselects.
                bgColor
                    .ignoresSafeArea()
                    .onTapGesture { selectedObjectID = nil }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isPanning {
                                    isPanning = true
                                    panStart = panOffset
                                }
                                panOffset = CGSize(
                                    width: panStart.width + value.translation.width,
                                    height: panStart.height + value.translation.height
                                )
                            }
                            .onEnded { _ in isPanning = false }
                    )

                // Grid background (follows zoom + pan)
                if showGrid {
                    CanvasGridBackground(dotColor: gridDotColor)
                        .scaleEffect(zoomScale, anchor: .topLeading)
                        .offset(panOffset)
                        .allowsHitTesting(false)
                }

                // Objects layer
                ForEach(boardData.objects) { obj in
                    CanvasObjectView(
                        object: obj,
                        isSelected: obj.id == selectedObjectID,
                        zoomScale: zoomScale,
                        onUpdate: { updated in
                            updateObject(updated)
                        },
                        onSelect: {
                            selectedObjectID = obj.id
                        },
                        onDelete: {
                            deleteObject(obj.id)
                        }
                    )
                    .position(
                        x: obj.position.x * zoomScale + panOffset.width,
                        y: obj.position.y * zoomScale + panOffset.height
                    )
                    .scaleEffect(zoomScale)
                }

                // Drawing layer (pen/eraser). Hit-transparent in select mode so
                // objects beneath it can be grabbed — see DrawingNSView.hitTest.
                DrawingCanvasView(
                    strokes: Binding(
                        get: { boardData.strokes },
                        set: { boardData.strokes = $0 }
                    ),
                    tool: currentTool,
                    color: currentColor,
                    lineWidth: currentLineWidth,
                    zoomScale: zoomScale,
                    panOffset: panOffset
                )
            }
            .clipShape(Rectangle())
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
        }
    }

    /// Change zoom while keeping the canvas point under the viewport centre
    /// fixed — the old buttons zoomed toward the canvas origin (top-left),
    /// which flung content off screen.
    private func setZoom(_ newZoom: CGFloat) {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            zoomScale = newZoom
            return
        }
        let viewportCentre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        // Canvas point currently under the viewport centre…
        let anchor = CGPoint(
            x: (viewportCentre.x - panOffset.width) / zoomScale,
            y: (viewportCentre.y - panOffset.height) / zoomScale
        )
        zoomScale = newZoom
        // …kept under the viewport centre at the new zoom.
        panOffset = CGSize(
            width: viewportCentre.x - anchor.x * newZoom,
            height: viewportCentre.y - anchor.y * newZoom
        )
    }

    /// Canvas-coordinate centre of the currently visible viewport — new objects
    /// insert here so they're always on screen, whatever the zoom/pan.
    private var visibleCentre: CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return CGPoint(x: 300, y: 300)
        }
        return CGPoint(
            x: (canvasSize.width / 2 - panOffset.width) / zoomScale,
            y: (canvasSize.height / 2 - panOffset.height) / zoomScale
        )
    }

    /// Slight cascade so stacked inserts don't perfectly overlap.
    private func cascadedInsertPoint() -> CGPoint {
        let centre = visibleCentre
        let step = CGFloat(boardData.objects.count % 8) * 24
        return CGPoint(x: centre.x + step, y: centre.y + step)
    }

    // MARK: - Insert actions

    private func insertStickyNote() {
        let colors = ["#FFE066", "#FF9F9B", "#A8E6CF", "#B5DEFF", "#E8DAEF"]
        let color = colors.randomElement()!
        let obj = CanvasObject(
            type: .stickyNote(color: color),
            text: "Note",
            position: cascadedInsertPoint(),
            size: CGSize(width: 200, height: 200)
        )
        boardData.objects.append(obj)
        selectedObjectID = obj.id
        currentTool = .select
    }

    private func insertTextBox() {
        let obj = CanvasObject(
            type: .textBox,
            text: "Text",
            position: cascadedInsertPoint(),
            size: CGSize(width: 250, height: 60)
        )
        boardData.objects.append(obj)
        selectedObjectID = obj.id
        currentTool = .select
    }

    private func insertShape(_ shape: CanvasObject.ShapeKind) {
        let obj = CanvasObject(
            type: .shape(shape),
            text: "",
            position: cascadedInsertPoint(),
            size: CGSize(width: 150, height: 150)
        )
        boardData.objects.append(obj)
        selectedObjectID = obj.id
        currentTool = .select
    }

    private func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let obj = CanvasObject(
            type: .image(data),
            text: "",
            position: cascadedInsertPoint(),
            size: CGSize(width: 300, height: 300)
        )
        boardData.objects.append(obj)
        selectedObjectID = obj.id
        currentTool = .select
    }

    private func updateObject(_ updated: CanvasObject) {
        if let idx = boardData.objects.firstIndex(where: { $0.id == updated.id }) {
            boardData.objects[idx] = updated
        }
    }

    private func deleteObject(_ id: UUID) {
        boardData.objects.removeAll { $0.id == id }
        if selectedObjectID == id { selectedObjectID = nil }
    }

    private func undoLast() {
        if !boardData.strokes.isEmpty {
            boardData.strokes.removeLast()
        } else if !boardData.objects.isEmpty {
            boardData.objects.removeLast()
        }
    }

    private func clearAll() {
        boardData.strokes.removeAll()
        boardData.objects.removeAll()
        selectedObjectID = nil
    }

    // MARK: - Export

    enum ExportFormat {
        case pngTransparent, pngWhite, jpg, pdf, svg
    }

    private func exportBoard(as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Board"
        panel.nameFieldStringValue = "\(boardName).\(fileExtension(for: format))"
        panel.allowedContentTypes = fileTypes(for: format)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Calculate bounding box of all content
        let contentSize = calculateContentSize()

        switch format {
        case .pngTransparent, .pngWhite:
            if let image = renderBoardImage(size: contentSize, background: format == .pngTransparent ? nil : (colorScheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1))) {
                saveImage(image, to: url, type: .png)
            }
        case .jpg:
            let bgColor = colorScheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)
            if let image = renderBoardImage(size: contentSize, background: bgColor) {
                saveImage(image, to: url, type: .jpeg)
            }
        case .pdf:
            exportPDF(to: url, size: contentSize)
        case .svg:
            exportSVG(to: url)
        }
    }

    private func calculateContentSize() -> CGSize {
        // NOTE: CanvasObject.position is the object's CENTRE (the display layer
        // uses SwiftUI .position). Export used to treat it as top-left, which
        // shifted every object down-right by half its size in exported files.
        var maxX: CGFloat = 800
        var maxY: CGFloat = 600
        for obj in boardData.objects {
            maxX = max(maxX, obj.position.x + obj.size.width / 2 + 40)
            maxY = max(maxY, obj.position.y + obj.size.height / 2 + 40)
        }
        for stroke in boardData.strokes {
            for pt in stroke.points {
                maxX = max(maxX, pt.x + 40)
                maxY = max(maxY, pt.y + 40)
            }
        }
        return CGSize(width: maxX, height: maxY)
    }

    private func renderBoardImage(size: CGSize, background: NSColor?) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        // Background
        if let bg = background {
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        // Draw strokes
        for stroke in boardData.strokes {
            drawStrokeForExport(stroke, in: ctx)
        }

        // Draw objects
        for obj in boardData.objects {
            drawObjectForExport(obj, in: ctx, size: size)
        }

        image.unlockFocus()
        return image
    }

    private func drawStrokeForExport(_ stroke: Stroke, in ctx: CGContext) {
        guard let c = NSColor(hexString: stroke.color), stroke.points.count >= 2 else { return }
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(stroke.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: stroke.points[0])
        for i in 1..<stroke.points.count {
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            ctx.addQuadCurve(to: CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2), control: prev)
        }
        ctx.addLine(to: stroke.points.last!)
        ctx.strokePath()
    }

    private func drawObjectForExport(_ obj: CanvasObject, in ctx: CGContext, size: CGSize) {
        // position is the CENTRE (display uses SwiftUI .position)
        let rect = CGRect(x: obj.position.x - obj.size.width / 2,
                          y: obj.position.y - obj.size.height / 2,
                          width: obj.size.width, height: obj.size.height)

        switch obj.type {
        case .stickyNote(let color):
            if let c = NSColor(hexString: color) {
                ctx.setFillColor(c.cgColor)
                let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }
            // Draw text
            if !obj.text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.black
                ]
                let str = NSAttributedString(string: obj.text, attributes: attrs)
                let textRect = CGRect(x: rect.minX + 8, y: rect.minY + 8, width: rect.width - 16, height: rect.height - 16)
                str.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
            }

        case .textBox:
            let border = NSColor.white.withAlphaComponent(0.3)
            ctx.setStrokeColor(border.cgColor)
            ctx.setLineWidth(1)
            let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(path)
            ctx.strokePath()
            if !obj.text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: NSColor.white
                ]
                let str = NSAttributedString(string: obj.text, attributes: attrs)
                let textRect = CGRect(x: rect.minX + 8, y: rect.minY + 8, width: rect.width - 16, height: rect.height - 16)
                str.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
            }

        case .shape(let kind):
            if let c = NSColor(hexString: obj.shapeColor) {
                ctx.setFillColor(c.cgColor)
                ctx.setStrokeColor(c.withAlphaComponent(0.8).cgColor)
                ctx.setLineWidth(2)
                let path = shapeCGPath(in: rect, kind: kind)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.strokePath()
            }

        case .image(let data):
            if let img = NSImage(data: data) {
                img.draw(in: rect)
            }
        }
    }

    private func shapeCGPath(in rect: CGRect, kind: CanvasObject.ShapeKind) -> CGPath {
        let path = CGMutablePath()
        switch kind {
        case .rectangle:
            path.addRect(rect)
        case .roundedRectangle:
            path.addRoundedRect(in: rect, cornerWidth: 12, cornerHeight: 12)
        case .circle, .ellipse:
            path.addEllipse(in: rect)
        case .diamond:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        case .arrow:
            let midY = rect.midY
            path.move(to: CGPoint(x: rect.minX, y: midY))
            path.addLine(to: CGPoint(x: rect.maxX - 20, y: midY))
            path.move(to: CGPoint(x: rect.maxX - 20, y: midY - 15))
            path.addLine(to: CGPoint(x: rect.maxX, y: midY))
            path.addLine(to: CGPoint(x: rect.maxX - 20, y: midY + 15))
        case .star:
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerR = min(rect.width, rect.height) / 2
            let innerR = outerR * 0.4
            for i in 0..<5 {
                let outerA = CGFloat(i) * .pi * 2 / 5 - .pi / 2
                let innerA = outerA + .pi / 5
                let op = CGPoint(x: center.x + cos(outerA) * outerR, y: center.y + sin(outerA) * outerR)
                let ip = CGPoint(x: center.x + cos(innerA) * innerR, y: center.y + sin(innerA) * innerR)
                if i == 0 { path.move(to: op) } else { path.addLine(to: op) }
                path.addLine(to: ip)
            }
            path.closeSubpath()
        case .cloud:
            path.addEllipse(in: rect)
        case .heart:
            let center = CGPoint(x: rect.midX, y: rect.midY + 5)
            let s = min(rect.width, rect.height) / 2
            path.move(to: CGPoint(x: center.x, y: center.y + s * 0.7))
            path.addCurve(to: CGPoint(x: center.x - s, y: center.y),
                          control1: CGPoint(x: center.x - s, y: center.y + s * 0.4),
                          control2: CGPoint(x: center.x - s * 0.5, y: center.y - s * 0.3))
            path.addCurve(to: CGPoint(x: center.x, y: center.y + s * 0.3),
                          control1: CGPoint(x: center.x - s * 0.5, y: center.y - s * 0.1),
                          control2: CGPoint(x: center.x - s * 0.2, y: center.y + s * 0.1))
            path.addCurve(to: CGPoint(x: center.x + s, y: center.y),
                          control1: CGPoint(x: center.x + s * 0.2, y: center.y + s * 0.1),
                          control2: CGPoint(x: center.x + s * 0.5, y: center.y - s * 0.1))
            path.addCurve(to: CGPoint(x: center.x, y: center.y + s * 0.7),
                          control1: CGPoint(x: center.x + s * 0.5, y: center.y - s * 0.3),
                          control2: CGPoint(x: center.x + s, y: center.y + s * 0.4))
            path.closeSubpath()
        }
        return path
    }

    private func saveImage(_ image: NSImage, to url: URL, type: NSBitmapImageRep.FileType) {
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let data = rep.representation(using: type, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private func exportPDF(to url: URL, size: CGSize) {
        let image = renderBoardImage(size: size, background: colorScheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1))
        guard let image else { return }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
        ctx.beginPage(mediaBox: &box)
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            if let cgImage = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
            }
        }
        ctx.endPage()
        ctx.closePDF()
        try? (data as Data).write(to: url)
    }

    private func exportSVG(to url: URL) {
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(calculateContentSize().width))\" height=\"\(Int(calculateContentSize().height))\">\n"

        // Strokes
        for stroke in boardData.strokes {
            guard stroke.points.count >= 2 else { continue }
            let pathStr = stroke.points.enumerated().map { i, pt in
                i == 0 ? "M \(Int(pt.x)) \(Int(pt.y))" : "L \(Int(pt.x)) \(Int(pt.y))"
            }.joined(separator: " ")
            svg += "<path d=\"\(pathStr)\" stroke=\"\(stroke.color)\" stroke-width=\"\(stroke.width)\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
        }

        // Objects (position is the CENTRE — match the display layer)
        for obj in boardData.objects {
            let x = Int(obj.position.x - obj.size.width / 2)
            let y = Int(obj.position.y - obj.size.height / 2)
            let w = Int(obj.size.width), h = Int(obj.size.height)
            switch obj.type {
            case .stickyNote(let color):
                svg += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" fill=\"\(color)\" rx=\"4\"/>\n"
                if !obj.text.isEmpty {
                    svg += "<text x=\"\(x+8)\" y=\"\(y+20)\" font-size=\"14\" fill=\"black\">\(obj.text)</text>\n"
                }
            case .textBox:
                svg += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" fill=\"none\" stroke=\"rgba(255,255,255,0.3)\" stroke-width=\"1\" rx=\"4\"/>\n"
                if !obj.text.isEmpty {
                    svg += "<text x=\"\(x+8)\" y=\"\(y+20)\" font-size=\"16\" fill=\"white\">\(obj.text)</text>\n"
                }
            case .shape(let kind):
                svg += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" fill=\"\(obj.shapeColor)\" rx=\"4\"/>\n"
            case .image:
                break // SVG export of embedded binary images not supported
            }
        }

        svg += "</svg>"
        try? svg.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fileExtension(for format: ExportFormat) -> String {
        switch format {
        case .pngTransparent, .pngWhite: return "png"
        case .jpg: return "jpg"
        case .pdf: return "pdf"
        case .svg: return "svg"
        }
    }

    private func fileTypes(for format: ExportFormat) -> [UTType] {
        switch format {
        case .pngTransparent, .pngWhite: return [.png]
        case .jpg: return [.jpeg]
        case .pdf: return [.pdf]
        case .svg: return [.svg]
        }
    }
}

// MARK: - Grid background

struct CanvasGridBackground: View {
    let dotColor: Color

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 20

            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    y += spacing
                }
                x += spacing
            }
        }
    }
}

// MARK: - Canvas object view

struct CanvasObjectView: View {
    let object: CanvasObject
    let isSelected: Bool
    let zoomScale: CGFloat
    var onUpdate: (CanvasObject) -> Void
    var onSelect: () -> Void
    var onDelete: () -> Void

    @State private var isDragging = false
    @State private var isResizing = false
    @State private var dragOffset: CGSize = .zero
    @State private var resizeOffset: CGSize = .zero
    @State private var isEditingText = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Object content (clamped so a fast drag can't invert the frame)
            objectContent
                .frame(width: max(40, object.size.width + resizeOffset.width),
                       height: max(40, object.size.height + resizeOffset.height))
                .overlay(
                    RoundedRectangle(cornerRadius: object.cornerRadius)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            // Resize handles (when selected)
            if isSelected && !isEditingText {
                resizeHandles
            }
        }
        .offset(dragOffset)
        .onTapGesture {
            onSelect()
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                    }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    isDragging = false
                    var updated = object
                    updated.position.x += value.translation.width / zoomScale
                    updated.position.y += value.translation.height / zoomScale
                    dragOffset = .zero
                    onUpdate(updated)
                }
        )
    }

    @ViewBuilder
    private var objectContent: some View {
        switch object.type {
        case .stickyNote(let color):
            StickyNoteView(
                text: Binding(
                    get: { object.text },
                    set: { var o = object; o.text = $0; onUpdate(o) }
                ),
                color: Color(hex: color) ?? .yellow,
                isEditing: $isEditingText
            )

        case .textBox:
            TextBoxView(
                text: Binding(
                    get: { object.text },
                    set: { var o = object; o.text = $0; onUpdate(o) }
                ),
                isEditing: $isEditingText
            )

        case .shape(let kind):
            ShapeView(kind: kind, color: object.shapeColor)

        case .image(let data):
            ImageView(data: data)
        }
    }

    private var resizeHandles: some View {
        GeometryReader { geo in
            // Bottom-right resize handle. The gesture translation arrives in
            // SCREEN points but this view's frame is rendered through the
            // parent's scaleEffect — so the live preview divides by zoomScale
            // or the corner runs ahead of/behind the pointer at any zoom ≠ 1.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .position(x: geo.size.width - 5, y: geo.size.height - 5)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            resizeOffset = CGSize(
                                width: value.translation.width / zoomScale,
                                height: value.translation.height / zoomScale
                            )
                        }
                        .onEnded { value in
                            var updated = object
                            // Clamp: never smaller than a usable touch target,
                            // never inverted by a drag past the top-left edge.
                            updated.size.width = max(40, object.size.width + value.translation.width / zoomScale)
                            updated.size.height = max(40, object.size.height + value.translation.height / zoomScale)
                            resizeOffset = .zero
                            onUpdate(updated)
                        }
                )
        }
    }
}

// MARK: - Sticky note view

struct StickyNoteView: View {
    @Binding var text: String
    let color: Color
    @Binding var isEditing: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 2, y: 2)

            if isEditing {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.black)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onTapGesture(count: 2) {
                        isEditing = true
                    }
            }
        }
        .onTapGesture {
            isEditing = false
        }
    }
}

// MARK: - Text box view

struct TextBoxView: View {
    @Binding var text: String
    @Binding var isEditing: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )

            if isEditing {
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onTapGesture(count: 2) {
                        isEditing = true
                    }
            }
        }
        .onTapGesture {
            isEditing = false
        }
    }
}

// MARK: - Shape view

struct ShapeView: View {
    let kind: CanvasObject.ShapeKind
    let color: String

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let fillColor = Color(hex: color) ?? .blue
            context.fill(shapePath(in: rect, kind: kind), with: .color(fillColor))
            context.stroke(shapePath(in: rect, kind: kind), with: .color(fillColor.opacity(0.8)), lineWidth: 2)
        }
    }

    private func shapePath(in rect: CGRect, kind: CanvasObject.ShapeKind) -> Path {
        switch kind {
        case .rectangle:
            return Path(roundedRect: rect, cornerRadius: 0)
        case .roundedRectangle:
            return Path(roundedRect: rect, cornerRadius: 12)
        case .circle:
            return Path(ellipseIn: rect)
        case .ellipse:
            return Path(ellipseIn: rect)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        case .arrow:
            var path = Path()
            let midY = rect.midY
            path.move(to: CGPoint(x: rect.minX, y: midY))
            path.addLine(to: CGPoint(x: rect.maxX - 20, y: midY))
            path.move(to: CGPoint(x: rect.maxX - 20, y: midY - 15))
            path.addLine(to: CGPoint(x: rect.maxX, y: midY))
            path.addLine(to: CGPoint(x: rect.maxX - 20, y: midY + 15))
            return path
        case .star:
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerRadius = min(rect.width, rect.height) / 2
            let innerRadius = outerRadius * 0.4
            for i in 0..<5 {
                let outerAngle = CGFloat(i) * .pi * 2 / 5 - .pi / 2
                let innerAngle = outerAngle + .pi / 5
                let outerPoint = CGPoint(x: center.x + cos(outerAngle) * outerRadius,
                                         y: center.y + sin(outerAngle) * outerRadius)
                let innerPoint = CGPoint(x: center.x + cos(innerAngle) * innerRadius,
                                         y: center.y + sin(innerAngle) * innerRadius)
                if i == 0 {
                    path.move(to: outerPoint)
                } else {
                    path.addLine(to: outerPoint)
                }
                path.addLine(to: innerPoint)
            }
            path.closeSubpath()
            return path
        case .cloud:
            return Path(ellipseIn: rect)
        case .heart:
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY + 5)
            let size = min(rect.width, rect.height) / 2
            path.move(to: CGPoint(x: center.x, y: center.y + size * 0.7))
            path.addCurve(to: CGPoint(x: center.x - size, y: center.y),
                          control1: CGPoint(x: center.x - size, y: center.y + size * 0.4),
                          control2: CGPoint(x: center.x - size * 0.5, y: center.y - size * 0.3))
            path.addCurve(to: CGPoint(x: center.x, y: center.y + size * 0.3),
                          control1: CGPoint(x: center.x - size * 0.5, y: center.y - size * 0.1),
                          control2: CGPoint(x: center.x - size * 0.2, y: center.y + size * 0.1))
            path.addCurve(to: CGPoint(x: center.x + size, y: center.y),
                          control1: CGPoint(x: center.x + size * 0.2, y: center.y + size * 0.1),
                          control2: CGPoint(x: center.x + size * 0.5, y: center.y - size * 0.1))
            path.addCurve(to: CGPoint(x: center.x, y: center.y + size * 0.7),
                          control1: CGPoint(x: center.x + size * 0.5, y: center.y - size * 0.3),
                          control2: CGPoint(x: center.x + size, y: center.y + size * 0.4))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Image view

struct ImageView: View {
    let data: Data

    var body: some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(4)
                .shadow(color: .black.opacity(0.15), radius: 3, x: 1, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - Drawing canvas (AppKit)

struct DrawingCanvasView: NSViewRepresentable {
    @Binding var strokes: [Stroke]
    let tool: CanvasTool
    let color: Color
    let lineWidth: CGFloat
    let zoomScale: CGFloat
    let panOffset: CGSize

    func makeNSView(context: Context) -> DrawingNSView {
        let nsView = DrawingNSView()
        nsView.onStrokesChanged = { strokes = $0 }
        nsView.currentTool = tool
        nsView.currentNSColor = NSColor(color)
        nsView.currentLineWidth = lineWidth
        nsView.zoomScale = zoomScale
        nsView.panOffset = panOffset
        return nsView
    }

    func updateNSView(_ nsView: DrawingNSView, context: Context) {
        nsView.currentTool = tool
        nsView.currentNSColor = NSColor(color)
        nsView.currentLineWidth = lineWidth
        var needsDisplay = false
        if nsView.zoomScale != zoomScale || nsView.panOffset != panOffset {
            nsView.zoomScale = zoomScale
            nsView.panOffset = panOffset
            needsDisplay = true
        }
        if nsView.strokes != strokes {
            nsView.strokes = strokes
            needsDisplay = true
        }
        if needsDisplay { nsView.needsDisplay = true }
    }
}

final class DrawingNSView: NSView {
    var strokes: [Stroke] = []
    var onStrokesChanged: (([Stroke]) -> Void)?
    var currentTool: CanvasTool = .select
    var currentNSColor: NSColor = .white
    var currentLineWidth: CGFloat = 3
    var zoomScale: CGFloat = 1.0
    var panOffset: CGSize = .zero

    private var currentPoints: [CGPoint] = []
    private var isDrawing = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    /// In select mode this layer must be transparent to the mouse: it sits ON
    /// TOP of the SwiftUI object layer, and the default NSView hit-test used
    /// to swallow every click — making objects impossible to grab, move, or
    /// resize no matter which tool was active. Only pen and eraser need events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard currentTool == .pen || currentTool == .eraser else { return nil }
        return super.hitTest(point)
    }

    /// Strokes are stored in CANVAS coordinates (zoom/pan independent). Convert
    /// a view-space event point into canvas space before storing/hit-testing.
    private func canvasPoint(for event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: (viewPoint.x - panOffset.width) / zoomScale,
            y: (viewPoint.y - panOffset.height) / zoomScale
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard currentTool == .pen || currentTool == .eraser else { return }

        if currentTool == .eraser {
            if let idx = nearestStrokeIndex(to: canvasPoint(for: event)) {
                strokes.remove(at: idx)
                onStrokesChanged?(strokes)
                needsDisplay = true
            }
            return
        }

        isDrawing = true
        currentPoints = [canvasPoint(for: event)]
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawing else { return }
        currentPoints.append(canvasPoint(for: event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawing else { return }
        isDrawing = false

        if currentPoints.count > 1 {
            strokes.append(Stroke(
                points: currentPoints,
                color: currentNSColor.hexString,
                width: currentLineWidth
            ))
            onStrokesChanged?(strokes)
        }
        currentPoints = []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Render canvas-space strokes through the same zoom + pan transform
        // the object layer uses, so drawing and objects never drift apart.
        ctx.saveGState()
        ctx.translateBy(x: panOffset.width, y: panOffset.height)
        ctx.scaleBy(x: zoomScale, y: zoomScale)

        for stroke in strokes { drawStroke(stroke, in: ctx) }

        if isDrawing && currentPoints.count > 1 {
            drawStroke(Stroke(points: currentPoints, color: currentNSColor.hexString, width: currentLineWidth), in: ctx)
        }

        ctx.restoreGState()
    }

    private func drawStroke(_ stroke: Stroke, in ctx: CGContext) {
        guard let c = NSColor(hexString: stroke.color), stroke.points.count >= 2 else { return }
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(stroke.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: stroke.points[0])
        for i in 1..<stroke.points.count {
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            ctx.addQuadCurve(to: CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2), control: prev)
        }
        ctx.addLine(to: stroke.points.last!)
        ctx.strokePath()
    }

    /// Hit-test in canvas space; tolerance scales with zoom so the eraser
    /// covers a consistent ~20 screen points at any zoom level.
    private func nearestStrokeIndex(to point: CGPoint) -> Int? {
        let tolerance = 20 / max(zoomScale, 0.01)
        var best: (Int, CGFloat)?
        for (i, s) in strokes.enumerated() {
            for p in s.points {
                let d = hypot(p.x - point.x, p.y - point.y)
                if d < tolerance, best.map({ d < $0.1 }) ?? true { best = (i, d) }
            }
        }
        return best?.0
    }
}

// MARK: - Models

enum CanvasTool: String, CaseIterable {
    case select, pen, eraser
}

struct CanvasBoardData: Codable {
    var strokes: [Stroke] = []
    var objects: [CanvasObject] = []
}

struct Stroke: Codable, Equatable {
    let points: [CGPoint]
    let color: String
    let width: CGFloat
}

struct CanvasObject: Codable, Identifiable {
    let id: UUID
    var type: ObjectType
    var text: String
    var position: CGPoint
    var size: CGSize
    var shapeColor: String
    var textColor: String
    var cornerRadius: CGFloat

    init(id: UUID = UUID(), type: ObjectType, text: String, position: CGPoint, size: CGSize,
         shapeColor: String = "#3498DB", textColor: String = "#000000", cornerRadius: CGFloat = 4) {
        self.id = id
        self.type = type
        self.text = text
        self.position = position
        self.size = size
        self.shapeColor = shapeColor
        self.textColor = textColor
        self.cornerRadius = cornerRadius
    }

    enum ShapeKind: String, Codable {
        case rectangle, roundedRectangle, circle, ellipse, diamond, arrow, star, cloud, heart
    }

    enum ObjectType: Codable {
        case stickyNote(color: String)
        case textBox
        case shape(ShapeKind)
        case image(Data)
    }
}

// MARK: - Color helpers

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.genericRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }

    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6,
              let r = UInt8(hex[hex.startIndex..<hex.index(hex.startIndex, offsetBy: 2)], radix: 16),
              let g = UInt8(hex[hex.index(hex.startIndex, offsetBy: 2)..<hex.index(hex.startIndex, offsetBy: 4)], radix: 16),
              let b = UInt8(hex[hex.index(hex.startIndex, offsetBy: 4)..<hex.index(hex.startIndex, offsetBy: 6)], radix: 16)
        else { return nil }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1.0)
    }
}

// MARK: - Preview

#Preview {
    CanvasView()
        .environment(CanvasStore())
}