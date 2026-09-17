import SwiftUI
import WebKit

#if canImport(AppKit)
import AppKit
#endif

/// Inoreader-style RSS reader panel.
struct RSSReaderView: View {
    let store = RSSReaderStore.shared
    let tracker = YouTubeHistoryTracker.shared
    @Environment(ThemeStore.self) private var theme
    @Environment(\.isWorkspaceEmbedded) private var isWorkspaceEmbedded

    @State private var selectedFeedID: UUID?
    @State private var selectedArticleID: UUID?
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var showOPMLImport = false
    @State private var showCategoryFilterSheet = false
    @State private var feedForCategoryFilter: RSSFeed?
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var selectedFeed: RSSFeed? {
        selectedFeedID.flatMap { store.feed(id: $0) }
    }

    private var selectedArticle: RSSArticle? {
        selectedArticleID.flatMap { store.article(id: $0) }
    }

    var body: some View {
        Group {
            if isWorkspaceEmbedded {
                embeddedBody
            } else {
                regularBody
            }
        }
        .task {
            store.loadIfNeeded()
            tracker.scanAllArticles()
        }
        .sheet(isPresented: $showAddSheet) {
            AddFeedSheet(isPresented: $showAddSheet) { feed in
                selectedFeedID = feed.id
                Task { await refreshFeed(feed) }
            }
        }
        .fileImporter(isPresented: $showOPMLImport, allowedContentTypes: [.xml, .plainText]) { result in
            handleOPMLImport(result)
        }
        .sheet(item: $feedForCategoryFilter) { feed in
            FeedCategoryFilterSheet(feed: feed) {
                feedForCategoryFilter = nil
            }
        }
        .alert("Import Error", isPresented: .constant(fetchError != nil)) {
            Button("OK") { fetchError = nil }
        } message: {
            Text(fetchError ?? "")
        }
    }

