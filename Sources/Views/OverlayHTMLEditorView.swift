import SwiftUI
import WebKit

// MARK: - HTML/CSS Editor (WYSIWYG)

/// A split-pane WYSIWYG editor for HTML/CSS. The left pane is a
/// code editor (tabbed HTML / CSS), the right pane is a live WKWebView
/// preview that re-renders on every keystroke. Exports to transparent PNG
/// via WKWebView snapshot.
struct OverlayHTMLEditorView: View {
    @State private var store = OverlayBuilderStore.shared
    @State private var selectedTab: CodeTab = .html
    @State private var fontSize: Double = 13
    @State private var viewMode: ViewMode = .split
    @State private var cursorLocation: Int = 0
    @State private var exportAlertMessage: String?
    @State private var pendingInsert: String?

    /// Dreamweaver's signature Code / Split / Design modes.
    enum ViewMode: String, CaseIterable {
        case code = "Code"
        case split = "Split"
        case design = "Design"
    }

    enum CodeTab: String, CaseIterable {
        case html = "HTML"
        case css = "CSS"
    }

    // MARK: - Default Templates

    static let defaultHTML = OverlayHTMLEditorDefaults.html
    static let defaultCSS = OverlayHTMLEditorDefaults.css

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
                // Dreamweaver's signature view-mode switch
                Picker(selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)

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

