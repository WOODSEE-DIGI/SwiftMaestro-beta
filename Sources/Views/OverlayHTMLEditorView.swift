import SwiftUI
import WebKit

// MARK: - HTML/CSS Editor (WYSIWYG)

/// A split-pane WYSIWYG editor for HTML/CSS. The left pane is a
/// code editor (tabbed HTML / CSS), the right pane is a live WKWebView
/// preview that re-renders on every keystroke. Exports to transparent PNG
/// via WKWebView snapshot.
struct OverlayHTMLEditorView: View {
    @State private var store = OverlayBuilderStore.shared
    @State private var htmlSource: String = Self.defaultHTML
    @State private var cssSource: String = Self.defaultCSS
    @State private var selectedTab: CodeTab = .html
    @State private var fontSize: Double = 13
    @State private var showPreview = true
    @State private var exportAlertMessage: String?
    @State private var pendingInsert: String?

    enum CodeTab: String, CaseIterable {
        case html = "HTML"
        case css = "CSS"
    }

    // MARK: - Default Templates

    static let defaultHTML = """
    <div class="overlay">
      <div class="accent-bar"></div>
      <div class="content">
        <div class="title">Your Title Here</div>
        <div class="subtitle">Subtitle text goes here</div>
      </div>
    </div>
    """

    static let defaultCSS = """
    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif;
      background: transparent;
      width: 1920px;
      height: 1080px;
      overflow: hidden;
    }

    .overlay {
      position: absolute;
      left: 60px;
      bottom: 80px;
      display: flex;
      flex-direction: row;
      align-items: stretch;
      gap: 0;
    }

    .accent-bar {
      width: 5px;
      background: #7c3aed;
      border-radius: 3px 0 0 3px;
    }

    .content {
      background: rgba(12, 12, 18, 0.92);
      border: 1px solid rgba(124, 58, 237, 0.3);
      border-left: none;
      border-radius: 0 10px 10px 0;
      padding: 18px 28px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .title {
      color: #ffffff;
      font-size: 34px;
      font-weight: 600;
      letter-spacing: -0.3px;
    }

    .subtitle {
      color: rgba(255, 255, 255, 0.7);
      font-size: 16px;
      font-weight: 400;
    }
    """

    // MARK: - Template Gallery

    struct Template {
        let name: String
        let icon: String
        let html: String
        let css: String
    }

