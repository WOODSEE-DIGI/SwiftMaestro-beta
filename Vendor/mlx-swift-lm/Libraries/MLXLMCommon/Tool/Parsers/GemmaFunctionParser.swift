// Copyright © 2025 Apple Inc.

import Foundation

/// Parser for Gemma format: call:name{key:value,k:<escape>str<escape>}
/// Reference: https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/tool_parsers/function_gemma.py
public struct GemmaFunctionParser: ToolCallParser, Sendable {
    public let startTag: String?
    public let endTag: String?
    public let escapeMarker: String?

    public init(startTag: String, endTag: String, escapeMarker: String) {
        self.startTag = startTag
        self.endTag = endTag
        self.escapeMarker = escapeMarker
    }

    public func parse(content: String, tools: [[String: any Sendable]]?) -> ToolCall? {
        // Unwrap
        guard let start = startTag, let end = endTag else { return nil }
        guard let marker = escapeMarker else { return nil }

        // Strip tags if present
        var text = content
        if let startRange = text.range(of: start) {
            text = String(text[startRange.upperBound...])
        }
        if let endRange = text.range(of: end) {
            text = String(text[..<endRange.lowerBound])
        }

        // Pattern: call:(\w+)\{(.*?)\}
        // Find "call:" followed by function name and arguments in braces
        guard let callRange = text.range(of: "call:") else { return nil }

        let remaining = String(text[callRange.upperBound...])

        // Extract function name (word characters until {)
        guard let braceStart = remaining.firstIndex(of: "{") else { return nil }
        let funcName = String(remaining[..<braceStart])

        guard !funcName.isEmpty else { return nil }

        // Extract arguments string (everything between { and })
        guard let braceEnd = remaining.lastIndex(of: "}") else { return nil }
        var argsStr = String(remaining[remaining.index(after: braceStart) ..< braceEnd])

        var arguments: [String: any Sendable] = [:]

        // Parse key:value pairs
        while !argsStr.isEmpty {
            // Find the key (everything before :)
            guard let colonIdx = argsStr.firstIndex(of: ":") else { break }
            var key = String(argsStr[..<colonIdx])
            // Small models frequently escape-delimit KEYS too (`<|"|>url<|"|>`
            // instead of `url`), which leaves the handler unable to find the
            // parameter. Strip the escape marker from either end of the key.
            if key.hasPrefix(marker) { key = String(key.dropFirst(marker.count)) }
            if key.hasSuffix(marker) { key = String(key.dropLast(marker.count)) }
            argsStr = String(argsStr[argsStr.index(after: colonIdx)...])

            // Handle escape-delimited strings: <marker>value<marker>
            if argsStr.hasPrefix(marker) {
                argsStr = String(argsStr.dropFirst(marker.count))
                guard let endEscape = argsStr.range(of: marker) else { break }
                let value = String(argsStr[..<endEscape.lowerBound])
                arguments[key] = value
                argsStr = String(argsStr[endEscape.upperBound...])
                // Skip comma if present
                if argsStr.hasPrefix(",") {
                    argsStr = String(argsStr.dropFirst())
                }
                continue
            }

            // Handle composite values (arrays/objects). These start with [ or {
            // rather than the escape marker, so the escape markers INSIDE them
            // must be converted to real quotes before JSON decoding — otherwise a
            // value like [<|"|>a<|"|>,<|"|>b<|"|>] is stored as a raw, token-laden
            // string (and naively reading "until comma" would split it apart).
            if let first = argsStr.first, first == "[" || first == "{",
                let (composite, rest) = Self.extractBalanced(argsStr, marker: marker)
            {
                let jsonText = composite.replacingOccurrences(of: marker, with: "\"")
                if let data = jsonText.data(using: .utf8),
                    let json = deserializeJSON(data)
                {
                    arguments[key] = json
                } else {
                    arguments[key] = composite
                }
                argsStr = rest
                if argsStr.hasPrefix(",") {
                    argsStr = String(argsStr.dropFirst())
                }
                continue
            }

            // Handle scalar values (number/bool/bare word) — until comma or end
            let commaIdx = argsStr.firstIndex(of: ",") ?? argsStr.endIndex
            let value = String(argsStr[..<commaIdx])
            argsStr =
                commaIdx < argsStr.endIndex
                ? String(argsStr[argsStr.index(after: commaIdx)...]) : ""

            // Try JSON decode, fallback to string
            if let data = value.data(using: .utf8),
                let json = deserializeJSON(data)
            {
                arguments[key] = json
            } else {
                arguments[key] = value
            }
        }

        return ToolCall(function: .init(name: funcName, arguments: arguments))
    }

    /// Extract a balanced `[...]` or `{...}` block from the start of `text`,
    /// skipping brackets that appear inside escape-delimited `<marker>...<marker>`
    /// strings. Returns the block (including its outer brackets) and the
    /// remaining argument string after it, or nil if no balanced block exists.
    private static func extractBalanced(_ text: String, marker: String) -> (block: String, rest: String)? {
        guard let first = text.first, first == "[" || first == "{" else { return nil }
        let open = first
        let close: Character = open == "[" ? "]" : "}"
        var depth = 0
        var index = text.startIndex
        var inEscape = false
        while index < text.endIndex {
            if !inEscape, text[index...].hasPrefix(marker) {
                inEscape = true
                index = text.index(index, offsetBy: marker.count)
                continue
            }
            if inEscape {
                if text[index...].hasPrefix(marker) {
                    inEscape = false
                    index = text.index(index, offsetBy: marker.count)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            let character = text[index]
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    let block = String(text[...index])
                    let rest = String(text[text.index(after: index)...])
                    return (block, rest)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
