import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Rich Markdown View

/// Renders markdown text with properly styled code blocks, inline code,
/// and basic formatting. Replaces plain `Text()` for assistant messages.
struct RichMarkdownView: View {

    let text: String
    let isUser: Bool
    /// Optional callback when user taps "Run" on a shell code block.
    var onRunCommand: ((String) -> Void)? = nil
    /// Base directory for resolving relative image paths (clip notes reference
    /// assets/… folders beside the .md file). Nil = remote URLs only.
    var baseURL: URL? = nil

    /// Parsed segments: alternating text and code blocks.
    private var segments: [MarkdownSegment] {
        MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments) { segment in
                switch segment {
                case .text(let content):
                    TextSegmentView(content: content, isUser: isUser, baseURL: baseURL)
                case .code(let language, let code, let id):
                    CodeBlockView(
                        language: language,
                        code: code,
                        segmentID: id,
                        onRun: isShellLanguage(language) ? onRunCommand : nil
                    )
                }
            }
        }
    }

    private func isShellLanguage(_ lang: String) -> Bool {
        let l = lang.lowercased()
        return ["bash", "sh", "zsh", "shell", "command", "terminal"].contains(l)
    }
}

// MARK: - Markdown Segment

enum MarkdownSegment: Identifiable {
    case text(String)
    case code(language: String, code: String, id: String)

    var id: String {
        switch self {
        case .text(let content): return "text-\(content.hashValue)"
        case .code(_, _, let id): return id
        }
    }
}

// MARK: - Markdown Parser

enum MarkdownParser {

    /// Split markdown text into text and fenced code block segments.
    /// Supports both backtick (```) and tilde (~~~) fences.
    static func parse(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var currentText = ""
        var inCodeBlock = false
        var codeLanguage = ""
        var codeContent = ""
        var codeBlockID = 0
        var fenceChar: Character = "`" // track which fence opened the block

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // One-line fenced block (fence run + lang + code + closing fence
            // run on ONE line). Invalid CommonMark but chat models emit it
            // constantly; without this the markers render as nothing and the
            // NEXT bare fence swallows all following prose into a bogus block.
            if !inCodeBlock, let oneLiner = parseOneLineFence(trimmed) {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                segments.append(.code(language: oneLiner.language, code: oneLiner.code,
                                      id: "code-\(codeBlockID)"))
                codeBlockID += 1
                continue
            }

            // Check for opening/closing fence (``` or ~~~)
            if isFenceOpen(trimmed) || isFenceClose(trimmed) {
                let currentFenceChar = trimmed.first!

                if inCodeBlock {
                    // Closing fence: same char, 3+ in a row at line start. Prose
                    // the model glued after the fence run (e.g. a fence run
                    // followed by "3. Next step:") is kept as a text segment
                    // instead of invalidating the close and swallowing prose.
                    if currentFenceChar == fenceChar
                        && trimmed.prefix(while: { $0 == fenceChar }).count >= 3 {
                        // End of code block
                        segments.append(.code(
                            language: codeLanguage,
                            code: codeContent.trimmingCharacters(in: .whitespacesAndNewlines),
                            id: "code-\(codeBlockID)"
                        ))
                        codeBlockID += 1
                        inCodeBlock = false
                        codeLanguage = ""
                        codeContent = ""
                        let tail = String(trimmed.drop(while: { $0 == fenceChar }))
                            .trimmingCharacters(in: .whitespaces)
                        if !tail.isEmpty {
                            if !currentText.isEmpty { currentText += "\n" }
                            currentText += tail
                        }
                        continue
                    }
                }

                if !inCodeBlock && isFenceOpen(trimmed) {
                    // Start of code block — flush accumulated text
                    if !currentText.isEmpty {
                        segments.append(.text(currentText))
                        currentText = ""
                    }
                    inCodeBlock = true
                    fenceChar = currentFenceChar
                    codeLanguage = String(trimmed.drop(while: { $0 == fenceChar })
                        .trimmingCharacters(in: .whitespaces))
                } else if inCodeBlock {
                    // Inside code block — the line is content (mismatched fence)
                    if !codeContent.isEmpty { codeContent += "\n" }
                    codeContent += line
                } else {
                    // Not a fence, just text
                    if !currentText.isEmpty { currentText += "\n" }
                    currentText += line
                }
            } else if inCodeBlock {
                if !codeContent.isEmpty { codeContent += "\n" }
                codeContent += line
            } else {
                if !currentText.isEmpty { currentText += "\n" }
                currentText += line
            }
        }