    static let templates: [Template] = [
        Template(
            name: "Title Card",
            icon: "rectangle.split.2x2",
            html: """
            <div class="title-card">
              <div class="tagline">PRESENTED BY</div>
              <div class="title">Your Title Here</div>
              <div class="subtitle">Subtitle goes here</div>
              <div class="accent-line"></div>
            </div>
            """,
            css: """
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, "SF Pro Display", sans-serif; background: transparent; width: 1920px; height: 1080px; overflow: hidden; }
            .title-card { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); text-align: center; }
            .tagline { color: rgba(255,255,255,0.5); font-size: 14px; letter-spacing: 6px; text-transform: uppercase; margin-bottom: 16px; }
            .title { color: #fff; font-size: 80px; font-weight: 800; letter-spacing: -2px; line-height: 1.05; }
            .subtitle { color: rgba(255,255,255,0.7); font-size: 24px; font-weight: 400; margin-top: 12px; }
            .accent-line { width: 60px; height: 4px; background: #7c3aed; border-radius: 2px; margin: 24px auto 0; }
            """
        ),
        Template(
            name: "Lower Third",
            icon: "rectangle.bottomthird.inset.filled",
            html: """
            <div class="lower-third">
              <div class="accent-bar"></div>
              <div class="content">
                <div class="name">John Doe</div>
                <div class="role">Creative Director</div>
              </div>
            </div>
            """,
            css: """
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, "SF Pro Display", sans-serif; background: transparent; width: 1920px; height: 1080px; overflow: hidden; }
            .lower-third { position: absolute; left: 60px; bottom: 80px; display: flex; flex-direction: row; align-items: stretch; }
            .accent-bar { width: 5px; background: #3b82f6; border-radius: 3px 0 0 3px; }
            .content { background: rgba(12,12,18,0.92); border: 1px solid rgba(59,130,246,0.3); border-left: none; border-radius: 0 10px 10px 0; padding: 18px 28px; display: flex; flex-direction: column; gap: 4px; }
            .name { color: #fff; font-size: 34px; font-weight: 600; }
            .role { color: rgba(255,255,255,0.7); font-size: 16px; }
            """
        ),
        Template(
            name: "Info Grid",
            icon: "square.grid.2x2",
            html: """
            <div class="grid">
              <div class="card"><div class="icon">🚀</div><div class="card-title">Speed</div><div class="card-text">Lightning fast performance</div></div>
              <div class="card"><div class="icon">🔒</div><div class="card-title">Secure</div><div class="card-text">End-to-end encryption</div></div>
              <div class="card"><div class="icon">🎨</div><div class="card-title">Design</div><div class="card-text">Beautiful interfaces</div></div>
              <div class="card"><div class="icon">⚡</div><div class="card-title">Power</div><div class="card-text">Enterprise grade</div></div>
            </div>
            """,
            css: """
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, "SF Pro Display", sans-serif; background: transparent; width: 1920px; height: 1080px; overflow: hidden; }
            .grid { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px; }
            .card { background: rgba(12,12,18,0.88); border: 1px solid rgba(255,255,255,0.1); border-radius: 16px; padding: 32px; width: 380px; }
            .icon { font-size: 40px; margin-bottom: 12px; }
            .card-title { color: #fff; font-size: 24px; font-weight: 600; margin-bottom: 8px; }
            .card-text { color: rgba(255,255,255,0.6); font-size: 16px; line-height: 1.4; }
            """
        ),
        Template(
            name: "Alert Banner",
            icon: "exclamationmark.triangle.fill",
            html: """
            <div class="alert">
              <div class="alert-icon">⚠️</div>
              <div class="alert-content">
                <div class="alert-title">Breaking News</div>
                <div class="alert-subtitle">This is an important announcement</div>
              </div>
            </div>
            """,
            css: """
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, "SF Pro Display", sans-serif; background: transparent; width: 1920px; height: 1080px; overflow: hidden; }
            .alert { position: absolute; top: 0; left: 0; right: 0; display: flex; align-items: center; gap: 16px; background: rgba(220,38,38,0.95); padding: 20px 40px; }
            .alert-icon { font-size: 28px; }
            .alert-title { color: #fff; font-size: 22px; font-weight: 700; }
            .alert-subtitle { color: rgba(255,255,255,0.8); font-size: 15px; margin-top: 2px; }
            """
        ),
        Template(
            name: "Social Card",
            icon: "person.crop.rectangle.stack",
            html: """
            <div class="social-card">
              <div class="avatar">👤</div>
              <div class="info">
                <div class="handle">@username</div>
                <div class="followers">12.4K followers</div>
              </div>
              <div class="follow-btn">Follow</div>
            </div>
            """,
            css: """
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, "SF Pro Display", sans-serif; background: transparent; width: 1920px; height: 1080px; overflow: hidden; }
            .social-card { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); display: flex; align-items: center; gap: 20px; background: rgba(12,12,18,0.92); border: 1px solid rgba(255,255,255,0.1); border-radius: 16px; padding: 24px 32px; }
            .avatar { width: 64px; height: 64px; border-radius: 50%; background: rgba(255,255,255,0.1); display: flex; align-items: center; justify-content: center; font-size: 32px; }
            .info { margin-right: 24px; }
            .handle { color: #fff; font-size: 20px; font-weight: 600; }
            .followers { color: rgba(255,255,255,0.6); font-size: 14px; margin-top: 4px; }
            .follow-btn { background: #3b82f6; color: #fff; font-size: 16px; font-weight: 600; padding: 10px 28px; border-radius: 24px; }
            """
        ),
    ]

    // MARK: - HTML Snippets

