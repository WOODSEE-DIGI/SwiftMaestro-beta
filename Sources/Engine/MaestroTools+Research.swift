import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Research tools (autonomous capture)
//
// Composite tools that turn the capture stack into one-call operations for
// the agent. The failure mode these prevent: the Aug 4 research run where the
// model choreographed browser_open -> browser_read -> browser_clip by hand,
// browsed 36 rounds, and never wrote anything. clip_url makes single-source
// capture atomic; research_topic runs the whole loop (search -> capture N
// sources -> report) with deterministic writes built in.

extension MaestroTools {

    static func registerResearchTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "clip_url", spec: researchToolSpecs[0],
                category: ToolCategory.browser.rawValue,
                handler: { call in await clipURLTool(call) }),
            ToolDefinition(
                name: "research_topic", spec: researchToolSpecs[1],
                category: ToolCategory.browser.rawValue,
                handler: { call in await researchTopicTool(call) }),
        ])
    }

    static var researchToolSpecs: [ToolSpec] {
        [
            rawSpec("clip_url",
                "Capture a web page in ONE call: opens a background tab, extracts content + metadata "
                + "(author, published, schema.org, meta tags), renders the note with the matched "
                + "template, downloads images, saves snapshot.html/reader.html/screenshot, writes to "
                + "the Notes vault and/or MaestroDB per the template, then closes the tab. Use this "
                + "instead of browser_open + browser_read + browser_clip when the goal is CAPTURING "
                + "a page (not reading it into context). Template auto-matches by URL; pass 'template' "
                + "to force one (clip_template_list shows options: Default, Research, YouTube, Forensics).",
                properties: [
                    "url": ["type": "string", "description": "URL to capture (https:// added if missing)"],
                    "template": ["type": "string", "description": "Template NAME (default: auto-match by URL)"],
                    "destination": ["type": "string", "description": "'both', 'notes', or 'maestrodb' (default: template's settings)"],
                ],
                required: ["url"]),
            rawSpec("research_topic",
                "Autonomous research capture: searches the web for a topic, then captures the top N "
                + "sources with the Web Clipper: each becomes a formatted note (with images + "
                + "snapshot) in the Notes vault and a queryable row in MaestroDB. Returns a report "
                + "of what was captured where. Use 'Research' template (default) for general topics "
                + "or 'Forensics' when provenance metadata matters (timestamps, headers, RDAP). "
                + "Afterwards you can answer from the captured notes instead of re-browsing.",
                properties: [
                    "query": ["type": "string", "description": "Research question or topic"],
                    "max_sources": ["type": "integer", "description": "Sources to capture (default 4, max 8)"],
                    "template": ["type": "string", "description": "Template NAME (default 'Research')"],
                ],
                required: ["query"]),
        ]
    }

    // MARK: - Args

    private struct ClipURLArgs: Decodable {
        let url: String?
        let template: String?
        let destination: String?
    }

    private struct ResearchTopicArgs: Decodable {
        let query: String?
        let max_sources: LenientInt?
        let template: String?
    }

    // MARK: - clip_url

    @MainActor
    private static func clipURLTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ClipURLArgs.self),
              let rawURL = args.url, !rawURL.isEmpty else {
            return errorJSON("'url' is required")
        }
        let urlString = ToolArgumentRepair.sanitizeAgentURL(rawURL)
        guard !urlString.isEmpty else {
            return errorJSON("'url' was empty after cleaning escape junk from '\(rawURL)'")
        }

        var template: ClipTemplate?
        if let name = args.template, !name.isEmpty {
            template = ClipTemplateStore.shared.templates.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            })
            if template == nil {
                let available = ClipTemplateStore.shared.templates.map(\.name).joined(separator: ", ")
                return errorJSON("Unknown template '\(name)'. Available: \(available)")
            }
        }

        var destinations: WebBrowserStore.ClipDestinations? = nil
        switch args.destination?.lowercased() {
        case "notes": destinations = .notes
        case "maestrodb", "maestro", "db": destinations = .maestroDB
        case "both": destinations = .both
        case nil, "": break  // template's own destination settings decide
        default:
            return errorJSON("unknown destination - use 'notes', 'maestrodb', or 'both'")
        }

        let outcome = await captureURL(urlString, template: template, destinations: destinations)
        guard let outcome else {
            return errorJSON("capture failed for \(urlString) - page unreachable or extraction failed")
        }
        return jsonString([
            "status": "captured",
            "title": outcome.title,
            "url": urlString,
            "template": outcome.templateName,
            "note_path": outcome.notePath as Any,
            "maestrodb_row": outcome.maestroRowID as Any,
        ])
    }

    // MARK: - research_topic

    @MainActor
    private static func researchTopicTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ResearchTopicArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return errorJSON("'query' is required")
        }
        let maxSources = min(max(args.max_sources?.value ?? 4, 1), 8)

        // Template: explicit, else Research, else URL auto-match at save time
        let templateName = args.template ?? "Research"
        let template = ClipTemplateStore.shared.templates.first(where: {
            $0.name.localizedCaseInsensitiveCompare(templateName) == .orderedSame
        })
        if args.template != nil && template == nil {
            let available = ClipTemplateStore.shared.templates.map(\.name).joined(separator: ", ")
            return errorJSON("Unknown template '\(templateName)'. Available: \(available)")
        }

        // 1. Discover sources
        let results = await searchWeb(query: query, maxResults: maxSources)
        guard !results.isEmpty else {
            return errorJSON("No search results for '\(query)' - try rephrasing")
        }

        // 2. Capture each source sequentially (the clipper's hidden webview is
        // a singleton - parallel clips would interleave on it).
        var captured: [[String: Any]] = []
        var failed: [[String: String]] = []
        for result in results {
            let outcome = await captureURL(result.url, template: template, destinations: nil)
            if let outcome {
                captured.append([
                    "title": outcome.title,
                    "url": result.url,
                    "note_path": outcome.notePath as Any,
                    "maestrodb_row": outcome.maestroRowID as Any,
                ])
            } else {
                failed.append(["url": result.url, "title": result.title])
            }
        }

        return jsonString([
            "status": "complete",
            "query": query,
            "template": template?.name ?? "auto",
            "captured_count": captured.count,
            "failed_count": failed.count,
            "captured": captured,
            "failed": failed,
            "note": captured.isEmpty
                ? "Nothing captured - all sources failed to load or extract."
                : "Answer from the captured notes (vault + MaestroDB Web Clips base) - no need to re-browse these sources.",
        ])
    }

    // MARK: - Shared capture pipeline

    /// Capture one URL: background tab -> wait for load -> full clip -> save ->
    /// close tab. Atomic from the agent's perspective.
    @MainActor
    private static func captureURL(
        _ urlString: String,
        template: ClipTemplate?,
        destinations: WebBrowserStore.ClipDestinations?
    ) async -> WebBrowserStore.ClipOutcome? {
        let store = WebBrowserStore.shared
        guard let tab = store.openURLInNewTab(urlString, background: true, reuseExisting: false) else {
            return nil
        }
        defer { store.closeTab(id: tab.id) }

        // Wait for the page to load (bounded) before capturing.
        await tab.waitUntilLoaded(timeout: 20)
        guard let url = tab.currentURL?.absoluteString,
              let html = try? await tab.capturePageHTML(), !html.isEmpty,
              let clip = try? await WebClipperService.shared.clipFull(html: html, url: url) else {
            return nil
        }
        return await store.saveClip(clip, template: template, destinations: destinations)
    }

    // MARK: - Web search (Bing, same engine as web_search)

    /// Fetch Bing results as typed structs. Reuses the parser from the
    /// web_search tool so both tools see the same result quality.
    private static func searchWeb(query: String, maxResults: Int) async -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://www.bing.com/search?q=\(encoded)") else {
            return []
        }
        var request = URLRequest(url: searchURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }
        return MaestroTools.parseBingResults(html, maxResults: maxResults)
    }
}
