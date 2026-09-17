import Foundation

/// Minimal Markdown → HTML converter for feed bodies.
/// Handles headings, paragraphs, bold, italic, inline code, code blocks,
/// links, images, and line breaks. Not a full CommonMark implementation,
/// but sufficient for notes written in SwiftMaestro.
enum PublishMarkdownToHTML {

    static func convert(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var output: [String] = []
        var inCodeBlock = false
        var codeLanguage = ""
        var codeContent: [String] = []
        var currentParagraph: [String] = []

        func flushParagraph() {
            guard !currentParagraph.isEmpty else { return }
            let joined = currentParagraph.joined(separator: " ")
            let inline = inlineHTML(for: joined)
            output.append("<p>\(inline)</p>")
            currentParagraph.removeAll()
        }

        func flushCodeBlock() {
            guard inCodeBlock else { return }
            let escaped = codeContent.joined(separator: "\n")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let langAttr = codeLanguage.isEmpty ? "" : " class=\"language-\(codeLanguage)\""
            output.append("<pre><code\(langAttr)>\(escaped)</code></pre>")
            inCodeBlock = false
            codeLanguage = ""
            codeContent.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if isFence(trimmed) {
                if inCodeBlock {
                    flushParagraph()
                    flushCodeBlock()
                } else {
                    flushParagraph()
                    inCodeBlock = true
                    codeLanguage = languageFromFence(trimmed)
                }
                continue
            }

            if inCodeBlock {
                codeContent.append(rawLine)
                continue
            }

            // Headings
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                output.append("<h\(heading.level)>\(inlineHTML(for: heading.text))</h\(heading.level)>")
                continue
            }

            // Blank line ends a paragraph
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            currentParagraph.append(rawLine)
        }

        flushParagraph()
        flushCodeBlock()

        return output.joined(separator: "\n")
    }

    // MARK: - Inline formatting

    private static func inlineHTML(for text: String) -> String {
        var result = text
            .replacingInlineCode()
            .replacingImageMarkdown()
            .replacingLinkMarkdown()
            .replacingPairs(pattern: #"\*\*(.+?)\*\*"#, open: "<strong>", close: "</strong>")
            .replacingPairs(pattern: #"__(.+?)__"#, open: "<strong>", close: "</strong>")
            .replacingPairs(pattern: #"\*(.+?)\*"#, open: "<em>", close: "</em>")
            .replacingPairs(pattern: #"_(.+?)_"#, open: "<em>", close: "</em>")
            .replacingLineBreaks()
        return result
    }

    // MARK: - Headings

    private struct Heading {
        let level: Int
        let text: String
    }

    private static func parseHeading(_ line: String) -> Heading? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        guard level <= 6 else { return nil }
        let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return Heading(level: level, text: text)
    }

    // MARK: - Code fences

    private static func isFence(_ line: String) -> Bool {
        let run = line.prefix(while: { $0 == "`" || $0 == "~" })
        return run.count >= 3
    }

    private static func languageFromFence(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let fenceChar = trimmed.first ?? "`"
        let run = trimmed.prefix(while: { $0 == fenceChar })
        let after = String(trimmed.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
        return after.components(separatedBy: .whitespaces).first ?? ""
    }
}

// MARK: - String helpers

private extension String {
    func replacingImageMarkdown() -> String {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#, options: []) else { return self }
        let range = NSRange(self.startIndex..<self.endIndex, in: self)
        var result = self
        for match in regex.matches(in: self, options: [], range: range).reversed() {
            guard let full = Range(match.range, in: result),
                  let altRange = Range(match.range(at: 1), in: result),
                  let urlRange = Range(match.range(at: 2), in: result) else { continue }
            let alt = String(result[altRange]).htmlEscaped
            let url = String(result[urlRange]).htmlEscaped
            result.replaceSubrange(full, with: #"<img src="\#(url)" alt="\#(alt)" />"#)
        }
        return result
    }

    func replacingLinkMarkdown() -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, options: []) else { return self }
        let range = NSRange(self.startIndex..<self.endIndex, in: self)
        var result = self
        for match in regex.matches(in: self, options: [], range: range).reversed() {
            guard let full = Range(match.range, in: result),
                  let textRange = Range(match.range(at: 1), in: result),
                  let urlRange = Range(match.range(at: 2), in: result) else { continue }
            let text = String(result[textRange]).htmlEscaped
            let url = String(result[urlRange]).htmlEscaped
            result.replaceSubrange(full, with: #"<a href="\#(url)">\#(text)</a>"#)
        }
        return result
    }

    func replacingInlineCode() -> String {
        guard let regex = try? NSRegularExpression(pattern: #"`([^`]+)`"#, options: []) else { return self }
        let range = NSRange(self.startIndex..<self.endIndex, in: self)
        var result = self
        for match in regex.matches(in: self, options: [], range: range).reversed() {
            guard let full = Range(match.range, in: result),
                  let codeRange = Range(match.range(at: 1), in: result) else { continue }
            let code = String(result[codeRange]).htmlEscaped
            result.replaceSubrange(full, with: "<code>\(code)</code>")
        }
        return result
    }

    func replacingLineBreaks() -> String {
        self.replacingOccurrences(of: "\n", with: "<br />")
    }

    func replacingPairs(pattern: String, open: String, close: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let range = NSRange(self.startIndex..<self.endIndex, in: self)
        var result = self
        for match in regex.matches(in: self, options: [], range: range).reversed() {
            guard let full = Range(match.range, in: result),
                  let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let inner = String(result[innerRange])
            result.replaceSubrange(full, with: "\(open)\(inner)\(close)")
        }
        return result
    }

    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
