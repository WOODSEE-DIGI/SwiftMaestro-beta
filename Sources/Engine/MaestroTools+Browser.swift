import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native Internal-Browser Tools
//
// Gives agents (Maestro/navigator and project agents) full control of the
// internal WebKit browser for research: open/focus/close tabs, navigate, read
// pages as markdown/text/html, clip pages into the Notes vault, evaluate
// JavaScript, and capture screenshots. These complement the URLSession-based
// `web_search`/`fetch_url` tools by driving the real, rendered browser — which
// handles JavaScript-heavy pages that a plain fetch cannot.

extension MaestroTools {

    /// Registers internal-browser tools with `ToolRegistry`.
    static func registerBrowserTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "browser_open", spec: browserToolSpecs[0],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserOpen(call) }),
            ToolDefinition(
                name: "browser_list", spec: browserToolSpecs[1],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserList(call) }),
            ToolDefinition(
                name: "browser_focus", spec: browserToolSpecs[2],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserFocus(call) }),
            ToolDefinition(
                name: "browser_close", spec: browserToolSpecs[3],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserClose(call) }),
            ToolDefinition(
                name: "browser_navigate", spec: browserToolSpecs[4],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserNavigate(call) }),
            ToolDefinition(
                name: "browser_read", spec: browserToolSpecs[5],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserRead(call) }),
            ToolDefinition(
                name: "browser_current", spec: browserToolSpecs[6],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserCurrent(call) }),
            ToolDefinition(
                name: "browser_clip", spec: browserToolSpecs[7],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserClip(call) }),
            ToolDefinition(
                name: "browser_eval", spec: browserToolSpecs[8],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserEval(call) }),
            ToolDefinition(
                name: "browser_screenshot", spec: browserToolSpecs[9],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserScreenshot(call) }),
            ToolDefinition(
                name: "browser_links", spec: browserToolSpecs[10],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserLinks(call) }),
        ])
    }

    static var browserToolSpecs: [ToolSpec] {
        [
            rawSpec("browser_open",
                "Open a URL in an internal browser tab. If that URL is already open, the existing "
                + "tab is focused and returned (no duplicate is created) — so check browser_list "
                + "first and do NOT open the same page twice. IMPORTANT: only open URLs from a real "
                + "source — the user's request, or links returned by browser_links / browser_read / "
                + "web_search. NEVER invent or guess a URL; invented URLs almost always 404. Returns "
                + "the tab_id and warns if the page is a dead link. Pass background=true to open "
                + "without switching focus.",
                properties: [
                    "url": ["type": "string", "description": "URL to open (https:// added if missing)"],
                    "background": ["type": "boolean", "description": "Open without focusing the tab (default false)"],
                ],
                required: ["url"]),
            rawSpec("browser_list",
                "List all open internal-browser tabs with their tab_id, title, URL, active flag, and "
                + "loading state. Use before browser_focus/browser_read to find the right tab_id.",
                properties: [:],
                required: []),
            rawSpec("browser_focus",
                "Switch the active internal-browser tab to the given tab_id.",
                properties: [
                    "tab_id": ["type": "string", "description": "The tab_id to make active"],
                ],
                required: ["tab_id"]),
            rawSpec("browser_close",
                "Close an internal-browser tab. Defaults to the active tab when tab_id is omitted.",
                properties: [
                    "tab_id": ["type": "string", "description": "The tab_id to close (default: active tab)"],
                ],
                required: []),
            rawSpec("browser_navigate",
                "Navigate a tab: back, forward, reload, or stop. Defaults to the active tab.",
                properties: [
                    "action": ["type": "string", "description": "One of: back, forward, reload, stop"],
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                ],
                required: ["action"]),
            rawSpec("browser_read",
                "Read a tab's page content. format 'markdown' (default) runs the Web Clipper extractor "
                + "for clean article markdown; 'text' returns visible body text; 'html' returns the raw "
                + "document HTML. Defaults to the active tab.",
                properties: [
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                    "format": ["type": "string", "description": "markdown (default), text, or html"],
                ],
                required: []),
            rawSpec("browser_current",
                "Return the active tab's tab_id, URL, title, loading state, and back/forward availability.",
                properties: [:],
                required: []),
            rawSpec("browser_clip",
                "Clip a tab's page into the Notes vault as a Markdown note (uses the Web Clipper). "
                + "Defaults to the active tab. Returns the clip status / note filename.",
                properties: [
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                ],
                required: []),
            rawSpec("browser_eval",
                "Evaluate JavaScript in a tab and return the JSON-encoded result. Powerful — use for "
                + "reading DOM state, extracting data, or interacting with the page. Defaults to active tab.",
                properties: [
                    "script": ["type": "string", "description": "JavaScript to evaluate"],
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                ],
                required: ["script"]),
            rawSpec("browser_screenshot",
                "Capture a PNG screenshot of a tab (WebKit only), save it to a temp file, and return the "
                + "file path. Use ocr_image or attach the file to view it. Defaults to the active tab.",
                properties: [
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                ],
                required: []),
            rawSpec("browser_links",
                "Extract the REAL links (href + anchor text) from a page's actual DOM. Use this to "
                + "decide where to navigate next instead of guessing a URL — open these hrefs with "
                + "browser_open. Optionally restrict to same-domain links and cap the count.",
                properties: [
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                    "limit": ["type": "integer", "description": "Max links to return (default 50, max 200)"],
                    "same_domain": ["type": "boolean", "description": "Only links on the current domain (default false)"],
                ],
                required: []),
        ]
    }

    // MARK: - Args

    private struct OpenArgs: Decodable { let url: String?; let background: LenientBool? }
    private struct TabIDArgs: Decodable { let tab_id: String? }
    private struct NavigateArgs: Decodable { let action: String?; let tab_id: String? }
    private struct LinksArgs: Decodable { let tab_id: String?; let limit: LenientInt?; let same_domain: LenientBool? }
    private struct ReadArgs: Decodable { let tab_id: String?; let format: String? }
    private struct EvalArgs: Decodable { let script: String?; let tab_id: String? }

    // MARK: - Helpers

    /// Resolve a tab from an optional tab_id string, falling back to the active tab.
    @MainActor
    private static func resolveTab(_ tabID: String?, in store: WebBrowserStore) -> BrowserTab? {
        if let id = agentUUID(tabID), let tab = store.tabs.first(where: { $0.id == id }) {
            return tab
        }
        return store.selectedTab
    }

    /// JS that detects "soft 404" error pages — pages that return HTTP 200 but
    /// render a "can't be found / page not found" message — and also reports how much
    /// text has rendered so the caller can distinguish a still-rendering SPA from a
    /// genuinely good page. Returns `{ notFound: Bool, textLength: Int }`.
    ///
    /// IMPORTANT: it walks the DOM recursively and descends into OPEN shadow roots.
    /// Apple's developer site (and many component-based SPAs) render their main
    /// content — including the error message — inside Web Component shadow DOM, which
    /// `innerText`/`textContent` on document.body do NOT traverse. The light-DOM
    /// footer alone would otherwise make the page look populated while the real error
    /// stayed invisible. Text is collected into an array and joined once (O(n), not
    /// O(n²) string concatenation) since this runs in a poll loop.
    private static let soft404Script = #"""
    (function() {
        var parts = [];
        function collect(node, depth) {
            if (!node || depth > 40) { return; }
            if (node.shadowRoot) { collect(node.shadowRoot, depth + 1); }
            var children = node.childNodes;
            for (var i = 0; i < children.length; i++) {
                var c = children[i];
                if (c.nodeType === 3) { parts.push(c.textContent); }
                else if (c.nodeType === 1) {
                    var tag = c.tagName ? c.tagName.toLowerCase() : '';
                    if (tag === 'script' || tag === 'style' || tag === 'noscript') { continue; }
                    collect(c, depth + 1);
                }
            }
        }
        if (document.body) { collect(document.body, 0); }
        var bodyText = parts.join(' ');
        var text = ((document.title || '') + ' ' + bodyText).toLowerCase();
        var markers = ["can't be found", "can’t be found", "page you're looking for", "page you’re looking for",
            "page not found", "doesn't exist", "doesn’t exist", "no longer exists",
            "couldn't find that page", "couldn’t find that page", "this page doesn't exist", "this page doesn’t exist",
            "nothing to see here", "lost your way"];
        var found = false;
        for (var i = 0; i < markers.length; i++) {
            if (text.indexOf(markers[i]) !== -1) { found = true; break; }
        }
        return { notFound: found, textLength: bodyText.length };
    })()
    """#

    /// Whether the tab is showing a soft-404 error page (HTTP 200 + "not found" content).
    /// SPA pages (Apple Developer etc.) render content — including the error message —
    /// via JS *after* the load event, so a single check right after `waitUntilLoaded`
    /// sees an empty shell and misses it. Poll: return true the moment the marker
    /// appears, and false only after the page has rendered real content with no marker
    /// on two consecutive reads (so it settles) or we time out.
    @MainActor
    private static func tabIsSoft404(_ tab: BrowserTab) async -> Bool {
        guard tab.engineType == .webKit else { return false }
        let deadline = Date().addingTimeInterval(4)
        var settledReads = 0
        while Date() < deadline {
            if let data = try? await tab.evaluateJavaScript(soft404Script),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (obj["notFound"] as? Bool) == true { return true }
                if ((obj["textLength"] as? Int) ?? 0) > 200 {
                    settledReads += 1
                    if settledReads >= 2 { return false }
                } else {
                    settledReads = 0
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    /// Wait until the page has rendered some visible text. SPA pages (Apple
    /// Developer etc.) render their DOM via JS *after* the load event, so reading
    /// `outerHTML`/links/innerText immediately after `waitUntilLoaded` can return an
    /// empty shell. Poll until real content appears (or the timeout elapses).
    /// No-op for non-WebKit tabs.
    @MainActor
    private static func waitForRenderedContent(_ tab: BrowserTab, timeout: TimeInterval = 4) async {
        guard tab.engineType == .webKit else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? await tab.evaluateJavaScript(
                "document.body ? (document.body.innerText || document.body.textContent || '').length : 0"),
               let length = try? JSONDecoder().decode(Int.self, from: data), length > 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: - Handlers

    @MainActor
    private static func browserOpen(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenArgs.self)
        guard let urlString = args?.url,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorJSON("'url' is required")
        }
        let background = args?.background?.value ?? false
        let store = WebBrowserStore.shared
        // Snapshot existing tab ids so we can tell whether we reused one below.
        let tabIDsBefore = Set(store.tabs.map { $0.id })
        guard let tab = store.openURLInNewTab(urlString, background: background, reuseExisting: true) else {
            return errorJSON("Invalid URL: \(urlString)")
        }
        let reusedExisting = tabIDsBefore.contains(tab.id)
        // Wait for the navigation so we can report whether the page actually exists.
        await tab.waitUntilLoaded(timeout: 15)
        var result: [String: Any] = [
            "tab_id": tab.id.uuidString,
            "url": tab.currentURL?.absoluteString ?? urlString,
            "active": store.selectedTabID == tab.id,
            "background": background,
        ]
        if reusedExisting {
            result["reused_existing"] = true
            result["note"] = "This URL is already open in a tab — reused it instead of opening a "
                + "duplicate. You do NOT need to open the same page again; use browser_list to see open tabs."
        }
        if let status = tab.lastHTTPStatus { result["http_status"] = status }
        // A failed navigation (malformed URL, DNS/unreachable host) sets a load error
        // and the tab renders "The URL can't be shown". That is a dead link too — report
        // it rather than letting the agent mistake the error page for real content.
        if let loadError = tab.error, !loadError.isEmpty {
            result["dead_link"] = true
            result["load_error"] = loadError
            result["warning"] = "The page FAILED to load (\(loadError)). Do NOT treat it as loaded — "
                + "call browser_links on a real page and open one of its real hrefs instead of guessing a URL."
            return jsonString(result)
        }
        // Dead-link detection: hard 404 (HTTP status) OR soft 404 (HTTP 200 error page).
        let soft404 = await tabIsSoft404(tab)
        if tab.isDeadLink || soft404 {
            result["dead_link"] = true
            let reason = tab.isDeadLink ? "HTTP \(tab.lastHTTPStatus ?? 0)" : "page shows a 'not found' message"
            result["warning"] = "This page is a DEAD LINK (\(reason)). Do NOT treat it as loaded — "
                + "call browser_links on a real page and open one of its real hrefs instead of guessing."
        }
        return jsonString(result)
    }

    @MainActor
    private static func browserList(_ call: ToolCall) async -> String {
        let store = WebBrowserStore.shared
        let list: [[String: Any]] = store.tabs.map { tab in
            [
                "tab_id": tab.id.uuidString,
                "title": tab.title,
                "url": tab.currentURL?.absoluteString ?? "",
                "active": store.selectedTabID == tab.id,
                "loading": tab.isLoading,
            ]
        }
        return jsonString(["tabs": list, "count": list.count])
    }

    @MainActor
    private static func browserFocus(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: TabIDArgs.self)
        guard let id = agentUUID(args?.tab_id) else { return errorJSON("'tab_id' is required") }
        let store = WebBrowserStore.shared
        guard store.tabs.contains(where: { $0.id == id }) else {
            return errorJSON("No tab with id \(id.uuidString)")
        }
        store.selectedTabID = id
        return jsonString(["active_tab_id": id.uuidString])
    }

    @MainActor
    private static func browserClose(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: TabIDArgs.self)
        let store = WebBrowserStore.shared
        guard let id = agentUUID(args?.tab_id) ?? store.selectedTabID else {
            return errorJSON("No tab to close")
        }
        store.closeTab(id: id)
        return jsonString(["closed_tab_id": id.uuidString, "remaining_tabs": store.tabs.count])
    }

    @MainActor
    private static func browserNavigate(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: NavigateArgs.self)
        guard let action = args?.action?.lowercased(), !action.isEmpty else {
            return errorJSON("'action' is required: back, forward, reload, or stop")
        }
        let store = WebBrowserStore.shared
        guard let tab = resolveTab(args?.tab_id, in: store) else { return errorJSON("No active tab") }
        switch action {
        case "back": await tab.goBack()
        case "forward": await tab.goForward()
        case "reload": await tab.reload()
        case "stop": tab.stopLoading()
        default:
            return errorJSON("Unknown action '\(action)'. Use back, forward, reload, or stop")
        }
        return jsonString(["action": action, "tab_id": tab.id.uuidString])
    }

    @MainActor
    private static func browserRead(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ReadArgs.self)
        let store = WebBrowserStore.shared
        guard let tab = resolveTab(args?.tab_id, in: store) else { return errorJSON("No active tab") }
        // SPAs render their DOM after load — wait for real content before extracting.
        await waitForRenderedContent(tab)
        let format = (args?.format ?? "markdown").lowercased()
        let url = tab.currentURL?.absoluteString ?? ""

        switch format {
        case "html":
            do {
                let html = try await tab.capturePageHTML()
                return jsonString([
                    "tab_id": tab.id.uuidString, "url": url, "title": tab.title,
                    "html": html, "length": html.count,
                ])
            } catch {
                return errorJSON("Failed to read HTML: \(error.localizedDescription)")
            }
        case "text":
            do {
                let data = try await tab.evaluateJavaScript("document.body ? document.body.innerText : ''")
                let text = data.flatMap { try? JSONDecoder().decode(String.self, from: $0) } ?? ""
                return jsonString([
                    "tab_id": tab.id.uuidString, "url": url, "title": tab.title,
                    "text": text, "length": text.count,
                ])
            } catch {
                return errorJSON("Failed to read text: \(error.localizedDescription)")
            }
        default: // markdown
            do {
                let html = try await tab.capturePageHTML()
                guard !html.isEmpty else { return errorJSON("Page has no readable content") }
                let result = try await WebClipperService.shared.clip(html: html, url: url)
                return jsonString([
                    "tab_id": tab.id.uuidString, "url": url, "title": result.title,
                    "excerpt": result.excerpt, "markdown": result.markdown, "length": result.markdown.count,
                ])
            } catch {
                return errorJSON("Failed to read page: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private static func browserCurrent(_ call: ToolCall) async -> String {
        let store = WebBrowserStore.shared
        guard let tab = store.selectedTab else { return errorJSON("No active tab") }
        return jsonString([
            "tab_id": tab.id.uuidString,
            "url": tab.currentURL?.absoluteString ?? "",
            "title": tab.title,
            "loading": tab.isLoading,
            "can_go_back": tab.canGoBack,
            "can_go_forward": tab.canGoForward,
            "engine": tab.engineType.rawValue,
        ])
    }

    @MainActor
    private static func browserClip(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: TabIDArgs.self)
        let store = WebBrowserStore.shared
        if let id = agentUUID(args?.tab_id) { store.selectedTabID = id }
        guard store.selectedTab != nil else { return errorJSON("No active tab to clip") }
        await store.clipCurrentPage()
        return jsonString(["status": store.lastClipStatus ?? "done"])
    }

    @MainActor
    private static func browserEval(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: EvalArgs.self)
        guard let script = args?.script, !script.isEmpty else { return errorJSON("'script' is required") }
        let store = WebBrowserStore.shared
        guard let tab = resolveTab(args?.tab_id, in: store) else { return errorJSON("No active tab") }
        do {
            let data = try await tab.evaluateJavaScript(script)
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return jsonString(["tab_id": tab.id.uuidString, "result": text])
        } catch {
            return errorJSON("JavaScript error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func browserScreenshot(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: TabIDArgs.self)
        let store = WebBrowserStore.shared
        guard let tab = resolveTab(args?.tab_id, in: store) else { return errorJSON("No active tab") }
        guard tab.engineType == .webKit, let engine = tab.webKitEngine else {
            return errorJSON("Screenshots are only supported for WebKit tabs")
        }
        do {
            guard let png = try await engine.takeSnapshot() else {
                return errorJSON("Snapshot returned no image data")
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftmaestro-browser-\(tab.id.uuidString).png")
            try png.write(to: url, options: .atomic)
            return jsonString([
                "tab_id": tab.id.uuidString,
                "path": url.path,
                "note": "Use ocr_image or attach this file to view the screenshot",
            ])
        } catch {
            return errorJSON("Screenshot failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func browserLinks(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: LinksArgs.self)
        let store = WebBrowserStore.shared
        guard let tab = resolveTab(args?.tab_id, in: store) else { return errorJSON("No active tab") }
        // SPAs render their links after load — wait for real content before extracting.
        await waitForRenderedContent(tab)
        let limit = min(max(args?.limit?.value ?? 50, 1), 200)
        let sameDomainOnly = args?.same_domain?.value ?? false

        // Pull every anchor's resolved href + visible text, tagging same-domain ones.
        let script = #"""
        (function() {
            var out = [];
            var host = location.host;
            var anchors = document.querySelectorAll('a[href]');
            for (var i = 0; i < anchors.length; i++) {
                var href = anchors[i].href;
                if (!href || href.indexOf('javascript:') === 0) continue;
                var text = (anchors[i].innerText || anchors[i].textContent || '').trim().replace(/\s+/g, ' ');
                var same = false;
                try { same = (new URL(href, location.href)).host === host; } catch (e) {}
                out.push({ href: href, text: text, same_domain: same });
            }
            return out;
        })()
        """#

        guard let data = try? await tab.evaluateJavaScript(script),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return errorJSON("Could not extract links from the page") }

        var links = raw
        if sameDomainOnly { links = links.filter { ($0["same_domain"] as? Bool) == true } }
        let total = links.count
        links = Array(links.prefix(limit))

        let cleaned: [[String: Any]] = links.map { [
            "href": $0["href"] ?? "",
            "text": $0["text"] ?? "",
        ] }

        return jsonString([
            "url": tab.currentURL?.absoluteString ?? "",
            "count": cleaned.count,
            "total_matched": total,
            "links": cleaned,
            "note": "These are the page's real links. Open one of these hrefs with browser_open instead of guessing a URL.",
        ])
    }
}
