import SwiftUI

// MARK: - Rich Markdown View

/// Renders markdown text with properly styled code blocks, inline code,
/// and basic formatting. Replaces plain `Text()` for assistant messages.
struct RichMarkdownView: View {

    let text: String
    let isUser: Bool
    /// Optional callback when user taps "Run" on a shell code block.
    var onRunCommand: ((String) -> Void)? = nil

    /// Parsed segments: alternating text and code blocks.
    private var segments: [MarkdownSegment] {
        MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments) { segment in
                switch segment {
                case .text(let content):
                    TextSegmentView(content: content, isUser: isUser)
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

            // Check for opening/closing fence (``` or ~~~)
            if isFenceOpen(trimmed) || isFenceClose(trimmed) {
                let currentFenceChar = trimmed.first!

                if inCodeBlock {
                    // Closing fence: same char, 3+ in a row, nothing else after
                    if currentFenceChar == fenceChar && trimmed.filter({ $0 == fenceChar }).count >= 3
                        && trimmed.drop(while: { $0 == fenceChar }).trimmingCharacters(in: .whitespaces).isEmpty {
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

    /// Check if a trimmed line is an opening fence (3+ backticks or tildes, optionally with language).
    private static func isFenceOpen(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        let fenceCount = trimmed.prefix(while: { $0 == first }).count
        guard fenceCount >= 3 else { return false }
        // Opening: ```lang or ~~~lang (nothing after lang except whitespace)
        let rest = String(trimmed.dropFirst(fenceCount)).trimmingCharacters(in: .whitespaces)
        // Empty or just a language name = opening fence
        return rest.allSatisfy { $0.isLetter || $0 == "-" || $0 == "_" || $0 == " " || $0 == "\t" }
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

    let content: String
    let isUser: Bool

    var body: some View {
        // Render with SwiftUI's built-in markdown support
        // which handles **bold**, *italic*, `code`, lists, etc.
        Text(LocalizedStringKey(content))
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            headerBar

            if expanded {
                // Code content
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        // Line numbers
                        lineNumbers
                            .padding(.trailing, 8)
                            .padding(.leading, 12)
                            .padding(.vertical, 10)

                        Divider()

                        // Code with syntax highlighting
                        highlightedCode
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .background(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
            .help("Copy code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)))
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
            keywordRegex.enumerateMatches(in: code, range: fullRange) { match, _, _ in
                guard let range = match?.range, let swiftRange = Range(range, in: result) else { return }
                result[swiftRange].foregroundColor = NSColor(red: 0.68, green: 0.50, blue: 0.85, alpha: 1.0)
                result[swiftRange].font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
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
