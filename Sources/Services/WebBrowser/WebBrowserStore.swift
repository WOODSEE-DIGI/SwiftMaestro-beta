import Foundation

/// Central store for the internal browser. Holds tabs and the active tab.
@Observable
@MainActor
final class WebBrowserStore {
    static let shared = WebBrowserStore()

    var tabs: [BrowserTab] = []
    var selectedTabID: UUID?
    var lastClipStatus: String?

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The local start page shown in every new tab.
    static var startPageURL: URL {
        Bundle.main.url(forResource: "browser-start", withExtension: "html")
            ?? URL(string: "about:blank")!
    }

    init() {
        addTab(url: Self.startPageURL)
    }

    /// Add a tab and (by default) select it. `activate == false` opens it in the
    /// background (used for Cmd/middle-click "open in new tab"). Returns the tab.
    @discardableResult
    func addTab(engineType: BrowserEngineType = .webKit, url: URL? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(engineType: engineType)
        wireNewTabHandler(into: tab)
        tabs.append(tab)
        if activate { selectedTabID = tab.id }
        let initialURL = url ?? Self.startPageURL
        Task { await tab.loadURL(initialURL) }
        return tab
    }

    /// Strip model-emitted URL artifacts: the Gemma `<|"|>` escape token, escaped
    /// slashes/quotes, backslashes, and wrapping/trailing quotes/braces/brackets/commas
    /// that small models leak onto a URL (which otherwise get percent-encoded into the
    /// path and become dead links). URLs never legitimately begin or end with these.
    /// Pure string work — `nonisolated` so the deep-web tools can reuse it too.
    nonisolated static func cleanURLLike(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "<|\"|>", with: "")
        s = s.replacingOccurrences(of: "\\\"", with: "\"")
        // Browsers treat a backslash as a forward slash. The model sometimes emits
        // literal/escaped backslashes ("https:\\\//host") that otherwise stay
        // malformed and render "The URL can't be shown" — normalise them to slashes.
        s = s.replacingOccurrences(of: "\\", with: "/")
        // Collapse accidental multi-slash runs introduced by escaped slashes
        // (e.g. "https:////host" -> "https://host"), preserving the scheme's "://".
        if let schemeRange = s.range(of: "://") {
            let scheme = String(s[..<schemeRange.upperBound])
            let rest = String(s[schemeRange.upperBound...])
            let collapsed = rest.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
            s = scheme + collapsed
        }
        while let first = s.first, ["\"", "'", "{", "[", ","].contains(first) {
            s.removeFirst()
        }
        while let last = s.last, ["\"", "'", "}", "]", ","].contains(last) {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize a URL string (add https:// if missing) and open it in a new tab.
    /// `background == true` opens it without switching the selection. When
    /// `reuseExisting == true`, a tab already showing the same URL is focused and
    /// returned instead of opening a duplicate (used by the agent's browser_open).
    /// Returns the new/existing tab, or nil if the URL is invalid.
    @discardableResult
    func openURLInNewTab(_ string: String, background: Bool = false, reuseExisting: Bool = false) -> BrowserTab? {
        let trimmed = Self.cleanURLLike(string)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        let scheme = URL(string: normalized)?.scheme?.lowercased() ?? ""
        if scheme.isEmpty { normalized = "https://\(normalized)" }
        guard let url = URL(string: normalized),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if reuseExisting, let existing = tab(matching: url) {
            if !background { selectedTabID = existing.id }
            return existing
        }
        return addTab(url: url, activate: !background)
    }

    /// A tab already showing `url`, matched leniently on both the requested and the
    /// committed URL so a still-loading tab is caught too.
    func tab(matching url: URL) -> BrowserTab? {
        tabs.first { Self.urlsEquivalent($0.requestedURL, url) || Self.urlsEquivalent($0.currentURL, url) }
    }

    /// Lenient URL equality: scheme/host case-insensitive, fragment and trailing
    /// slashes ignored — enough to catch genuine duplicates without merging distinct pages.
    static func urlsEquivalent(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return canonicalForComparison(a) == canonicalForComparison(b)
    }

    private static func canonicalForComparison(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            var fallback = url.absoluteString
            while fallback.hasSuffix("/") { fallback.removeLast() }
            return fallback
        }
        // Read into locals before mutating to satisfy value-type exclusivity.
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()
        components.fragment = nil
        components.scheme = scheme
        components.host = host
        var string = components.string ?? url.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        return string
    }

    /// Lets a tab ask the store to open a link in a new tab (target=_blank or
    /// Cmd/middle-click). `background == true` keeps the current tab selected.
    private func wireNewTabHandler(into tab: BrowserTab) {
        tab.webKitEngine?.onRequestNewTab = { [weak self] url, background in
            self?.addTab(engineType: .webKit, url: url, activate: !background)
        }
    }

    /// Open a second tab showing the same page as the given tab.
    func duplicateTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let source = tabs[index]
        let tab = BrowserTab(engineType: source.engineType)
        wireNewTabHandler(into: tab)
        tabs.insert(tab, at: index + 1)
        selectedTabID = tab.id
        Task { await tab.loadURL(source.currentURL ?? Self.startPageURL) }
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = (selectedTabID == id)
        tabs.remove(at: index)
        if tabs.isEmpty {
            addTab()
            return
        }
        // Select the neighbouring tab rather than always jumping to the first.
        if wasSelected {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeOtherTabs(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id != id }
        selectedTabID = id
    }

    func closeTabsToTheRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs = Array(tabs.prefix(index + 1))
        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = id
        }
    }

    /// Reorder a tab left (`offset == -1`) or right (`offset == 1`).
    func moveTab(id: UUID, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + offset
        guard tabs.indices.contains(newIndex) else { return }
        tabs.swapAt(index, newIndex)
    }

    func loadURL(_ string: String, in tab: BrowserTab?) async {
        guard let tab else { return }
        let trimmed = Self.cleanURLLike(string)
        guard !trimmed.isEmpty else {
            tab.error = "Enter a URL"
            return
        }
        var normalized = trimmed
        let schemeLower = URL(string: normalized)?.scheme?.lowercased() ?? ""
        if schemeLower.isEmpty {
            normalized = "https://\(normalized)"
        } else if schemeLower != "http" && schemeLower != "https" {
            tab.error = "Only http and https URLs are supported"
            return
        }
        guard let url = URL(string: normalized) else {
            tab.error = "Invalid URL"
            return
        }
        tab.error = nil
        await tab.loadURL(url)
    }

    func clipCurrentPage() async {
        guard let tab = selectedTab else {
            lastClipStatus = "No active tab"
            return
        }
        guard let url = tab.currentURL?.absoluteString else {
            lastClipStatus = "No URL to clip"
            return
        }
        do {
            let html = try await tab.capturePageHTML()
            guard !html.isEmpty else {
                lastClipStatus = "Could not capture page content"
                return
            }
            let result = try await WebClipperService.shared.clip(html: html, url: url)
            let vaultURL = NotesViewModel.resolveVaultURL()
            let service = NotesService(vaultURL: vaultURL)
            let clipFolder = vaultURL.appendingPathComponent("Clippings", isDirectory: true)
            let content = Self.noteContent(from: result)
            let noteURL = try await service.createClippedNote(
                title: result.title,
                content: content,
                in: clipFolder
            )
            lastClipStatus = "Clipped to \(noteURL.lastPathComponent)"
        } catch {
            lastClipStatus = "Clip failed: \(error.localizedDescription)"
        }
    }

    private static func noteContent(from result: WebClipResult) -> String {
        var frontmatter = "---\n"
        frontmatter += "title: \"\(escapeYAML(result.title))\"\n"
        frontmatter += "url: \"\(escapeYAML(result.url))\"\n"
        if !result.author.isEmpty {
            frontmatter += "author: \"\(escapeYAML(result.author))\"\n"
        }
        if !result.published.isEmpty {
            frontmatter += "published: \"\(escapeYAML(result.published))\"\n"
        }
        if !result.site.isEmpty {
            frontmatter += "site: \"\(escapeYAML(result.site))\"\n"
        }
        if !result.excerpt.isEmpty {
            frontmatter += "excerpt: \"\(escapeYAML(result.excerpt))\"\n"
        }
        frontmatter += "clipped: \"\(ISO8601DateFormatter().string(from: Date()))\"\n"
        frontmatter += "---\n\n"
        return frontmatter + result.markdown
    }

    private static func escapeYAML(_ string: String) -> String {
        string.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
