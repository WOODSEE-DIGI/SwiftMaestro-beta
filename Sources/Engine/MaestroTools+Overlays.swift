import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - SwiftWeaver tools
//
// Agent surface for the SwiftWeaver HTML editor panel. The editor's source
// lives in SwiftWeaverStore, so these tools read/write the SAME document the
// user sees in the live preview. Typical flows:
//   - "Build me a blog landing page" -> weaver_html_set with full html+css
//   - "Fix the broken layout" -> weaver_html_get, then weaver_html_set
//   - "Start from the MySpot template" -> weaver_html_template(name: "MySpot")

extension MaestroTools {

    static func registerSwiftWeaverTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "weaver_html_get", spec: weaverToolSpecs[0],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { _ in await weaverHTMLGetTool() }),
            ToolDefinition(
                name: "weaver_html_set", spec: weaverToolSpecs[1],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { call in await weaverHTMLSetTool(call) }),
            ToolDefinition(
                name: "weaver_html_template", spec: weaverToolSpecs[2],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { call in await weaverHTMLTemplateTool(call) }),
            ToolDefinition(
                name: "weaver_list_templates", spec: weaverToolSpecs[3],
                category: ToolCategory.overlayBuilder.rawValue,
                handler: { _ in await weaverListTool() }),
        ])
    }

    static var weaverToolSpecs: [ToolSpec] {
        [
            rawSpec("weaver_html_get",
                "Read SwiftWeaver's current HTML and CSS source. Always call this BEFORE "
                + "weaver_html_set when the user asks you to fix or modify existing content, so "
                + "you preserve what's there instead of overwriting blind.",
                properties: [:], required: []),
            rawSpec("weaver_html_set",
                "Write HTML and/or CSS into SwiftWeaver's live editor. The preview updates "
                + "immediately - the user watches your changes land. Pass only the parts you want "
                + "to change; omit html or css to leave it untouched. Use this to build pages from "
                + "user prompts or apply fixes after weaver_html_get.",
                properties: [
                    "html": ["type": "string", "description": "New HTML body markup (optional)"],
                    "css": ["type": "string", "description": "New CSS (optional)"],
                ], required: []),
            rawSpec("weaver_html_template",
                "Load a website template into SwiftWeaver (replaces current HTML and CSS). "
                + "Use weaver_list_templates to see options (Blog, Vlog, MySpot, Timble, "
                + "Meme Lab, Avatar, Banner, Link Bio).",
                properties: [
                    "name": ["type": "string", "description": "Template name"],
                ],
                required: ["name"]),
            rawSpec("weaver_list_templates",
                "List the website templates available in SwiftWeaver with descriptions.",
                properties: [:], required: []),
        ]
    }

    // MARK: - Handlers

    private struct HTMLSetArgs: Decodable { let html: String?; let css: String? }
    private struct NameArgs: Decodable { let name: String? }

    private static func weaverHTMLGetTool() async -> String {
        await MainActor.run {
            let store = SwiftWeaverStore.shared
            return jsonString([
                "html": store.htmlSource,
                "css": store.cssSource,
                "file": store.fileURL?.lastPathComponent ?? "untitled",
            ])
        }
    }

    private static func weaverHTMLSetTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: HTMLSetArgs.self) else {
            return errorJSON("Could not parse arguments")
        }
        return await MainActor.run {
            let store = SwiftWeaverStore.shared
            var changed: [String] = []
            if let html = args.html {
                store.htmlSource = html
                changed.append("html")
            }
            if let css = args.css {
                store.cssSource = css
                changed.append("css")
            }
            guard !changed.isEmpty else {
                return errorJSON("Nothing to change - pass html and/or css.")
            }
            return jsonString(["updated": changed])
        }
    }

    private static func weaverHTMLTemplateTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NameArgs.self),
              let name = args.name, !name.isEmpty else {
            return errorJSON("'name' is required (weaver_list_templates shows options)")
        }
        return await MainActor.run {
            guard let tpl = WebsiteTemplates.all.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                let valid = WebsiteTemplates.all.map(\.name).joined(separator: ", ")
                return errorJSON("Unknown template '\(name)'. Available: \(valid)")
            }
            SwiftWeaverStore.shared.applyWebsiteTemplate(tpl)
            return jsonString(["applied": tpl.name, "description": tpl.description])
        }
    }

    private static func weaverListTool() async -> String {
        await MainActor.run {
            let templates = WebsiteTemplates.all.map {
                ["name": $0.name, "description": $0.description] as [String: Any]
            }
            return jsonString(["website_templates": templates])
        }
    }
}
