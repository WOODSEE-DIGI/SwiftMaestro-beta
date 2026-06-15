import SwiftUI
import UniformTypeIdentifiers

/// Lightweight, `Hashable & Codable` value that identifies a plan for the
/// data-driven plan `WindowGroup` (`openWindow(id:value:)`). We pass the scope
/// key + plan id rather than the `Plan` itself so the window always reads the
/// live copy from `PlanStore` (and presentation values stay lightweight, as the
/// SwiftUI window docs recommend).
struct PlanWindowID: Hashable, Codable {
    let scopeKey: String
    let planID: UUID
}

/// Minimal `FileDocument` used only to export a plan's markdown via the standard
/// `.fileExporter` modifier. Serialization runs off the main actor, so the type
/// is a plain `Sendable` value.
struct MarkdownDocument: FileDocument {
    /// A `.md` content type derived from the extension (falls back to plain text
    /// if the system can't synthesize one), so exported files get a `.md` name.
    static let markdown = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    static var readableContentTypes: [UTType] { [markdown, .plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// A standalone, resizable reading window for a single plan. Opened from the
/// Plans browser via `openWindow`. The window's scene uses
/// `.windowResizability(.contentSize)`, so the `idealWidth/idealHeight` below
/// drive the opening size (the system clamps it to the visible screen), and the
/// inner `ScrollView` handles plans taller than what fits.
struct PlanWindowView: View {
    @Environment(PlanStore.self) private var planStore
    /// The plan to show, or `nil` when SwiftUI opens the group without a value
    /// (e.g. File ▸ New Window) or the plan was deleted.
    let target: PlanWindowID?

    @State private var showingExporter = false

    private var scope: PlanScope? { target.flatMap { PlanScope(key: $0.scopeKey) } }

    private var plan: Plan? {
        guard let scope, let target else { return nil }
        return planStore.plans(in: scope).first { $0.id == target.planID }
    }

    var body: some View {
        Group {
            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(plan.title)
                            .font(.title.weight(.bold))
                            .textSelection(.enabled)
                        Divider()
                        Text(Self.rendered(plan.content))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(24)
                }
                .frame(
                    minWidth: 480, idealWidth: 860, maxWidth: 1200,
                    minHeight: 360, idealHeight: Self.idealHeight(for: plan.content), maxHeight: 1600)
                .navigationTitle(plan.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingExporter = true } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .help("Export this plan as a Markdown file")
                    }
                }
                .fileExporter(
                    isPresented: $showingExporter,
                    document: MarkdownDocument(text: Self.markdown(for: plan)),
                    contentType: MarkdownDocument.markdown,
                    defaultFilename: Self.filename(for: plan.title)
                ) { _ in }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Plan not found")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 360, minHeight: 220)
                .padding(40)
            }
        }
    }

    /// Full markdown for export, leading with the title as an H1 (mirrors the
    /// `.md` files PlanStore writes).
    private static func markdown(for plan: Plan) -> String {
        "# \(plan.title)\n\n\(plan.content)\n"
    }

    /// A filesystem-friendly default export name (extension added by the panel).
    private static func filename(for title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Plan" : cleaned
    }

    /// Estimate a content-proportional opening height so short plans open small
    /// and long ones open tall — capped so the window never exceeds a sensible
    /// size (the window scene additionally clamps to the visible screen).
    private static func idealHeight(for content: String) -> CGFloat {
        let charsPerLine = 92.0
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).reduce(0.0) {
            $0 + max(1.0, ceil(Double($1.count) / charsPerLine))
        }
        let estimate = lines * 20.0 + 160.0
        return CGFloat(min(max(estimate, 360.0), 1500.0))
    }

    /// Render markdown preserving line breaks (inline styles only); falls back to
    /// plain text if parsing fails. Matches the Plans browser's rendering.
    private static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
