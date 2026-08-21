import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Overlay Builder / HTML Builder tools
//
// Agent surface for the Overlay Builder panel (WorkspacePanelKind.htmlBuilder).
// The HTML editor's source lives in OverlayBuilderStore (hoisted out of the
// view's @State) so these tools read/write the SAME document the user sees in
// the live preview. Typical flows:
//   - "Build me a blog landing page" -> overlay_html_set with full html+css
//   - "Fix the broken layout" -> overlay_html_get, then overlay_html_set
//   - "Start from the MySpace template" -> overlay_html_template(name: "MySpace")
//   - Form-based overlays: overlay_select + overlay_set_field(title: ...)

extension MaestroTools {

    static func registerOverlayTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "overlay_html_get", spec: overlayToolSpecs[0],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { _ in await overlayHTMLGetTool() }),
            ToolDefinition(
                name: "overlay_html_set", spec: overlayToolSpecs[1],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { call in await overlayHTMLSetTool(call) }),
            ToolDefinition(
                name: "overlay_html_template", spec: overlayToolSpecs[2],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { call in await overlayHTMLTemplateTool(call) }),
            ToolDefinition(
                name: "overlay_list", spec: overlayToolSpecs[3],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { _ in await overlayListTool() }),
            ToolDefinition(
                name: "overlay_select", spec: overlayToolSpecs[4],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { call in await overlaySelectTool(call) }),
            ToolDefinition(
                name: "overlay_set_field", spec: overlayToolSpecs[5],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { call in await overlaySetFieldTool(call) }),
            ToolDefinition(
                name: "overlay_get_fields", spec: overlayToolSpecs[6],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { _ in await overlayGetFieldsTool() }),
        ])
    }

    static var overlayToolSpecs: [ToolSpec] {
        [
            rawSpec("overlay_html_get",
                "Read the HTML Builder's current HTML and CSS source. Always call this BEFORE "
                + "overlay_html_set when the user asks you to fix or modify existing content, so "
                + "you preserve what's there instead of overwriting blind.",
                properties: [:], required: []),
            rawSpec("overlay_html_set",
                "Write HTML and/or CSS into the HTML Builder's live editor. The preview updates "
                + "immediately - the user watches your changes land. Pass only the parts you want "
                + "to change; omit html or css to leave it untouched. Use this to build pages from "
                + "user prompts or apply fixes after overlay_html_get.",
                properties: [
                    "html": ["type": "string", "description": "New HTML body markup (optional)"],
                    "css": ["type": "string", "description": "New CSS (optional)"],
                ], required: []),
            rawSpec("overlay_html_template",
                "Load a full-page website template into the HTML Builder (replaces current HTML "
                + "and CSS). Available templates: Blog (serif personal blog with sidebar), Vlog "
                + "(dark video channel page), MySpace (retro 2005 profile with top-8 friends), "
                + "Tumblr (dashboard feed). Use overlay_list to see descriptions.",
                properties: [
                    "name": ["type": "string", "description": "Template name: Blog, Vlog, MySpace, or Tumblr"],
                ],
                required: ["name"]),
            rawSpec("overlay_list",
                "List everything the Overlay Builder can create: form-based overlay types (lower "
                + "thirds, titles, tickers, etc. with their groups) and the full-page website "
                + "templates for the HTML editor.",
                properties: [:], required: []),
            rawSpec("overlay_select",
                "Switch the Overlay Builder to a different overlay type (e.g. lowerThird, "
                + "titleCard, ticker, htmlEditor). Use overlay_list to see valid type ids.",
                properties: [
                    "type": ["type": "string", "description": "Overlay type id from overlay_list"],
                ],
                required: ["type"]),
            rawSpec("overlay_set_field",
                "Set a text/style field on the currently selected form-based overlay (e.g. title, "
                + "subtitle, accent color). Use overlay_get_fields first to see available keys.",
                properties: [
                    "key": ["type": "string", "description": "Field key (from overlay_get_fields)"],
                    "value": ["type": "string", "description": "New value"],
                ],
                required: ["key", "value"]),
            rawSpec("overlay_get_fields",
                "Read the current field values of the selected form-based overlay, plus the field "
                + "definitions (keys, labels, kinds) its editor exposes. Not applicable to the "
                + "htmlEditor type - use overlay_html_get for that.",
                properties: [:], required: []),
        ]
    }

    // MARK: - Handlers

    private struct HTMLSetArgs: Decodable { let html: String?; let css: String? }
    private struct NameArgs: Decodable { let name: String? }
    private struct SelectArgs: Decodable { let type: String? }
    private struct SetFieldArgs: Decodable { let key: String?; let value: String? }

    private static func overlayHTMLGetTool() async -> String {
        await MainActor.run {
            let store = OverlayBuilderStore.shared
            return jsonString([
                "html": store.htmlEditorSource,
                "css": store.cssEditorSource,
                "selected_type": store.selectedType.rawValue,
            ])
        }
    }

    private static func overlayHTMLSetTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: HTMLSetArgs.self) else {
            return errorJSON("Could not parse arguments")
        }
        return await MainActor.run {
            let store = OverlayBuilderStore.shared
            var changed: [String] = []
            if let html = args.html {
                store.htmlEditorSource = html
                changed.append("html")
            }
            if let css = args.css {
                store.cssEditorSource = css
                changed.append("css")
            }
            guard !changed.isEmpty else {
                return errorJSON("Nothing to change - pass html and/or css.")
            }
            if store.selectedType != .htmlEditor {
                store.selectType(.htmlEditor)
                changed.append("switched_to_htmlEditor")
            }
            return jsonString(["updated": changed])
        }
    }

    private static func overlayHTMLTemplateTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NameArgs.self),
              let name = args.name, !name.isEmpty else {
            return errorJSON("'name' is required (Blog, Vlog, MySpace, Tumblr)")
        }
        return await MainActor.run {
            guard let tpl = WebsiteTemplates.all.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                let valid = WebsiteTemplates.all.map(\.name).joined(separator: ", ")
                return errorJSON("Unknown template '\(name)'. Available: \(valid)")
            }
            let store = OverlayBuilderStore.shared
            store.htmlEditorSource = tpl.html
            store.cssEditorSource = tpl.css
            if store.selectedType != .htmlEditor {
                store.selectType(.htmlEditor)
            }
            return jsonString(["applied": tpl.name, "description": tpl.description])
        }
    }

    private static func overlayListTool() async -> String {
        await MainActor.run {
            let grouped = Dictionary(grouping: OverlayType.allCases, by: \.group)
            let overlays = grouped.sorted { $0.key < $1.key }.map { group, types in
                [
                    "group": group,
                    "types": types.map { ["id": $0.rawValue, "name": $0.displayName] },
                ] as [String: Any]
            }
            let templates = WebsiteTemplates.all.map {
                ["name": $0.name, "description": $0.description] as [String: Any]
            }
            return jsonString([
                "overlay_types": overlays,
                "website_templates": templates,
                "selected_type": OverlayBuilderStore.shared.selectedType.rawValue,
            ])
        }
    }

    private static func overlaySelectTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SelectArgs.self),
              let raw = args.type, !raw.isEmpty else {
            return errorJSON("'type' is required (use overlay_list to see ids)")
        }
        return await MainActor.run {
            guard let type = OverlayType.allCases.first(where: {
                $0.rawValue.localizedCaseInsensitiveCompare(raw) == .orderedSame
                    || $0.displayName.localizedCaseInsensitiveCompare(raw) == .orderedSame
            }) else {
                let valid = OverlayType.allCases.map(\.rawValue).joined(separator: ", ")
                return errorJSON("Unknown overlay type '\(raw)'. Valid: \(valid)")
            }
            OverlayBuilderStore.shared.selectType(type)
            return jsonString(["selected": type.rawValue, "name": type.displayName])
        }
    }

    private static func overlaySetFieldTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SetFieldArgs.self),
              let key = args.key, !key.isEmpty, let value = args.value else {
            return errorJSON("'key' and 'value' are required")
        }
        return await MainActor.run {
            let store = OverlayBuilderStore.shared
            guard store.selectedType != .htmlEditor else {
                return errorJSON("htmlEditor has no form fields - use overlay_html_set")
            }
            store.setField(key, value: value)
            return jsonString(["set": key, "type": store.selectedType.rawValue])
        }
    }

    private static func overlayGetFieldsTool() async -> String {
        await MainActor.run {
            let store = OverlayBuilderStore.shared
            guard store.selectedType != .htmlEditor else {
                return jsonString([
                    "type": "htmlEditor",
                    "note": "Use overlay_html_get for the HTML editor",
                ])
            }
            let defs = OverlayConfig.defaults(for: store.selectedType).fields
            return jsonString([
                "type": store.selectedType.rawValue,
                "fields": store.currentFields,
                "available_keys": defs.keys.sorted(),
            ])
        }
    }
}
