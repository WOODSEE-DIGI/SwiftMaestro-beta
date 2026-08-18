import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Overlay Builder View

/// Full-featured overlay builder panel for live video production.
/// Renders overlays at 1920×1080 and exports transparent PNGs.
struct OverlayBuilderView: View {
    @State private var store = OverlayBuilderStore.shared
    @State private var showExportAll = false
    @State private var showForm = true
    @State private var showSafeAreas = false
    @State private var exportAlertMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            // ── Overlay type list ──
            overlayList
                .frame(minWidth: 140, idealWidth: 180, maxWidth: 240)

            Divider()

            // ── Inspector (collapsible) ──
            if showForm {
                formPanel
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            // ── Preview + toolbar (fills remaining space) ──
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 10) {
                    Button { showForm.toggle() } label: {
                        Image(systemName: "sidebar.left")
                            .foregroundStyle(showForm ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Inspector")

                    Text(store.selectedType.displayName)
                        .font(.headline)

                    Spacer()

                    // Hide canvas picker for HTML editor (it manages its own)
                    if store.selectedType != .htmlEditor {
                        Picker("Canvas", selection: Binding(
                            get: { store.canvasSizeIndex },
                            set: { store.canvasSizeIndex = $0; store.saveGlobals() }
                        )) {
                            Text("Custom").tag(CanvasSizePresets.customIndex)
                            ForEach(Array(CanvasSizePresets.all.enumerated()), id: \.offset) { i, size in
                                Text(size.label).tag(i)
                            }
                        }
                        .pickerStyle(.menu)

                        Text("\(store.canvasWidth)×\(store.canvasHeight)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()

                        Toggle(isOn: $showSafeAreas) {
                            Label("Safe Areas", systemImage: "rectangle.badge.checkmark")
                                .font(.caption)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Show platform safe area guides on canvas")

                        Button("Export PNG") { exportPNG() }
                        Button("Export All") { showExportAll = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)

                Divider()

                // Content: HTML editor or normal preview
                if store.selectedType == .htmlEditor {
                    OverlayHTMLEditorView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Preview (fills all remaining space)
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: showForm)
        .confirmationDialog("Export All Overlays", isPresented: $showExportAll) {
            Button("Export All as PNG") { exportAllPNG() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Export", isPresented: Binding(
            get: { exportAlertMessage != nil },
            set: { if !$0 { exportAlertMessage = nil } }
        )) {
            Button("OK") { exportAlertMessage = nil }
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    // MARK: - Overlay List

    private var overlayList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groupedOverlays, id: \.key) { group, items in
                    Section {
                        ForEach(items) { type in
                            overlayRow(type)
                        }
                    } header: {
                        Text(group.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private var groupedOverlays: [(key: String, value: [OverlayType])] {
        let grouped = Dictionary(grouping: OverlayType.allCases, by: \.group)
        return grouped.sorted { $0.key < $1.key }
    }

    private func overlayRow(_ type: OverlayType) -> some View {
        Button {
            store.selectType(type)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: type.icon)
                    .frame(width: 20)
                    .foregroundStyle(store.selectedType == type ? .white : .secondary)
                Text(type.displayName)
                    .font(.subheadline)
                    .foregroundStyle(store.selectedType == type ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                store.selectedType == type
                    ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.3))
                    : nil
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Form Panel

    private var formPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Overlay-specific fields
                Text(store.selectedType.displayName)
                    .font(.headline)
                    .padding(.horizontal, 4)

                ForEach(Array(fieldDefinitions.enumerated()), id: \.offset) { _, field in
                    fieldView(field)
                }

                // Position quick actions (only for overlays with X/Y)
                if fieldDefinitions.contains(where: { $0.key == "posX" }) {
                    HStack(spacing: 8) {
                        Button("Reset") {
                            store.setField("posX", value: "60")
                            store.setField("posY", value: String(Int(Double(store.canvasHeight) * 0.83)))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Center") {
                            store.setField("posX", value: String(Int(Double(store.canvasWidth) / 2 - 200)))
                            store.setField("posY", value: String(Int(Double(store.canvasHeight) / 2 - 40)))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Top Left") {
                            store.setField("posX", value: "40")
                            store.setField("posY", value: "40")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // Custom canvas size (only when Custom is selected)
                if store.canvasSizeIndex == CanvasSizePresets.customIndex {
                    Text("Custom Canvas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack {
                        TextField("W", text: Binding(
                            get: { String(store.customWidth) },
                            set: { store.customWidth = Int($0) ?? 1920; store.saveGlobals() }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        Text("×")
                            .foregroundStyle(.secondary)
                        TextField("H", text: Binding(
                            get: { String(store.customHeight) },
                            set: { store.customHeight = Int($0) ?? 1080; store.saveGlobals() }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                    }
                    Divider()
                }

                // Safe Areas
                Text("Safe Areas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                globalField(label: "Style") {
                    Picker("", selection: Binding(
                        get: { store.safeAreaStyle },
                        set: { store.safeAreaStyle = $0; store.saveGlobals() }
                    )) {
                        Text("Outline").tag(0)
                        Text("Fill").tag(1)
                        Text("Both").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                globalField(label: "Opacity") {
                    HStack {
                        Slider(value: Binding(
                            get: { store.safeAreaOpacity },
                            set: { store.safeAreaOpacity = $0; store.saveGlobals() }
                        ), in: 10...60, step: 5)
                        Text("\(Int(store.safeAreaOpacity))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                globalField(label: "Color") {
                    HStack(spacing: 8) {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex6: store.safeAreaColorHex) },
                            set: { store.safeAreaColorHex = $0.hexString; store.saveGlobals() }
                        ))
                        .labelsHidden()
                        ForEach(["#ffffff", "#ff3b3b", "#00ff88", "#3b82f6", "#ffaa00"], id: \.self) { hex in
                            Circle()
                                .fill(Color(hex6: hex))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(store.safeAreaColorHex == hex ? Color.white : .clear, lineWidth: 2))
                                .onTapGesture { store.safeAreaColorHex = hex; store.saveGlobals() }
                        }
                    }
                }

                Divider()

                // Global style
                Text("Global Style")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                globalField(label: "Font") {
                    Picker("", selection: Binding(
                        get: { store.globalFont },
                        set: { store.globalFont = $0; store.saveGlobals() }
                    )) {
                        Text("System").tag("system")
                        Text("Monospace").tag("mono")
                        Text("Rounded").tag("rounded")
                        Text("Serif").tag("serif")
                    }
                    .pickerStyle(.segmented)
                }

                globalField(label: "Panel Opacity") {
                    HStack {
                        Slider(value: Binding(
                            get: { store.globalOpacity },
                            set: { store.globalOpacity = $0; store.saveGlobals() }
                        ), in: 50...100, step: 1)
                        Text("\(Int(store.globalOpacity))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                globalField(label: "Corner Radius") {
                    HStack {
                        Slider(value: Binding(
                            get: { store.globalCornerRadius },
                            set: { store.globalCornerRadius = $0; store.saveGlobals() }
                        ), in: 0...30, step: 1)
                        Text("\(Int(store.globalCornerRadius))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                    }
                }

                Divider()

                // (No presets: every overlay type saves its own settings
                // automatically — edits persist across type switches and
                // relaunches, no save button needed.)
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }

    private var fieldDefinitions: [(key: String, label: String, type: FieldType)] {
        let cw = Double(store.canvasWidth), ch = Double(store.canvasHeight)
        switch store.selectedType {
        case .lowerThird:
            return [("title", "Title", .text), ("subtitle", "Subtitle", .text),
                    ("accent", "Accent Color", .color), ("barWidth", "Bar Width", .range(2...12)),
                    ("titleSize", "Title Size", .range(16...80)),
                    ("subtitleSize", "Subtitle Size", .range(10...40)),
                    ("lineSpacing", "Line Spacing", .range(0...30)),
                    ("letterSpacing", "Letter Spacing", .range(-5...10)),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .lowerThirdIcon:
            return [("title", "Title", .text), ("subtitle", "Subtitle", .text),
                    ("accent", "Accent Color", .color),
                    ("iconEmoji", "Icon (emoji)", .text),
                    ("iconImage", "Logo Image", .image),
                    ("titleSize", "Title Size", .range(16...80)),
                    ("subtitleSize", "Subtitle Size", .range(10...40)),
                    ("lineSpacing", "Line Spacing", .range(0...30)),
                    ("letterSpacing", "Letter Spacing", .range(-5...10)),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .titleCard:
            return [("title", "Title", .text), ("subtitle", "Subtitle", .text),
                    ("tagline", "Tagline", .text), ("accent", "Accent", .color),
                    ("bgColor", "Background", .color), ("fontSize", "Title Size", .range(40...120)),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .chapter:
            return [("num", "Number", .text), ("title", "Title", .text),
                    ("accent", "Accent", .color), ("bgColor", "Background", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .ticker:
            return [("text", "Ticker Text", .text), ("accent", "Bar Color", .color),
                    ("label", "Label", .text), ("labelBg", "Label Color", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .alert:
            return [("title", "Title", .text), ("subtitle", "Subtitle", .text),
                    ("accent", "Color", .color), ("icon", "Icon (emoji)", .text),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .webcamFrame:
            return [("accent", "Border Color", .color), ("borderWidth", "Width", .range(2...12)),
                    ("cornerRadius", "Radius", .range(0...40)),
                    ("width", "Frame W", .range(100...(cw * 0.8))),
                    ("height", "Frame H", .range(80...(ch * 0.8))),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .cornerBug:
            return [("text", "Text", .text), ("accent", "Color", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .infoPill:
            return [("label", "Label", .text), ("badge", "Badge", .text),
                    ("accent", "Dot Color", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .stepCounter:
            return [("step", "Current", .text), ("total", "Total", .text),
                    ("label", "Label", .text), ("accent", "Color", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .webLink:
            return [("label", "Label", .text), ("url", "URL", .text),
                    ("accent", "Color", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .countdown:
            return [("hours", "Hours", .text), ("minutes", "Minutes", .text),
                    ("seconds", "Seconds", .text), ("label", "Label", .text),
                    ("accent", "Color", .color), ("bgColor", "Background", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .brb:
            return [("title", "Title", .text), ("subtitle", "Subtitle", .text),
                    ("accent", "Color", .color), ("bgColor", "Background", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .ending:
            return [("title", "Title", .text), ("subtitle", "Subtitle", .text),
                    ("socials", "Socials", .text), ("accent", "Color", .color),
                    ("bgColor", "Background", .color),
                    ("posX", "X", .range(0...cw)),
                    ("posY", "Y", .range(0...ch))]
        case .htmlEditor:
            return []  // Editor is handled by OverlayHTMLEditorView — no form fields
        }
    }

    enum FieldType {
        case text, color, image
        case range(ClosedRange<Double>)
    }

    @ViewBuilder
    private func fieldView(_ field: (key: String, label: String, type: FieldType)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch field.type {
            case .text:
                TextField("", text: Binding(
                    get: { store.field(field.key) },
                    set: { store.setField(field.key, value: $0) }
                ))
                .textFieldStyle(.roundedBorder)

            case .color:
                HStack(spacing: 8) {
                    ColorPicker("", selection: Binding(
                        get: { store.colorField(field.key) },
                        set: { store.setField(field.key, value: $0.hexString) }
                    ))
                    .labelsHidden()

                    TextField("", text: Binding(
                        get: { store.field(field.key) },
                        set: { store.setField(field.key, value: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .monospaced()
                }

            case .range(let bounds):
                HStack {
                    Slider(value: Binding(
                        get: { store.numField(field.key) },
                        set: { store.setField(field.key, value: String(Int($0))) }
                    ), in: bounds, step: 1)
                    Text("\(Int(store.numField(field.key)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }

            case .image:
                let path = store.field(field.key)
                HStack(spacing: 8) {
                    if let nsImage = store.image(atPath: path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            )
                    }

                    Button("Choose Image…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.begin { result in
                            guard result == .OK, let url = panel.url else { return }
                            store.setField(field.key, value: url.path)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !path.isEmpty {
                        Button("Clear") { store.setField(field.key, value: "") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func globalField(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Preview

    @State private var dragStart: CGPoint?

    private var previewArea: some View {
        GeometryReader { geo in
            let margin: CGFloat = 32
            let maxW = geo.size.width - margin * 2
            let maxH = geo.size.height - margin * 2
            let scale = min(maxW / CGFloat(store.canvasWidth), maxH / CGFloat(store.canvasHeight))
            let dispW = CGFloat(store.canvasWidth) * scale
            let dispH = CGFloat(store.canvasHeight) * scale

            // Work area background
            Color(white: 0.10)
                .ignoresSafeArea()

            // Grid dots for work area
            canvasGrid(size: geo.size, spacing: 20)

            // ── Canvas frame ──
            ZStack {
                // Drop shadow
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: dispW + 2, height: dispH + 2)
                    .offset(x: 2, y: 2)

                // White canvas background (what gets exported)
                Rectangle()
                    .fill(Color(white: 0.04))
                    .frame(width: dispW, height: dispH)

                // Canvas content
                OverlayCanvasView(store: store, showSafeAreas: showSafeAreas)
                    .frame(width: dispW, height: dispH)

                // Border
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5)
                    .frame(width: dispW, height: dispH)

                // Corner brackets
                canvasCornerBrackets(w: dispW, h: dispH)

                // Dimension label
                Text("\(store.canvasWidth) × \(store.canvasHeight)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .position(x: dispW / 2, y: dispH + 18)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let canvasDeltaX = Double(value.translation.width) / Double(scale)
                        let canvasDeltaY = Double(value.translation.height) / Double(scale)

                        let startX = store.numField("posX")
                        let startY = store.numField("posY")
                        if dragStart == nil {
                            dragStart = CGPoint(x: startX, y: startY)
                        }
                        // Clamp to canvas bounds (allow graphic to sit at edges)
                        let newX = max(0, min(Double(store.canvasWidth),
                                              dragStart!.x + canvasDeltaX))
                        let newY = max(0, min(Double(store.canvasHeight),
                                              dragStart!.y + canvasDeltaY))
                        store.setFieldLive("posX", value: String(Int(newX)))
                        store.setFieldLive("posY", value: String(Int(newY)))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        store.flushDraft()
                    }
            )
            .help("Drag to reposition overlay")
        }
    }

    /// Subtle dot grid in the work area background
    private func canvasGrid(size: CGSize, spacing: CGFloat) -> some View {
        Canvas { context, canvasSize in
            let dotColor = Color.white.opacity(0.04)
            let dotSize: CGFloat = 1.5
            var x: CGFloat = spacing
            while x < canvasSize.width {
                var y: CGFloat = spacing
                while y < canvasSize.height {
                    let rect = CGRect(x: x - dotSize/2, y: y - dotSize/2, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    y += spacing
                }
                x += spacing
            }
        }
    }

    /// Corner brackets at each corner of the canvas
    private func canvasCornerBrackets(w: CGFloat, h: CGFloat) -> some View {
        let len: CGFloat = 16
        let color = Color.accentColor.opacity(0.6)
        return ZStack {
            // Top-left
            Path { p in
                p.move(to: CGPoint(x: 0, y: len)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: len, y: 0))
            }.stroke(color, lineWidth: 2)
            // Top-right
            Path { p in
                p.move(to: CGPoint(x: w - len, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: len))
            }.stroke(color, lineWidth: 2)
            // Bottom-left
            Path { p in
                p.move(to: CGPoint(x: 0, y: h - len)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: len, y: h))
            }.stroke(color, lineWidth: 2)
            // Bottom-right
            Path { p in
                p.move(to: CGPoint(x: w - len, y: h)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w, y: h - len))
            }.stroke(color, lineWidth: 2)
        }
        .frame(width: w, height: h)
    }

    // MARK: - Export

    /// Render the store's current state to PNG data at exact canvas pixel size.
    private func renderPNG() -> Data? {
        let w = CGFloat(store.canvasWidth), h = CGFloat(store.canvasHeight)
        let renderer = ImageRenderer(content: OverlayCanvasView(store: store, showSafeAreas: false)
            .frame(width: w, height: h))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: w, height: h)

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    }

    private func exportPNG() {
        guard let png = renderPNG() else {
            exportAlertMessage = "Could not render the overlay as a PNG."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(store.selectedType.rawValue)-\(store.canvasWidth)x\(store.canvasHeight).png"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
            } catch {
                Task { @MainActor in
                    exportAlertMessage = "Couldn't save the PNG: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportAllPNG() {
        // One directory chooser for the whole batch — not 14 stacked save panels.
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.message = "All overlay PNGs will be written into this folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export All Here"
        panel.begin { result in
            guard result == .OK, let dir = panel.url else { return }
            Task { @MainActor in
                // Render every type with default fields WITHOUT saving them:
                // plain property assignments bypass autosave, and the user's
                // settings are restored afterwards.
                let savedType = store.selectedType
                let savedFields = store.currentFields
                var exported = 0
                var failed: [String] = []

                for type in OverlayType.allCases {
                    store.selectedType = type
                    store.currentFields = OverlayConfig.defaults(for: type).fields

                    guard let png = renderPNG() else {
                        failed.append(type.displayName)
                        continue
                    }
                    let url = dir.appendingPathComponent("\(type.rawValue)-\(store.canvasWidth)x\(store.canvasHeight).png")
                    do {
                        try png.write(to: url)
                        exported += 1
                    } catch {
                        failed.append(type.displayName)
                    }
                }

                store.selectedType = savedType
                store.currentFields = savedFields

                exportAlertMessage = failed.isEmpty
                    ? "Exported \(exported) overlays to \(dir.lastPathComponent)."
                    : "Exported \(exported) overlays; failed: \(failed.joined(separator: ", "))."
            }
        }
    }
}

// MARK: - Overlay Canvas View

/// Renders the actual overlay at full resolution using SwiftUI Canvas.
struct OverlayCanvasView: View {
    let store: OverlayBuilderStore
    var showSafeAreas: Bool = false

    var body: some View {
        Canvas { context, size in
            // Scale drawing context from canvas-space (e.g. 1920×1080) to display-space
            let scaleX = size.width / CGFloat(store.canvasWidth)
            let scaleY = size.height / CGFloat(store.canvasHeight)
            context.scaleBy(x: scaleX, y: scaleY)

            let canvasSize = CGSize(width: store.canvasWidth, height: store.canvasHeight)
            drawOverlay(context: context, size: canvasSize)
            if showSafeAreas {
                drawSafeAreas(context: context, size: canvasSize)
            }
        }
    }

    private func drawOverlay(context: GraphicsContext, size: CGSize) {
        let W = size.width, H = size.height
        let r = store.globalCornerRadius

        switch store.selectedType {
        case .lowerThird:
            drawLowerThird(context: context, W: W, H: H, r: r, withIcon: false)
        case .lowerThirdIcon:
            drawLowerThird(context: context, W: W, H: H, r: r, withIcon: true)
        case .titleCard:
            drawTitleCard(context: context, W: W, H: H)
        case .chapter:
            drawChapter(context: context, W: W, H: H)
        case .ticker:
            drawTicker(context: context, W: W, H: H)
        case .alert:
            drawAlert(context: context, W: W, H: H)
        case .webcamFrame:
            drawWebcamFrame(context: context, W: W, H: H)
        case .cornerBug:
            drawCornerBug(context: context, W: W, H: H)
        case .infoPill:
            drawInfoPill(context: context, W: W, H: H)
        case .stepCounter:
            drawStepCounter(context: context, W: W, H: H)
        case .webLink:
            drawWebLink(context: context, W: W, H: H)
        case .countdown:
            drawCountdown(context: context, W: W, H: H)
        case .brb:
            drawBRB(context: context, W: W, H: H)
        case .ending:
            drawEnding(context: context, W: W, H: H)
        case .htmlEditor:
            break  // HTML editor renders via WKWebView, not SwiftUI Canvas
        }
    }

    // MARK: - Safe Area Guides

    /// Draws safe area guides for all canvas ratios.
    /// Shows where platform UI elements sit so overlays avoid being covered.
    private func drawSafeAreas(context: GraphicsContext, size: CGSize) {
        let W = size.width, H = size.height
        let isPortrait = H > W * 1.1

        let opacity = store.safeAreaOpacity / 100.0
        let saColor = Color(hex6: store.safeAreaColorHex)
        // Style picker: 0 = Outline, 1 = Fill, 2 = Both.
        let fillOnly = store.safeAreaStyle == 1
        let outlineOnly = store.safeAreaStyle == 0

        func drawZone(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, label: String) {
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if !outlineOnly {
                context.fill(Path(rect), with: .color(saColor.opacity(opacity * 0.4)))
            }
            if !fillOnly {
                context.stroke(Path(rect), with: .color(saColor.opacity(opacity)), lineWidth: 1.5)
            }
            // Label
            let fontSize: CGFloat = min(w, h) > 80 ? 16 : 12
            context.draw(
                Text(label).font(.system(size: fontSize, weight: .semibold)),
                at: CGPoint(x: x + 12, y: y + 12), anchor: .topLeading
            )
        }

        if isPortrait {
            // ── PORTRAIT (9:16 — TikTok, Reels, Shorts, Instagram Portrait) ──
            let topH = H * 0.07
            drawZone(0, 0, W, topH, label: "Status Bar / Notch")

            let botH = H * 0.10
            drawZone(0, H - botH, W, botH, label: "Caption / Controls")

            let rightW = W * 0.13
            let rightY = H * 0.28
            let rightH = H * 0.40
            drawZone(W - rightW, rightY, rightW, rightH, label: "Actions")

        } else {
            // ── ALL OTHER RATIOS — simple 5% border ──
            let inset = min(W, H) * 0.05
            drawZone(0, 0, W, inset, label: "")
            drawZone(0, H - inset, W, inset, label: "")
            drawZone(0, 0, inset, H, label: "")
            drawZone(W - inset, 0, inset, H, label: "")
        }
    }

    // MARK: - Font Resolution

    /// Global font design from the Global Style picker. sysFont defaults to it
    /// so every overlay text element follows the selection.
    private var globalDesign: Font.Design {
        switch store.globalFont {
        case "mono":    return .monospaced
        case "rounded": return .rounded
        case "serif":   return .serif
        default:        return .default
        }
    }

    private func sysFont(_ size: Double, _ weight: Font.Weight = .regular, _ design: Font.Design? = nil) -> Font {
        .system(size: size, weight: weight, design: design ?? globalDesign)
    }

    // MARK: - Panel Drawing

    private func drawPanel(context: GraphicsContext, x: Double, y: Double, w: Double, h: Double,
                           accent: Color, cornerRadius: Double? = nil) {
        let r = cornerRadius ?? store.globalCornerRadius
        let opacity = store.globalOpacity / 100.0
        let rect = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        context.fill(rect, with: .color(Color(white: 0.04, opacity: opacity)))
        context.stroke(rect, with: .color(accent.opacity(0.2)), lineWidth: 1)
    }

    private func drawAccentBar(context: GraphicsContext, x: Double, y0: Double, y1: Double,
                               w: Double, color: Color) {
        let rect = CGRect(x: x, y: y0, width: w, height: y1 - y0)
        context.fill(Path(rect), with: .color(color))
    }

    private func drawGradientLine(context: GraphicsContext, x: Double, y: Double, w: Double,
                                  color: Color) {
        let rect = CGRect(x: x, y: y, width: w, height: 2)
        context.fill(Path(rect), with: .color(color.opacity(0.6)))
    }

    // MARK: - Individual Renderers

    private func drawLowerThird(context: GraphicsContext, W: Double, H: Double, r: Double, withIcon: Bool) {
        let title = store.field("title")
        let sub = store.field("subtitle")
        let accent = store.colorField("accent")
        let bw = store.numField("barWidth")
        let fs = store.numField("titleSize")
        let subFs = store.numField("subtitleSize")
        let lineGap = store.numField("lineSpacing")
        let letterGap = store.numField("letterSpacing")
        let px = store.numField("posX")
        let py = store.numField("posY")
        let ph = fs + subFs + lineGap + 30
        let pw: Double = 480

        drawAccentBar(context: context, x: px, y0: py, y1: py + ph, w: bw, color: accent)
        drawPanel(context: context, x: px + bw, y: py, w: pw, h: ph, accent: accent)

        if withIcon {
            let iconSize: Double = 40
            let iconX = px + bw + 20
            let iconY = py + ph / 2 - iconSize / 2
            let iconRect = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
            context.fill(Path(ellipseIn: iconRect), with: .color(accent.opacity(0.15)))

            let imagePath = store.field("iconImage")
            if let nsImage = store.image(atPath: imagePath) {
                context.draw(Image(nsImage: nsImage), in: iconRect)
            } else {
                let emoji = store.field("iconEmoji").isEmpty ? "⭐" : store.field("iconEmoji")
                context.draw(Text(emoji).font(.system(size: 22)),
                             at: CGPoint(x: iconX + iconSize / 2, y: iconY + iconSize / 2),
                             anchor: .center)
            }
        }

        let tx = withIcon ? px + bw + 70 : px + bw + 22
        let titleY = py + 16
        context.draw(Text(title).font(sysFont(fs, .bold)), at: CGPoint(x: tx, y: titleY), anchor: .topLeading)
        context.draw(Text(sub).font(sysFont(subFs, .medium)), at: CGPoint(x: tx, y: titleY + fs + lineGap), anchor: .topLeading)
        drawGradientLine(context: context, x: tx, y: py + ph - 8, w: pw - 44, color: accent)
    }

    private func drawTitleCard(context: GraphicsContext, W: Double, H: Double) {
        let bg = store.colorField("bgColor")
        let px = store.numField("posX"), py = store.numField("posY")
        context.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(bg))

        let fs = store.numField("fontSize")
        let cx = px + W / 2, cy = py + H / 2
        context.draw(Text(store.field("title")).font(sysFont(fs, .heavy)),
                     at: CGPoint(x: cx, y: cy - 10), anchor: .center)

        if !store.field("subtitle").isEmpty {
            context.draw(Text(store.field("subtitle")).font(sysFont(fs * 0.33, .medium)),
                         at: CGPoint(x: cx, y: cy + fs * 0.55), anchor: .center)
        }
        if !store.field("tagline").isEmpty {
            let tag = store.field("tagline").uppercased()
            context.draw(Text(tag).font(sysFont(13, .semibold)),
                         at: CGPoint(x: cx, y: cy + fs * 0.55 + 30), anchor: .center)
        }
    }

    private func drawChapter(context: GraphicsContext, W: Double, H: Double) {
        let bg = store.colorField("bgColor")
        let accent = store.colorField("accent")
        let px = store.numField("posX"), py = store.numField("posY")
        context.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(bg))

        let cx = px + W / 2, cy = py + H / 2
        let num = store.field("num").padding(toLength: 2, withPad: "0", startingAt: 0)
        context.draw(Text(num).font(sysFont(140, .heavy)),
                     at: CGPoint(x: cx - 30, y: cy + 50), anchor: .trailing)

        context.draw(Text("CHAPTER").font(sysFont(14, .semibold)),
                     at: CGPoint(x: cx + 20, y: cy - 15), anchor: .leading)
        context.draw(Text(store.field("title")).font(sysFont(52, .bold)),
                     at: CGPoint(x: cx + 20, y: cy + 35), anchor: .leading)
    }

    private func drawTicker(context: GraphicsContext, W: Double, H: Double) {
        let accent = store.colorField("accent")
        let labelBg = store.colorField("labelBg")
        let px = store.numField("posX"), py = store.numField("posY")
        let barH: Double = 48

        // Label background
        let label = store.field("label")
        let lw = Double(label.count) * 10 + 32
        context.fill(Path(CGRect(x: px, y: py, width: lw, height: barH)), with: .color(labelBg))
        context.draw(Text(label).font(sysFont(14, .bold)),
                     at: CGPoint(x: px + 16, y: py + barH / 2), anchor: .leading)

        // Bar
        context.fill(Path(CGRect(x: px + lw, y: py, width: W - px - lw, height: barH)),
                     with: .color(accent.opacity(0.9)))

        // Text
        context.draw(Text(store.field("text")).font(sysFont(18, .semibold)),
                     at: CGPoint(x: px + lw + 20, y: py + barH / 2), anchor: .leading)
    }

    private func drawAlert(context: GraphicsContext, W: Double, H: Double) {
        let accent = store.colorField("accent")
        let px = store.numField("posX"), py = store.numField("posY")
        let pw: Double = 500, ph: Double = 100

        drawPanel(context: context, x: px, y: py, w: pw, h: ph, accent: accent, cornerRadius: 12)
        context.draw(Text(store.field("icon")).font(.system(size: 32)),
                     at: CGPoint(x: px + 20, y: py + ph / 2), anchor: .leading)
        context.draw(Text(store.field("title")).font(sysFont(24, .bold)),
                     at: CGPoint(x: px + 65, y: py + 30), anchor: .leading)
        context.draw(Text(store.field("subtitle")).font(sysFont(16, .medium)),
                     at: CGPoint(x: px + 65, y: py + 58), anchor: .leading)
    }

    private func drawWebcamFrame(context: GraphicsContext, W: Double, H: Double) {
        let accent = store.colorField("accent")
        let bw = store.numField("borderWidth")
        let cr = store.numField("cornerRadius")
        let fw = store.numField("width"), fh = store.numField("height")
        let px = store.numField("posX"), py = store.numField("posY")

        let rect = Path(roundedRect: CGRect(x: px, y: py, width: fw, height: fh), cornerRadius: cr)
        context.stroke(rect, with: .color(accent), lineWidth: bw)
    }

    private func drawCornerBug(context: GraphicsContext, W: Double, H: Double) {
        let accent = store.colorField("accent")
        let text = store.field("text")
        let px = store.numField("posX"), py = store.numField("posY")
        let tw = Double(text.count) * 10 + 28

        let rect = Path(roundedRect: CGRect(x: px - tw / 2, y: py, width: tw, height: 32), cornerRadius: 16)
        context.fill(rect, with: .color(accent.opacity(0.9)))
        context.draw(Text(text).font(sysFont(16, .bold)),
                     at: CGPoint(x: px, y: py + 16), anchor: .center)
    }

    private func drawInfoPill(context: GraphicsContext, W: Double, H: Double) {
        let accent = store.colorField("accent")
        let label = store.field("label"), badge = store.field("badge")
        let px = store.numField("posX"), py = store.numField("posY")

        let lw = Double(label.count) * 9 + 30
        let bw = Double(badge.count) * 8 + 20
        let pw = lw + bw + 50, ph: Double = 40

        let pill = Path(roundedRect: CGRect(x: px, y: py, width: pw, height: ph), cornerRadius: ph / 2)
        context.fill(pill, with: .color(Color(white: 0.04, opacity: 0.9)))
        context.stroke(pill, with: .color(accent.opacity(0.2)), lineWidth: 1)

        // Dot
        context.fill(Path(ellipseIn: CGRect(x: px + 14, y: py + ph / 2 - 5, width: 10, height: 10)),
                     with: .color(accent))

        context.draw(Text(label).font(sysFont(14, .semibold)),
                     at: CGPoint(x: px + 30, y: py + ph / 2), anchor: .leading)

        // Badge pill on the trailing end (bw was already factored into the width).
        if !badge.isEmpty {
            let badgeRect = Path(roundedRect: CGRect(x: px + pw - bw - 8, y: py + 7, width: bw, height: ph - 14),
                                 cornerRadius: (ph - 14) / 2)
            context.fill(badgeRect, with: .color(accent))
            context.draw(Text(badge).font(sysFont(12, .bold)),
                         at: CGPoint(x: px + pw - bw / 2 - 8, y: py + ph / 2), anchor: .center)
        }
    }

    private func drawStepCounter(context: GraphicsContext, W: Double, H: Double) {
        let accent = store.colorField("accent")
        let step = store.field("step"), total = store.field("total")
        let px = store.numField("posX"), py = store.numField("posY")
        let num = "\(step)/\(total)"
        let nw = Double(num.count) * 14 + 36

        let rect = Path(roundedRect: CGRect(x: px, y: py, width: nw, height: 48), cornerRadius: 12)
        context.fill(rect, with: .color(Color(white: 0.04, opacity: 0.9)))
        context.stroke(rect, with: .color(accent.opacity(0.2)), lineWidth: 1)

        context.draw(Text(step).font(sysFont(22, .bold)),
                     at: CGPoint(x: px + 18, y: py + 24), anchor: .leading)
        context.draw(Text(store.field("label")).font(sysFont(15, .medium)),
                     at: CGPoint(x: px + nw + 12, y: py + 24), anchor: .leading)
    }

    private func drawWebLink(context: GraphicsContext, W: Double, H: Double) {
        let accent = store.colorField("accent")
        let url = store.field("url")
        let px = store.numField("posX"), py = store.numField("posY")
        let pw = max(200, Double(url.count) * 11 + 50), ph: Double = 60

        drawPanel(context: context, x: px, y: py, w: pw, h: ph, accent: accent)
        context.draw(Text(store.field("label").uppercased()).font(sysFont(11, .semibold)),
                     at: CGPoint(x: px + 16, y: py + 18), anchor: .leading)
        context.draw(Text(url).font(sysFont(16, .semibold)),
                     at: CGPoint(x: px + 16, y: py + 42), anchor: .leading)
    }

    private func drawCountdown(context: GraphicsContext, W: Double, H: Double) {
        let bg = store.colorField("bgColor")
        let accent = store.colorField("accent")
        let px = store.numField("posX"), py = store.numField("posY")
        context.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(bg))

        let cx = px + W / 2, cy = py + H / 2
        let h = store.field("hours").padding(toLength: 2, withPad: "0", startingAt: 0)
        let m = store.field("minutes").padding(toLength: 2, withPad: "0", startingAt: 0)
        let s = store.field("seconds").padding(toLength: 2, withPad: "0", startingAt: 0)
        let time = "\(h):\(m):\(s)"

        context.draw(Text(time).font(sysFont(100, .heavy)),
                     at: CGPoint(x: cx, y: cy), anchor: .center)

        if !store.field("label").isEmpty {
            context.draw(Text(store.field("label")).font(sysFont(22, .medium)),
                         at: CGPoint(x: cx, y: cy + 60), anchor: .center)
        }
    }

    private func drawBRB(context: GraphicsContext, W: Double, H: Double) {
        let bg = store.colorField("bgColor")
        let px = store.numField("posX"), py = store.numField("posY")
        context.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(bg))

        let cx = px + W / 2, cy = py + H / 2
        context.draw(Text(store.field("title")).font(sysFont(72, .heavy)),
                     at: CGPoint(x: cx, y: cy - 10), anchor: .center)
        context.draw(Text(store.field("subtitle")).font(sysFont(22, .medium)),
                     at: CGPoint(x: cx, y: cy + 50), anchor: .center)
    }

    private func drawEnding(context: GraphicsContext, W: Double, H: Double) {
        let bg = store.colorField("bgColor")
        let px = store.numField("posX"), py = store.numField("posY")
        context.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(bg))

        let cx = px + W / 2, cy = py + H / 2
        context.draw(Text(store.field("title")).font(sysFont(60, .heavy)),
                     at: CGPoint(x: cx, y: cy - 30), anchor: .center)
        context.draw(Text(store.field("subtitle")).font(sysFont(22, .medium)),
                     at: CGPoint(x: cx, y: cy + 25), anchor: .center)

        if !store.field("socials").isEmpty {
            let accent = store.colorField("accent")
            context.draw(Text(store.field("socials")).font(sysFont(18, .semibold)),
                         at: CGPoint(x: cx, y: cy + 75), anchor: .center)
        }
    }
}
