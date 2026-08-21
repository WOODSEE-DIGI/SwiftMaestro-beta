import SwiftUI
import WebKit

// MARK: - Note Asset Viewer
//
// Renders non-markdown files from the Notes vault — the Web Clipper's
// per-clip artifacts: reader.html / snapshot.html (live webview), images,
// and capture-metadata.json (pretty-printed). Read-only; binary assets never
// route through the markdown editor.

struct NoteAssetViewer: View {
    let item: NoteItem
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerIcon)
                .foregroundStyle(Color.accentColor)
            Text(item.url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            Button {
                NSWorkspace.shared.open(item.url)
            } label: {
                Label("Open Externally", systemImage: "arrow.up.forward.square")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground)
    }

    private var headerIcon: String {
        switch item.assetKind {
        case .html: return "globe"
        case .json: return "curlybraces"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.assetKind {
        case .html:
            AssetWebView(url: item.url)
        case .image:
            AssetImageView(url: item.url)
        case .json, .text, .other:
            AssetTextView(url: item.url)
        }
    }
}

// MARK: - HTML in a live webview

private struct AssetWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // reader.html is fully self-contained (base64 images); snapshot.html
        // references sibling files in the assets folder — allow read access
        // to the file's directory so those resolve.
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

// MARK: - Image

private struct AssetImageView: View {
    let url: URL

    var body: some View {
        GeometryReader { geometry in
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            } else {
                ContentUnavailableView("Cannot Display Image",
                                       systemImage: "photo",
                                       description: Text(url.lastPathComponent))
            }
        }
    }
}

// MARK: - JSON / text (pretty-printed, read-only)

private struct AssetTextView: View {
    let url: URL
    @State private var text: String = ""
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Cannot Read File",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .task { load() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            loadError = "File could not be read."
            return
        }
        // Pretty-print JSON when possible
        if url.pathExtension.lowercased() == "json",
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            text = prettyString
            return
        }
        text = String(data: data, encoding: .utf8) ?? "(\(data.count) bytes of non-text data)"
    }
}
