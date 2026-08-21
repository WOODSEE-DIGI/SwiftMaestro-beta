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
    ///
    /// `isPrivate` (WebKit only) gives the tab a non-persistent data store —
    /// cookies/cache/site storage vanish on tab close. Defaults to the
    /// "private new tabs" privacy setting.
    @discardableResult
    func addTab(engineType: BrowserEngineType = .webKit, url: URL? = nil, activate: Bool = true,
                isPrivate: Bool? = nil) -> BrowserTab {
        let privateTab = isPrivate ?? (engineType == .webKit ? BrowserPrivacyStore.shared.privateNewTabs : false)
        let tab = BrowserTab(engineType: engineType, isPrivate: privateTab)
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
    func openURLInNewTab(_ string: String, background: Bool = false, reuseExisting: Bool = false,
                         isPrivate: Bool = false) -> BrowserTab? {
        let trimmed = Self.cleanURLLike(string)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        let scheme = URL(string: normalized)?.scheme?.lowercased() ?? ""
        if scheme.isEmpty { normalized = "https://\(normalized)" }
        guard let url = URL(string: normalized),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        // Never reuse a shared-store tab for a private request (or vice versa).
        if reuseExisting, !isPrivate, let existing = tab(matching: url), !existing.isPrivate {
            if !background { selectedTabID = existing.id }
            return existing
        }
        return addTab(url: url, activate: !background, isPrivate: isPrivate)
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

    // MARK: - Web Clipper

    /// Which destinations a clip writes to.
    struct ClipDestinations: OptionSet, Sendable {
        let rawValue: Int
        static let notes = ClipDestinations(rawValue: 1 << 0)
        static let maestroDB = ClipDestinations(rawValue: 1 << 1)
        static let both: ClipDestinations = [.notes, .maestroDB]
    }

    /// Result of a clip operation — what was written where.
    struct ClipOutcome: Sendable {
        let notePath: String?
        let maestroRowID: String?
        let templateName: String
        let title: String
    }

    var isClipping = false

    /// Legacy entry point (toolbar button / agent tool): clip with the
    /// auto-matched template, honoring the template's destination settings.
    func clipCurrentPage() async {
        _ = await clipCurrentPage(template: nil, destinations: nil)
    }

    /// Full clip flow: capture page HTML → Defuddle content extraction →
    /// metadata enrichment → template render → write to chosen destinations.
    /// Pass `destinations: nil` to honor the template's own settings.
    @discardableResult
    func clipCurrentPage(
        template requestedTemplate: ClipTemplate?,
        destinations: ClipDestinations?
    ) async -> ClipOutcome? {
        guard let tab = selectedTab else {
            lastClipStatus = "No active tab"
            return nil
        }
        guard let url = tab.currentURL?.absoluteString else {
            lastClipStatus = "No URL to clip"
            return nil
        }
        isClipping = true
        defer { isClipping = false }
        do {
            let html = try await tab.capturePageHTML()
            guard !html.isEmpty else {
                lastClipStatus = "Could not capture page content"
                return nil
            }
            // Full clip: Defuddle content + metadata (domain, favicon, image,
            // language, wordCount, meta tags, schema.org)
            let result = try await WebClipperService.shared.clipFull(html: html, url: url)
            return await saveClip(result, template: requestedTemplate, destinations: destinations)
        } catch {
            lastClipStatus = "Clip failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Save an already-extracted clip (the popover extracts once for preview,
    /// then saves without re-extracting).
    ///
    /// `destinations` overrides the template's own destination settings when
    /// non-nil — the popover passes its toggles; the legacy/agent path passes
    /// nil to honor whatever the template says.
    @discardableResult
    func saveClip(
        _ result: WebClipResult,
        template requestedTemplate: ClipTemplate?,
        destinations requestedDestinations: ClipDestinations?
    ) async -> ClipOutcome? {
        isClipping = true
        defer { isClipping = false }
        do {
            let url = result.url
            let template = requestedTemplate ?? ClipTemplateStore.shared.template(for: url)
            // Popover overrides win; otherwise the template decides.
            let destinations = requestedDestinations
                ?? ClipDestinations(template: template)
            var notePath: String?
            var maestroRowID: String?

            // MARK: Asset capture (Wayback-style snapshot)
            // Runs before destination writes so the markdown links rewrite to
            // local paths and the snapshot lands beside the note.
            var assetSummary = ""
            var clip = result
            if template.downloadAssets && destinations.contains(.notes) {
                let vaultURL = NotesViewModel.resolveVaultURL()
                let clipFolder = vaultURL.appendingPathComponent(template.folder, isDirectory: true)
                let slug = ClipTemplateEngine.safeFileName(
                    "\(ISO8601DateFormatter().string(from: Date()).prefix(19))-\(result.title)")
                let assetsDir = clipFolder
                    .appendingPathComponent("assets", isDirectory: true)
                    .appendingPathComponent(slug, isDirectory: true)
                let relativePrefix = "assets/\(slug)"

                // 1. Download images FIRST so every artifact can rewrite or
                // inline them.
                let imageURLs = ClipAssetDownloader.imageURLs(
                    contentHTML: result.html, pageURL: result.url, ogImage: result.image)
                var imageMapping: [String: String] = [:]
                if !imageURLs.isEmpty {
                    let download = await ClipAssetDownloader().download(
                        imageURLs, into: assetsDir, relativePrefix: relativePrefix)
                    imageMapping = download.urlToLocalPath
                    if !imageMapping.isEmpty {
                        clip.markdown = clip.markdown.rewritingImageURLs(imageMapping)
                        clip.html = clip.html.rewritingImageURLs(imageMapping)
                        if let local = imageMapping[result.image] { clip.image = local }
                        assetSummary = " +\(download.downloadedCount) images"
                    }
                }

                // 2. Raw page snapshot with images rewritten to local assets —
                // opens offline with pictures intact.
                if !result.fullHtml.isEmpty {
                    let offlineHTML = result.fullHtml.rewritingImageURLs(imageMapping)
                    try? offlineHTML.write(
                        to: assetsDir.appendingPathComponent("snapshot.html"),
                        atomically: true, encoding: .utf8)
                    assetSummary += " +snapshot.html"
                }

                // 3. Reader export — one self-contained HTML file: the cleaned
                // article in a reader template with images base64-inlined.
                let readerHTML = ClipReaderExport.render(
                    clip: clip, imageMapping: imageMapping, assetsDir: assetsDir)
                try? readerHTML.write(
                    to: assetsDir.appendingPathComponent("reader.html"),
                    atomically: true, encoding: .utf8)
                assetSummary += " +reader.html"

                // 3. Viewport screenshot of the live tab (visual snapshot)
                if let engine = selectedTab?.webKitEngine,
                   let png = try? await engine.takeSnapshot() {
                    try? png.write(to: assetsDir.appendingPathComponent("screenshot.png"))
                    assetSummary += " +screenshot"
                }
            }

            // MARK: Forensic metadata (opt-in per template, independent of
            // asset downloads): universal + local timestamps, HTTP transport,
            // TLS cert, RDAP domain record. Never fails the clip. Written even
            // for MaestroDB-only clips (the file lands in the template's Notes
            // folder regardless, so evidence is always on disk).
            if template.captureForensics {
                let vaultURL = NotesViewModel.resolveVaultURL()
                let clipFolder = vaultURL.appendingPathComponent(template.folder, isDirectory: true)
                let slug = ClipTemplateEngine.safeFileName(
                    "\(ISO8601DateFormatter().string(from: Date()).prefix(19))-\(result.title)")
                let assetsDir = clipFolder
                    .appendingPathComponent("assets", isDirectory: true)
                    .appendingPathComponent(slug, isDirectory: true)
                try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
                let metadata = await ClipForensicsService.shared.capture(url: result.url)
                if let data = try? JSONEncoder.prettyEncoder.encode(metadata) {
                    try? data.write(to: assetsDir.appendingPathComponent("capture-metadata.json"),
                                    options: .atomic)
                    assetSummary += " +forensics"
                }
            }

            let variables = ClipTemplateEngine.buildVariables(from: clip)

            // Destination 1: Notes vault — YAML frontmatter + rendered body
            if destinations.contains(.notes) {
                let vaultURL = NotesViewModel.resolveVaultURL()
                let service = NotesService(vaultURL: vaultURL)
                let clipFolder = vaultURL.appendingPathComponent(template.folder, isDirectory: true)
                let frontmatter = ClipTemplateEngine.renderFrontmatter(
                    properties: template.properties, variables: variables)
                let body = ClipTemplateEngine.render(template.bodyFormat, variables: variables)
                let content = frontmatter + "\n" + body
                let noteName = ClipTemplateEngine.render(template.noteNameFormat, variables: variables)
                let noteURL = try await service.createClippedNote(
                    title: noteName.isEmpty ? clip.title : noteName,
                    content: content,
                    in: clipFolder
                )
                notePath = noteURL.path
                // Tell open Notes panels to reload — they don't watch the
                // filesystem, so without this a clipped note only appears
                // after closing and reopening the panel.
                NotificationCenter.default.post(name: .notesVaultContentChanged, object: nil)
            }

            // Destination 2: MaestroDB "Web Clips" base
            if destinations.contains(.maestroDB) {
                maestroRowID = try ClipLibraryBridge.shared.saveClip(
                    clip, template: template, notePath: notePath)
            }

            ClipTemplateStore.shared.markUsed(template)
            var parts: [String] = []
            if let notePath { parts.append(notePath.components(separatedBy: "/").last ?? "note") }
            if maestroRowID != nil { parts.append("Web Clips base") }
            lastClipStatus = "Clipped to " + parts.joined(separator: " + ") + assetSummary

            return ClipOutcome(
                notePath: notePath, maestroRowID: maestroRowID,
                templateName: template.name, title: clip.title)
        } catch {
            lastClipStatus = "Clip failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Extract the clip (content + metadata + matched template) without
    /// saving — the clip popover previews this before the user confirms.
    /// Returns the values directly; no shared mutable state (the popover
    /// holds its own @State).
    func prepareClip() async -> (clip: WebClipResult, template: ClipTemplate)? {
        guard let tab = selectedTab,
              let url = tab.currentURL?.absoluteString,
              let html = try? await tab.capturePageHTML(),
              !html.isEmpty,
              let result = try? await WebClipperService.shared.clipFull(html: html, url: url) else {
            return nil
        }
        let template = ClipTemplateStore.shared.template(for: url)
        return (result, template)
    }
}

extension WebBrowserStore.ClipDestinations {
    /// Derive destinations from a template's per-template settings.
    init(template: ClipTemplate) {
        var d: WebBrowserStore.ClipDestinations = []
        if template.saveToNotes { d.insert(.notes) }
        if template.saveToMaestroDB { d.insert(.maestroDB) }
        self = d
    }
}