    private var regularBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            feedSidebar
        } content: {
            articleList
        } detail: {
            articleReader
        }
    }

    /// Workspace-tile layout: avoids NavigationSplitView's automatic sidebar
    /// toggle, which leaks into the main window toolbar and shifts the title bar.
    private var embeddedBody: some View {
        HSplitView {
            feedSidebarEmbedded
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 320, maxHeight: .infinity)
            articleList
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
            articleReader
                .frame(minWidth: 280, maxHeight: .infinity)
        }
    }

    // MARK: - Feed Sidebar

    private var feedSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Menu {
                    Button("Import OPML…") { showOPMLImport = true }
                    Button("Export OPML…") { exportOPML() }
                    Divider()
                    Button("Refresh All") { Task { await refreshAll() } }
                    Button("Mark All Read") { store.markAllRead(in: selectedFeedID) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Text("Reader")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            List(selection: $selectedFeedID) {
                Section {
                    NavigationLink(value: Optional<UUID>.none as Optional<UUID>) {
                        Label("All Articles", systemImage: "tray.full")
                    }
                    .tag(Optional<UUID>.none)

                    NavigationLink(value: Optional<UUID>.some(starredPseudoID)) {
                        Label("Starred", systemImage: "star.fill")
                    }
                    .tag(Optional<UUID>.some(starredPseudoID))

                    NavigationLink(value: Optional<UUID>.some(watchLaterPseudoID)) {
                        Label("Watch Later", systemImage: "play.rectangle")
                    }
                    .tag(Optional<UUID>.some(watchLaterPseudoID))
                }

                if store.feeds.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Feeds Yet",
                            systemImage: "dot.radiowaves.up.forward",
                            description: Text("Tap Add Feed above to subscribe to an RSS feed, or import an OPML file.")
                        )
                    } header: {
                        Text("Get Started")
                    }
                }

                ForEach(folderedFeeds.keys.sorted(), id: \.self) { folder in
                    Section(folder.isEmpty ? "Uncategorized" : folder) {
                        ForEach(folderedFeeds[folder] ?? []) { feed in
                            FeedRow(feed: feed, unreadCount: unreadCount(for: feed))
                                .tag(Optional(feed.id))
                                .contextMenu {
                                    Button("Refresh") { Task { await refreshFeed(feed) } }
                                    Button("Manage Categories…") {
                                        feedForCategoryFilter = feed
                                        showCategoryFilterSheet = true
                                    }
                                    Button("Delete") { store.removeFeed(id: feed.id) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Sidebar without NavigationLink, used in the workspace-tile layout so it
    /// doesn't depend on NavigationSplitView selection machinery.
    private var feedSidebarEmbedded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .controlSize(.small)

                Menu {
                    Button("Import OPML…") { showOPMLImport = true }
                    Button("Export OPML…") { exportOPML() }
                    Divider()
                    Button("Refresh All") { Task { await refreshAll() } }
                    Button("Mark All Read") { store.markAllRead(in: selectedFeedID) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Text("Reader")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            List(selection: $selectedFeedID) {
                Section {
                    Label("All Articles", systemImage: "tray.full")
                        .tag(Optional<UUID>.none)
                    Label("Starred", systemImage: "star.fill")
                        .tag(Optional<UUID>.some(starredPseudoID))
                    Label("Watch Later", systemImage: "play.rectangle")
                        .tag(Optional<UUID>.some(watchLaterPseudoID))
                }

                if store.feeds.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Feeds Yet",
                            systemImage: "dot.radiowaves.up.forward",
                            description: Text("Tap Add Feed above to subscribe to an RSS feed, or import an OPML file.")
                        )
                    } header: {
                        Text("Get Started")
                    }
                }

                ForEach(folderedFeeds.keys.sorted(), id: \.self) { folder in
                    Section(folder.isEmpty ? "Uncategorized" : folder) {
                        ForEach(folderedFeeds[folder] ?? []) { feed in
                            FeedRow(feed: feed, unreadCount: unreadCount(for: feed))
                                .tag(Optional(feed.id))
                                .contextMenu {
                                    Button("Refresh") { Task { await refreshFeed(feed) } }
                                    Button("Manage Categories…") {
                                        feedForCategoryFilter = feed
                                        showCategoryFilterSheet = true
                                    }
                                    Button("Delete") { store.removeFeed(id: feed.id) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var folderedFeeds: [String: [RSSFeed]] {
        Dictionary(grouping: store.feeds.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { $0.folder ?? "" }
    }

    private func unreadCount(for feed: RSSFeed) -> Int {
        store.articles(for: feed.id).filter { !$0.isRead }.count
    }

    // MARK: - Article List

    private var articleList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(listTitle)
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Image(systemName: isFetching ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                    }
                    .disabled(isFetching)
                    .help("Refresh all feeds")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            List(selection: $selectedArticleID) {
                if store.feeds.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Feeds Yet",
                            systemImage: "dot.radiowaves.up.forward",
                            description: Text("Tap Add Feed in the sidebar to subscribe to an RSS feed.")
                        )
                    }
                } else if displayedArticles.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Articles",
                            systemImage: "newspaper",
                            description: Text("This feed has no articles yet. Try refreshing.")
                        )
                    }
                }
                ForEach(displayedArticles) { article in
                    ArticleRow(article: article, feed: store.feed(id: article.feedID), tracker: tracker)
                        .tag(article.id)
                        .listRowBackground(article.isRead ? Color.clear : theme.accent.opacity(0.08))
                }
            }
            .listStyle(.plain)
        }
        .onChange(of: selectedArticleID) { _, newID in
            if let id = newID {
                store.markRead(articleID: id, read: true)
                if let article = store.article(id: id) {
                    _ = tracker.trackArticle(article)
                }
            }
        }
    }

    private var displayedArticles: [RSSArticle] {
        let base: [RSSArticle]
        if selectedFeedID == starredPseudoID {
            base = store.allVisibleArticles.filter { $0.isStarred }
        } else if selectedFeedID == watchLaterPseudoID {
            base = store.allVisibleArticles.filter { $0.youtubeVideoID != nil && !tracker.isWatched(videoID: $0.youtubeVideoID!) }
        } else if let feedID = selectedFeedID {
            base = store.articles(for: feedID)
        } else {
            base = store.allVisibleArticles
        }

        if searchText.isEmpty { return base }
        let lower = searchText.lowercased()
        return base.filter {
            $0.title.lowercased().contains(lower)
            || ($0.summary ?? "").lowercased().contains(lower)
            || ($0.author ?? "").lowercased().contains(lower)
        }
    }

    private var listTitle: String {
        if selectedFeedID == starredPseudoID { return "Starred" }
        if selectedFeedID == watchLaterPseudoID { return "Watch Later" }
        return selectedFeed?.title ?? "All Articles"
    }

    // MARK: - Article Reader

    private var articleReader: some View {
        Group {
            if let article = selectedArticle {
                RSSArticleReaderView(article: article, feed: selectedFeed, tracker: tracker)
            } else {
                ContentUnavailableView(
                    "No Article Selected",
                    systemImage: "newspaper",
                    description: Text("Select an article from the list to read it.")
                )
            }
        }
    }

    // MARK: - Pseudo IDs

    private var starredPseudoID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    private var watchLaterPseudoID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000002")! }

    // MARK: - Actions

    private func refreshAll() async {
        isFetching = true
        defer { isFetching = false }
        for feed in store.feeds {
            await refreshFeed(feed)
        }
        tracker.scanAllArticles()
    }

    private func refreshFeed(_ feed: RSSFeed) async {
        do {
            let result = try await RSSFeedService.shared.fetchFeed(url: feed.url)
            // RSSFeedService creates a new RSSFeed instance (new UUID). Re-map it
            // to the existing subscription so articles stay tied to the correct feed.
            var updatedFeed = result.feed
            updatedFeed.id = feed.id
            store.updateFeed(updatedFeed)
            store.upsertArticles(result.articles.map { var a = $0; a.feedID = feed.id; return a })
            // Remove stale articles left over from earlier refreshes that created
            // phantom feed IDs before this mapping was in place.
            store.pruneOrphanedArticles()
        } catch {
            var mutable = feed
            mutable.lastFetchError = error.localizedDescription
            mutable.lastFetchDate = Date()
            store.updateFeed(mutable)
            fetchError = "\(feed.title): \(error.localizedDescription)"
        }
    }

    private func handleOPMLImport(_ result: Result<URL, any Error>) {
        Task {
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                let data = try Data(contentsOf: url)
                let outlines = try await RSSFeedService.shared.importOPML(data: data)
                let feeds = await RSSFeedService.shared.feeds(from: outlines)
                for feed in feeds { _ = store.addFeed(title: feed.title, url: feed.url, siteURL: feed.siteURL, folder: feed.folder) }
                await refreshAll()
            } catch {
                fetchError = error.localizedDescription
            }
        }
    }

    private func exportOPML() {
        Task {
            guard let data = await RSSFeedService.shared.exportOPML(feeds: store.feeds) else { return }
            await MainActor.run {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.xml]
                panel.nameFieldStringValue = "swiftmaestro-subscriptions.opml"
                panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        try data.write(to: url)
                    } catch {
                        fetchError = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Feed Row

private struct FeedRow: View {
    let feed: RSSFeed
    let unreadCount: Int

    var body: some View {
        HStack {
            Text(feed.title)
                .lineLimit(1)
            Spacer()
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Article Row

private struct ArticleRow: View {
    let article: RSSArticle
    let feed: RSSFeed?
    let tracker: YouTubeHistoryTracker

    private var isYouTube: Bool { article.youtubeVideoID != nil }
    private var isWatched: Bool {
        guard let id = article.youtubeVideoID else { return false }
        return tracker.isWatched(videoID: id)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let imageURL = article.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if isYouTube {
                        Image(systemName: isWatched ? "play.rectangle.fill" : "play.rectangle")
                            .foregroundStyle(isWatched ? Color.secondary : Color.red)
                    }
                    Text(article.title)
                        .font(.system(size: 14, weight: article.isRead ? .regular : .semibold))
                        .lineLimit(2)
                    Spacer()
                    if article.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                    }
                }
                HStack(spacing: 6) {
                    Text(feed?.title ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let date = article.publishedDate {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Article Reader

private struct RSSArticleReaderView: View {
    let article: RSSArticle
    let feed: RSSFeed?
    let tracker: YouTubeHistoryTracker
    @Environment(ThemeStore.self) private var theme
    @Environment(\.isWorkspaceEmbedded) private var isWorkspaceEmbedded

    var body: some View {
        Group {
            if isWorkspaceEmbedded {
                readerContent
            } else {
                readerContent.toolbar { readerToolbarItems }
            }
        }
    }

    private var readerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let imageURL = article.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        default:
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.secondary.opacity(0.15))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                }

                HStack {
                    Text(article.title)
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        RSSReaderStore.shared.markStarred(articleID: article.id, starred: !article.isStarred)
                    } label: {
                        Image(systemName: article.isStarred ? "star.fill" : "star")
                            .foregroundStyle(article.isStarred ? .yellow : .primary)
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 8) {
                    Text(feed?.title ?? "")
                    if let author = article.author, !author.isEmpty {
                        Text("•")
                        Text(author)
                    }
                    if let date = article.publishedDate {
                        Text("•")
                        Text(date, style: .date)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let videoID = article.youtubeVideoID {
                    YouTubeWatchBar(videoID: videoID, tracker: tracker)
                }

                if let html = article.contentHTML ?? article.summary, !html.isEmpty {
                    RichRSSContentView(html: html, baseURL: article.url)
                        .frame(minHeight: 200)
                } else {
                    Text("No content available.")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 40)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background)
    }

    @ToolbarContentBuilder
    private var readerToolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            if let url = article.url {
                Button {
                    NSWorkspace.shared.open(url)
                    if let videoID = article.youtubeVideoID {
                        tracker.markWatched(videoID: videoID, source: "external-open", sourceURL: url)
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open in browser")
            }
            Button {
                RSSReaderStore.shared.markRead(articleID: article.id, read: !article.isRead)
            } label: {
                Image(systemName: article.isRead ? "envelope.badge" : "envelope.open")
            }
            .help(article.isRead ? "Mark unread" : "Mark read")
        }
    }
}

// MARK: - YouTube Watch Bar

private struct YouTubeWatchBar: View {
    let videoID: String
    let tracker: YouTubeHistoryTracker

    private var isWatched: Bool { tracker.isWatched(videoID: videoID) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isWatched ? "checkmark.circle.fill" : "play.circle")
                .foregroundStyle(isWatched ? .green : .red)
            Text(isWatched ? "Watched" : "Not watched")
            Spacer()
            if let url = YouTubeURLParser.youTubeURL(for: videoID) {
                Button {
                    NSWorkspace.shared.open(url)
                    tracker.markWatched(videoID: videoID, source: "reader-open", sourceURL: url)
                } label: {
                    Label("Watch on YouTube", systemImage: "play.rectangle")
                }
            }
            Button {
                if isWatched {
                    tracker.markUnwatched(videoID: videoID)
                } else {
                    tracker.markWatched(videoID: videoID, source: "manual")
                }
            } label: {
                Text(isWatched ? "Mark unwatched" : "Mark watched")
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Rich Content View

private struct RichRSSContentView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Make the web view transparent so the app's theme background shows through.
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let processed = plainTextToHTMLIfNeeded(html)
        let wrapped = wrapHTML(processed)
        webView.loadHTMLString(wrapped, baseURL: baseURL)
    }

    /// If the input has no HTML tags, treat it as plain text and convert
    /// newlines to <br> so line breaks survive into the WebView.
    private func plainTextToHTMLIfNeeded(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("<") else { return html }
        return trimmed
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func wrapHTML(_ html: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: dark; }
        * { background-color: transparent !important; }
        html, body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 15px; line-height: 1.6; margin: 0; padding: 0; color: #ddd !important; }
        *:not(a) { color: #ddd !important; }
        a { color: #0A84FF !important; text-decoration: none; }
        a:hover { text-decoration: underline; }
        p, div, span, article, section, aside, header, footer, figure, figcaption, main, li, td, th, blockquote, pre, code { background-color: transparent !important; }
        img, video, iframe, picture, figure { max-width: 100%; height: auto; display: block; margin: 1em 0; }
        blockquote { border-left: 3px solid #555; margin: 1em 0; padding-left: 1em; color: #aaa !important; }
        pre, code { font-family: SFMono-Regular, monospace; background: #1c1c1e !important; border-radius: 6px; }
        pre { padding: 1em; overflow-x: auto; }
        code { padding: 0.15em 0.35em; }
        table { width: 100%; border-collapse: collapse; }
        h1, h2, h3, h4, h5, h6 { margin-top: 1.2em; margin-bottom: 0.5em; line-height: 1.3; }
        ul, ol { padding-left: 1.5em; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Add Feed Sheet

private struct AddFeedSheet: View {
    @Binding var isPresented: Bool
    var onAdded: (RSSFeed) -> Void

    @State private var urlString = ""
    @State private var folder = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var discoveredFeeds: [RSSDiscoveredFeed] = []
    @State private var selectedDiscoveredID: RSSDiscoveredFeed.ID?

    private var trimmedURL: String { urlString.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Feed").font(.title2.bold())
            Form {
                TextField("Feed or website URL", text: $urlString)
                    .onSubmit { Task { await discover() } }
                TextField("Folder (optional)", text: $folder)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            if !discoveredFeeds.isEmpty {
                discoveredFeedList
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Discover") { Task { await discover() } }
                    .disabled(trimmedURL.isEmpty || isLoading)
                Button("Add") { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .disabled((trimmedURL.isEmpty && selectedDiscoveredID == nil) || isLoading)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: discoveredFeeds.isEmpty ? 200 : 380)
    }

    private var discoveredFeedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discovered feeds")
                .font(.headline)
            List(discoveredFeeds, selection: $selectedDiscoveredID) { feed in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(feed.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(feed.kind.rawValue.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .tag(feed.id)
            }
            .listStyle(.plain)
            .frame(minHeight: 120)
        }
    }

    private func discover() async {
        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true else {
            error = "Enter a valid http(s) URL."
            return
        }
        isLoading = true
        error = nil
        discoveredFeeds = []
        selectedDiscoveredID = nil

        do {
            // If the URL is already a feed, use it directly.
            let result = try await RSSFeedService.shared.fetchFeed(url: url)
            let feed = RSSReaderStore.shared.addFeed(
                title: result.feed.title,
                url: result.feed.url,
                siteURL: result.feed.siteURL,
                folder: folder.isEmpty ? nil : folder
            )
            RSSReaderStore.shared.upsertArticles(result.articles.map { var a = $0; a.feedID = feed.id; return a })
            isLoading = false
            isPresented = false
            onAdded(feed)
        } catch {
            // Treat the URL as a website and discover its feeds.
            let found = await RSSDiscoveryService.shared.discoverFeeds(fromSiteURL: url)
            await MainActor.run {
                isLoading = false
                if found.isEmpty {
                    self.error = "No feeds found at that URL."
                } else {
                    self.discoveredFeeds = found
                    self.selectedDiscoveredID = found.first?.id
                }
            }
        }
    }

    private func add() async {
        // If a discovery result is selected, subscribe to it.
        if let selected = discoveredFeeds.first(where: { $0.id == selectedDiscoveredID }) {
            do {
                let result = try await RSSFeedService.shared.fetchFeed(url: selected.url)
                let feed = RSSReaderStore.shared.addFeed(
                    title: result.feed.title,
                    url: result.feed.url,
                    siteURL: result.feed.siteURL ?? selected.siteURL,
                    folder: folder.isEmpty ? nil : folder
                )
                RSSReaderStore.shared.upsertArticles(result.articles.map { var a = $0; a.feedID = feed.id; return a })
                isPresented = false
                onAdded(feed)
            } catch {
                self.error = error.localizedDescription
            }
            return
        }

        // Otherwise treat the text field as a direct feed URL.
        isLoading = true
        error = nil
        do {
            let result = try await RSSFeedService.shared.fetchFeed(urlString: urlString)
            let feed = RSSReaderStore.shared.addFeed(
                title: result.feed.title,
                url: result.feed.url,
                siteURL: result.feed.siteURL,
                folder: folder.isEmpty ? nil : folder
            )
            RSSReaderStore.shared.upsertArticles(result.articles.map { var a = $0; a.feedID = feed.id; return a })
            isLoading = false
            isPresented = false
            onAdded(feed)
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Category Filter Sheet

private struct FeedCategoryFilterSheet: View {
    let feed: RSSFeed
    let onDone: () -> Void

    @State private var included: Set<String> = []
    @State private var excluded: Set<String> = []
    @State private var customCategory = ""
    @State private var extraCategories: [String] = []

    private var allCategories: [String] {
        let known = RSSReaderStore.shared.allCategories(for: feed.id)
        var seen = Set(known.map { $0.lowercased() })
        var result = known
        for cat in extraCategories where !seen.contains(cat.lowercased()) {
            result.append(cat)
            seen.insert(cat.lowercased())
        }
        return result.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Category Filters: \(feed.title)")
                .font(.title3.bold())

            Text("Choose which categories to show or hide. Select “Show only” to whitelist, or “Hide” to blacklist.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if allCategories.isEmpty {
                ContentUnavailableView(
                    "No Categories Found",
                    systemImage: "tag.slash",
                    description: Text("This feed hasn't published any category tags yet. Try refreshing the feed, or add a custom category below.")
                )
                .frame(minHeight: 160)
            } else {
                List(allCategories, id: \.self) { category in
                    HStack(spacing: 12) {
                        Text(category)
                            .lineLimit(1)
                        Spacer()
                        Picker("", selection: choice(for: category)) {
                            Text("Default").tag(0)
                            Text("Show only").tag(1)
                            Text("Hide").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }
                .listStyle(.plain)
            }

            HStack(spacing: 8) {
                TextField("Add custom category", text: $customCategory)
                Button("Add") { addCustomCategory() }
                    .disabled(customCategory.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 520, height: 440)
        .onAppear {
            included = Set(feed.includedCategories)
            excluded = Set(feed.excludedCategories)
        }
    }

    private func choice(for category: String) -> Binding<Int> {
        Binding(
            get: {
                if included.contains(category) { return 1 }
                if excluded.contains(category) { return 2 }
                return 0
            },
            set: { newValue in
                included.remove(category)
                excluded.remove(category)
                if newValue == 1 { included.insert(category) }
                else if newValue == 2 { excluded.insert(category) }
            }
        )
    }

    private func addCustomCategory() {
        let trimmed = customCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        guard !allCategories.contains(where: { $0.lowercased() == lower }) else {
            customCategory = ""
            return
        }
        extraCategories.append(trimmed)
        included.insert(trimmed)
        customCategory = ""
    }

    private func save() {
        var updated = feed
        updated.includedCategories = Array(included)
        updated.excludedCategories = Array(excluded)
        RSSReaderStore.shared.updateFeed(updated)
        onDone()
    }
}

#Preview {
    RSSReaderView()
        .environment(ThemeStore())
}
