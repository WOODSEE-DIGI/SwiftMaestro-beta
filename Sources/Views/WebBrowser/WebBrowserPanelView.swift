import SwiftUI
import AppKit
import WebKit

/// Top-level workspace panel for the internal WebKit/Chromium browser.
struct WebBrowserPanelView: View {
    @State private var store = WebBrowserStore.shared
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            WebBrowserTabStrip(store: store)
            Divider()
            WebBrowserToolbar(store: store)
            Divider()
            if let tab = store.selectedTab {
                WebBrowserTabContent(tab: tab)
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Tab",
                    systemImage: "globe",
                    description: Text("Add a tab to start browsing.")
                )
            }
            if let status = store.lastClipStatus {
                Text(status)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.background)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toolbar

private struct WebBrowserToolbar: View {
    let store: WebBrowserStore
    @Environment(ThemeStore.self) private var theme
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.selectedTab?.goBack() }
            } label: {
                Image(systemName: "arrow.backward")
            }
            .disabled(!(store.selectedTab?.canGoBack ?? false))
            .help("Back")

            Button {
                Task { await store.selectedTab?.goForward() }
            } label: {
                Image(systemName: "arrow.forward")
            }
            .disabled(!(store.selectedTab?.canGoForward ?? false))
            .help("Forward")

            Button {
                Task { await store.selectedTab?.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")

            Button {
                store.selectedTab?.stopLoading()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Stop loading")

            TextField("URL", text: addressBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200, maxWidth: .infinity)
                .focused($urlFieldFocused)
                .onChange(of: urlFieldFocused) { _, isFocused in
                    store.selectedTab?.isURLFieldEditing = isFocused
                }
                .onSubmit {
                    Task { await store.loadURL(addressBinding.wrappedValue, in: store.selectedTab) }
                }

            Button {
                Task { await store.loadURL(addressBinding.wrappedValue, in: store.selectedTab) }
            } label: {
                Image(systemName: "arrow.turn.down.right")
            }
            .help("Go to URL")

            Button {
                Task { await store.clipCurrentPage() }
            } label: {
                Image(systemName: "scissors")
            }
            .help("Clip this page to Notes")

            Text(store.selectedTab?.engineType.rawValue.capitalized ?? "WebKit")
                .font(.caption)
                .lineLimit(1)
                .help("Active tab engine")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { store.selectedTab?.urlString ?? "" },
            set: { store.selectedTab?.urlString = $0 }
        )
    }
}

// MARK: - Tab Strip

/// The persistent strip of tabs across the top of the browser panel. Lives at
/// the panel level (not inside each tab's content) so it isn't torn down and
/// rebuilt every time the selection changes.
private struct WebBrowserTabStrip: View {
    let store: WebBrowserStore
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.tabs) { tab in
                    WebBrowserTabItem(
                        store: store,
                        tab: tab,
                        isSelected: store.selectedTabID == tab.id
                    )
                }
                Button {
                    store.addTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(theme.background)
        .frame(maxWidth: .infinity, minHeight: 30)
    }
}

/// A single tab in the strip: engine icon, title, loading spinner, close button,
/// and a context menu with the usual tab operations.
private struct WebBrowserTabItem: View {
    let store: WebBrowserStore
    let tab: BrowserTab
    let isSelected: Bool
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        Button {
            store.selectedTabID = tab.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.engineType == .webKit ? "safari" : "globe")
                    .font(.caption2)
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 10, height: 10)
                }
                Button {
                    store.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .opacity(isSelected ? 1.0 : 0.45)
                .help("Close tab")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? theme.accent.opacity(0.22) : Color.clear)
            .foregroundStyle(isSelected ? theme.accent : theme.sidebarText)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate") { store.duplicateTab(id: tab.id) }
            Divider()
            Button("Move Left") { store.moveTab(id: tab.id, by: -1) }
                .disabled(!canMove(by: -1))
            Button("Move Right") { store.moveTab(id: tab.id, by: 1) }
                .disabled(!canMove(by: 1))
            Divider()
            Button("Close Other Tabs") { store.closeOtherTabs(id: tab.id) }
                .disabled(store.tabs.count <= 1)
            Button("Close Tabs to the Right") { store.closeTabsToTheRight(of: tab.id) }
            Divider()
            Button("Close") { store.closeTab(id: tab.id) }
        }
    }

    private func canMove(by offset: Int) -> Bool {
        guard let index = store.tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return store.tabs.indices.contains(index + offset)
    }
}

// MARK: - Tab Content

/// The web content for the selected tab (the tab strip now lives at the panel
/// level, so this is just the engine view).
private struct WebBrowserTabContent: View {
    let tab: BrowserTab

    var body: some View {
        switch tab.engineType {
        case .webKit:
            if let engine = tab.webKitEngine {
                WebKitBrowserView(engine: engine)
            }
        case .chromium:
            if let engine = tab.chromiumEngine {
                ChromiumBrowserView(engine: engine)
            }
        }
    }
}

// MARK: - WebKit View

private struct WebKitBrowserView: View {
    let engine: WebKitBrowserEngine

    var body: some View {
        WebKitWebViewRepresentable(engine: engine)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if let error = engine.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding(.top, 8)
                }
            }
    }
}

private struct WebKitWebViewRepresentable: NSViewRepresentable {
    let engine: WebKitBrowserEngine

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = engine.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Chromium View

private struct ChromiumBrowserView: View {
    let engine: ChromiumBrowserEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if engine.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                } else {
                    Label("Ready", systemImage: "checkmark.circle")
                        .font(.caption)
                }
                Spacer()
                Button("Screenshot") {
                    Task { await engine.captureScreenshot() }
                }
                .help("Capture a PNG screenshot of the page")
                Button("Capture HTML") {
                    Task {
                        if let data = try? await engine.evaluateJavaScript("document.documentElement.outerHTML"),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let result = json["result"] as? [String: Any],
                           let html = result["value"] as? String {
                            engine.lastResponse = html
                        }
                    }
                }
                .help("Capture the page HTML")
                Button("Evaluate JS") {
                    Task {
                        if let data = try? await engine.evaluateJavaScript("document.title") {
                            engine.lastResponse = String(data: data, encoding: .utf8)
                        }
                    }
                }
                .help("Evaluate document.title")
            }
            .padding(8)
            .background(theme.background)

            if let screenshot = engine.screenshot, let image = NSImage(data: screenshot) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 400)
            }

            ScrollView {
                Text(engine.lastResponse ?? "No response yet")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

            if let error = engine.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var theme: ThemeStore {
        ThemeStore.sharedIfAvailable ?? ThemeStore()
    }
}

// MARK: - ThemeStore fallback

private extension ThemeStore {
    static var sharedIfAvailable: ThemeStore? {
        // SwiftUI environment provides the real store; this is only used for previews.
        nil
    }
}

#Preview {
    WebBrowserPanelView()
        .environment(ThemeStore())
}
