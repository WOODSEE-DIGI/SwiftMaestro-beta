import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Excalidraw Panel

/// Embeds the Excalidraw whiteboard editor in a WKWebView panel.
/// A lightweight local HTTP server serves the built Excalidraw assets,
/// and a JS↔Swift bridge handles file save/load.
struct ExcalidrawPanelView: View {
    private let store = ExcalidrawStore.shared

    @State private var currentFileURL: URL?
    @State private var fileName: String = "Untitled"
    @State private var isEdited = false
    @State private var showFilePicker = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            ExcalidrawToolbar(
                fileName: fileName,
                isEdited: isEdited,
                onNew: createNew,
                onOpen: { showFilePicker = true },
                onSave: saveCurrentFile,
                onSaveAs: saveAsFile,
                onExportJSON: exportAsJSON,
                onExportPNG: exportAsPNG
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            ExcalidrawWebView(
                store: store,
                currentFileURL: $currentFileURL,
                fileName: $fileName,
                isEdited: $isEdited
            )
        }
        .task {
            // Ensure the local HTTP server is up before the webview loads its URL.
            try? await store.startServer()
        }
        .alert("Excalidraw Error", isPresented: .constant(loadError != nil)) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "excalidraw") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    currentFileURL = url
                    // The WebView will load via the bridge
                }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }

    private func createNew() {
        currentFileURL = nil
        fileName = "Untitled"
        isEdited = false
        // The WebView observes currentFileURL changes and clears itself
    }

    private func saveCurrentFile() {
        NotificationCenter.default.post(
            name: .excalidrawRequestSave,
            object: currentFileURL
        )
    }

    private func saveAsFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "excalidraw") ?? .json]
        panel.nameFieldStringValue = "\(fileName).excalidraw"
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                currentFileURL = url
                fileName = url.deletingPathExtension().lastPathComponent
                NotificationCenter.default.post(
                    name: .excalidrawRequestSave,
                    object: url
                )
            }
        }
    }

    private func exportAsJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(fileName).excalidraw"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                NotificationCenter.default.post(
                    name: .excalidrawRequestExportJSON,
                    object: url
                )
            }
        }
    }

    private func exportAsPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(fileName).png"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                NotificationCenter.default.post(
                    name: .excalidrawRequestExportPNG,
                    object: url
                )
            }
        }
    }
}

// MARK: - Toolbar

private struct ExcalidrawToolbar: View {
    let fileName: String
    let isEdited: Bool
    let onNew: () -> Void
    let onOpen: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onExportJSON: () -> Void
    let onExportPNG: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(fileName)
                .font(.headline)
                .foregroundColor(isEdited ? .secondary : .primary)

            if isEdited {
                Text("\u{2022}")
                    .foregroundColor(.orange)
            }

            Spacer()

            Group {
                Button(action: onNew) {
                    Image(systemName: "plus")
                }
                .help("New board")

                Button(action: onOpen) {
                    Image(systemName: "folder")
                }
                .help("Open .excalidraw file")

                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save")

                Button(action: onSaveAs) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save As...")
            }
            .buttonStyle(.borderless)

            Menu {
                Button("Export as .excalidraw (JSON)", action: onExportJSON)
                Button("Export as PNG", action: onExportPNG)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .help("Export")
        }
    }
}

// MARK: - WKWebView Wrapper

