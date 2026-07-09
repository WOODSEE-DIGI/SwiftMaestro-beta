import Foundation

/// Shared thinking-tag / channel-tag stripper used by the executor stream,
/// the delegate-stream cache, and the message bubble UI as a safety net.
///
/// Gemma 4 emits reasoning markers in several forms depending on the checkpoint
/// and whether the output is tokenized with/without whitespace:
/// - bracket style: `[channel]`, `[/channel]`, `[thought]`, `[/thought]`
/// - plain angle style: `<channel>`, `</channel>`, `<channel/>`, `<channel >`
/// - pipe style: `<|channel>`, `</|channel>`, `<|channel|>`, `</|channel|>`
/// - bare reasoning markers: `thought`, `|thought`, `[thought]`
///
/// The function strips all of these and collapses the resulting whitespace.
enum ThinkingTagStripper {
    static func strip(_ text: String) -> String {
        var result = text

        // 1. Literal tag markers. Order matters: longer prefixes first.
        let patterns = [
            // Combined channel+thought tokens (Gemma 4 emits these as one token)
            "<channel>thought", "</channel>thought",
            "[channel]thought", "[/channel]thought",
            "<|channel>thought", "</|channel>thought",
            // Bracket style (Gemma 4)
            "[/channel]", "[/channel]>", "[channel]", "[channel]>",
            "[/thought]", "[/thought]>", "[thought]", "[thought]>", "[thought",
            // Pipe/angle style (Qwen and some Gemma 4 checkpoints)
            "</|channel|>", "<|channel|>", "</|channel|", "<|channel|",
            "</|channel>", "<|channel>", "<|channel>>", "</|channel>>",
            "<|channel|>thought", "<|channel>thought",
            "|thought>", "|/thought>", "|thought", "|/thought",
            // Plain angle style (observed in some Gemma 4 outputs)
            "</channel>", "<channel>", "<channel/>", "</channel/>",
            "<channel >", "</channel >",
            // Legacy / partial forms
            "<|channel", "</channel",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "")
        }

        // 2. Regex block stripping: remove `<channel>...</channel>` blocks
        // non-greedily, plus matching variants. This catches tags that span
        // token boundaries with content inside.
        let blockPatterns = [
            #"<\s*channel\s*[^>]*>.*?<\s*/\s*channel\s*>"#,
            #"<\|\s*channel\s*\|>.*?<\s*/\s*\|\s*channel\s*\|>"#,
            #"<\|\s*channel\s*>.*?<\s*/\s*\|\s*channel\s*>"#,
            #"\[\s*channel\s*\].*?\[/\s*channel\s*\]"#,
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }

        // 3. Collapse stray "thought" lines that are only thinking markers.
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
