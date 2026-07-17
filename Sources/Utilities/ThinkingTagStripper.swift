import Foundation

/// Shared thinking-tag / channel-tag stripper used by the executor stream,
/// the delegate-stream cache, and the message bubble UI as a safety net.
///
/// Gemma 4 emits reasoning markers in several forms depending on the checkpoint
/// and whether the output is tokenized with/without whitespace:
/// - bracket style: `[channel]`, `[/channel]`, `[thought]`, `[/thought]`
/// - plain angle style: `<channel>`, `</channel>`, `<channel/>`, `<channel >`
/// - pipe style: `<|channel>`, `</|channel>`, `<|channel|>`, `</|channel|>`
/// - combined tokens: `<channel>thought`, `<channel><channel>thought`, `</channel>thought`
/// - bare reasoning markers: `thought`, `|thought`, `[thought]`
///
/// The function strips all of these and collapses the resulting whitespace.
enum ThinkingTagStripper {
    static func strip(_ text: String) -> String {
        var result = text

        // 1. Remove complete reasoning blocks for all known formats. These regexes
        //    are greedy enough to swallow nested/repeated opening tags such as
        //    `<channel><channel>...
        let blockPatterns: [(String, String)] = [
            // Gemma 4 <channel>...</channel> (handles repeated opening tags)
            (#"(?i)<\s*channel(?:\s*>\s*)+.*?<\s*/\s*channel\s*>"#, ""),
            // Qwen / pipe <|channel|>...</|channel|>
            (#"(?i)<\s*\|\s*channel\s*\|(?:\s*>\s*)+.*?<\s*/\s*\|\s*channel\s*\|\s*>"#, ""),
            (#"(?i)<\s*\|\s*channel(?:\s*>\s*)+.*?<\s*/\s*\|\s*channel\s*>"#, ""),
            // Bracket [channel]...[/channel]
            (#"(?i)\[\s*channel(?:\s*\]\s*)+.*?\[/\s*channel\s*\]"#, ""),
            // Qwen <think>...</think>
            (#"(?i)<\s*think\s*>.*?<\s*/\s*think\s*>"#, ""),
        ]
        for (pattern, template) in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            }
        }

        // 2. Remove any remaining standalone opening/closing tags. This catches
        //    unclosed markers and repeated tags like `<channel><channel>` that
        //    were not part of a complete block.
        let tagPatterns: [String] = [
            #"(?i)<\s*channel\s*/?>"#,
            #"(?i)</\s*channel\s*>"#,
            #"(?i)<\s*\|\s*channel\s*\|\s*/?>"#,
            #"(?i)</\s*\|\s*channel\s*\|\s*>"#,
            #"(?i)<\s*\|\s*channel\s*/?>"#,
            #"(?i)</\s*\|\s*channel\s*>"#,
            #"(?i)\[\s*channel\s*\]"#,
            #"(?i)\[/\s*channel\s*\]"#,
            #"(?i)<\s*think\s*/?>"#,
            #"(?i)</\s*think\s*>"#,
            #"(?i)\[\s*thought\s*\]"#,
            #"(?i)\[/\s*thought\s*\]"#,
        ]
        for pattern in tagPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }

        // 3. Collapse stray lines that are only thinking markers or their remnants.
        //    This catches `<channel>thought` becoming `thought` after tag stripping.
        let lines = result.components(separatedBy: .newlines)
        let cleaned = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "thought" || trimmed == "|thought" || trimmed == "[thought]" {
                return ""
            }
            return line
        }
        result = cleaned.joined(separator: "\n")

        // 4. Collapse excessive blank lines and trim.
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
