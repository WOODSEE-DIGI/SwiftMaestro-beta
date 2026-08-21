import SwiftUI

// MARK: - Clipper Settings Tab
//
// Web Clipper configuration: template management (the Obsidian-clipper-style
// engine that formats clipped pages), default destinations, and activity.
// Templates live in ClipTemplateStore; clips land in the Notes vault and/or
// the MaestroDB "Web Clips" base.

struct ClipperSettingsTab: View {
    @State private var templateStore = ClipTemplateStore.shared
    @State private var selection: ClipTemplate.ID?
    @State private var clipCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                activitySection
                templatesSection
                if let selection,
                   let template = templateStore.templates.first(where: { $0.id == selection }) {
                    // .id forces a fresh editor per template — otherwise the
                    // editor's @State (patternsText, etc.) survives a template
                    // switch and shows the previous template's values.
                    TemplateEditorView(template: template)
                        .id(selection)
                }
            }
            .padding()
        }
        .onAppear {
            clipCount = ClipLibraryBridge.shared.clipCount
            if selection == nil { selection = templateStore.templates.first?.id }
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        GroupBox("Activity") {
            HStack {
                Label("\(clipCount) pages saved to MaestroDB", systemImage: "doc.richtext")
                Spacer()
                Text("Notes vault clips are plain .md files — not counted here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        GroupBox("Templates") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Templates control how clipped pages are formatted: the note name, "
                     + "the vault folder, the YAML properties, and the body. URL patterns "
                     + "auto-select a template by site (e.g. \"youtube.com\").")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(templateStore.templates) { template in
                    Button {
                        selection = template.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(selection == template.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.body.weight(selection == template.id ? .semibold : .regular))
                                HStack(spacing: 8) {
                                    if !template.urlPatterns.isEmpty {
                                        Label(template.urlPatterns.joined(separator: ", "), systemImage: "link")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Label(template.folder, systemImage: "folder")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if selection == template.id {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            selection == template.id ? Color.accentColor.opacity(0.1) : Color.clear,
                            in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Button {
                        let new = ClipTemplate(
                            name: "New Template",
                            properties: ClipTemplate.defaultTemplate.properties,
                            bodyFormat: "{{content}}\n")
                        templateStore.add(new)
                        selection = new.id
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                    Spacer()
                    if let selection,
                       let template = templateStore.templates.first(where: { $0.id == selection }),
                       templateStore.templates.count > 1 {
                        Button(role: .destructive) {
                            templateStore.delete(template)
                            self.selection = templateStore.templates.first?.id
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Template Editor

private struct TemplateEditorView: View {
    @State private var template: ClipTemplate
    @State private var patternsText: String
    private let templateStore = ClipTemplateStore.shared

    init(template: ClipTemplate) {
        _template = State(initialValue: template)
        _patternsText = State(initialValue: template.urlPatterns.joined(separator: ", "))
    }

    var body: some View {
        GroupBox("Edit: \(template.name)") {
            VStack(alignment: .leading, spacing: 12) {
                // Name + folder
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Template name", text: $template.name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: template.name) { _, _ in save() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vault folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Clippings", text: $template.folder)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: template.folder) { _, _ in save() }
                    }
                }

                // Destinations
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save destinations")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Toggle(isOn: $template.saveToNotes) {
                        Label("Notes vault → \(template.folder.isEmpty ? "Clippings" : template.folder)",
                              systemImage: "doc.text")
                    }
                    .onChange(of: template.saveToNotes) { _, _ in save() }
                    Toggle(isOn: $template.saveToMaestroDB) {
                        Label("MaestroDB", systemImage: "tablecells")
                    }
                    .onChange(of: template.saveToMaestroDB) { _, _ in save() }
                    if template.saveToMaestroDB {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Base").font(.caption2).foregroundStyle(.tertiary)
                                TextField("Web Clips", text: $template.maestroBase)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: template.maestroBase) { _, _ in save() }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Table").font(.caption2).foregroundStyle(.tertiary)
                                TextField("Clips", text: $template.maestroTable)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: template.maestroTable) { _, _ in save() }
                            }
                        }
                        .padding(.leading, 22)
                    }
                    Text("The clip popover can still override these per-clip; these are the defaults.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Asset capture
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $template.downloadAssets) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Download page assets (snapshot)", systemImage: "photo.on.rectangle")
                            Text("Images download to an assets folder next to the note and links rewrite "
                                 + "to local paths; the full page HTML and a screenshot are saved alongside — "
                                 + "the clip survives the source page changing or disappearing.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: template.downloadAssets) { _, _ in save() }
                }

                // Forensic metadata
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $template.captureForensics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Capture forensic metadata", systemImage: "checkmark.shield")
                            Text("Writes capture-metadata.json beside the clip: universal (UTC) + local "
                                 + "timestamps, HTTP status and headers, TLS certificate issuer/expiry, and "
                                 + "the domain's RDAP record (registrar, registered/expiry dates, nameservers). "
                                 + "For investigative provenance. Off by default.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: template.captureForensics) { _, _ in save() }
                }

                // URL patterns
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL auto-match patterns (comma-separated)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("youtube.com, youtu.be", text: $patternsText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: patternsText) { _, newValue in
                            template.urlPatterns = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            save()
                        }
                }

                // Note name format
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note name format").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("{{title}}", text: $template.noteNameFormat)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: template.noteNameFormat) { _, _ in save() }
                }

                // Properties
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Properties (YAML frontmatter)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            template.properties.append(
                                ClipProperty(name: "property", valueTemplate: ""))
                            save()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .help("Add property")
                    }
                    ForEach(template.properties) { property in
                        PropertyRow(
                            property: property,
                            onChange: { updated in
                                if let idx = template.properties.firstIndex(where: { $0.id == updated.id }) {
                                    template.properties[idx] = updated
                                    save()
                                }
                            },
                            onDelete: {
                                template.properties.removeAll { $0.id == property.id }
                                save()
                            })
                    }
                }

                // Body format
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note body format").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $template.bodyFormat)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(4)
                        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
                        .onChange(of: template.bodyFormat) { _, _ in save() }
                    Text("Variables: {{title}} {{content}} {{author}} {{published|date:\"yyyy-MM-dd\"}} "
                         + "{{domain}} {{site}} {{url}} {{description}} {{image}} {{words}} "
                         + "{{meta:property:og:title}} {{schema:@Article:headline}}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
        }
    }

    private func save() {
        templateStore.update(template)
    }
}

// MARK: - Property Row

private struct PropertyRow: View {
    @State private var property: ClipProperty
    let onChange: (ClipProperty) -> Void
    let onDelete: () -> Void

    init(property: ClipProperty, onChange: @escaping (ClipProperty) -> Void, onDelete: @escaping () -> Void) {
        _property = State(initialValue: property)
        self.onChange = onChange
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $property.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onChange(of: property.name) { _, _ in onChange(property) }
            TextField("{{value}}", text: $property.valueTemplate)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: property.valueTemplate) { _, _ in onChange(property) }
            Picker("Type", selection: $property.type) {
                ForEach(ClipPropertyType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: property.type) { _, _ in onChange(property) }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove property")
        }
    }
}
