import Foundation
import JavaScriptCore

/// Parses JSON-like blobs that small models emit but that strict JSONDecoder
/// rejects: unquoted object keys, single-quoted strings, trailing commas, etc.
/// Uses JavaScriptCore as a forgiving parser and returns the result as a
/// Foundation dictionary/array/string/number/bool/null.
enum LenientJSON {

    /// Best-effort parse of `raw`. Returns `nil` if the input cannot be interpreted.
    static func parse(_ raw: String) -> Any? {
        let cleaned = cleanArtifacts(raw)

        // Fast path: already strict JSON.
        if let data = cleaned.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) {
            return value
        }

        // Fallback: evaluate as a JS expression and stringify back to JSON.
        guard let ctx = JSContext() else { return nil }
        // Prevent template-literal ${...} interpolation from executing arbitrary code.
        let sanitized = cleaned.replacingOccurrences(of: "${", with: "\\${")
        let script = "var __sm_lenient_input = \(sanitized); JSON.stringify(__sm_lenient_input);"
        guard let result = ctx.evaluateScript(script),
              result.isString,
              let jsonString = result.toString(),
              let data = jsonString.data(using: .utf8)
        else { return nil }

        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Convenience cast to a string-keyed dictionary.
    static func dictionary(_ raw: String) -> [String: Any]? {
        parse(raw) as? [String: Any]
    }

    private static func cleanArtifacts(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "<|\"|>", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "<|", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "|>", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "“", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "”", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "‘", with: "'")
        cleaned = cleaned.replacingOccurrences(of: "’", with: "'")
        return cleaned
    }
}
