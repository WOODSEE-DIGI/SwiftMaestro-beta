// Copyright © 2025 Apple Inc.
// SwiftMaestro: DeepSeek tool-call dialect (deepseek_v2 / deepseek_v3 model families).

import Foundation

/// Parser for the DeepSeek tool-call format used by DeepSeek-Coder-V2-Lite /
/// DeepSeek-V3 style models:
///
/// ```
/// <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>read_file
/// ```json
/// {"path": "/tmp/notes.txt"}
/// ```<｜tool▁call▁end｜><｜tool▁calls▁end｜>
/// ```
///
/// The plural wrapper tags are the stream markers so the per-call singular tags
/// and the `function`/`<｜tool▁sep｜>` preamble never leak into visible content.
/// When `<｜tool▁calls▁end｜>` is registered as a stop token, it is intercepted
/// at the token-id level and never reaches the text stream — in that case the
/// buffer ends after the last singular `<｜tool▁call▁end｜>` and `parseEOS`
/// extracts the call(s) at generation end.
public struct DeepSeekToolCallParser: ToolCallParser, Sendable {
    public let startTag: String? = "<｜tool▁calls▁begin｜>"
    public let endTag: String? = "<｜tool▁calls▁end｜>"

    private let callBegin = "<｜tool▁call▁begin｜>"
    private let callEnd = "<｜tool▁call▁end｜>"
    private let separator = "<｜tool▁sep｜>"

    public init() {}

    public func parse(content: String, tools: [[String: any Sendable]]?) -> ToolCall? {
        parseAll(content: content, tools: tools).first
    }

    /// The protocol default splits on `startTag`, which would merge all calls in
    /// the plural wrapper into one blob — split on the singular tag instead so
    /// every call in the block is recovered.
    public func parseEOS(_ toolCallBuffer: String, tools: [[String: any Sendable]]?) -> [ToolCall] {
        parseAll(content: toolCallBuffer, tools: tools)
    }

    private func parseAll(content: String, tools: [[String: any Sendable]]?) -> [ToolCall] {
        // Per-call segments: everything between each <｜tool▁call▁begin｜> and its
        // matching <｜tool▁call▁end｜>. dropFirst() discards any preamble (incl.
        // the plural wrapper start tag).
        content.components(separatedBy: callBegin).dropFirst().compactMap { segment in
            var body = segment
            if let endRange = body.range(of: callEnd) {
                body = String(body[..<endRange.lowerBound])
            }
            // Expect: function<｜tool▁sep｜>NAME\n```json\n{…}\n```
            guard let sepRange = body.range(of: separator) else { return nil }
            // The call-type literal ("function"/"code_interpreter") precedes the
            // separator; the delimiters already delineate the call block, so the
            // literal itself is not validated.

            var rest = String(body[sepRange.upperBound...])
            // Name runs to the first newline (or the json fence, whichever first).
            let nameEnd = rest.firstIndex(where: { $0 == "\n" || $0 == "`" })
                ?? rest.endIndex
            let name = rest[..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            rest = String(rest[nameEnd...])

            // Arguments live inside a ```json … ``` fence.
            guard let fenceStart = rest.range(of: "```json") ?? rest.range(of: "```")
            else { return nil }
            var args = String(rest[fenceStart.upperBound...])
            if let fenceEnd = args.range(of: "```") {
                args = String(args[..<fenceEnd.lowerBound])
            }
            args = args.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = args.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data)
                    as? [String: any Sendable]
            else { return nil }

            // If tool schemas are provided, only accept calls to declared tools.
            if let tools, !tools.isEmpty {
                let declared = tools.contains { tool in
                    (tool["function"] as? [String: any Sendable])?["name"] as? String == name
                }
                guard declared else { return nil }
            }

            return ToolCall(function: .init(name: name, arguments: arguments))
        }
    }
}
