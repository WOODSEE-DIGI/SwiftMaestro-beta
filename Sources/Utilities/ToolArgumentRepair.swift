import Foundation

/// Repairs malformed JSON argument blobs produced by small local models.
///
/// Gemma 4 and other compact checkpoints sometimes emit tool-call JSON with
/// structural mistakes that strict `JSONDecoder` / `JSONSerialization` accept
/// but that leave the wrong keys, so the tool handler sees empty/missing
/// parameters. Two patterns are handled:
///
/// 1. **String-wrapped JSON**: the model emits the entire object as a JSON
///    string literal, e.g. `"{\"query\":\"swift\"}"`. We unwrap the literal
///    and use the inner object.
/// 2. **Keys wrapped in JSON object punctuation**: the model leaks an extra
///    quote or brace into the key, e.g. `{"\\\"query":"swift"}` or
///    `{"{"query":"swift"}`. We strip the punctuation and keep the
///    intended identifier.
/// 3. **Value prefixed with the key name**: small models sometimes emit the
///    parameter value as `query="swift"` or `query=swift` instead of just
///    `swift`. We strip the leading `key=` prefix and surrounding quotes.
enum ToolArgumentRepair {
    static func repair(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{}" }

        let unwrapped = unwrapStringLiteral(trimmed) ?? trimmed

        guard let data = unwrapped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return unwrapped
        }

        var repaired: [String: Any] = [:]
        var changed = false
        for (key, value) in obj {
            let cleanKey = cleanKey(key)
            if cleanKey != key { changed = true }
            guard !cleanKey.isEmpty else { continue }
            let cleanValue = repairValue(cleanKey, value: value)
            if let oldStr = value as? String, let newStr = cleanValue as? String, oldStr != newStr {
                changed = true
            }
            repaired[cleanKey] = cleanValue
        }

        if !changed { return unwrapped }

        guard let out = try? JSONSerialization.data(withJSONObject: repaired, options: []),
              let outString = String(data: out, encoding: .utf8)
        else {
            return unwrapped
        }
        return outString
    }

    // MARK: - Private helpers

    private static func unwrapStringLiteral(_ json: String) -> String? {
        guard json.count >= 2,
              json.hasPrefix("\""),
              json.hasSuffix("\"")
        else { return nil }

        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data)
        else { return nil }

        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let innerData = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: innerData)) != nil
        else { return nil }
        return trimmed
    }

    private static func cleanKey(_ key: String) -> String {
        guard key.contains("\"") || key.contains("{") || key.contains("}") || key.contains(" ") else {
            return key
        }
        var cleaned = key
        while let first = cleaned.first, ["\"", "{", " "].contains(first) {
            cleaned.removeFirst()
        }
        while let last = cleaned.last, ["\"", "}", " "].contains(last) {
            cleaned.removeLast()
        }
        return cleaned
    }

    /// Strip a leading `key="value"` or `key=value` prefix that some models
    /// emit inside the parameter value.
    private static func repairValue(_ key: String, value: Any) -> Any {
        guard var cleaned = value as? String else { return value }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove a leading `key=` or `key:` prefix.
        let prefixes = ["\(key)=", "\(key):"]
        for prefix in prefixes {
            if cleaned.hasPrefix(prefix) {
                cleaned.removeFirst(prefix.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Remove surrounding double quotes, even if unbalanced.
        if cleaned.hasPrefix("\"") {
            cleaned.removeFirst()
        }
        if cleaned.hasSuffix("\"") {
            cleaned.removeLast()
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