    static let htmlSnippets: [(name: String, icon: String, snippet: String)] = [
        ("Div Container", "rectangle", "<div class=\"container\">\n  \n</div>"),
        ("Section", "rectangle.split.3x1", "<section>\n  \n</section>"),
        ("Header", "text.justify.leading", "<header>\n  \n</header>"),
        ("Footer", "text.justify.trailing", "<footer>\n  \n</footer>"),
        ("Nav", "menubar", "<nav>\n  \n</nav>"),
        ("Heading 1", "textformat.size.larger", "<h1>Title</h1>"),
        ("Heading 2", "textformat.size", "<h2>Subtitle</h2>"),
        ("Heading 3", "textformat.size.smaller", "<h3>Section</h3>"),
        ("Paragraph", "doc.text", "<p>Text goes here</p>"),
        ("Span", "textformat.abc", "<span class=\"highlight\">text</span>"),
        ("Image", "photo", "<img src=\"\" alt=\"Description\" />"),
        ("Video", "film", "<video src=\"\" controls></video>"),
        ("Figure", "photo.on.rectangle", "<figure>\n  <img src=\"\" alt=\"\" />\n  <figcaption>Caption</figcaption>\n</figure>"),
        ("Table", "tablecells", "<table>\n  <tr>\n    <td></td>\n  </tr>\n</table>"),
        ("Unordered List", "list.bullet", "<ul>\n  <li>Item</li>\n</ul>"),
        ("Ordered List", "list.number", "<ol>\n  <li>Item</li>\n</ol>"),
        ("Form", "text.cursor", "<form>\n  <input type=\"text\" placeholder=\"Name\" />\n  <button type=\"submit\">Submit</button>\n</form>"),
        ("Input", "textfield", "<input type=\"text\" placeholder=\"Enter text\" />"),
        ("Button", "rectangle.and.hand.point.up.left", "<button>Click me</button>"),
        ("Iframe", "globe", "<iframe src=\"\" width=\"100%\" height=\"400\"></iframe>"),
        ("SVG", "scribble", "<svg viewBox=\"0 0 100 100\" width=\"100\" height=\"100\">\n  <circle cx=\"50\" cy=\"50\" r=\"40\" fill=\"#7c3aed\" />\n</svg>"),
        ("Canvas", "rectangle.dashed", "<canvas id=\"myCanvas\" width=\"800\" height=\"600\"></canvas>"),
        ("Line Break", "return", "<br />"),
        ("Horizontal Rule", "minus", "<hr />"),
        ("Div with Class", "rectangle.on.rectangle", "<div class=\"custom\">\n  \n</div>"),
        ("Link", "link", "<a href=\"https://example.com\">Link text</a>"),
    ]

    // MARK: - CSS Snippets

