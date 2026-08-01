import SwiftUI
import AppKit

// MARK: - Markdown Text Editor
//
// NSTextView-backed plain-text markdown editor with selection-aware formatting
// commands (bold/italic/headings/lists/quotes/code/links/highlight/color).
// SwiftUI's TextEditor exposes no selection API, so this representable backs
// the Notes editor and the formatting toolbar drives it via the controller.

/// Formatting commands the toolbar can send to the editor.
enum MarkdownEditCommand {
    case bold, italic, strikethrough, inlineCode, codeBlock, link
    case heading(Int)          // 1...6
    case bullet, numbered, checkbox, quote
    case highlight
    case textColor(String)     // hex like "#e74c3c"
    case highlightColor(String)
}

/// Shared handle the toolbar uses to reach the live NSTextView.
@Observable
final class MarkdownEditorController {
    weak var textView: NSTextView?

    func apply(_ command: MarkdownEditCommand) {
        guard let tv = textView else { return }
        switch command {
        case .bold:            wrap(tv, prefix: "**", suffix: "**", placeholder: "bold text")
        case .italic:          wrap(tv, prefix: "*", suffix: "*", placeholder: "italic text")
        case .strikethrough:   wrap(tv, prefix: "~~", suffix: "~~", placeholder: "strikethrough")
        case .inlineCode:      wrap(tv, prefix: "`", suffix: "`", placeholder: "code")
        case .codeBlock:       wrapBlock(tv, fence: "```")
        case .highlight:       wrap(tv, prefix: "==", suffix: "==", placeholder: "highlight")
        case .textColor(let hex):
            wrap(tv, prefix: "<span style=\"color:\(hex)\">", suffix: "</span>", placeholder: "colored text")
        case .highlightColor(let hex):
            wrap(tv, prefix: "<span style=\"background-color:\(hex)\">", suffix: "</span>", placeholder: "highlighted text")
        case .link:            insertLink(tv)
        case .heading(let level):
            linePrefix(tv, prefix: String(repeating: "#", count: level) + " ", toggle: true)
        case .bullet:          linePrefix(tv, prefix: "- ", toggle: true)
        case .numbered:        numberedList(tv)
        case .checkbox:        linePrefix(tv, prefix: "- [ ] ", toggle: true)
        case .quote:           linePrefix(tv, prefix: "> ", toggle: true)
        }
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: - Selection wrapping

    /// Wraps the selection with prefix/suffix. With an empty selection, inserts
    /// prefix+placeholder+suffix and selects the placeholder.
    private func wrap(_ tv: NSTextView, prefix: String, suffix: String, placeholder: String) {
        let range = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: range)
        let inner = selected.isEmpty ? placeholder : selected
        tv.insertText("\(prefix)\(inner)\(suffix)", replacementRange: range)
        if selected.isEmpty {
            let start = range.location + prefix.count
            tv.setSelectedRange(NSRange(location: start, length: inner.count))
        } else {
            let start = range.location + prefix.count
            tv.setSelectedRange(NSRange(location: start, length: inner.count))
        }
    }

    /// Wraps the selected lines (or current line) in a fenced code block.
    private func wrapBlock(_ tv: NSTextView, fence: String) {
        let range = tv.selectedRange()
        let nsString = tv.string as NSString
        let lineRange = nsString.lineRange(for: range)
        let content = nsString.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let body = content.isEmpty ? "code" : content
        tv.insertText("\(fence)\n\(body)\n\(fence)\n", replacementRange: lineRange)
        if content.isEmpty {
            let start = lineRange.location + fence.count + 1
            tv.setSelectedRange(NSRange(location: start, length: body.count))
        }
    }

    /// Inserts markdown link syntax. URL-selected text becomes the URL,
    /// otherwise the selection becomes the label.
    private func insertLink(_ tv: NSTextView) {
        let range = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: range)
        if selected.lowercased().hasPrefix("http://") || selected.lowercased().hasPrefix("https://") {
            tv.insertText("[\(selected)](\(selected))", replacementRange: range)
        } else {
            let label = selected.isEmpty ? "link text" : selected
            tv.insertText("[\(label)](https://)", replacementRange: range)
            let urlStart = range.location + label.count + 3
            tv.setSelectedRange(NSRange(location: urlStart, length: 8))
        }
    }

    // MARK: - Line prefixes

    /// Adds/removes a line prefix over every line touched by the selection.
    /// `toggle: true` removes the prefix when every line already has it.
    private func linePrefix(_ tv: NSTextView, prefix: String, toggle: Bool) {
        let range = tv.selectedRange()
        let nsString = tv.string as NSString
        let lineRange = nsString.lineRange(for: range)
        let content = nsString.substring(with: lineRange)
        var lines = content.components(separatedBy: .newlines)
        if let last = lines.last, last.isEmpty, lines.count > 1 { lines.removeLast() }

        let allPrefixed = toggle && lines.allSatisfy { $0.hasPrefix(prefix) }
        var deltaTotal = 0
        var newLines: [String] = []
        newLines.reserveCapacity(lines.count)
        for line in lines {
            if allPrefixed {
                let stripped = String(line.dropFirst(prefix.count))
                deltaTotal -= prefix.count
                newLines.append(stripped)
            } else if !line.hasPrefix(prefix) {
                newLines.append(prefix + line)
                deltaTotal += prefix.count
            } else {
                newLines.append(line)
            }
        }
        let replacement = newLines.joined(separator: "\n")
        tv.insertText(replacement, replacementRange: lineRange)
        // Keep the original selection roughly mapped over the edited region.
        let anchor = lineRange.location + max(0, range.location - lineRange.location)
        tv.setSelectedRange(NSRange(location: anchor, length: 0))
    }

    /// Numbers each selected line sequentially (1. 2. 3. …); strips numbering
    /// when every line is already numbered.
    private func numberedList(_ tv: NSTextView) {
        let range = tv.selectedRange()
        let nsString = tv.string as NSString
        let lineRange = nsString.lineRange(for: range)
        let content = nsString.substring(with: lineRange)
        var lines = content.components(separatedBy: .newlines)
        if let last = lines.last, last.isEmpty, lines.count > 1 { lines.removeLast() }

        let numberRegex = try? NSRegularExpression(pattern: #"^\d+\. "#)
        let allNumbered = lines.allSatisfy { line in
            numberRegex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        var newLines: [String] = []
        for (index, line) in lines.enumerated() {
            if allNumbered {
                let stripped = numberRegex?.stringByReplacingMatches(
                    in: line, range: NSRange(line.startIndex..., in: line), withTemplate: ""
                ) ?? line
                newLines.append(stripped)
            } else {
                newLines.append("\(index + 1). \(line)")
            }
        }
        tv.insertText(newLines.joined(separator: "\n"), replacementRange: lineRange)
        tv.setSelectedRange(NSRange(location: lineRange.location, length: 0))
    }
}

// MARK: - NSViewRepresentable

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var controller: MarkdownEditorController
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.font = font
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.delegate = context.coordinator
        textView.string = text

        controller.textView = textView
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.font != font { textView.font = font }
        // External text change (note switch/load): update without clobbering
        // the user's selection when the text is identical.
        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            // Restore selection if it still fits.
            if let first = ranges.first?.rangeValue, first.location + first.length <= text.count {
                textView.selectedRanges = ranges
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownTextEditor
        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onChange()
        }
    }
}

