import SwiftUI

/// Popover shown from SwiftBrowser that discovers RSS/Atom feeds on the current page.
struct RSSDiscoveryPopoverView: View {
    let tab: BrowserTab
    let onSubscribe: (RSSFeed) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var discoveredFeeds: [RSSDiscoveredFeed] = []
    @State private var selectedID: RSSDiscoveredFeed.ID?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscribe to Feed")
                .font(.headline)

            if isLoading {
                ProgressView("Looking for feeds…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let error {
                ContentUnavailableView(
                    "Discovery Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(minHeight: 120)
            } else if discoveredFeeds.isEmpty {
                ContentUnavailableView(
                    "No Feeds Found",
                    systemImage: "dot.radiowaves.up.forward",
                    description: Text("This page doesn't appear to publish any RSS or Atom feeds.")
                )
                .frame(minHeight: 120)
            } else {
                List(discoveredFeeds, selection: $selectedID) { feed in
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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Subscribe") { Task { await subscribe() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedID == nil || isLoading)
            }
        }
        .padding()
        .frame(width: 420)
        .task {
            await discover()
        }
    }

    private func discover() async {
        guard let url = tab.currentURL else {
            await MainActor.run {
                isLoading = false
                error = "No page URL available."
            }
            return
        }

        do {
            let html = try await tab.capturePageHTML()
            let feeds = await RSSDiscoveryService.shared.discoverFeeds(html: html, baseURL: url)
            await MainActor.run {
                discoveredFeeds = feeds
                selectedID = feeds.first?.id
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func subscribe() async {
        guard let feed = discoveredFeeds.first(where: { $0.id == selectedID }) else { return }
        do {
            let result = try await RSSFeedService.shared.fetchFeed(url: feed.url)
            let subscribed = RSSReaderStore.shared.addFeed(
                title: result.feed.title,
                url: result.feed.url,
                siteURL: result.feed.siteURL ?? feed.siteURL,
                folder: nil
            )
            RSSReaderStore.shared.upsertArticles(result.articles.map { var a = $0; a.feedID = subscribed.id; return a })
            onSubscribe(subscribed)
            dismiss()
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }
}

#Preview {
    // Preview requires a BrowserTab instance; omitted because BrowserTab needs a web engine.
    EmptyView()
}