    static let cssSnippets: [(name: String, icon: String, snippet: String)] = [
        ("Flex Center", "rectangle.center.inset.filled", "display: flex;\njustify-content: center;\nalign-items: center;"),
        ("Flex Row", "rectangle.split.3x1", "display: flex;\nflex-direction: row;\ngap: 16px;"),
        ("Grid 2 Col", "square.grid.2x2", "display: grid;\ngrid-template-columns: repeat(2, 1fr);\ngap: 16px;"),
        ("Grid 3 Col", "square.grid.3x2", "display: grid;\ngrid-template-columns: repeat(3, 1fr);\ngap: 16px;"),
        ("Absolute Center", "scope", "position: absolute;\ntop: 50%;\nleft: 50%;\ntransform: translate(-50%, -50%);"),
        ("Glass Morphism", "circle.hexagongrid", "backdrop-filter: blur(10px);\nbackground: rgba(255, 255, 255, 0.1);\nborder: 1px solid rgba(255, 255, 255, 0.2);"),
        ("Box Shadow", "square.and.line.vertical.and.square", "box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);"),
        ("Text Gradient", "character.textbox", "background: linear-gradient(135deg, #7c3aed, #3b82f6);\n-webkit-background-clip: text;\n-webkit-text-fill-color: transparent;"),
        ("Transition", "arrow.triangle.2.circlepath", "transition: all 0.3s ease;"),
        ("Rounded", "rectangle.roundedtop", "border-radius: 12px;"),
        ("Pill Shape", "capsule", "border-radius: 9999px;"),
        ("Text Overflow", "text.append", "overflow: hidden;\nwhite-space: nowrap;\ntext-overflow: ellipsis;"),
        ("Border", "rectangle.dashed", "border: 1px solid rgba(255, 255, 255, 0.15);"),
        ("Gradient BG", "rectangle.gradientdx", "background: linear-gradient(135deg, #1a1a2e, #16213e);"),
        ("Fixed Size", "arrow.up.left.and.arrow.down.right", "width: 300px;\nheight: 200px;"),
        ("Z-Index", "rectangle.stack", "z-index: 10;"),
        ("Font Size", "textformat.size", "font-size: 16px;"),
        ("Letter Spacing", "textformat.abc", "letter-spacing: 2px;"),
        ("Line Height", "text.justify", "line-height: 1.6;"),
        ("Padding", "rectangle.and.hand.point.up.left", "padding: 16px 24px;"),
        ("Margin Auto", "rectangle.center.inset.filled", "margin: 0 auto;"),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Inline toolbar (replaces SwiftUI .toolbar which needs NavigationView) ──
            HStack(spacing: 8) {
                Toggle(isOn: $showPreview) {
                    Label("Preview", systemImage: "eye")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Divider().frame(height: 16)

                // HTML Snippets
                Menu {
                    ForEach(Self.htmlSnippets, id: \.name) { item in
                        Button {
                            pendingInsert = item.snippet
                            if selectedTab != .html { selectedTab = .html }
                        } label: {
                            Label(item.name, systemImage: item.icon)
                        }
                    }
                } label: {
                    Label("Snippets", systemImage: "text.badge.plus")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)

                // CSS Helpers
                Menu {
                    ForEach(Self.cssSnippets, id: \.name) { item in
                        Button {
                            pendingInsert = item.snippet
                            if selectedTab != .css { selectedTab = .css }
                        } label: {
                            Label(item.name, systemImage: item.icon)
                        }
                    }
                } label: {
                    Label("CSS", systemImage: "paintbrush")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)

                // Template Gallery
                Menu {
                    ForEach(Self.templates, id: \.name) { tpl in
                        Button {
                            htmlSource = tpl.html
                            cssSource = tpl.css
                        } label: {
                            Label(tpl.name, systemImage: tpl.icon)
                        }
                    }
                } label: {
                    Label("Template", systemImage: "doc.text")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)

                Divider().frame(height: 16)

                // Copy HTML
                Button {
                    let combined = """
                    <!DOCTYPE html>
                    <html><head><style>
                    \(cssSource)
                    </style></head><body>
                    \(htmlSource)
                    </body></html>
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(combined, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .help("Copy HTML + CSS to clipboard")

                // Format
                Button {
                    htmlSource = Self.beautifyHTML(htmlSource)
                    cssSource = Self.beautifyCSS(cssSource)
                } label: {
                    Label("Format", systemImage: "text.justify.left")
                        .font(.caption)
                }
                .help("Auto-format code")

                Spacer()

                // Export
                Button("Export PNG") { exportPNG() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            // ── Content ──
            HSplitView {
                // ── Code editor pane ──
                codeEditorPane
                    .frame(minWidth: 280, idealWidth: 420, maxWidth: 600)

                // ── Live preview pane ──
                if showPreview {
                    previewPane
                        .frame(minWidth: 300)
                }
            }
        }
        .alert("Export", isPresented: Binding(
            get: { exportAlertMessage != nil },
            set: { if !$0 { exportAlertMessage = nil } }
        )) {
            Button("OK") { exportAlertMessage = nil }
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    // MARK: - Code Editor Pane

    private var codeEditorPane: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(CodeTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.caption)
                            .fontWeight(selectedTab == tab ? .semibold : .regular)
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                selectedTab == tab
                                    ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.15))
                                    : nil
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Font size control
                HStack(spacing: 4) {
                    Button { fontSize = max(10, fontSize - 1) } label: {
                        Image(systemName: "minus")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(fontSize))")
                        .font(.caption2)
                        .monospacedDigit()
                        .frame(width: 20)

                    Button { fontSize = min(24, fontSize + 1) } label: {
                        Image(systemName: "plus")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)

            Divider()

            // Code editor
            CodeTextView(
                text: selectedTab == .html ? $htmlSource : $cssSource,
                fontSize: fontSize,
                language: selectedTab == .html ? "html" : "css",
                pendingInsert: $pendingInsert
            )
        }
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        GeometryReader { geo in
            // Dark work area
            Color(white: 0.10)
                .ignoresSafeArea()

            let margin: CGFloat = 24
            let maxW = geo.size.width - margin * 2
            let maxH = geo.size.height - margin * 2
            let scale = min(maxW / CGFloat(store.canvasWidth), maxH / CGFloat(store.canvasHeight))
            let dispW = CGFloat(store.canvasWidth) * scale
            let dispH = CGFloat(store.canvasHeight) * scale

            // Canvas frame
            ZStack {
                // Drop shadow
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: dispW + 2, height: dispH + 2)
                    .offset(x: 2, y: 2)

                // Canvas background (transparent for HTML overlays)
                Rectangle()
                    .fill(Color(white: 0.04))
                    .frame(width: dispW, height: dispH)

                // WKWebView preview
                HTMLPreviewWebView(
                    htmlSource: htmlSource,
                    cssSource: cssSource,
                    canvasWidth: store.canvasWidth,
                    canvasHeight: store.canvasHeight
                )
                .frame(width: dispW, height: dispH)
                .clipShape(Rectangle())

                // Border
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5)
                    .frame(width: dispW, height: dispH)

                // Dimension label
                Text("\(store.canvasWidth) × \(store.canvasHeight)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .position(x: dispW / 2, y: dispH + 18)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    // MARK: - Export

    private func exportPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "html-overlay-\(store.canvasWidth)x\(store.canvasHeight).png"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            // Snapshot the WKWebView via JavaScript
            Task { @MainActor in
                guard let data = await HTMLSnapshotService.snapshot(
                    html: htmlSource, css: cssSource,
                    width: store.canvasWidth, height: store.canvasHeight
                ) else {
                    exportAlertMessage = "Could not render the HTML overlay as a PNG."
                    return
                }
                do {
                    try data.write(to: url)
                } catch {
                    exportAlertMessage = "Couldn't save the PNG: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Code Formatting

    /// Basic HTML beautifier: ensures proper newline indentation.
    static func beautifyHTML(_ input: String) -> String {
        var result = ""
        var indent = 0
        // Simple tag-level reindent
        for line in input.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Closing tag → decrease indent before printing
            if trimmed.hasPrefix("</") || trimmed.hasPrefix("<!--") {
                indent = max(0, indent - 1)
            }
            result += String(repeating: "  ", count: indent) + trimmed + "\n"
            // Opening tag (not self-closing, not closing, not comment)
            if trimmed.hasPrefix("<") && !trimmed.hasPrefix("</") && !trimmed.hasPrefix("<!") && !trimmed.hasSuffix("/>") {
                indent += 1
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Basic CSS beautifier: one property per line, normalize spacing.
    static func beautifyCSS(_ input: String) -> String {
        var result = ""
        var indent = 0
        for line in input.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("}") {
                indent = max(0, indent - 1)
            }
            result += String(repeating: "  ", count: indent) + trimmed + "\n"
            if trimmed.hasSuffix("{") {
                indent += 1
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WKWebView Preview

/// Wraps a WKWebView that renders the combined HTML+CSS and re-renders
/// on every source change (debounced 300ms to avoid hammering the web view).
struct HTMLPreviewWebView: NSViewRepresentable {
    let htmlSource: String
    let cssSource: String
    let canvasWidth: Int
    let canvasHeight: Int

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")  // transparent background
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Debounce rapid updates
        context.coordinator.pendingHTML = htmlSource
        context.coordinator.pendingCSS = cssSource
        context.coordinator.scheduleUpdate(webView: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate {
        var pendingHTML = ""
        var pendingCSS = ""
        private var updateTask: Task<Void, Never>?

        func scheduleUpdate(webView: WKWebView) {
            updateTask?.cancel()
            updateTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                let html = Self.wrapHTML(html: pendingHTML, css: pendingCSS)
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        static func wrapHTML(html: String, css: String) -> String {
            """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
            \(css)
            </style>
            </head>
            <body>
            \(html)
            </body>
            </html>
            """
        }
    }
}

// MARK: - HTML Snapshot Service

/// Renders HTML+CSS to PNG via a headless WKWebView at exact canvas pixel size.
enum HTMLSnapshotService {
    static func snapshot(html: String, css: String, width: Int, height: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let config = WKWebViewConfiguration()
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
                webView.setValue(false, forKey: "drawsBackground")

                let wrappedHTML = HTMLPreviewWebView.Coordinator.wrapHTML(html: html, css: css)

                // Load and wait for finish, then snapshot
                let delegate = SnapshotDelegate(webView: webView, continuation: continuation)
                webView.navigationDelegate = delegate
                objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
                webView.loadHTMLString(wrappedHTML, baseURL: nil)
            }
        }
    }

    private class SnapshotDelegate: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        let continuation: CheckedContinuation<Data?, Never>

        init(webView: WKWebView, continuation: CheckedContinuation<Data?, Never>) {
            self.webView = webView
            self.continuation = continuation
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Take a bitmap snapshot at native resolution
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: webView.bounds.height)
            config.snapshotWidth = NSNumber(value: Int(webView.bounds.width))

            webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    self.continuation.resume(returning: nil)
                    return
                }
                self.continuation.resume(returning: png)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation.resume(returning: nil)
        }
    }
}

// MARK: - Code Text Editor (AppKit NSTextView wrapper)

/// A syntax-highlighted code editor wrapping NSTextView with monospaced font.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let language: String
    @Binding var pendingInsert: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.controlBackgroundColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isEditable = true
        textView.isSelectable = true

        // Line numbers via line gutters (basic: just set up the text view)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Coordinator handles text changes
        textView.delegate = context.coordinator

        // Set initial text
        textView.string = text

        // Syntax highlighting
        highlightSyntax(textView, language: language)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        // Only update if text actually changed externally (not from user typing)
        if textView.string != text && context.coordinator.isExternalUpdate {
            textView.string = text
            highlightSyntax(textView, language: language)
            context.coordinator.isExternalUpdate = false
        }
        // Update font size
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Handle pending snippet insertion at cursor
        if let snippet = pendingInsert {
            let cursor = textView.selectedRange
            textView.insertText(snippet, replacementRange: cursor)
            highlightSyntax(textView, language: language)
            pendingInsert = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeTextView
        var isExternalUpdate = false

        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.highlightSyntax(textView, language: parent.language)
        }
    }

    /// Lightweight syntax highlighting via NSAttributedString.
    private func highlightSyntax(_ textView: NSTextView, language: String) {
        let text = textView.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        // Start with base attributes
        let baseColor = NSColor.labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: baseColor
        ]
        let attrStr = NSMutableAttributedString(string: text, attributes: attrs)

        // Keywords / tags (simple regex-based)
        let tagPattern = "</?[a-zA-Z][a-zA-Z0-9]*"
        let attributePattern = #"[a-zA-Z-]+="#
        let stringPattern = #""[^"]*""#
        let commentPattern = #"<!--[\s\S]*?-->"#
        let cssPropertyPattern = #"^[\s]*[a-zA-Z-]+(?=\s*:)"#
        let cssValuePattern = #":\s*[^;]+"#
        let numberPattern = #"\b\d+(\.\d+)?(px|em|rem|%|vh|vw|s|ms)?\b"#
        let colorPattern = #"#[0-9a-fA-F]{3,8}"#

        func applyPattern(_ pattern: String, color: NSColor) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                attrStr.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        if language == "html" {
            applyPattern(tagPattern, color: NSColor.systemPink)
            applyPattern(attributePattern, color: NSColor.systemCyan)
            applyPattern(stringPattern, color: NSColor.systemGreen)
            applyPattern(commentPattern, color: NSColor.secondaryLabelColor)
        } else {
            applyPattern(cssPropertyPattern, color: NSColor.systemCyan)
            applyPattern(stringPattern, color: NSColor.systemGreen)
            applyPattern(numberPattern, color: NSColor.systemOrange)
            applyPattern(colorPattern, color: NSColor.systemYellow)
        }

        // Preserve the cursor position
        let cursor = textView.selectedRange
        textView.textStorage?.setAttributedString(attrStr)
        textView.selectedRange = cursor
    }
}