        // Flush remaining content
        if inCodeBlock {
            // Unclosed code block — treat as text with the fence prefix
            let fenceString = String(repeating: fenceChar, count: 3)
            currentText += "\(fenceString)\(codeLanguage)\n\(codeContent)"
        }
        if !currentText.isEmpty {
            segments.append(.text(currentText))
        }

        return segments
    }

    /// LaTeX commands small models emit inside `$…$` spans (most often arrows in
    /// version diffs: `$\rightarrow$`). Mapped to plain Unicode so chat renders
    /// "3.14.6 → 3.14.7" instead of leaking raw markup.
    private static let inlineMathSymbols: [(command: String, symbol: String)] = [
        // Longest first so prefix commands don't shadow longer ones.
        ("\\longrightarrow", "⟶"), ("\\longleftarrow", "⟵"),
        ("\\rightarrow", "→"), ("\\leftarrow", "←"),
        ("\\Rightarrow", "⇒"), ("\\Leftarrow", "⇐"),
        ("\\mapsto", "↦"), ("\\to", "→"),
        ("\\geq", "≥"), ("\\leq", "≤"), ("\\neq", "≠"),
        ("\\approx", "≈"), ("\\equiv", "≡"), ("\\pm", "±"),
        ("\\times", "×"), ("\\div", "÷"), ("\\cdot", "·"),
        ("\\infty", "∞"), ("\\degree", "°"), ("\\alpha", "α"),
        ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\lambda", "λ"), ("\\mu", "μ"), ("\\pi", "π"),
        ("\\sigma", "σ"), ("\\omega", "ω"), ("\\sum", "∑"),
        ("\\prod", "∏"), ("\\sqrt", "√"), ("\\in", "∈"),
    ]

    /// Normalize inline LaTeX math that models emit (`$\rightarrow$`,
    /// `$\geq$`, …) into plain Unicode so it renders instead of leaking raw
    /// markup into chat. Only touches `$…$` spans that actually contain a
    /// backslash command, and only unwraps when every command inside
    /// converted cleanly — currency ("$5 and $10") and unrenderable math are
    /// left untouched.
    static func normalizeInlineMath(_ text: String) -> String {
        guard text.contains("$"), text.contains("\\") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"\$([^$]+?)\$"#) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = text
        // Right-to-left so replacements don't shift the ranges of earlier matches.
        for match in regex.matches(in: text, range: range).reversed() {
            guard let full = Range(match.range, in: result),
                  let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let inner = String(result[innerRange])
            guard inner.contains("\\") else { continue }  // not LaTeX (maybe currency)
            var replaced = inner
            for (command, symbol) in inlineMathSymbols {
                replaced = replaced.replacingOccurrences(of: command, with: symbol)
            }
            guard !replaced.contains("\\") else { continue }  // real math we can't render
            result.replaceSubrange(full, with: replaced.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    /// Convert plain http/https URLs in text segments into markdown link syntax so
    /// SwiftUI's Text renderer makes them clickable. Skips URLs that already appear
    /// inside markdown link syntax `[text](url)` or angle brackets `<url>`.
    static func autoLinkURLs(_ text: String) -> String {        // Use a greedy path so the whole URL (including trailing paths like
        // /timeline_single_file.html) is captured as one link.
        let pattern = #"(?<![\]\(<"'])https?://[\w\-\.]+(:\d+)?(/[\w\-\.~%!$&'()*+,;=:@/]*)?(\?[\w\-\.~%!$&'()*+,;=:@/?#]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = text
        // Enumerate matches right-to-left so earlier replacements don't shift ranges.
        let matches = regex.matches(in: text, options: [], range: range).reversed()
        for match in matches {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let url = String(result[matchRange])
            // Don't double-link if the URL already looks wrapped in markdown or angle brackets.
            let prefix = result[..<matchRange.lowerBound]
            let lastTwo = String(prefix.suffix(2))
            let lastOne = String(prefix.suffix(1))
            if lastTwo == "](" || lastTwo == "=[" || lastOne == "<" || lastOne == "\"" || lastOne == "'" {
                continue
            }
            result.replaceSubrange(matchRange, with: "[\(url)](\(url))")
        }
        return result
    }

    /// Parses a single-line fenced block: a fence run, optional language tag,
    /// code, and the closing fence run all on one trimmed line.
    /// Returns nil when the shape doesn't match (normal multi-line blocks are
    /// handled by the main loop).
    private static func parseOneLineFence(_ trimmed: String) -> (language: String, code: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let fenceCount = trimmed.prefix(while: { $0 == first }).count
        guard fenceCount >= 3 else { return nil }
        let fence = String(repeating: first, count: fenceCount)
        let afterOpen = trimmed.dropFirst(fenceCount)
        // Needs a closing fence at the end and real content between them.
        guard afterOpen.count > fenceCount, afterOpen.hasSuffix(fence) else { return nil }
        let inner = afterOpen.dropLast(fenceCount).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        // Split an optional leading language tag from the code.
        if let space = inner.firstIndex(of: " ") {
            let lang = String(inner[..<space])
            let code = String(inner[space...]).trimmingCharacters(in: .whitespaces)
            if !lang.isEmpty, !code.isEmpty {
                return (lang, code)
            }
        }
        return ("", inner)
    }

    /// Check if a trimmed line is an opening fence (3+ backticks or tildes, optionally with language).
    private static func isFenceOpen(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        let fenceCount = trimmed.prefix(while: { $0 == first }).count
        guard fenceCount >= 3 else { return false }
        // Opening: ```lang or ~~~lang (nothing after lang except whitespace).
        // The info string can contain letters, digits, common punctuation for
        // language identifiers (e.g. python3, c++, c#), and spaces.
        let rest = String(trimmed.dropFirst(fenceCount)).trimmingCharacters(in: .whitespaces)
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" || $0 == "#" || $0 == " " || $0 == "\t" || $0 == "." }
    }

    /// Check if a trimmed line is a closing fence (3+ of the same char, nothing else).
    private static func isFenceClose(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        let fenceCount = trimmed.prefix(while: { $0 == first }).count
        guard fenceCount >= 3 else { return false }
        return trimmed.dropFirst(fenceCount).trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Text Segment View

struct TextSegmentView: View {
    @Environment(ThemeStore.self) private var theme

    let content: String
    let isUser: Bool
    /// Base directory for resolving relative image paths (nil = remote only).
    var baseURL: URL? = nil

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(
            MarkdownParser.autoLinkURLs(MarkdownParser.normalizeInlineMath(content)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, textColor: theme.chatText, baseURL: baseURL)
            }
        }
        .font(.body)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

// MARK: - Markdown Blocks

enum MarkdownBlock: Identifiable {
    case heading(id: Int, level: Int, text: String)
    case paragraph(id: Int, text: String)
    case blockquote(id: Int, text: String)
    case bullet(id: Int, text: String, indent: Int, checked: Bool?)
    case numbered(id: Int, index: Int, text: String, indent: Int)
    case rule(id: Int)
    case table(id: Int, header: [String], rows: [[String]])
    /// Standalone image line: ![alt](path) — local (vault-relative) or remote.
    case image(id: Int, alt: String, path: String)

    var id: Int {
        switch self {
        case .heading(let id, _, _), .paragraph(let id, _), .blockquote(let id, _),
             .bullet(let id, _, _, _), .numbered(let id, _, _, _), .rule(let id),
             .table(let id, _, _), .image(let id, _, _):
            return id
        }
    }
}

/// Block-level markdown parsing: headings, blockquotes, lists (incl. task
/// checkboxes), thematic breaks, and paragraphs. Inline formatting (bold,
/// italic, inline code, links) is handled per-block by AttributedString(markdown:).
enum MarkdownBlockParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var nextID = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(id: nextID, text: paragraph.joined(separator: " ")))
            nextID += 1
            paragraph.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.blockquote(id: nextID, text: quote.joined(separator: "\n")))
            nextID += 1
            quote.removeAll()
        }

        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph(); flushQuote()
                i += 1; continue
            }
            // Thematic break (---, ***, ___)
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }),
               let ch = trimmed.first, trimmed.count >= 3,
               trimmed.allSatisfy({ $0 == ch }) {
                flushParagraph(); flushQuote()
                blocks.append(.rule(id: nextID)); nextID += 1
                i += 1; continue
            }
            // Heading: 1-6 '#' followed by a space
            if let (level, headingText) = parseHeading(trimmed) {
                flushParagraph(); flushQuote()
                blocks.append(.heading(id: nextID, level: level, text: headingText)); nextID += 1
                i += 1; continue
            }
            // Blockquote: consecutive '>' lines group into one quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1; continue
            } else {
                flushQuote()
            }
            // Tables: | col | col | with a |---|---| separator on the NEXT line.
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"),
               !trimmed.allSatisfy({ $0 == "|" || $0 == " " || $0 == "-" }) {
                if let table = parseTable(lines: lines, startIndex: i) {
                    flushParagraph()
                    blocks.append(.table(id: nextID, header: table.header, rows: table.rows))
                    nextID += 1
                    i += table.linesConsumed
                    continue
                }
            }
            // Standalone image line: ![alt](path) on its own line renders as
            // an actual image (local vault-relative or remote http(s)).
            if let image = parseImageLine(trimmed) {
                flushParagraph(); flushQuote()
                blocks.append(.image(id: nextID, alt: image.alt, path: image.path))
                nextID += 1
                i += 1; continue
            }
            // Bullets (-, *, +) with optional task checkbox.
            if let (text, indent, checked) = parseBullet(rawLine) {
                flushParagraph()
                blocks.append(.bullet(id: nextID, text: text, indent: indent, checked: checked))
                nextID += 1
                i += 1; continue
            }
            // Numbered lists (1. / 2) )
            if let (index, text, indent) = parseNumbered(rawLine) {
                flushParagraph()
                blocks.append(.numbered(id: nextID, index: index, text: text, indent: indent))
                nextID += 1
                i += 1; continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph(); flushQuote()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }  // "#hashtag" is not a heading
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Parse a standalone image line: ![alt](path). Returns nil unless the
    /// entire line is one image — inline images inside prose stay as text.
    private static func parseImageLine(_ line: String) -> (alt: String, path: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let openBracket = line.firstIndex(of: "]"),
              line[line.index(after: openBracket)] == "(" else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<openBracket])
        let pathStart = line.index(openBracket, offsetBy: 2)
        let path = String(line[pathStart..<line.index(before: line.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return (alt, path)
    }

    /// Payload of a bullet line (text, indent, checkbox state), or nil when
    /// the line isn't a bullet. The caller assigns the block id AFTER any
    /// pending paragraph is flushed — see parse() for why that ordering
    /// matters (duplicate ids otherwise).
    private static func parseBullet(_ line: String) -> (String, Int, Bool?)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indent = leadingSpaces / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        let marker = trimmed.prefix(1)
        guard marker == "-" || marker == "*" || marker == "+",
              trimmed.dropFirst(1).first == " " else { return nil }
        var text = String(trimmed.dropFirst(2))
        // Task list: [ ] / [x] / [X]
        var checked: Bool? = nil
        if text.hasPrefix("[ ] ") {
            checked = false
            text = String(text.dropFirst(4))
        } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            checked = true
            text = String(text.dropFirst(4))
        }
        return (text, indent, checked)
    }

    /// Payload of a numbered-list line (index, text, indent), or nil.
    private static func parseNumbered(_ line: String) -> (Int, String, Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indent = leadingSpaces / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var rest = trimmed[...]
        while let ch = rest.first, ch.isNumber {
            digits.append(ch)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let index = Int(digits) else { return nil }
        guard rest.first == "." || rest.first == ")" else { return nil }
        let afterMarker = rest.dropFirst()
        guard afterMarker.first == " " else { return nil }
        return (index, afterMarker.trimmingCharacters(in: .whitespaces), indent)
    }

    /// Parse a markdown table starting at `startIndex`. Returns the header row,
    /// data rows, and number of lines consumed — or nil if the table is invalid.
    /// Requires: header line (| ... |), separator line (| --- | ...), then data rows.
    private static func parseTable(lines: [String], startIndex: Int) -> (header: [String], rows: [[String]], linesConsumed: Int)? {
        guard startIndex + 1 < lines.count else { return nil }

        let headerLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let separatorLine = lines[startIndex + 1].trimmingCharacters(in: .whitespaces)

        // Separator must be |---|---|... (dashes, pipes, colons for alignment, spaces)
        let isSeparator: Bool = {
            let s = separatorLine.dropFirst().dropLast()  // strip outer pipes
            return s.split(separator: "|").allSatisfy { cell in
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                return trimmed.allSatisfy { $0 == "-" || $0 == ":" } && trimmed.count >= 1
            }
        }()
        guard isSeparator else { return nil }

        func splitCells(_ line: String) -> [String] {
            let inner = line.trimmingCharacters(in: .whitespaces)
            let dropped = inner.hasPrefix("|") ? String(inner.dropFirst()) : inner
            let final = dropped.hasSuffix("|") ? String(dropped.dropLast()) : dropped
            return final.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let header = splitCells(headerLine)
        var rows: [[String]] = []
        var consumed = 2  // header + separator

        var j = startIndex + 2
        while j < lines.count {
            let rowLine = lines[j].trimmingCharacters(in: .whitespaces)
            guard rowLine.hasPrefix("|"), rowLine.hasSuffix("|") else { break }
            // Don't consume a separator-only line (shouldn't happen, but safety)
            if rowLine.allSatisfy({ $0 == "|" || $0 == " " || $0 == "-" || $0 == ":" }) { break }
            rows.append(splitCells(rowLine))
            consumed += 1
            j += 1
        }

        return (header, rows, consumed)
    }
}

// MARK: - Markdown Block View

struct MarkdownBlockView: View {
    @Environment(ThemeStore.self) private var theme
    let block: MarkdownBlock
    let textColor: Color
    /// Base directory for resolving relative image paths (nil = remote only).
    var baseURL: URL? = nil

    var body: some View {
        switch block {
        case .heading(_, let level, let text):
            inlineText(text)
                .font(fontFor(level))
                .fontWeight(.semibold)
                .padding(.top, level == 1 ? 10 : 6)
        case .paragraph(_, let text):
            inlineText(text)
        case .blockquote(_, let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.chatSecondaryText.opacity(0.5))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(theme.chatSecondaryText)
            }
            .padding(.leading, 4)
        case .bullet(_, let text, let indent, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square" : "square")
                        .foregroundStyle(checked ? .green : theme.chatSecondaryText)
                } else {
                    Text("•")
                }
                inlineText(text)
            }
            .padding(.leading, CGFloat(indent) * 14 + 8)
        case .numbered(_, let index, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index).")
                    .monospacedDigit()
                inlineText(text)
            }
            .padding(.leading, CGFloat(indent) * 14 + 8)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(_, let header, let rows):
            tableview(header: header, rows: rows)
        case .image(_, let alt, let path):
            imageView(alt: alt, path: path)
        }
    }

    /// Render a standalone image block: remote http(s) via AsyncImage, or a
    /// vault-relative path resolved against the note's directory (baseURL).
    @ViewBuilder
    private func imageView(alt: String, path: String) -> some View {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            AsyncImage(url: URL(string: path)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                case .failure:
                    imagePlaceholder(alt: alt)
                default:
                    ProgressView().controlSize(.small).padding(8)
                }
            }
        } else if let baseURL {
            let fileURL = baseURL.appendingPathComponent(path)
            if let nsImage = NSImage(contentsOf: fileURL) {
                Image(nsImage: nsImage)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                imagePlaceholder(alt: alt)
            }
        } else {
            imagePlaceholder(alt: alt)
        }
    }

    private func imagePlaceholder(alt: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .foregroundStyle(theme.chatSecondaryText)
            Text(alt.isEmpty ? "Image" : alt)
                .font(.caption)
                .foregroundStyle(theme.chatSecondaryText)
        }
        .padding(8)
        .background(theme.chatSecondaryText.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    private func fontFor(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        default: return .subheadline
        }
    }

    /// Inline markdown (bold, italic, inline code, links) plus Obsidian-style
    /// extensions: ==highlights== and <span style="color/background-color:…">.
    /// Falls back to literal text on any parse failure.
    private func inlineText(_ text: String) -> Text {
        Text(MarkdownInlineRenderer.render(text)).foregroundStyle(textColor)
    }

    /// Renders a markdown table with alternating row backgrounds and header styling.
    private func tableview(header: [String], rows: [[String]]) -> some View {
        let columnCount = header.count
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(col < header.count ? header[col] : "")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.chatText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 60, alignment: .leading)
                            .background(theme.chatSecondaryText.opacity(0.12))
                    }
                }
                Divider()
                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { col in
                            Text(col < row.count ? row[col] : "")
                                .font(.subheadline)
                                .foregroundStyle(theme.chatText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(minWidth: 60, alignment: .leading)
                                .background(rowIdx % 2 == 0 ? Color.clear : theme.chatSecondaryText.opacity(0.06))
                        }
                    }
                    Divider()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.chatSecondaryText.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Markdown Inline Renderer