                // Template Gallery — overlay starters + full website templates
                Menu {
                    Section("Websites") {
                        ForEach(WebsiteTemplates.all) { tpl in
                            Button {
                                store.applyWebsiteTemplate(tpl)
                            } label: {
                                Label(tpl.name, systemImage: tpl.icon)
                            }
                        }
                    }
                    Section("Overlays") {
                        ForEach(Self.templates, id: \.name) { tpl in
                            Button {
                                store.htmlEditorSource = tpl.html
                                store.cssEditorSource = tpl.css
                            } label: {
                                Label(tpl.name, systemImage: tpl.icon)
                            }
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
                    \(store.cssEditorSource)
                    </style></head><body>
                    \(store.htmlEditorSource)
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
                    store.htmlEditorSource = Self.beautifyHTML(store.htmlEditorSource)
                    store.cssEditorSource = Self.beautifyCSS(store.cssEditorSource)
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

            // ── Insert bar (Dreamweaver-style quick elements) ──
            insertBar

            // ── Content: Code / Split / Design ──
            switch viewMode {
            case .code:
                codeEditorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .design:
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .split:
                HSplitView {
                    codeEditorPane
                        .frame(minWidth: 280, idealWidth: 420, maxWidth: 600)
                    previewPane
                        .frame(minWidth: 300)
                }
            }

            // ── CSS variables panel (Dreamweaver Properties inspector) ──
            if !cssVariables.isEmpty {
                cssVariablesPanel
            }

            // ── Status bar: tag breadcrumb + document stats ──
            statusBar
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
                text: selectedTab == .html ? $store.htmlEditorSource : $store.cssEditorSource,
                fontSize: fontSize,
                language: selectedTab == .html ? "html" : "css",
                pendingInsert: $pendingInsert,
                cursorLocation: $cursorLocation
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
                    htmlSource: store.htmlEditorSource,
                    cssSource: store.cssEditorSource,
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

    // MARK: - Insert Bar (Dreamweaver quick elements)

    /// Common elements, one click inserts at cursor. Grouped like
    /// Dreamweaver's Insert bar: structure, text, media, forms.
    static let insertBarItems: [(name: String, icon: String, snippet: String)] = [
        ("div", "square.dashed", "<div class=\"\">\n  \n</div>"),
        ("p", "text.alignleft", "<p></p>"),
        ("a", "link", "<a href=\"#\"></a>"),
        ("img", "photo", "<img src=\"\" alt=\"\">"),
        ("h1", "textformat.size.larger", "<h1></h1>"),
        ("ul", "list.bullet", "<ul>\n  <li></li>\n</ul>"),
        ("table", "tablecells", "<table>\n  <tr><th></th></tr>\n  <tr><td></td></tr>\n</table>"),
        ("form", "rectangle.and.pencil.and.ellipsis", "<form>\n  <input type=\"text\" name=\"\">\n  <button type=\"submit\">Send</button>\n</form>"),
        ("video", "play.rectangle", "<video controls width=\"100%\">\n  <source src=\"\" type=\"video/mp4\">\n</video>"),
        ("br", "return", "<br>"),
        ("hr", "minus", "<hr>"),
        ("!--", "text.bubble", "<!--  -->"),
    ]

    private var insertBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("INSERT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                ForEach(Self.insertBarItems, id: \.name) { item in
                    Button {
                        pendingInsert = item.snippet
                        if selectedTab != .html { selectedTab = .html }
                        if viewMode == .design { viewMode = .split }
                    } label: {
                        Label(item.name, systemImage: item.icon)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Insert <\(item.name)> at cursor")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    // MARK: - Status Bar (tag breadcrumb + stats)

    /// Dreamweaver's tag selector: walks the HTML up to the cursor and
    /// reports the open-tag stack, e.g. body > div.container > p.
    private var tagBreadcrumb: String {
        guard selectedTab == .html else { return "css" }
        let source = store.htmlEditorSource
        let upto = min(cursorLocation, source.count)
        let prefix = String(source.prefix(upto))
        var stack: [String] = []
        var i = prefix.startIndex
        while i < prefix.endIndex {
            if prefix[i] == "<", let close = prefix[i...].firstIndex(of: ">") {
                let tag = prefix[prefix.index(after: i)..<close]
                let t = tag.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("/") {
                    let name = String(t.dropFirst()).split(separator: " ").first.map(String.init) ?? ""
                    if let idx = stack.lastIndex(where: { $0.hasPrefix(name) }) {
                        stack.removeSubrange(idx...)
                    }
                } else if !t.hasPrefix("!") && !t.hasSuffix("/") {
                    let name = t.split(separator: " ").first.map(String.init) ?? t
                    let cls = t.range(of: "class=\"([^\"]*)\"", options: .regularExpression)
                        .map { String(t[$0]).replacingOccurrences(of: "class=\"", with: "").replacingOccurrences(of: "\"", with: "").split(separator: " ").first.map(String.init) ?? "" } ?? ""
                    if !["br", "hr", "img", "input", "meta", "link", "source"].contains(name) {
                        stack.append(cls.isEmpty ? name : "\(name).\(cls)")
                    }
                }
                i = prefix.index(after: close)
            } else {
                i = prefix.index(after: i)
            }
        }
        return stack.isEmpty ? "body" : stack.joined(separator: " › ")
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Tag breadcrumb (Dreamweaver tag selector)
            Text(tagBreadcrumb)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // Doc stats
            let src = selectedTab == .html ? store.htmlEditorSource : store.cssEditorSource
            Text("\(src.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text("\(src.utf8.count) bytes")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text("\(store.canvasWidth)×\(store.canvasHeight)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - CSS Variables Panel (Properties inspector)

    /// A CSS custom property found in the current document.
    private struct CSSVariable: Identifiable {
        let name: String      // e.g. "--sprite"
        let hex: String       // current #rrggbb value
        var id: String { name }
    }

    /// Scans the CSS source for `--name: #hex` declarations, then for
    /// `var(--name, #hex)` fallbacks in both CSS and HTML (the Meme Lab
    /// templates declare colors only as fallbacks). First occurrence wins.
    private var cssVariables: [CSSVariable] {
        var found: [CSSVariable] = []
        var seen = Set<String>()

        // 1. Declarations: --name: #hex;
        for match in store.cssEditorSource.matches(of: #/(--[a-zA-Z0-9-]+)\s*:\s*(#[0-9a-fA-F]{3,8})/#) {
            let name = String(match.1)
            if !seen.contains(name) {
                seen.insert(name)
                found.append(CSSVariable(name: name, hex: String(match.2)))
            }
        }
        // 2. Fallbacks: var(--name, #hex) — covers templates that never
        //    declare the variable, only consume it with a default.
        for source in [store.cssEditorSource, store.htmlEditorSource] {
            for match in source.matches(of: #/var\((--[a-zA-Z0-9-]+)\s*,\s*(#[0-9a-fA-F]{3,8})\)/#) {
                let name = String(match.1)
                if !seen.contains(name) {
                    seen.insert(name)
                    found.append(CSSVariable(name: name, hex: String(match.2)))
                }
            }
        }
        return found
    }

    private var cssVariablesPanel: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Text("COLORS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    ForEach(cssVariables) { v in
                        HStack(spacing: 6) {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: v.hex) ?? .white },
                                set: { setCSSVariable(v.name, hex: $0.hexString) }
                            ))
                            .labelsHidden()
                            .frame(width: 22, height: 22)
                            Text(v.name.replacingOccurrences(of: "--", with: ""))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }

    /// Rewrites the variable's color in the source. Targets the declaration
    /// `--name: #old` first; if absent, rewrites every `var(--name, #old)`
    /// fallback in CSS and HTML so the preview always reflects the pick.
    private func setCSSVariable(_ name: String, hex: String) {
        let escaped = NSRegularExpression.escapedPattern(for: name)

        // Declaration: --name: #oldhex -> --name: #newhex
        let declPattern = NSRegularExpression.escapedPattern(for: name) + #"\s*:\s*#[0-9a-fA-F]{3,8}"#
        if let matchRange = store.cssEditorSource.range(of: declPattern, options: .regularExpression),
           let hexStart = store.cssEditorSource[matchRange].firstIndex(of: "#") {
            store.cssEditorSource.replaceSubrange(hexStart..<matchRange.upperBound, with: hex)
            return
        }
        // Fallback: var(--name, #old) -> var(--name, #new) — rewrite all.
        let fbPattern = #"var\("# + escaped + #",\s*#[0-9a-fA-F]{3,8}"#
        var css = store.cssEditorSource
        while let matchRange = css.range(of: fbPattern, options: .regularExpression),
              let hexStart = css[matchRange].firstIndex(of: "#") {
            css.replaceSubrange(hexStart..<matchRange.upperBound, with: hex)
        }
        store.cssEditorSource = css
        var html = store.htmlEditorSource
        while let matchRange = html.range(of: fbPattern, options: .regularExpression),
              let hexStart = html[matchRange].firstIndex(of: "#") {
            html.replaceSubrange(hexStart..<matchRange.upperBound, with: hex)
        }
        store.htmlEditorSource = html
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
                    html: store.htmlEditorSource, css: store.cssEditorSource,
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
    @Binding var cursorLocation: Int

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
        context.coordinator.lastSyncedText = text

        // Syntax highlighting
        highlightSyntax(textView, language: language)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        // External change (template load, agent write, tab switch, Format):
        // coordinator.lastSyncedText only advances on user typing, so any
        // mismatch here means the binding changed outside the text view.
        if text != context.coordinator.lastSyncedText {
            let sel = textView.selectedRange
            textView.string = text
            context.coordinator.lastSyncedText = text
            highlightSyntax(textView, language: language)
            // Keep cursor where the user had it (clamped to new length)
            let maxLoc = (text as NSString).length
            textView.selectedRange = NSRange(
                location: min(sel.location, maxLoc),
                length: min(sel.length, maxLoc - min(sel.location, maxLoc)))
        }
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Handle pending snippet insertion at cursor
        if let snippet = pendingInsert {
            let cursor = textView.selectedRange
            textView.insertText(snippet, replacementRange: cursor)
            context.coordinator.lastSyncedText = textView.string
            highlightSyntax(textView, language: language)
            pendingInsert = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeTextView
        /// Last text the text view is known to hold. Advances on user edits
        /// and on external applications — used by updateNSView to distinguish
        /// user typing (skip) from template/agent writes (apply).
        var lastSyncedText = ""

        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            lastSyncedText = textView.string
            parent.text = textView.string
            parent.highlightSyntax(textView, language: parent.language)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.cursorLocation = textView.selectedRange.location
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
