import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Excalidraw Panel

/// Embeds the Excalidraw whiteboard editor in a WKWebView panel.
/// A lightweight local HTTP server serves the built Excalidraw assets,
/// and a JS↔Swift bridge handles file save/load.
struct ExcalidrawPanelView: View {
    private let store = ExcalidrawStore.shared

    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.openWindow) private var openWindow

    @State private var currentFileURL: URL?
    @State private var fileName: String = "Untitled"
    @State private var isEdited = false
    @State private var showFilePicker = false
    @State private var loadError: String?

    @State private var assistant: ExcalidrawAIAssistant?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var generationError: String?
    @State private var codeResult: String?
    @State private var webView: WKWebView?

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
                isEdited: $isEdited,
                webView: $webView,
                onTextToDiagram: { runTextToDiagram() },
                onWireframeToCode: { runWireframeToCode() }
            )
            .overlay {
                if isGenerating {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Maestro is generating…")
                                .font(.callout)
                            Button("Cancel") { cancelGeneration() }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .task {
            // Ensure the local HTTP server is up before the webview loads its URL.
            do {
                try await store.startServer()
            } catch {
                loadError = "Excalidraw server failed to start: \(error.localizedDescription)"
            }
        }
        .alert("Excalidraw Error", isPresented: .constant(loadError != nil)) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .alert("Diagram Generation Error", isPresented: .constant(generationError != nil)) {
            Button("OK") { generationError = nil }
        } message: {
            Text(generationError ?? "")
        }
        .alert("Generated Code", isPresented: .constant(codeResult != nil)) {
            Button("Open in SwiftWeaver") { openCodeInSwiftWeaver() }
            Button("Open in SwiftBrowser") { openCodeInSwiftBrowser() }
            Button("Copy") { copyCodeResult() }
            Button("Done") { codeResult = nil }
        } message: {
            Text(codeResult?.isEmpty == false ? "Code generated (\(codeResult!.count) chars)." : "No code was generated.")
        }
        .task {
            assistant = ExcalidrawAIAssistant(engine: engine, catalog: catalog)
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

    // MARK: - Maestro-backed AI features

    private func runTextToDiagram() {
        guard let assistant, !isGenerating else { return }
        let prompt = requestTextInput(title: "Text to Diagram", message: "Describe the diagram you want Maestro to build:", defaultValue: "")
        guard !prompt.isEmpty else { return }

        isGenerating = true
        generationTask = Task {
            do {
                let board = try await assistant.generateDiagram(from: prompt)
                currentFileURL = board.url
                fileName = board.name
                isEdited = false
            } catch is CancellationError {
                // User cancelled — no error surface.
            } catch {
                generationError = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func runWireframeToCode() {
        guard let assistant, !isGenerating else { return }
        guard let webView else {
            generationError = "Excalidraw editor is not ready."
            return
        }

        isGenerating = true
        generationTask = Task {
            do {
                let sceneJSON = try await webView.evaluateJavaScriptAsync("window.__swiftmaestro.getSceneData()") ?? ""
                guard !sceneJSON.isEmpty else {
                    generationError = "Could not read the current wireframe scene."
                    isGenerating = false
                    return
                }

                let instructions = requestTextInput(
                    title: "Wireframe to Code",
                    message: "Optional instructions (e.g. 'Use Tailwind', 'Make it React'):",
                    defaultValue: "")

                let code = try await assistant.generateCode(
                    from: sceneJSON,
                    instructions: instructions.isEmpty ? nil : instructions)
                codeResult = code
            } catch is CancellationError {
                // User cancelled — no error surface.
            } catch {
                generationError = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    private func openCodeInSwiftWeaver() {
        guard let code = codeResult else { return }
        do {
            let url = try writeCodeToTempFile(code)
            try SwiftWeaverStore.shared.openDocument(from: url)
            openResultPanel(.htmlBuilder)
        } catch {
            generationError = "Could not open SwiftWeaver: \(error.localizedDescription)"
        }
        codeResult = nil
    }

    private func openCodeInSwiftBrowser() {
        guard let code = codeResult else { return }
        do {
            let url = try writeCodeToTempFile(code)
            WebBrowserStore.shared.addTab(url: url, activate: true)
            openResultPanel(.webBrowser)
        } catch {
            generationError = "Could not open SwiftBrowser: \(error.localizedDescription)"
        }
        codeResult = nil
    }

    private func writeCodeToTempFile(_ code: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftmaestro-wireframe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Wireframe-\(Self.dateSuffix()).html")
        try code.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func openResultPanel(_ kind: WorkspacePanelKind) {
        // Default panel behavior: dock into the largest free canvas area if
        // space exists; otherwise float as a pop-out window.
        let result = WorkspaceLayoutState.shared.open(kind, zone: .right)
        if result == .floated || (result == .alreadyOpen && WorkspaceLayoutState.shared.isFloating(kind)) {
            openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
        }
    }

    private func copyCodeResult() {
        guard let code = codeResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private static func dateSuffix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// Shows a modal text-input alert and returns the trimmed text.
    private func requestTextInput(title: String, message: String, defaultValue: String) -> String {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        textField.stringValue = defaultValue
        textField.placeholderString = "Describe what you want…"
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return "" }
        return textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
        HStack(spacing: 14) {
            Text(fileName)
                .font(.headline)
                .foregroundColor(isEdited ? .secondary : .primary)

            if isEdited {
                Text("\u{2022}")
                    .foregroundColor(.orange)
                    .font(.title2)
            }

            Spacer()

            Group {
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(minWidth: 28, minHeight: 28)
                }
                .help("New board")

                Button(action: onOpen) {
                    Image(systemName: "folder")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(minWidth: 28, minHeight: 28)
                }
                .help("Open .excalidraw file")

                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(minWidth: 28, minHeight: 28)
                }
                .help("Save")

                Button(action: onSaveAs) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(minWidth: 28, minHeight: 28)
                }
                .help("Save As...")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)

            Menu {
                Button("Export as .excalidraw (JSON)", action: onExportJSON)
                Button("Export as PNG", action: onExportPNG)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(minWidth: 28, minHeight: 28)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.large)
            .help("Export")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - WKWebView Wrapper

private struct ExcalidrawWebView: NSViewRepresentable {
    let store: ExcalidrawStore
    @Binding var currentFileURL: URL?
    @Binding var fileName: String
    @Binding var isEdited: Bool
    @Binding var webView: WKWebView?
    let onTextToDiagram: () -> Void
    let onWireframeToCode: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let bridge = ExcalidrawBridge()
        bridge.coordinator = context.coordinator
        contentController.add(bridge, name: "excalidrawBridge")

        // Capture JS console logs/errors so we can diagnose blank canvas / asset failures.
        let consoleCaptureScript = WKUserScript(
            source: ExcalidrawWebView.consoleCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(consoleCaptureScript)

        // Hide Excalidraw's external-service menu items that don't apply inside SwiftMaestro.
        let hideExternalScript = WKUserScript(
            source: ExcalidrawWebView.hideExternalMenuItemsScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        contentController.addUserScript(hideExternalScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        bridge.webView = webView
        self.webView = webView

        // Load Excalidraw from local server if it's already running; otherwise
        // updateNSView will pick up serverURL once startServer() finishes.
        loadServerURLIfNeeded(into: webView, coordinator: context.coordinator)

        context.coordinator.bridge = bridge
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // If the local server URL changed (first start or restart), reset the
        // loaded-file tracker so we re-issue the board load through the new URL.
        if context.coordinator.lastSeenServerURL != store.serverURL {
            context.coordinator.lastSeenServerURL = store.serverURL
            context.coordinator.lastLoadedFileURL = nil
        }

        // If the local server started after makeNSView, load it now.
        loadServerURLIfNeeded(into: nsView, coordinator: context.coordinator)

        // Handle file URL changes, loading through the local HTTP server so the
        // WKWebView can fetch the board without file:// sandbox issues.
        loadCurrentBoard(into: nsView, coordinator: context.coordinator)
    }

    private func loadServerURLIfNeeded(into webView: WKWebView, coordinator: Coordinator) {
        guard let serverURL = store.serverURL,
              coordinator.lastLoadedServerURL != serverURL,
              !webView.isLoading,
              webView.url?.host == nil else { return }
        coordinator.lastLoadedServerURL = serverURL
        let request = URLRequest(url: serverURL.appendingPathComponent("/"))
        webView.load(request)
    }

    /// Loads the current board file through the local HTTP server. The board's
    /// file:// URL is translated to `http://localhost:<port>/board/<name>` so the
    /// webview can fetch it without hitting sandbox restrictions.
    private func loadCurrentBoard(into webView: WKWebView, coordinator: Coordinator) {
        guard let fileURL = currentFileURL,
              coordinator.lastLoadedFileURL != fileURL,
              let serverBoardURL = store.serverURL(for: fileURL)
        else { return }
        coordinator.lastLoadedFileURL = fileURL
        let escaped = serverBoardURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        webView.evaluateJavaScript("window.__swiftmaestro_loadFile('\(escaped)')")
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(self)
        // Watch for agent-tool edits to a board on disk. If they touch the
        // board currently open in THIS webview, reload it so the user sees
        // the live update. If `shouldOpen` is true, switch this webview to
        // the affected board first — this lets agent-created boards replace
        // whatever blank/existing board was already open.
        coordinator.externalModificationObserver = NotificationCenter.default.addObserver(
            forName: .excalidrawBoardExternallyModified,
            object: nil,
            queue: .main
        ) { [weak coordinator] note in
            guard let boardURL = note.userInfo?["boardURL"] as? URL else { return }
            let shouldOpen = note.userInfo?["shouldOpen"] as? Bool ?? false
            Task { @MainActor in
                guard let coordinator,
                      let webView = coordinator.bridge?.webView
                else { return }
                if shouldOpen, coordinator.parent.currentFileURL?.standardizedFileURL != boardURL.standardizedFileURL {
                    coordinator.parent.currentFileURL = boardURL
                    coordinator.parent.fileName = boardURL.deletingPathExtension().lastPathComponent
                    coordinator.parent.isEdited = false
                    coordinator.lastLoadedFileURL = nil
                    coordinator.parent.loadCurrentBoard(into: webView, coordinator: coordinator)
                } else if coordinator.parent.currentFileURL?.standardizedFileURL == boardURL.standardizedFileURL {
                    coordinator.lastLoadedFileURL = nil
                    coordinator.parent.loadCurrentBoard(into: webView, coordinator: coordinator)
                }
            }
        }
        return coordinator
    }

    /// JS snippet that forwards console.* messages to the Swift bridge as "console" events.
    private static var consoleCaptureScript: String {
        """
        (function() {
            const levels = ['log', 'info', 'warn', 'error', 'debug'];
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.excalidrawBridge;
            levels.forEach(function(level) {
                const original = console[level];
                console[level] = function() {
                    if (bridge) {
                        try {
                            const message = Array.from(arguments).map(function(arg) {
                                if (arg instanceof Error) return arg.name + ': ' + arg.message + '\\n' + (arg.stack || '');
                                if (typeof arg === 'object') {
                                    try { return JSON.stringify(arg); } catch (e) { return String(arg); }
                                }
                                return String(arg);
                            }).join(' ');
                            bridge.postMessage({ type: 'console', level: level, message: message });
                        } catch (e) {}
                    }
                    if (original) original.apply(console, arguments);
                };
            });
            window.addEventListener('error', function(event) {
                if (bridge) {
                    try {
                        bridge.postMessage({ type: 'console', level: 'error', message: 'Uncaught error: ' + (event.message || '') + ' at ' + (event.filename || '') + ':' + (event.lineno || 0) });
                    } catch (e) {}
                }
            });
            window.addEventListener('unhandledrejection', function(event) {
                if (bridge) {
                    try {
                        const reason = event.reason instanceof Error ? event.reason.message : String(event.reason);
                        bridge.postMessage({ type: 'console', level: 'error', message: 'Unhandled promise rejection: ' + reason });
                    } catch (e) {}
                }
            });
        })();
        """
    }

    /// Hides Excalidraw UI that points to external services or features that don't work
    /// inside SwiftMaestro (Excalidraw+, GitHub, live collab, sign-up nags, etc.).
    /// Also intercepts "Text to diagram" and "Wireframe to code" menu items and
    /// routes them to Maestro's local AI instead of Excalidraw's cloud AI.
    private static var hideExternalMenuItemsScript: String {
        """
        (function() {
            const externalLabels = ['Excalidraw+', 'GitHub', 'Follow us', 'Discord chat', 'Sign up', 'Live collaboration...'];

            function hidePromotionalItems() {
                // Only hide the specific clickable/menu items whose own text matches an
                // external label. Do not hide parent containers, or the hamburger menu
                // itself will stop opening.
                const selectors = 'button, a, [role="menuitem"], [role="button"]';
                document.querySelectorAll(selectors).forEach(function(el) {
                    const text = (el.textContent || '').trim();
                    if (externalLabels.includes(text)) {
                        el.style.display = 'none';
                        el.setAttribute('aria-hidden', 'true');
                    }
                });
            }

            // Capture clicks on AI-powered menu items before React's handler runs.
            document.addEventListener('click', function(e) {
                const el = e.target.closest('button, a, [role="menuitem"], [role="button"]');
                if (!el) return;
                const text = (el.textContent || '').trim();
                if (text === 'Text to diagram') {
                    e.preventDefault();
                    e.stopPropagation();
                    window.__swiftmaestro.postMessage('textToDiagram', {});
                    return false;
                }
                if (text === 'Wireframe to code') {
                    e.preventDefault();
                    e.stopPropagation();
                    window.__swiftmaestro.postMessage('wireframeToCode', {});
                    return false;
                }
            }, true);

            const observer = new MutationObserver(function() { hidePromotionalItems(); });
            observer.observe(document.body, { childList: true, subtree: true });
            hidePromotionalItems();
        })();
        """
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ExcalidrawWebView
        var bridge: ExcalidrawBridge?
        var lastLoadedFileURL: URL?
        var lastLoadedServerURL: URL?
        var lastSeenServerURL: URL?
        var externalModificationObserver: NSObjectProtocol?

        init(_ parent: ExcalidrawWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject theme sync
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            webView.evaluateJavaScript("document.documentElement.classList.toggle('dark', \(isDark))")

            // If we have a file to load, send it via the local HTTP server.
            parent.loadCurrentBoard(into: webView, coordinator: self)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[Excalidraw] navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[Excalidraw] provisional navigation failed: \(error.localizedDescription)")
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

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Excalidraw uses window.open for some menu links. Open them in the system browser.
            if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            completionHandler(nil)
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
        case "console":
            if let level = body["level"] as? String,
               let message = body["message"] as? String {
                let prefix = "[Excalidraw JS \(level)]"
                NSLog("\(prefix) \(message)")
            }
        case "textToDiagram":
            Task { @MainActor in
                coordinator?.parent.onTextToDiagram()
            }
        case "wireframeToCode":
            Task { @MainActor in
                coordinator?.parent.onWireframeToCode()
            }
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

// MARK: - View / WebView helpers

extension WKWebView {
    /// Evaluates JavaScript and suspends until a string result (or an error) returns.
    /// Non-string results are returned as nil without error.
    func evaluateJavaScriptAsync(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String)
                }
            }
        }
    }
}