/// Recursive inline renderer: Foundation markdown for bold/italic/code/links,
/// with Obsidian-style extensions on top — `==highlight==`, `<mark>`, and
/// `<span style="color:… / background-color:…">` (the Obsidian HTML way of
/// doing text colors). Special constructs split the string; markdown is
/// parsed recursively inside them so `**bold**` still works within a span.
enum MarkdownInlineRenderer {

    static func render(_ text: String) -> AttributedString {
        guard let special = firstSpecial(in: text) else {
            return baseMarkdown(text)
        }
        var result = render(String(text[..<special.range.lowerBound]))
        var inner = render(special.inner)
        special.apply(to: &inner)
        result.append(inner)
        result.append(render(String(text[special.range.upperBound...])))
        return result
    }

    // MARK: Special constructs

    private struct Special {
        enum Kind {
            case highlight                 // ==text==
            case mark                      // <mark>text</mark>
            case span(color: NSColor?, background: NSColor?)
        }
        let kind: Kind
        let range: Range<String.Index>
        let inner: String

        func apply(to attributed: inout AttributedString) {
            switch kind {
            case .highlight, .mark:
                attributed.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35)
            case .span(let color, let background):
                if let color { attributed.foregroundColor = color }
                if let background { attributed.backgroundColor = background.withAlphaComponent(0.35) }
            }
        }
    }

    private static func firstSpecial(in text: String) -> Special? {
        let candidates: [Special?] = [
            matchHighlight(in: text),
            matchMark(in: text),
            matchSpan(in: text),
        ]
        return candidates
            .compactMap { $0 }
            .min(by: { $0.range.lowerBound < $1.range.lowerBound })
    }

    private static func matchHighlight(in text: String) -> Special? {
        guard let regex = try? NSRegularExpression(pattern: #"==([^=\n]+)=="#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let full = Range(match.range, in: text),
              let inner = Range(match.range(at: 1), in: text) else { return nil }
        return Special(kind: .highlight, range: full, inner: String(text[inner]))
    }

    private static func matchMark(in text: String) -> Special? {
        guard let regex = try? NSRegularExpression(pattern: #"<mark>(.*?)</mark>"#, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let full = Range(match.range, in: text),
              let inner = Range(match.range(at: 1), in: text) else { return nil }
        return Special(kind: .mark, range: full, inner: String(text[inner]))
    }

    private static func matchSpan(in text: String) -> Special? {
        guard let regex = try? NSRegularExpression(pattern: #"<span\s+style=\"([^\"]*)\">(.*?)</span>"#, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let full = Range(match.range, in: text),
              let style = Range(match.range(at: 1), in: text),
              let inner = Range(match.range(at: 2), in: text) else { return nil }
        var color: NSColor? = nil
        var background: NSColor? = nil
        for declaration in text[style].split(separator: ";") {
            let parts = declaration.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "color":            color = parseColor(parts[1])
            case "background-color": background = parseColor(parts[1])
            default: break
            }
        }
        return Special(kind: .span(color: color, background: background), range: full, inner: String(text[inner]))
    }

    /// Hex (#rgb/#rrggbb) plus a small named-color table (Obsidian-friendly).
    private static func parseColor(_ value: String) -> NSColor? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if v.hasPrefix("#") {
            var hex = String(v.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let int = UInt32(hex, radix: 16) else { return nil }
            return NSColor(
                red: CGFloat((int >> 16) & 0xFF) / 255,
                green: CGFloat((int >> 8) & 0xFF) / 255,
                blue: CGFloat(int & 0xFF) / 255,
                alpha: 1
            )
        }
        switch v {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "gray", "grey": return .systemGray
        case "black": return .black
        case "white": return .white
        default: return nil
        }
    }

    private static func baseMarkdown(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {

    let language: String
    let code: String
    let segmentID: String
    var onRun: ((String) -> Void)? = nil

    @State private var copied = false
    @State private var expanded = true

    private var displayLanguage: String {
        language.isEmpty ? "code" : language
    }

    // Visual language matches TerminalView/opencode's BlockTool: one continuous
    // surface accented by a single left border, rather than a fully boxed card
    // with its own contrasting header bar.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        lineNumbers
                            .padding(.trailing, 8)
                            .padding(.vertical, 6)

                        Divider()

                        highlightedCode
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Text(displayLanguage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            // Run button for shell commands
            if let onRun {
                Button {
                    onRun(code)
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .help("Open in Terminal and run")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Copy code")
        }
        .padding(.trailing, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Line Numbers

    private var lineNumbers: some View {
        let lines = code.components(separatedBy: .newlines)
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, _ in
                Text("\(idx + 1)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Highlighted Code

    private var highlightedCode: some View {
        let highlighted = SyntaxHighlighter.highlight(code: code, language: language)
        return Text(highlighted)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Syntax Highlighter

enum SyntaxHighlighter {

    /// Simple keyword-based syntax highlighting for common languages.
    static func highlight(code: String, language: String) -> AttributedString {
        var result = AttributedString(code)

        let lang = language.lowercased()

        // Keywords per language
        let keywords: Set<String>
        switch lang {
        case "swift":
            keywords = ["func", "var", "let", "if", "else", "guard", "switch", "case",
                        "for", "while", "return", "import", "struct", "class", "enum",
                        "protocol", "extension", "private", "public", "internal", "static",
                        "mutating", "self", "super", "true", "false", "nil", "async", "await",
                        "throws", "try", "catch", "some", "any", "init", "deinit", "actor"]
        case "python", "py":
            keywords = ["def", "class", "if", "else", "elif", "for", "while", "return",
                        "import", "from", "as", "with", "try", "except", "finally", "raise",
                        "True", "False", "None", "and", "or", "not", "in", "is", "lambda",
                        "yield", "async", "await", "self", "print"]
        case "bash", "sh", "zsh", "shell", "command", "terminal":
            keywords = ["if", "then", "else", "fi", "for", "do", "done", "while",
                        "case", "esac", "function", "return", "exit", "echo", "export",
                        "source", "local", "readonly", "declare", "unset", "shift"]
        case "javascript", "js", "typescript", "ts":
            keywords = ["const", "let", "var", "function", "return", "if", "else",
                        "for", "while", "do", "switch", "case", "break", "continue",
                        "class", "extends", "import", "export", "from", "default",
                        "new", "this", "super", "true", "false", "null", "undefined",
                        "async", "await", "try", "catch", "throw", "typeof", "instanceof"]
        case "json":
            keywords = ["true", "false", "null"]
        case "html", "xml":
            keywords = []
        case "css":
            keywords = ["import", "media", "font-face", "keyframes"]
        default:
            keywords = ["func", "let", "var", "if", "else", "return", "true", "false", "nil"]
        }

        // String literal colors
        let stringRegex = try! NSRegularExpression(pattern: #""[^"]*"|'[^']*'|`[^`]*`"#)
        let nsString = NSString(string: code)
        let fullRange = NSRange(location: 0, length: nsString.length)

        // Highlight strings
        stringRegex.enumerateMatches(in: code, range: fullRange) { match, _, _ in
            guard let range = match?.range, let swiftRange = Range(range, in: result) else { return }
            result[swiftRange].foregroundColor = NSColor(red: 0.75, green: 0.85, blue: 0.65, alpha: 1.0)
        }

        // Highlight comments
        let commentRegex = try! NSRegularExpression(pattern: #"#[^\n]*|//[^\n]*|/\*[\s\S]*?\*/""#)
        commentRegex.enumerateMatches(in: code, range: fullRange) { match, _, _ in
            guard let range = match?.range, let swiftRange = Range(range, in: result) else { return }
            result[swiftRange].foregroundColor = NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1.0)
        }

        // Highlight keywords
        if !keywords.isEmpty {
            let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            let keywordRegex = try! NSRegularExpression(pattern: keywordPattern)
            let codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            keywordRegex.enumerateMatches(in: code, range: fullRange) { match, _, _ in
                guard let range = match?.range, let swiftRange = Range(range, in: result) else { return }
                result[swiftRange].foregroundColor = NSColor(red: 0.68, green: 0.50, blue: 0.85, alpha: 1.0)
                result[swiftRange].font = codeFont
            }
        }

        // Highlight numbers
        let numberRegex = try! NSRegularExpression(pattern: #"\b\d+\.?\d*\b"#)
        numberRegex.enumerateMatches(in: code, range: fullRange) { match, _, _ in
            guard let range = match?.range, let swiftRange = Range(range, in: result) else { return }
            result[swiftRange].foregroundColor = NSColor(red: 0.90, green: 0.60, blue: 0.35, alpha: 1.0)
        }

        return result
    }
}

// MARK: - Preview

#Preview {
    RichMarkdownView(text: """
    Here's a Swift example:

    ```swift
    func greet(name: String) -> String {
        let message = "Hello, \\(name)!"
        print(message)
        return message
    }
    ```

    And some Python:

    ```python
    def hello(name):
        print(f"Hello, {name}!")
    ```

    And a shell command:

    ~~~bash
    cd /tmp
    ls -la
    ~~~

    **Bold text** and `inline code` work too.
    """, isUser: false)
    .frame(width: 600)
    .padding()
}
