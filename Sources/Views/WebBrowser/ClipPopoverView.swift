import SwiftUI

// MARK: - Clip Popover
//
// Obsidian Web Clipper-style popover for the SwiftBrowser toolbar: extracts
// the page, shows ONE BUTTON PER TEMPLATE (click clips immediately with that
// template's destinations and closes), and an optional adjust section for
// editing properties/destinations before clipping.

struct ClipPopoverView: View {
    @Bindable var store: WebBrowserStore
    @Environment(\.dismiss) private var dismiss

    @State private var templates = ClipTemplateStore.shared
    @State private var selectedTemplate: ClipTemplate?
    @State private var propertyValues: [UUID: String] = [:]
    @State private var noteName = ""
    @State private var saveToNotes = true
    @State private var saveToMaestroDB = true
    @State private var maestroLocation = ""
    @State private var isExtracting = true
    @State private var didExtract = false
    @State private var extractError: String?
    @State private var clip: WebClipResult?
    @State private var variables: [String: String] = [:]
    @State private var showAdjust = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isExtracting {
                extractingState
            } else if let error = extractError {
                errorState(error)
            } else {
                templateButtons
                Divider()
                adjustSection
            }
        }
        .frame(width: 420)
        .task { await extract() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("Clip Page")
                .font(.headline)
            Spacer()
            if let clip, clip.wordCount > 0 {
                Text("\(clip.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - States

    private var extractingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Extracting page content…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView(
            "Clip Failed",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Template buttons (one click = clip)

    private var templateButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clip with:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(templates.templates) { template in
                Button {
                    Task { await clipNow(with: template) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: template))
                            .font(.body)
                            .frame(width: 22)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.body.weight(.medium))
                            Text(destinationSummary(template))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "scissors")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .disabled(store.isClipping)
        .opacity(store.isClipping ? 0.6 : 1)
    }

    private func icon(for template: ClipTemplate) -> String {
        switch template.name.lowercased() {
        case "forensics": return "checkmark.shield"
        case "youtube": return "play.rectangle"
        case "research": return "doc.text.magnifyingglass"
        default: return "doc.text"
        }
    }

    private func destinationSummary(_ template: ClipTemplate) -> String {
        var parts: [String] = []
        if template.saveToNotes { parts.append(template.folder) }
        if template.saveToMaestroDB { parts.append("\(template.maestroBase) → \(template.maestroTable)") }
        if template.captureForensics { parts.append("+ forensic metadata") }
        return parts.isEmpty ? "No destinations enabled" : parts.joined(separator: "  ·  ")
    }

    // MARK: - Adjust section (optional, collapsed by default)

    private var adjustSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdjust.toggle() }
            } label: {
                HStack {
                    Text("Adjust before clipping")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showAdjust ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdjust {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        templatePicker
                        noteNameField
                        propertiesSection
                        destinationSection
                        adjustClipButton
                    }
                    .padding(12)
                }
                // Fixed height — maxHeight alone collapses to zero inside a
                // popover (ScrollView has no intrinsic content size).
                .frame(height: 280)
            }
        }
    }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Template")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Template", selection: $selectedTemplate) {
                ForEach(templates.templates) { template in
                    Text(template.name).tag(Optional(template))
                }
            }
            .labelsHidden()
            .onChange(of: selectedTemplate) { _, newTemplate in
                if let newTemplate { applyTemplate(newTemplate) }
            }
        }
    }

    private var noteNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Note name")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Note name", text: $noteName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Properties")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let template = selectedTemplate {
                ForEach(template.properties) { property in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(property.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        TextField(property.name,
                                  text: Binding(
                                    get: { propertyValues[property.id] ?? "" },
                                    set: { propertyValues[property.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save to")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle("Notes vault (Markdown + frontmatter)", isOn: $saveToNotes)
                .font(.callout)
            if saveToNotes, let template = selectedTemplate {
                Label(template.folder, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
            Toggle("MaestroDB", isOn: $saveToMaestroDB)
                .font(.callout)
            if saveToMaestroDB {
                Label(maestroLocation, systemImage: "tablecells")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
    }

    private var adjustClipButton: some View {
        Button {
            Task { await performAdjustedClip() }
        } label: {
            Label("Clip with Adjustments", systemImage: "scissors")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled((!saveToNotes && !saveToMaestroDB) || store.isClipping)
    }

    // MARK: - Actions

    private func extract() async {
        // .task can re-fire when the popover view rebuilds — never run twice.
        guard !didExtract else { return }
        didExtract = true
        isExtracting = true
        extractError = nil
        guard let prepared = await store.prepareClip() else {
            isExtracting = false
            extractError = store.lastClipStatus ?? "Could not extract page content."
            return
        }
        clip = prepared.clip
        variables = ClipTemplateEngine.buildVariables(from: prepared.clip)
        selectedTemplate = prepared.template
        applyTemplate(prepared.template)
        isExtracting = false
    }

    /// One-click path: clip immediately with the template's own settings.
    private func clipNow(with template: ClipTemplate) async {
        guard let clip else { return }
        _ = await store.saveClip(clip, template: template, destinations: nil)
        dismiss()
    }

    /// Re-render property values and note name from the selected template,
    /// and adopt the template's destination defaults.
    private func applyTemplate(_ template: ClipTemplate) {
        for property in template.properties {
            propertyValues[property.id] = ClipTemplateEngine.render(
                property.valueTemplate, variables: variables)
        }
        noteName = ClipTemplateEngine.render(template.noteNameFormat, variables: variables)
        saveToNotes = template.saveToNotes
        saveToMaestroDB = template.saveToMaestroDB
        maestroLocation = "\(template.maestroBase) → \(template.maestroTable)"
    }

    /// Adjusted path: user-edited property values + destination toggles win.
    private func performAdjustedClip() async {
        guard let clip, var template = selectedTemplate else { return }
        for i in template.properties.indices {
            if let edited = propertyValues[template.properties[i].id] {
                template.properties[i].valueTemplate = edited
            }
        }
        if !noteName.trimmingCharacters(in: .whitespaces).isEmpty {
            template.noteNameFormat = noteName
        }
        var destinations: WebBrowserStore.ClipDestinations = []
        if saveToNotes { destinations.insert(.notes) }
        if saveToMaestroDB { destinations.insert(.maestroDB) }
        // Save the already-extracted clip — no second page extraction.
        _ = await store.saveClip(clip, template: template, destinations: destinations)
        dismiss()
    }
}