// MARK: - Editor Font

/// Editor font choices for the markdown editor (persisted in UserDefaults).
enum MarkdownEditorFont: String, CaseIterable, Identifiable {
    case systemMono = "System Mono"
    case menlo = "Menlo"
    case newYork = "New York"
    case system = "System"

    var id: String { rawValue }

    var nsFont: NSFont {
        switch self {
        case .systemMono: return .monospacedSystemFont(ofSize: 13, weight: .regular)
        case .menlo:      return NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        case .newYork:    return NSFont(name: "New York", size: 14) ?? .systemFont(ofSize: 14)
        case .system:     return .systemFont(ofSize: 13)
        }
    }

    static func fromDefaults() -> MarkdownEditorFont {
        MarkdownEditorFont(rawValue: UserDefaults.standard.string(forKey: "notes.editorFont") ?? "") ?? .systemMono
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "notes.editorFont")
    }
}

// MARK: - Formatting Toolbar

/// Compact formatting toolbar for the Notes markdown editor.
struct MarkdownFormatToolbar: View {
    let controller: MarkdownEditorController
    @Binding var editorFont: MarkdownEditorFont
    var onCommand: () -> Void

    private func button(_ icon: String, _ help: String, _ command: MarkdownEditCommand) -> some View {
        Button {
            controller.apply(command)
            onCommand()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    var body: some View {
        HStack(spacing: 4) {
            button("bold", "Bold (⌘B)", .bold)
            button("italic", "Italic (⌘I)", .italic)
            button("strikethrough", "Strikethrough", .strikethrough)
            divider
            Menu {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { controller.apply(.heading(level)); onCommand() }
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Heading level")
            button("text.quote", "Blockquote", .quote)
            divider
            button("list.bullet", "Bullet list", .bullet)
            button("list.number", "Numbered list", .numbered)
            button("checklist", "Task checkbox", .checkbox)
            divider
            button("chevron.left.forwardslash.chevron.right", "Inline code", .inlineCode)
            button("curlybraces.square", "Code block", .codeBlock)
            button("link", "Link", .link)
            divider
            button("highlighter", "Highlight ==text==", .highlight)
            Menu {
                ForEach(ToolbarPalette.textColors, id: \.hex) { swatch in
                    Button { controller.apply(.textColor(swatch.hex)); onCommand() } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 10, height: 10)
                            Text(swatch.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text color (HTML span)")
            Menu {
                ForEach(ToolbarPalette.textColors, id: \.hex) { swatch in
                    Button { controller.apply(.highlightColor(swatch.hex)); onCommand() } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(swatch.color.opacity(0.5))
                                .frame(width: 10, height: 10)
                            Text(swatch.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Background color (HTML span)")
            divider
            Menu {
                ForEach(MarkdownEditorFont.allCases) { font in
                    Button(font.rawValue) {
                        editorFont = font
                        font.save()
                    }
                }
            } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Editor font")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var divider: some View {
        Divider().frame(height: 14).padding(.horizontal, 3)
    }
}

/// Preset text colors for the color menu (Obsidian-friendly palette).
enum ToolbarPalette {
    struct Swatch: Sendable {
        let name: String
        let hex: String
        let color: Color
    }

    static let textColors: [Swatch] = [
        .init(name: "Red",    hex: "#e74c3c", color: Color(hex: 0xe74c3c)),
        .init(name: "Orange", hex: "#e67e22", color: Color(hex: 0xe67e22)),
        .init(name: "Yellow", hex: "#f1c40f", color: Color(hex: 0xf1c40f)),
        .init(name: "Green",  hex: "#2ecc71", color: Color(hex: 0x2ecc71)),
        .init(name: "Blue",   hex: "#3498db", color: Color(hex: 0x3498db)),
        .init(name: "Purple", hex: "#9b59b6", color: Color(hex: 0x9b59b6)),
        .init(name: "Pink",   hex: "#fd79a8", color: Color(hex: 0xfd79a8)),
    ]
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
