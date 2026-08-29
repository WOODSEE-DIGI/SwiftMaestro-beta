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
            ToolDefinition(
                name: "clip_template_list", spec: browserToolSpecs[11],
                category: ToolCategory.browser.rawValue,
                handler: { _ in await clipTemplateList() }),
            ToolDefinition(
                name: "bookmark_add", spec: browserToolSpecs[12],
                category: ToolCategory.browser.rawValue,
                handler: { call in await bookmarkAdd(call) }),
            ToolDefinition(
                name: "bookmark_list", spec: browserToolSpecs[13],
                category: ToolCategory.browser.rawValue,
                handler: { call in await bookmarkList(call) }),
            ToolDefinition(
                name: "bookmark_open", spec: browserToolSpecs[14],
                category: ToolCategory.browser.rawValue,
                handler: { call in await bookmarkOpen(call) }),
            ToolDefinition(
                name: "bookmark_remove", spec: browserToolSpecs[15],
                category: ToolCategory.browser.rawValue,
                handler: { call in await bookmarkRemove(call) }),
            ToolDefinition(
                name: "bookmarks_export", spec: browserToolSpecs[16],
                category: ToolCategory.browser.rawValue,
                handler: { call in await bookmarksExport(call) }),
            ToolDefinition(
                name: "bookmarks_import", spec: browserToolSpecs[17],
                category: ToolCategory.browser.rawValue,
                handler: { call in await bookmarksImport(call) }),
            ToolDefinition(
                name: "browser_privacy_list", spec: browserToolSpecs[18],
                category: ToolCategory.browser.rawValue,
                handler: { _ in await browserPrivacyList() }),
            ToolDefinition(
                name: "browser_clear_site_data", spec: browserToolSpecs[19],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserClearSiteData(call) }),
            ToolDefinition(
                name: "browser_dismiss_overlays", spec: browserToolSpecs[20],
                category: ToolCategory.browser.rawValue,
                handler: { call in await browserDismissOverlays(call) }),
        ])
    }

    static var browserToolSpecs: [ToolSpec] {
        [
            rawSpec("browser_open",
                "Open a URL in the internal browser. This opens a NEW tab AND navigates to the URL "
                + "in one step — you do NOT need a separate navigate call afterwards. If that URL is "
                + "already open, the existing tab is focused and returned (no duplicate is created). "
                + "IMPORTANT: only open URLs from a real source — the user's request, or links returned "
                + "by browser_links / browser_read / web_search. NEVER invent or guess a URL; invented "
                + "URLs almost always 404. Returns the tab_id and warns if the page is a dead link. "
                + "Pass background=true to open without switching focus.",
                properties: [
                    "url": ["type": "string", "description": "URL to open and navigate to (https:// added if missing)"],
                    "background": ["type": "boolean", "description": "Open without focusing the tab (default false)"],
                    "private_tab": ["type": "boolean", "description": "Open in a private tab — non-persistent data store, cookies/cache/storage vanish on tab close (default false)"],
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
                "Navigate within an already-open tab: go back, go forward, reload the page, or stop "
                + "loading. Does NOT accept a URL — to open a new URL, use browser_open instead. "
                + "Defaults to the active tab.",
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
                "Clip a tab's page with the Web Clipper (Defuddle extraction + full page metadata: "
                + "author, published, domain, favicon, image, word count, meta tags, schema.org). "
                + "Saves a Markdown note with YAML frontmatter to the Notes vault AND/OR a typed row "
                + "to the MaestroDB 'Web Clips' base (query it later with db_list_rows). Templates "
                + "auto-match by URL (e.g. YouTube); override with 'template'. List templates with "
                + "clip_template_list. Defaults to the active tab.",
                properties: [
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                    "template": ["type": "string", "description": "Template NAME (default: auto-match by URL, fallback 'Default')"],
                    "destination": ["type": "string", "description": "'both' (default), 'notes', or 'maestrodb'"],
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
            rawSpec("clip_template_list",
                "List the Web Clipper templates (name, URL auto-match patterns, Notes folder, property "
                + "names). Templates control how clipped pages are formatted and where they're saved.",
                properties: [:],
                required: []),
            rawSpec("bookmark_add",
                "Bookmark a page in SwiftBrowser. Defaults to the active tab's URL. 'favorite: true' "
                + "pins it to the Favourites bar under the address field.",
                properties: [
                    "url": ["type": "string", "description": "URL to bookmark (default: active tab)"],
                    "title": ["type": "string", "description": "Bookmark name (default: page title)"],
                    "folder": ["type": "string", "description": "Folder name, e.g. 'Research' (default: root)"],
                    "favorite": ["type": "boolean", "description": "Pin to the Favourites bar (default false)"],
                ],
                required: []),
            rawSpec("bookmark_list",
                "List SwiftBrowser bookmarks, optionally filtered by folder or favorites-only.",
                properties: [
                    "folder": ["type": "string", "description": "Only bookmarks in this folder"],
                    "favorites": ["type": "boolean", "description": "Only Favourites-bar bookmarks"],
                ],
                required: []),
            rawSpec("bookmark_open",
                "Open a bookmarked URL in the browser (by bookmark title or URL substring match).",
                properties: [
                    "query": ["type": "string", "description": "Bookmark title or URL substring to match"],
                    "new_tab": ["type": "boolean", "description": "Open in a new tab (default false)"],
                ],
                required: ["query"]),
            rawSpec("bookmark_remove",
                "Remove a bookmark by title or URL substring match.",
                properties: [
                    "query": ["type": "string", "description": "Bookmark title or URL substring to match"],
                ],
                required: ["query"]),
            rawSpec("bookmarks_export",
                "Export all SwiftBrowser bookmarks as a NETSCAPE-format HTML file (readable by Safari, "
                + "Chrome, Firefox). Saves to the given path or ~/Desktop by default.",
                properties: [
                    "path": ["type": "string", "description": "Absolute output path (default: ~/Desktop/SwiftMaestro Bookmarks.html)"],
                ],
                required: []),
            rawSpec("bookmarks_import",
                "Import bookmarks from a NETSCAPE-format HTML file (the format Safari/Chrome/Firefox "
                + "export). Favorites/Bookmarks-bar folders become SwiftBrowser Favourites.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the bookmarks HTML file"],
                ],
                required: ["path"]),
            rawSpec("browser_privacy_list",
                "List what the browser has stored: per-site data (cookies, cache, local storage, "
                + "IndexedDB, service workers) and cookie counts. WebKit shared store only — Chromium "
                + "tabs are session-scoped and persist nothing between launches.",
                properties: [:],
                required: []),
            rawSpec("browser_clear_site_data",
                "Delete stored site data. With 'domain', clears one site's cookies/cache/storage; "
                + "without it, clears ALL site data (signs out of websites in SwiftBrowser).",
                properties: [
                    "domain": ["type": "string", "description": "Site domain to clear, e.g. 'example.com' (omit to clear everything)"],
                ],
                required: []),
            rawSpec("browser_dismiss_overlays",
                "Dismiss popup layers blocking a page: newsletter modals, spin-to-win wheels, cookie "
                + "walls, signup overlays, and their dimmed backdrops. Position-independent — finds "
                + "dialog-like containers anywhere in the DOM, clicks their close control (so the "
                + "site cleans up its own state), removes layers that survive, and restores page "
                + "scrolling. Call this when browser_read/browser_links results look like overlay "
                + "content instead of the page, or a screenshot shows a modal. Safe to call "
                + "repeatedly — new layers can spawn after each dismissal; returns counts.",
                properties: [
                    "tab_id": ["type": "string", "description": "Target tab_id (default: active tab)"],
                ],
                required: []),
        ]
    }

    private struct OpenArgs: Decodable {
        let url: String?
        let background: LenientBool?
        /// Open in a private tab (non-persistent data store — nothing survives close).
        let private_tab: LenientBool?
    }
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

    /// JavaScript that detects CAPTCHA / bot-detection pages. Google, Bing,
    /// Cloudflare, and many other sites serve these when they detect automated
    /// browsers. Returns `{ blocked: Bool }` by scanning the page text for
    /// common CAPTCHA markers.
    private static let captchaDetectScript = #"""
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
        var text = ((document.title || '') + ' ' + parts.join(' ')).toLowerCase();
        var markers = [
            "are you a robot", "i'm not a robot", "not a robot",
            "unusual traffic", "automated traffic", "unusual requests",
            "verify you are human", "please verify", "confirm you",
            "captcha", "recaptcha", "hcaptcha", "turnstile",
            "blocked", "access denied", "forbidden",
            "detected unusual", "suspicious activity",
            "checking your browser", "just a moment"
        ];
        for (var i = 0; i < markers.length; i++) {
            if (text.indexOf(markers[i]) !== -1) { return { blocked: true }; }
        }
        return { blocked: false };
    })()
    """#

    /// Whether the tab is showing a CAPTCHA / bot-detection wall. Checks a few
    /// times over a short window because CAPTCHA pages may render their block
    /// message via JS after the initial load event (same pattern as soft-404).
    @MainActor
    private static func tabIsCaptchaBlocked(_ tab: BrowserTab) async -> Bool {
        guard tab.engineType == .webKit else { return false }
        let deadline = Date().addingTimeInterval(3)
        var settledReads = 0
        while Date() < deadline {
            if let data = try? await tab.evaluateJavaScript(captchaDetectScript),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (obj["blocked"] as? Bool) == true { return true }
                // If we got real content (>500 chars) with no CAPTCHA marker, it's clean.
                if let length = obj["textLength"] as? Int, length > 500 {
                    settledReads += 1
                    if settledReads >= 2 { return false }
                } else {
                    // Page might still be loading the CAPTCHA — keep polling.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
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

    /// Click away cookie/consent banners before extracting content. The banners
    /// overlay prices and inject "Manage cookies / Decline all / OK" noise into
    /// the markdown — a user reported the agent re-reading pages while hunting
    /// for data obscured by The Front's consent bar. Tries explicit accept
    /// labels first, common framework selectors (OneTrust, Cookiebot) second,
    /// and falls back to decline/reject (which also dismisses the banner).
    /// No-op for non-WebKit tabs and for pages with no banner.
    @MainActor
    private static func dismissConsentBanners(_ tab: BrowserTab) async {
        guard tab.engineType == .webKit else { return }
        let js = """
        (() => {
            const labels = [
                'accept all', 'accept', 'allow all', 'agree', 'i agree', 'got it', 'ok', 'okay',
                'decline all', 'decline', 'reject all', 'reject'
            ];
            const els = [...document.querySelectorAll(
                'button, a, [role="button"], input[type="button"], input[type="submit"]')];
            for (const label of labels) {
                const el = els.find(e => {
                    const txt = (e.innerText || e.value || e.getAttribute('aria-label') || '')
                        .trim().toLowerCase();
                    return txt === label || txt.startsWith(label + ' ');
                });
                if (el && el.offsetParent !== null) { el.click(); return 'clicked:' + label; }
            }
            const known = document.querySelector(
                '#onetrust-accept-btn-handler, .cc-accept, .cc-allow, .cc-dismiss, ' +
                '.cookie-accept, .js-accept-cookies, #CybotCookiebotDialogBodyButtonDecline');
            if (known) { known.click(); return 'clicked:framework'; }
            return 'none';
        })()
        """
        _ = try? await tab.evaluateJavaScript(js)
        // Let any post-dismiss reflow settle before extraction.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Handlers

    /// Count currency-amount signals in extracted page text ("$250", "$95/day",
    /// "AUD 90"). Feeds the playbook's EXTRACTION TEST mechanically: a read with
    /// price_signals = 0 is a FAILED extraction for price research — the model no
    /// longer has to judge that itself.
    static func priceSignalCount(in text: String) -> Int {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)(\$\s?\d[\d,.]*|\bAUD\s?\d[\d,.]*)"#) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    /// Raw `document.body.innerText` extraction used when the clipper times out
    /// or wedges. Runs through the tab's own timeout-protected evaluateJavaScript
    /// (15s hard cap), so this fallback can never re-introduce the hang it
    /// rescues.
    @MainActor
    private static func plainTextFallback(_ tab: BrowserTab) async -> String? {
        guard let data = try? await tab.evaluateJavaScript(
            "document.body ? document.body.innerText : ''"),
              let text = try? JSONDecoder().decode(String.self, from: data) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private static func browserOpen(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenArgs.self)
        guard let rawURL = args?.url,
              !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorJSON("'url' is required")
        }
        // Small models compound escape layers across rounds until the URL is
        // `%22https///` garbage — clean to a fixpoint before navigating.
        let urlString = ToolArgumentRepair.sanitizeAgentURL(rawURL)
        guard !urlString.isEmpty else {
            return errorJSON("'url' was empty after cleaning escape junk from '\(rawURL)'. "
                + "Send the bare URL only: https://host/path — no quotes, no backslashes.")
        }
        let background = args?.background?.value ?? false
        let privateTab = args?.private_tab?.value ?? false
        let store = WebBrowserStore.shared
        // Snapshot existing tab ids so we can tell whether we reused one below.
        let tabIDsBefore = Set(store.tabs.map { $0.id })
        guard let tab = store.openURLInNewTab(urlString, background: background, reuseExisting: !privateTab,
                                              isPrivate: privateTab) else {
            return errorJSON("Invalid URL: \(urlString)")
        }
        // The tool is named browser_OPEN and the prompt tells the model the
        // user watches pages open live — but the tab used to be created only
        // in the store (invisible headless), so the user saw "browser_open"
        // in the tool log with no browser panel anywhere. Surface the
        // SwiftBrowser panel unless the caller explicitly asked for
        // background work.
        if !background {
            let layout = WorkspaceLayoutState.shared
            if !layout.allOpenPanels.contains(.webBrowser) {
                let openResult = layout.open(.webBrowser, zone: .right)
                if openResult == .floated {
                    // Same force-dock contract as open_panel: the agent can't
                    // call openWindow itself, and a floated-but-unpresented
                    // window is as invisible as no panel at all.
                    layout.dock(.webBrowser)
                }
            }
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
        if privateTab { result["private"] = true }
        if urlString != rawURL { result["sanitized_url"] = true }
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
        // CAPTCHA / bot-detection detection. Google, Bing, and many sites serve
        // "I'm not a robot" or "unusual traffic" pages when they detect automated
        // browsers. The model must know it's blocked so it doesn't treat the
        // CAPTCHA page as real content or hallucinate results.
        let captchaBlocked = await tabIsCaptchaBlocked(tab)
        if captchaBlocked {
            result["captcha_blocked"] = true
            result["warning"] = "This page is a CAPTCHA / bot-detection wall. "
                + "The site has blocked automated access. Do NOT try to solve it or treat the page as content. "
                + "Instead: use web_search (which uses a different backend) or try a different site."
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
        let tab: BrowserTab?
        if let requested = args?.tab_id?.trimmingCharacters(in: .whitespaces), !requested.isEmpty {
            // STRICT: an explicitly-given tab_id must exist. The model has
            // hallucinated ids — and once FABRICATED an entire tab — in
            // production; silently reading the active tab instead hides the
            // fabrication and lets the model trust its invented state.
            guard let id = agentUUID(requested),
                  let matched = store.tabs.first(where: { $0.id == id }) else {
                let open = store.tabs.map {
                    "\($0.id.uuidString) → \($0.currentURL?.absoluteString ?? "(no url)")"
                }
                return errorJSON(
                    "no tab with id '\(requested)'. Open tabs: "
                    + (open.isEmpty ? "(none)" : open.joined(separator: "; "))
                    + ". Use browser_list for current tab ids — NEVER invent a tab_id; "
                    + "use the tab_id returned by browser_open.")
            }
            tab = matched
        } else {
            tab = store.selectedTab
        }
        guard let tab else { return errorJSON("No active tab") }
        // SPAs render their DOM after load — wait for real content before extracting.
        await waitForRenderedContent(tab)
        // Clear cookie/consent banners so they don't overlay content or pollute
        // the extracted markdown with banner noise.
        await dismissConsentBanners(tab)
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
                var result: WebClipResult
                var extractionMode = "clipper"
                do {
                    result = try await WebClipperService.shared.clip(html: html, url: url)
                } catch {
                    // Clipper timed out or its webview wedged (the 14-minute
                    // Shopify stall). Degrade gracefully: raw innerText via the
                    // tab's own timeout-protected evaluateJavaScript, so the
                    // agent still gets page content instead of an empty error.
                    NSLog("[browser_read] clipper failed (\(error.localizedDescription)); falling back to innerText")
                    guard let text = await Self.plainTextFallback(tab), !text.isEmpty else {
                        return errorJSON("Failed to read page: clipper failed (\(error.localizedDescription)) "
                            + "and the plain-text fallback found no content. Try browser_eval, or "
                            + "browser_navigate reload and retry once.")
                    }
                    result = WebClipResult(
                        title: tab.title, url: url, excerpt: String(text.prefix(300)),
                        author: "", published: "", site: "", markdown: text, html: "")
                    extractionMode = "plain_text_fallback"
                }
                var payload: [String: Any] = [
                    "tab_id": tab.id.uuidString, "url": url, "title": result.title,
                    "excerpt": result.excerpt, "markdown": result.markdown, "length": result.markdown.count,
                    "extraction_mode": extractionMode,
                ]
                // Mechanical extraction test: the playbook's "no $ = failed
                // extraction" rule as a deterministic signal the model can act on
                // without judgment. Only nags on the negative — price-bearing
                // pages just report the count.
                let signals = priceSignalCount(in: result.markdown)
                payload["price_signals"] = signals
                if signals == 0 {
                    payload["extraction_note"] = "no currency amounts detected on this page — "
                        + "if you are collecting prices/rates, this read is a FAILED extraction: "
                        + "use browser_links to drill to a PRODUCT page or move on; do NOT record "
                        + "rows from this page. If you already have data from earlier pages, save "
                        + "it with db_add_rows now."
                }
                return jsonString(payload)
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
    private struct ClipArgs: Codable {
        let tab_id: String?
        let template: String?      // template NAME; omit for URL auto-match
        let destination: String?   // "notes", "maestrodb", or "both" (default)
    }

    @MainActor
    private static func browserClip(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ClipArgs.self)
        let store = WebBrowserStore.shared
        if let id = agentUUID(args?.tab_id) { store.selectedTabID = id }
        guard store.selectedTab != nil else { return errorJSON("No active tab to clip") }

        var template: ClipTemplate?
        if let name = args?.template, !name.isEmpty {
            template = ClipTemplateStore.shared.templates.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            })
            if template == nil {
                let available = ClipTemplateStore.shared.templates.map(\.name).joined(separator: ", ")
                return errorJSON("Unknown template '\(name)'. Available: \(available)")
            }
        }

        var destinations: WebBrowserStore.ClipDestinations? = nil
        switch args?.destination?.lowercased() {
        case "notes": destinations = .notes
        case "maestrodb", "maestro", "db": destinations = .maestroDB
        case "both": destinations = .both
        case nil, "": break  // template's own destination settings decide
        default:
            return errorJSON("unknown destination — use 'notes', 'maestrodb', or 'both'")
        }

        let outcome = await store.clipCurrentPage(template: template, destinations: destinations)
        guard let outcome else {
            return errorJSON(store.lastClipStatus ?? "clip failed")
        }
        return jsonString([
            "status": "clipped",
            "title": outcome.title,
            "template": outcome.templateName,
            "note_path": outcome.notePath as Any,
            "maestrodb_row": outcome.maestroRowID as Any,
        ])
    }

    @MainActor
    private static func clipTemplateList() async -> String {
        let templates = ClipTemplateStore.shared.templates
        return jsonString([
            "templates": templates.map { t in
                [
                    "name": t.name,
                    "url_patterns": t.urlPatterns.joined(separator: ", "),
                    "folder": t.folder,
                    "properties": t.properties.map(\.name).joined(separator: ", "),
                ]
            },
            "count": templates.count,
        ])
    }

    // MARK: - Bookmarks

    private struct BookmarkAddArgs: Decodable {
        let url: String?; let title: String?; let folder: String?; let favorite: LenientBool?
    }
    private struct BookmarkListArgs: Decodable { let folder: String?; let favorites: LenientBool? }
    private struct BookmarkQueryArgs: Decodable { let query: String?; let new_tab: LenientBool? }
    private struct BookmarkPathArgs: Decodable { let path: String? }
    private struct ClearSiteDataArgs: Decodable { let domain: String? }

    // MARK: - Privacy tools

    @MainActor
    private static func browserPrivacyList() async -> String {
        let privacy = BrowserPrivacyStore.shared
        await privacy.refresh()
        return jsonString([
            "site_count": privacy.siteRecords.count,
            "cookie_count": privacy.cookies.count,
            "sites": privacy.siteRecords.map { record in
                [
                    "domain": record.domain,
                    "cookies": record.cookieCount,
                    "data_types": record.dataTypeSummary,
                ] as [String: Any]
            },
            "note": "WebKit shared store only. Chromium tabs persist nothing (temp profile per launch). "
                + "Private tabs (browser_open private_tab:true) persist nothing after close.",
        ])
    }

    @MainActor
    private static func browserClearSiteData(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ClearSiteDataArgs.self)
        let privacy = BrowserPrivacyStore.shared
        if let domain = args?.domain, !domain.isEmpty {
            await privacy.deleteSiteData(forDomain: domain)
            return jsonString(["status": "cleared", "domain": domain])
        }
        await privacy.clearAllSiteData()
        return jsonString(["status": "cleared_all",
                           "note": "All cookies, cache, and site storage deleted."])
    }

    @MainActor
    private static func browserDismissOverlays(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: TabIDArgs.self)
        let store = WebBrowserStore.shared
        guard let tab = resolveTab(args?.tab_id, in: store) else {
            return errorJSON("No active tab")
        }
        guard let result = await OverlayDismissService.shared.dismiss(on: tab) else {
            return errorJSON("Could not evaluate the overlay dismisser on this tab")
        }
        return jsonString([
            "status": result.didSomething ? "dismissed" : "none_found",
            "close_clicked": result.clicked,
            "layers_removed": result.removed,
            "scroll_restored": result.scrollRestored,
            "note": result.didSomething
                ? "Overlays cleared. If the page spawns another layer, call again; then browser_read to verify the real content is reachable."
                : "No overlay layers found — the page content should be directly readable.",
        ])
    }

    @MainActor
    private static func bookmarkAdd(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: BookmarkAddArgs.self)
        let store = WebBrowserStore.shared
        let bookmarks = BookmarkStore.shared
        var url = args?.url ?? store.selectedTab?.currentURL?.absoluteString
        var title = args?.title ?? ""
        if url == nil, let query = args?.title, !query.isEmpty,
           query.lowercased().hasPrefix("http") {
            // Model passed the URL in 'title' — recover gracefully
            url = query
            title = ""
        }
        guard let url, URL(string: url)?.scheme?.hasPrefix("http") == true else {
            return errorJSON("No URL to bookmark — open a tab first or pass 'url'")
        }
        if title.isEmpty { title = store.selectedTab?.title ?? url }
        let bookmark = bookmarks.add(
            title: title, url: url,
            folder: args?.folder ?? "", isFavorite: args?.favorite?.value ?? false)
        return jsonString([
            "status": "bookmarked", "title": bookmark.title, "url": bookmark.url,
            "folder": bookmark.folder, "favorite": bookmark.isFavorite,
        ])
    }

    @MainActor
    private static func bookmarkList(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: BookmarkListArgs.self)
        var bookmarks = BookmarkStore.shared.bookmarks
        if let folder = args?.folder, !folder.isEmpty {
            bookmarks = bookmarks.filter { $0.folder.localizedCaseInsensitiveContains(folder) }
        }
        if args?.favorites?.value == true {
            bookmarks = bookmarks.filter(\.isFavorite)
        }
        return jsonString([
            "count": bookmarks.count,
            "bookmarks": bookmarks.map { b in
                [
                    "title": b.title, "url": b.url, "folder": b.folder,
                    "favorite": b.isFavorite, "host": b.host,
                ] as [String: Any]
            },
        ])
    }

    @MainActor
    private static func bookmarkOpen(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: BookmarkQueryArgs.self)
        guard let query = args?.query?.lowercased(), !query.isEmpty else {
            return errorJSON("'query' is required (bookmark title or URL substring)")
        }
        let store = WebBrowserStore.shared
        guard let bookmark = BookmarkStore.shared.bookmarks.first(where: {
            $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query)
        }) else {
            return errorJSON("No bookmark matching '\(query)'")
        }
        if args?.new_tab?.value == true {
            let tab = store.addTab()
            await store.loadURL(bookmark.url, in: tab)
        } else {
            await store.loadURL(bookmark.url, in: store.selectedTab)
        }
        return jsonString(["status": "opened", "title": bookmark.title, "url": bookmark.url])
    }

    @MainActor
    private static func bookmarkRemove(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: BookmarkQueryArgs.self)
        guard let query = args?.query?.lowercased(), !query.isEmpty else {
            return errorJSON("'query' is required (bookmark title or URL substring)")
        }
        let bookmarks = BookmarkStore.shared
        guard let bookmark = bookmarks.bookmarks.first(where: {
            $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query)
        }) else {
            return errorJSON("No bookmark matching '\(query)'")
        }
        bookmarks.remove(bookmark)
        return jsonString(["status": "removed", "title": bookmark.title, "url": bookmark.url])
    }

    private static func bookmarksExport(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: BookmarkPathArgs.self)
        let path = args?.path
            ?? NSHomeDirectory() + "/Desktop/SwiftMaestro Bookmarks.html"
        let bookmarks = await MainActor.run { BookmarkStore.shared }
        let count = await MainActor.run { bookmarks.bookmarks.count }
        guard count > 0 else { return errorJSON("No bookmarks to export") }
        let html = await MainActor.run { bookmarks.exportHTML() }
        do {
            try html.write(toFile: path, atomically: true, encoding: .utf8)
            return jsonString(["status": "exported", "path": path, "count": count])
        } catch {
            return errorJSON("Export failed: \(error.localizedDescription)")
        }
    }

    private static func bookmarksImport(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: BookmarkPathArgs.self)
        guard let path = args?.path, !path.isEmpty else {
            return errorJSON("'path' is required — the bookmarks HTML file to import")
        }
        guard let html = try? String(contentsOfFile: path, encoding: .utf8) else {
            return errorJSON("Could not read file at \(path)")
        }
        let result = await MainActor.run { BookmarkStore.shared.importHTML(html) }
        return jsonString([
            "status": "imported", "added": result.added,
            "skipped_duplicates": result.skippedDuplicates,
            "folders": result.folders,
        ])
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
