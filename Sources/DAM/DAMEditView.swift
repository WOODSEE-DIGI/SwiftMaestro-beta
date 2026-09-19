import AppKit
import SwiftUI

// MARK: - Non-destructive Edit Workspace
//
// The Edit tab's single-asset editor: live CoreImage preview on the left,
// grouped tool sliders on the right. Every slider writes into a DAMEditState
// recipe (saved to the `assetEdit` table, debounced) — the original file is
// never touched. Multi-selection keeps the existing batch rating/keywords
// tools (unchanged).

struct DAMEditView: View {
    let asset: DAMAsset
    var viewModel: DAMViewModel

    @State private var edit: DAMEditState = DAMEditState()
    @State private var rendered: NSImage?
    @State private var isRendering = false
    @State private var renderFailed = false
    @State private var saveTask: Task<Void, Never>?
    @State private var renderTask: Task<Void, Never>?
    /// Whether the crop tool is armed. The overlay only exists (and the
    /// preview only intercepts drags) while this is true — clicking the
    /// photo otherwise never draws a crop. While armed, the preview renders
    /// the recipe WITHOUT the crop so the full frame stays visible behind
    /// the crop rect (darktable-style modal crop).
    @State private var isCropToolActive = false
    /// Whether the redact tool is armed (modal like crop; the two tools are
    /// mutually exclusive — arming one disarms the other).
    @State private var isRedactToolActive = false
    /// The kind applied to newly drawn redaction boxes.
    @State private var redactKind: DAMEditState.RedactionBox.Kind = .blackout
    /// Options passed to the on-device AI detector.
    @State private var aiOptions = DAMRedactionDetectorService.Options()
    /// User-defined regex patterns, one per line, persisted across sessions.
    @State private var customPatternText: String = ""
    /// The selected redaction box (shared with the overlay; Delete removes).
    @State private var selectedRedactionID: UUID?
    /// The layer that receives newly drawn redaction boxes.
    @State private var activeLayerID: UUID?
    /// Feedback line for layout copy/paste actions.
    @State private var redactionStatus: String?

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            controls
        }
        .task(id: asset.id) { loadAndRender() }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            Color.black.opacity(0.9)
            if let rendered {
                Image(nsImage: rendered)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)

                // Drag-to-crop overlay — only present while the crop tool is
                // armed, so ordinary clicks on the photo never draw a rect.
                // Live updates during the drag; the recipe only persists (and
                // re-renders) when the drag ends.
                if isCropToolActive {
                    DAMCropOverlay(
                        crop: $edit.crop,
                        imageSize: rendered.size,
                        onChange: {},
                        onEnd: { persistAndRender() }
                    )
                    .padding(8)
                }

                // Redaction overlay — only present while the redact tool is
                // armed. Boxes bake into the render on drag end.
                if isRedactToolActive {
                    DAMRedactOverlay(
                        boxes: $edit.redactions,
                        layers: edit.redactionLayers,
                        activeLayerID: activeLayerID ?? edit.defaultRedactionLayerID(),
                        imageSize: rendered.size,
                        kind: redactKind,
                        selectedID: $selectedRedactionID,
                        onChange: {},
                        onEnd: { persistAndRender() }
                    )
                    .padding(8)
                }
            } else if isRendering {
                ProgressView("Rendering…")
                    .tint(.white)
            } else if renderFailed {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 22))
                    Text("Could not render this file")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView("Loading…").tint(.white)
            }

            if edit.crop != nil {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            edit.crop = nil
                            persistAndRender()
                        } label: {
                            Label("Clear crop", systemImage: "xmark.square")
                        }
                        .buttonStyle(.bordered)
                        .padding(8)
                    }
                    Spacer()
                }
            }

            if isCropToolActive || isRedactToolActive {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: isCropToolActive ? "crop" : "eye.slash")
                        Text(isCropToolActive
                             ? "Drag to draw · drag inside to move · corners to resize"
                             : "Drag to draw a box · drag box to move · corners to resize · ⌫ deletes · arrows nudge · Shift locks aspect")
                        Button("Done") { disarmTools() }
                            .keyboardShortcut(.escape, modifiers: [])
                        if isRedactToolActive && selectedRedactionID != nil {
                            Button("Delete") { deleteSelectedRedaction() }
                                .keyboardShortcut(.delete, modifiers: [])
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                // Primary action bar — kept at the top of the controls so Save
                // is always visible and users don't have to scroll to find it.
                HStack(spacing: 10) {
                    Button("Reset all") { edit = DAMEditState(); persistAndRender() }
                        .disabled(edit.isIdentity)
                        .controlSize(.small)
                    Spacer()
                    Button("Copy settings") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(edit.asJSON, forType: .string) }
                        .controlSize(.small)
                    Button("Paste") { pasteSettings() }
                        .controlSize(.small)
                    Button("Save") { saveNow() }
                        .keyboardShortcut("s", modifiers: .command)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }

                group("Geometry", icon: "crop.rotate") {
                    HStack(spacing: 8) {
                        cropToolButton
                        iconButton("rotate.left", "Rotate left") { edit.rotateQuarterTurns = (edit.rotateQuarterTurns + 3) % 4; persistAndRender() }
                        iconButton("rotate.right", "Rotate right") { edit.rotateQuarterTurns = (edit.rotateQuarterTurns + 1) % 4; persistAndRender() }
                        iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontal") { edit.flipHorizontal.toggle(); persistAndRender() }
                    }
                    sliderRow("Straighten", value: $edit.straightenDegrees, range: -45...45, format: "%.1f°", field: \.straightenDegrees)
                    sliderRow("Crop left", value: cropBinding(\.x, fallback: 0), range: 0...0.4, format: "%.2f", resetTo: 0)
                    sliderRow("Crop top", value: cropBinding(\.y, fallback: 0), range: 0...0.4, format: "%.2f", resetTo: 0)
                    sliderRow("Crop width", value: cropBinding(\.width, fallback: 1), range: 0.2...1.0, format: "%.2f", resetTo: 1)
                    sliderRow("Crop height", value: cropBinding(\.height, fallback: 1), range: 0.2...1.0, format: "%.2f", resetTo: 1)
                }

                group("Redact", icon: "eye.slash") {
                    HStack(spacing: 8) {
                        redactToolButton
                        Picker("Redaction kind", selection: $redactKind) {
                            Text("Blackout").tag(DAMEditState.RedactionBox.Kind.blackout)
                            Text("Blur").tag(DAMEditState.RedactionBox.Kind.blur)
                            Text("Pixelate").tag(DAMEditState.RedactionBox.Kind.pixelate)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Toggle("Show redactions", isOn: showRedactionsBinding)
                        .toggleStyle(.checkbox)
                        .onChange(of: viewModel.showRedactions) { _, _ in scheduleRender() }

                    aiRedactButton

                    redactionLayerList

                    if !edit.redactions.isEmpty {
                        redactionBoxList
                    }

                    if let index = selectedBoxIndex {
                        selectedBoxControls(index: index)
                    }

                    HStack(spacing: 8) {
                        Button("Copy layout") { copyRedactionLayout() }
                            .disabled(edit.redactions.isEmpty)
                        Button("Paste layout") { pasteRedactionLayout() }
                    }
                    .controlSize(.small)

                    if let redactionStatus {
                        Text(redactionStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                group("Light", icon: "sun.max") {
                    sliderRow("Exposure", value: $edit.exposureEV, range: -3...3, format: "%+.1f EV", field: \.exposureEV)
                    sliderRow("Contrast", value: $edit.contrast, range: 0.5...1.8, format: "%.2f", field: \.contrast)
                    sliderRow("Highlights", value: $edit.highlights, range: -1...1, format: "%+.2f", field: \.highlights)
                    sliderRow("Shadows", value: $edit.shadows, range: -1...1, format: "%+.2f", field: \.shadows)
                }

                group("Color", icon: "paintpalette") {
                    Toggle("Black & White", isOn: bwBinding)
                        .toggleStyle(.checkbox)
                    sliderRow("Temperature", value: $edit.temperature, range: 3000...10000, format: "%.0f K", field: \.temperature)
                    sliderRow("Tint", value: $edit.tint, range: -150...150, format: "%+.0f", field: \.tint)
                    sliderRow("Saturation", value: $edit.saturation, range: 0...2, format: "%.2f", field: \.saturation)
                    sliderRow("Vibrance", value: $edit.vibrance, range: -1...1, format: "%+.2f", field: \.vibrance)
                }

                group("Effects", icon: "wand.and.stars") {
                    sliderRow("Sharpen", value: $edit.sharpen, range: 0...1, format: "%.2f", field: \.sharpen)
                    sliderRow("Noise reduction", value: $edit.noiseReduction, range: 0...1, format: "%.2f", field: \.noiseReduction)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(asset.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text(DAMFileKind.isCameraRAW(URL(fileURLWithPath: asset.path)) ? "RAW (non-destructive)" : "Non-destructive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !edit.isIdentity {
                    Text("• edited")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Control builders

    private func group(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Arms/disarms the crop tool. Highlighted while active so the mode is
    /// obvious; the preview only accepts crop drags while armed.
    private var cropToolButton: some View {
        Button(action: toggleCropTool) {
            Image(systemName: "crop")
                .frame(width: 22, height: 22)
                .foregroundStyle(isCropToolActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.borderless)
        .help(isCropToolActive
              ? "Crop tool active — click (or Esc) to finish"
              : "Crop tool — arm it, then drag on the preview to crop")
    }

    private func toggleCropTool() {
        isCropToolActive.toggle()
        if isCropToolActive { isRedactToolActive = false }   // mutually exclusive
        // Mode switch changes how the preview must render (crop stripped
        // while armed, applied while disarmed) — re-render immediately.
        // The recipe itself is unchanged, so nothing is persisted here.
        scheduleRender(immediate: true)
    }

    /// Arms/disarms the redact tool. Highlighted while active.
    private var redactToolButton: some View {
        Button(action: toggleRedactTool) {
            Image(systemName: "eye.slash")
                .frame(width: 22, height: 22)
                .foregroundStyle(isRedactToolActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.borderless)
        .help(isRedactToolActive
              ? "Redact tool active — click (or Esc) to finish"
              : "Redact tool — arm it, then drag on the preview to draw blackout/blur boxes")
    }

    private func toggleRedactTool() {
        isRedactToolActive.toggle()
        if isRedactToolActive { isCropToolActive = false }   // mutually exclusive
        if !isRedactToolActive { selectedRedactionID = nil }
    }

    /// Disarm whichever modal tool is active (Esc / Done in the hint capsule).
    private func disarmTools() {
        if isCropToolActive { toggleCropTool() }
        if isRedactToolActive { toggleRedactTool() }
    }

    // MARK: - Redaction actions

    private var selectedBoxIndex: Int? {
        edit.redactions.firstIndex(where: { $0.id == selectedRedactionID })
    }

    /// Toggles a layer's visibility. Selecting a hidden layer makes it visible
    /// and active; selecting an already-active layer has no effect.
    private func selectLayer(_ layer: DAMEditState.RedactionLayer) {
        if let index = edit.redactionLayers.firstIndex(where: { $0.id == layer.id }) {
            edit.redactionLayers[index].isVisible = true
        }
        activeLayerID = layer.id
        scheduleRender()
    }

    private func toggleLayerVisibility(_ layer: DAMEditState.RedactionLayer) {
        guard let index = edit.redactionLayers.firstIndex(where: { $0.id == layer.id }) else { return }
        edit.redactionLayers[index].isVisible.toggle()
        // If the active layer was hidden, fall back to the first visible layer
        // so new boxes don't land on a hidden layer.
        if layer.id == activeLayerID, !edit.redactionLayers[index].isVisible {
            activeLayerID = edit.redactionLayers.first(where: \.isVisible)?.id ?? edit.defaultRedactionLayerID()
        }
        persistAndRender()
    }

    private func addRedactionLayer() {
        let id = edit.addRedactionLayer(named: "Layer \(edit.redactionLayers.count + 1)")
        activeLayerID = id
        persistAndRender()
    }

    private func renameLayer(_ layer: DAMEditState.RedactionLayer, to name: String) {
        guard let index = edit.redactionLayers.firstIndex(where: { $0.id == layer.id }) else { return }
        edit.redactionLayers[index].name = name
        persistAndRender()
    }

    private func deleteRedactionLayer(_ layer: DAMEditState.RedactionLayer) {
        edit.removeRedactionLayer(id: layer.id)
        if activeLayerID == layer.id {
            activeLayerID = edit.redactionLayers.first?.id ?? edit.defaultRedactionLayerID()
        }
        persistAndRender()
    }

    /// Layer list: visibility toggles, rename inline, add/delete, and active
    /// layer selection. New redaction boxes are added to the active layer.
    private var redactionLayerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Layers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addRedactionLayer()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Add a new redaction layer")
            }

            ForEach(edit.redactionLayers) { layer in
                let isActive = layer.id == (activeLayerID ?? edit.defaultRedactionLayerID())
                HStack(spacing: 6) {
                    Button {
                        toggleLayerVisibility(layer)
                    } label: {
                        Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                            .foregroundStyle(layer.isVisible ? .primary : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(layer.isVisible ? "Hide layer" : "Show layer")

                    TextField("Layer name", text: Binding(
                        get: { layer.name },
                        set: { renameLayer(layer, to: $0) }
                    ))
                    .font(.caption)
                    .textFieldStyle(.plain)

                    Spacer()

                    Button {
                        selectLayer(layer)
                    } label: {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isActive ? "Active layer" : "Make active layer")

                    Button {
                        deleteRedactionLayer(layer)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete layer and its boxes")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    /// Numbered box list for quick select/delete when many redactions overlap.
    private var redactionBoxList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(edit.redactions.count) box(es) — click to select, ⌫ deletes")
                .font(.caption2)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(Array(edit.redactions.enumerated()), id: \.element.id) { index, box in
                    let isSelected = box.id == selectedRedactionID
                    let isVisible = boxVisibility(box)
                    Button {
                        selectedRedactionID = box.id
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: box.kind.systemImage)
                            Text("\(index + 1)")
                        }
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : (isVisible ? .primary : .secondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                        lineWidth: isSelected ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(isVisible ? 1 : 0.5)
                }
            }

            HStack(spacing: 8) {
                Button("Delete selected") { deleteSelectedRedaction() }
                    .disabled(selectedRedactionID == nil)
                Button("Clear all") {
                    edit.redactions = []
                    selectedRedactionID = nil
                    persistAndRender()
                }
            }
            .controlSize(.small)
        }
    }

    private func boxVisibility(_ box: DAMEditState.RedactionBox) -> Bool {
        guard let layerID = box.layerID,
              let layer = edit.redactionLayers.first(where: { $0.id == layerID })
        else { return true }
        return layer.isVisible
    }

    /// Per-box editing for the selected redaction: change kind and strength.
    private func selectedBoxControls(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected box")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Kind", selection: selectedBoxKindBinding(index: index)) {
                    ForEach(DAMEditState.RedactionBox.Kind.allCases, id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            if edit.redactions[index].kind.hasStrength {
                HStack {
                    Text("Intensity")
                        .frame(width: 70, alignment: .leading)
                        .font(.caption)
                    Slider(value: selectedBoxStrengthBinding(index: index), in: 0...1)
                    Text(String(format: "%.0f%%", selectedBoxStrengthBinding(index: index).wrappedValue * 100))
                        .frame(width: 38, alignment: .trailing)
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func selectedBoxKindBinding(index: Int) -> Binding<DAMEditState.RedactionBox.Kind> {
        Binding(
            get: { edit.redactions[index].kind },
            set: { newValue in
                edit.redactions[index].kind = newValue
                persistAndRender()
            }
        )
    }

    private func selectedBoxStrengthBinding(index: Int) -> Binding<Double> {
        Binding(
            get: { edit.redactions[index].strength ?? 0.5 },
            set: { newValue in
                edit.redactions[index].strength = newValue
                persistAndRender()
            }
        )
    }

    private func deleteSelectedRedaction() {
        guard let id = selectedRedactionID else { return }
        edit.redactions.removeAll { $0.id == id }
        selectedRedactionID = nil
        persistAndRender()
    }

    /// Copy JUST the redaction layout (not the whole recipe) so it can be
    /// pasted onto other images without touching their light/color/geometry.
    private func copyRedactionLayout() {
        guard !edit.redactions.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(edit.redactionLayoutJSON, forType: .string)
        redactionStatus = "Layout copied — \(edit.redactions.count) box(es). "
            + "Paste onto this or other images."
    }

    private func pasteRedactionLayout() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let boxes = DAMEditState.redactionLayout(fromJSON: text)
        else {
            redactionStatus = "No redaction layout on the clipboard — "
                + "copy one first (Copy layout)."
            return
        }
        // Fresh ids so repeated pastes never collide with existing boxes.
        // Pasted boxes land on the active layer so the user can toggle them
        // as a set without disturbing other layers.
        let targetLayerID = activeLayerID ?? edit.defaultRedactionLayerID()
        edit.redactions = boxes.map { box in
            var copy = box
            copy.id = UUID()
            copy.layerID = targetLayerID
            return copy
        }
        selectedRedactionID = nil
        persistAndRender()
        redactionStatus = "Pasted \(boxes.count) box(es)."
    }

    /// Slider row for a direct scalar recipe field; the reset target is read
    /// from a fresh DAMEditState so it can never drift from the type defaults.
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, field: KeyPath<DAMEditState, Double>) -> some View {
        sliderRow(label, value: value, range: range, format: format, resetTo: DAMEditState.defaultValue(for: field))
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, resetTo defaultValue: Double) -> some View {
        HStack {
            Text(label)
                .frame(width: 92, alignment: .leading)
                .font(.caption)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, _ in persistAndRender() }
            Text(String(format: format, value.wrappedValue))
                .frame(width: 56, alignment: .trailing)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // Per-slider reset (alongside the group-level "Reset all").
            // Programmatic sets still fire the slider's onChange, so the
            // recipe persists + re-renders from here too.
            Button {
                value.wrappedValue = defaultValue
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .disabled(value.wrappedValue == defaultValue)
            .opacity(value.wrappedValue == defaultValue ? 0.25 : 0.85)
            .help("Reset \(label)")
        }
    }

    // MARK: - Crop bindings

    private func cropBinding(_ keyPath: WritableKeyPath<DAMEditState.CropRect, Double>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { edit.crop?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                if edit.crop == nil { edit.crop = DAMEditState.CropRect(x: 0, y: 0, width: 1, height: 1) }
                edit.crop?[keyPath: keyPath] = min(max(newValue, 0), 1)
            }
        )
    }

    private var bwBinding: Binding<Bool> {
        Binding(
            get: { edit.blackAndWhite },
            set: { edit.blackAndWhite = $0; persistAndRender() }
        )
    }

    private var showRedactionsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showRedactions },
            set: { viewModel.showRedactions = $0 }
        )
    }

    /// Split the custom-pattern editor text into non-empty regex strings.
    private func customPatterns(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Run on-device AI detection and add the resulting boxes to the active
    /// layer so the user can review, adjust, or delete before exporting.
    private var aiRedactButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await runAIRedaction() }
            } label: {
                Label("AI Redact", systemImage: "wand.and.rays")
            }
            .controlSize(.small)
            .help("Detect faces, text, and QR codes to redact")

            DisclosureGroup("AI Options") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Faces", isOn: $aiOptions.detectFaces)
                        .toggleStyle(.checkbox)
                    Toggle("Text / OCR", isOn: $aiOptions.detectText)
                        .toggleStyle(.checkbox)
                    Toggle("Barcodes & QR", isOn: $aiOptions.detectBarcodes)
                        .toggleStyle(.checkbox)

                    HStack {
                        Text("Confidence")
                            .font(.caption)
                        Slider(value: $aiOptions.minimumConfidence, in: 0.05...0.95)
                        Text(String(format: "%.0f%%", aiOptions.minimumConfidence * 100))
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }

                    if aiOptions.detectText {
                        let builtIn = DAMRedactionDetectorService.Options.piiPatterns
                        let custom = customPatterns(from: customPatternText)

                        Toggle("Built-in PII patterns", isOn: Binding(
                            get: { aiOptions.textPatterns.contains(where: builtIn.contains) },
                            set: { useBuiltIn in
                                aiOptions.textPatterns = useBuiltIn
                                    ? Array(Set(builtIn + custom))
                                    : custom
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Email, phone, date, address, VIN, rego, SSN, ABN, ACN, TFN, CRN, Medicare, passport, licence, bank account, certificate/transaction IDs")

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom regex patterns (one per line)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $customPatternText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 44, idealHeight: 70, maxHeight: 120)
                                .border(Color.secondary.opacity(0.2), width: 1)
                                .cornerRadius(4)
                                .onChange(of: customPatternText) { _, _ in
                                    let patterns = customPatterns(from: customPatternText)
                                    let useBuiltIn = aiOptions.textPatterns.contains(where: builtIn.contains)
                                    aiOptions.textPatterns = useBuiltIn
                                        ? Array(Set(builtIn + patterns))
                                        : patterns
                                    DAMCustomPatternStore.shared.save(patterns)
                                }
                        }
                    }
                }
            }
            .font(.caption)
        }
    }

    private func runAIRedaction() async {
        var options = aiOptions
        options.kind = redactKind
        do {
            let detected = try await DAMRedactionDetectorService.shared.detect(
                at: asset.path, options: options)
            guard !detected.isEmpty else {
                redactionStatus = "AI found nothing to redact."
                return
            }
            let layerID = activeLayerID ?? edit.defaultRedactionLayerID()
            let existing = edit.redactions.filter { $0.layerID == layerID }
            let newBoxes = detected.filter { candidate in
                !existing.contains { DAMEditState.iou(candidate.rect, $0.rect) > 0.7 }
            }
            guard !newBoxes.isEmpty else {
                redactionStatus = "AI found \(detected.count) region(s), all already redacted."
                return
            }
            var boxes = newBoxes
            for index in boxes.indices { boxes[index].layerID = layerID }
            edit.redactions.append(contentsOf: boxes)
            persistAndRender()
            redactionStatus = "AI added \(boxes.count) redaction box(es)."
        } catch {
            redactionStatus = "AI redaction failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence + rendering

    private func loadAndRender() {
        renderFailed = false
        if let id = asset.id, let saved = DAMDatabase.shared.loadEdits(assetId: id) {
            edit = saved
        } else {
            edit = DAMEditState()
        }
        activeLayerID = edit.defaultRedactionLayerID()

        // Load persisted custom patterns once per asset open.
        let custom = DAMCustomPatternStore.shared.load()
        customPatternText = custom.joined(separator: "\n")
        aiOptions.textPatterns = custom

        scheduleRender(immediate: true)
    }

    /// Save the recipe (debounced) and re-render the preview. The save runs in
    /// a detached task so it completes even if the user switches to another
    /// asset before the debounce fires.
    private func persistAndRender() {
        saveTask?.cancel()
        let currentEdit = edit
        let assetId = asset.id
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard let assetId else { return }
            try? DAMDatabase.shared.saveEdits(assetId: assetId, currentEdit)
        }
        scheduleRender()
    }

    /// Force an immediate save (Command+S) without waiting for the debounce.
    private func saveNow() {
        saveTask?.cancel()
        guard let assetId = asset.id else { return }
        let currentEdit = edit
        Task.detached(priority: .userInitiated) {
            try? DAMDatabase.shared.saveEdits(assetId: assetId, currentEdit)
        }
    }

    private func scheduleRender(immediate: Bool = false) {
        renderTask?.cancel()
        isRendering = true
        renderTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            let asset = self.asset
            // While the crop tool is armed the preview shows the FULL frame
            // (crop stripped) so the overlay rect stays aligned with what the
            // user sees; disarmed, the render applies the crop as usual.
            let recipe = isCropToolActive ? edit.forCropEditing : edit
            let showRedactions = viewModel.showRedactions
            let image = await Task.detached(priority: .userInitiated) {
                try? DAMEditRenderer.render(asset: asset, edit: recipe, maxPixelSize: 1600, showRedactions: showRedactions)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                rendered = image
                renderFailed = image == nil
                isRendering = false
            }
        }
    }

    private func pasteSettings() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let pasted = DAMEditState.fromJSON(text)
        edit = pasted
        persistAndRender()
    }
}