private struct ExcalidrawWebView: NSViewRepresentable {
    let store: ExcalidrawStore
    @Binding var currentFileURL: URL?
    @Binding var fileName: String
    @Binding var isEdited: Bool

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let bridge = ExcalidrawBridge()
        bridge.coordinator = context.coordinator
        contentController.add(bridge, name: "excalidrawBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        bridge.webView = webView

        // Load Excalidraw from local server
        if let url = store.serverURL {
            let request = URLRequest(url: url.appendingPathComponent("/"))
            webView.load(request)
        }

        context.coordinator.bridge = bridge
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Handle file URL changes
        if let fileURL = currentFileURL, context.coordinator.lastLoadedURL != fileURL {
            context.coordinator.lastLoadedURL = fileURL
            let escaped = fileURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let js = "window.__swiftmaestro_loadFile('\(escaped)')"
            nsView.evaluateJavaScript(js)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(self)
        // Watch for agent-tool edits to a board on disk. If they touch the
        // board currently open in THIS webview, reload it so the user sees
        // the live update.
        coordinator.externalModificationObserver = NotificationCenter.default.addObserver(
            forName: .excalidrawBoardExternallyModified,
            object: nil,
            queue: .main
        ) { [weak coordinator] note in
            guard let coordinator,
                  let boardURL = note.userInfo?["boardURL"] as? URL,
                  let current = coordinator.parent.currentFileURL,
                  current.standardizedFileURL == boardURL.standardizedFileURL,
                  let webView = coordinator.bridge?.webView
            else { return }
            let escaped = boardURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            webView.evaluateJavaScript("window.__swiftmaestro_loadFile('\(escaped)')")
        }
        return coordinator
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ExcalidrawWebView
        var bridge: ExcalidrawBridge?
        var lastLoadedURL: URL?
        var externalModificationObserver: NSObjectProtocol?

        init(_ parent: ExcalidrawWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject theme sync
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let theme = isDark ? "dark" : "light"
            webView.evaluateJavaScript("document.documentElement.classList.toggle('dark', \(isDark))")

            // If we have a file to load, send it
            if let fileURL = parent.currentFileURL {
                let escaped = fileURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                webView.evaluateJavaScript("window.__swiftmaestro_loadFile('\(escaped)')")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow initial load and file:// navigations
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
            } else {
                // Open external links in the system browser
                if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - JS↔Swift Bridge

/// Handles messages from the Excalidraw web app JavaScript.
final class ExcalidrawBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    fileprivate weak var coordinator: ExcalidrawWebView.Coordinator?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "save":
            handleSave(body: body)
        case "loadRequest":
            handleLoadRequest(body: body)
        case "fileLoaded":
            handleFileLoaded(body: body)
        case "edited":
            Task { @MainActor in
                coordinator?.parent.isEdited = true
            }
        case "setTitle":
            if let title = body["title"] as? String {
                Task { @MainActor in
                    coordinator?.parent.fileName = title
                }
            }
        case "ready":
            // Excalidraw is ready, send initial state
            break
        case "exportJSON":
            handleExportJSON(body: body)
        case "exportPNG":
            handleExportPNG(body: body)
        default:
            break
        }
    }

    private func handleSave(body: [String: Any]) {
        guard let dataString = body["data"] as? String else { return }
        Task { @MainActor in
            let url = coordinator?.parent.currentFileURL
            if let url = url {
                try? dataString.write(to: url, atomically: true, encoding: .utf8)
                coordinator?.parent.isEdited = false
            } else {
                // No file URL yet — trigger Save As
                saveAs(dataString: dataString)
            }
        }
    }

    @MainActor
    private func saveAs(dataString: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "excalidraw") ?? .json]
        panel.nameFieldStringValue = "\(coordinator?.parent.fileName ?? "Untitled").excalidraw"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? dataString.write(to: url, atomically: true, encoding: .utf8)
                self.coordinator?.parent.currentFileURL = url
                self.coordinator?.parent.isEdited = false
            }
        }
    }

    private func handleLoadRequest(body: [String: Any]) {
        guard let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }
        Task { @MainActor in
            coordinator?.parent.currentFileURL = url
            coordinator?.parent.fileName = url.deletingPathExtension().lastPathComponent
            coordinator?.parent.isEdited = false
        }
    }

    private func handleFileLoaded(body: [String: Any]) {
        Task { @MainActor in
            coordinator?.parent.isEdited = false
        }
    }

    private func handleExportJSON(body: [String: Any]) {
        guard let dataString = body["data"] as? String,
              let targetURL = body["targetURL"] as? String,
              let url = URL(string: targetURL) else { return }
        try? dataString.write(to: url, atomically: true, encoding: .utf8)
    }

    private func handleExportPNG(body: [String: Any]) {
        guard let base64 = body["data"] as? String,
              let targetURL = body["targetURL"] as? String,
              let url = URL(string: targetURL),
              let imageData = Data(base64Encoded: base64) else { return }
        try? imageData.write(to: url)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let excalidrawRequestSave = Notification.Name("excalidrawRequestSave")
    static let excalidrawRequestExportJSON = Notification.Name("excalidrawRequestExportJSON")
    static let excalidrawRequestExportPNG = Notification.Name("excalidrawRequestExportPNG")
    /// Posted (userInfo: ["boardURL": URL]) when an agent tool mutates a board's
    /// scene on disk, so an open Excalidraw panel reloads the board.
    static let excalidrawBoardExternallyModified = Notification.Name("excalidrawBoardExternallyModified")
}
