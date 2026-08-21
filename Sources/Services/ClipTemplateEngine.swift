import Foundation

// MARK: - Clip Template Engine
//
// Resolves {{variable}} interpolations against a WebClipResult, with pipe
// filters. Variable set mirrors the Obsidian Web Clipper:
//
//   title, content, contentHtml, fullHtml, excerpt, description, author,
//   published, site, url, domain, favicon, image, language, words,
//   noteName, date, time, created
//   meta:name:<name> / meta:property:<prop>   — raw meta tag lookup
//   schema:<path>                             — schema.org JSON-LD lookup
//                                               (e.g. schema:@VideoObject:name)
//
// Filters (pipe-separated, applied left to right):
//   date:"yyyy-MM-dd"     — parse + reformat dates (ISO, RFC, common formats)
//   default:"fallback"    — use fallback when value is empty
//   upper / lower / title — case transforms
//   trim                  — whitespace trim
//   replace:"a","b"       — literal string replace
//   slice:start[,end]     — substring slice
//   join:", "             — join (value split on "," first)
//   words                 — word count of the value
//   link                  — wrap a URL as [domain](url)
//   safe_name             — filename-safe

enum ClipTemplateEngine {

    // MARK: - Variable dictionary

    /// Build the full variable dictionary from a clip result.
    static func buildVariables(from clip: WebClipResult) -> [String: String] {
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        var vars: [String: String] = [
            "title": clip.title,
            "content": clip.markdown,
            "contentHtml": clip.html,
            "fullHtml": clip.fullHtml,
            "excerpt": clip.excerpt,
            "description": clip.description.isEmpty ? clip.excerpt : clip.description,
            "author": clip.author,
            "published": clip.published,
            "site": clip.site,
            "url": clip.url,
            "domain": clip.domain,
            "favicon": clip.favicon,
            "image": clip.image,
            "language": clip.language,
            "words": String(clip.wordCount),
            "noteName": safeFileName(clip.title),
            "date": iso,
            "time": iso,
            "created": iso,
        ]
        // Meta tags: meta:name:description / meta:property:og:title
        for tag in clip.metaTags {
            if let name = tag.name {
                vars["meta:name:\(name)"] = tag.content
            }
            if let property = tag.property {
                vars["meta:property:\(property)"] = tag.content
            }
        }
        // Extractor extras (e.g. YouTube transcript when a site extractor fired)
        for (key, value) in clip.extractorVariables where vars[key] == nil {
            vars[key] = value
        }
        if !clip.extractorType.isEmpty {
            vars["extractor"] = clip.extractorType
        }
        // Schema.org: flatten each JSON-LD block
        for block in clip.schemaOrg {
            flattenSchema(block.raw, into: &vars, prefix: "")
        }
        return vars
    }

    // MARK: - Schema.org flattening

    /// Flatten a JSON-LD block into schema: variables. Mirrors the Obsidian
    /// clipper: {{schema:@Type:key}} per typed object, nested keys dotted.
    private static func flattenSchema(_ raw: String, into vars: inout [String: String], prefix: String) {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return }
        flattenSchemaValue(value, into: &vars, prefix: prefix)
    }

    private static func flattenSchemaValue(_ value: Any, into vars: inout [String: String], prefix: String) {
        if let array = value as? [Any] {
            for (index, item) in array.enumerated() {
                guard let dict = item as? [String: Any] else { continue }
                if let type = dict["@type"] as? String {
                    flattenSchemaObject(dict, into: &vars, prefix: "@\(type):")
                } else {
                    flattenSchemaObject(dict, into: &vars, prefix: "\(prefix)[\(index)]:")
                }
            }
        } else if let dict = value as? [String: Any] {
            if let type = dict["@type"] as? String {
                flattenSchemaObject(dict, into: &vars, prefix: "@\(type):")
            } else {
                flattenSchemaObject(dict, into: &vars, prefix: prefix)
            }
        }
    }

    private static func flattenSchemaObject(_ dict: [String: Any], into vars: inout [String: String], prefix: String) {
        for (key, value) in dict where key != "@type" {
            let varKey = "schema:\(prefix)\(key)"
            switch value {
            case let s as String: vars[varKey] = s
            case let n as NSNumber: vars[varKey] = n.stringValue
            case let a as [Any]:
                vars[varKey] = (try? String(data: JSONSerialization.data(withJSONObject: a), encoding: .utf8)) ?? nil ?? ""
                for (i, item) in a.enumerated() {
                    if let d = item as? [String: Any] {
                        flattenSchemaObject(d, into: &vars, prefix: "\(prefix)\(key)[\(i)].")
                    }
                }
            case let d as [String: Any]:
                flattenSchemaObject(d, into: &vars, prefix: "\(prefix)\(key).")
            default: break
            }
        }
    }

    // MARK: - Rendering

    /// Render a template string against variables. Supports nested defaults
    /// like {{a|default:{{b}}}}.
    static func render(_ template: String, variables: [String: String]) -> String {
        renderInterpolations(in: template, variables: variables)
    }

    private static func renderInterpolations(in text: String, variables: [String: String]) -> String {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            guard let open = text.range(of: "{{", range: i..<text.endIndex) else {
                result += text[i...]
                break
            }
            result += text[i..<open.lowerBound]
            // Find matching close, honoring nested {{ inside (default: args)
            var depth = 1
            var j = open.upperBound
            var closeRange: Range<String.Index>?
            while j < text.endIndex {
                if let nextOpen = text.range(of: "{{", range: j..<text.endIndex),
                   let nextClose = text.range(of: "}}", range: j..<text.endIndex) {
                    if nextOpen.lowerBound < nextClose.lowerBound {
                        depth += 1
                        j = nextOpen.upperBound
                    } else {
                        depth -= 1
                        if depth == 0 {
                            closeRange = nextClose
                            break
                        }
                        j = nextClose.upperBound
                    }
                } else if let nextClose = text.range(of: "}}", range: j..<text.endIndex) {
                    depth -= 1
                    if depth == 0 {
                        closeRange = nextClose
                        break
                    }
                    j = nextClose.upperBound
                } else {
                    break
                }
            }
            guard let close = closeRange else {
                // Unterminated — emit the rest literally
                result += text[open.lowerBound...]
                return result
            }
            let expr = String(text[open.upperBound..<close.lowerBound])
            result += evaluateExpression(expr, variables: variables)
            i = close.upperBound
        }
        return result
    }

    /// Evaluate one {{...}} expression: variable path + pipe filters.
    private static func evaluateExpression(_ expr: String, variables: [String: String]) -> String {
        let parts = splitFilters(expr)
        guard let first = parts.first else { return "" }
        var value = resolveVariable(first.trimmingCharacters(in: .whitespaces), variables: variables)
        for filter in parts.dropFirst() {
            value = applyFilter(filter.trimmingCharacters(in: .whitespaces), to: value, variables: variables)
        }
        return value
    }

    /// Split on | but not inside quotes.
    private static func splitFilters(_ expr: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        for char in expr {
            if char == "\"" { inQuote.toggle(); current.append(char) }
            else if char == "|" && !inQuote { parts.append(current); current = "" }
            else { current.append(char) }
        }
        parts.append(current)
        return parts
    }

    // MARK: - Variable resolution

    private static func resolveVariable(_ name: String, variables: [String: String]) -> String {
        // Nested template as a value ({{...}} inside default:)
        if name.hasPrefix("{{") {
            return renderInterpolations(in: name, variables: variables)
        }
        // Quoted literal
        if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
            return String(name.dropFirst().dropLast())
        }
        if let value = variables[name] { return value }
        // Schema shorthand: schema:name → first schema:@*:name match
        if name.hasPrefix("schema:"), !name.contains("@") {
            let suffix = String(name.dropFirst("schema:".count))
            for (key, value) in variables where key.hasPrefix("schema:@") && key.hasSuffix(":\(suffix)") {
                return value
            }
        }
        return ""
    }

    // MARK: - Filters

    private static func applyFilter(_ filter: String, to value: String, variables: [String: String]) -> String {
        let (name, args) = parseFilter(filter)
        switch name {
        case "date":
            let format = args.first ?? "yyyy-MM-dd"
            return reformatDate(value, to: format)
        case "default":
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let raw = args.first ?? ""
                return resolveVariable(raw, variables: variables)
            }
            return value
        case "upper": return value.uppercased()
        case "lower": return value.lowercased()
        case "title": return value.capitalized
        case "trim": return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case "replace":
            guard args.count >= 2 else { return value }
            return value.replacingOccurrences(of: args[0], with: args[1])
        case "slice":
            guard let start = args.first.flatMap(Int.init) else { return value }
            let chars = Array(value)
            let lo = start >= 0 ? min(start, chars.count) : max(0, chars.count + start)
            let hi: Int
            if args.count >= 2, let end = Int(args[1]) {
                hi = end >= 0 ? min(end, chars.count) : max(0, chars.count + end)
            } else {
                hi = chars.count
            }
            guard lo < hi else { return "" }
            return String(chars[lo..<hi])
        case "join":
            let sep = args.first ?? ", "
            return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: sep)
        case "words":
            return String(value.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count)
        case "link":
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return value }
            return "[\(url.host ?? trimmed)](\(trimmed))"
        case "safe_name": return safeFileName(value)
        default: return value
        }
    }

    /// Parse `name:"arg1","arg2"` into (name, [args]).
    private static func parseFilter(_ filter: String) -> (String, [String]) {
        guard let colon = filter.firstIndex(of: ":") else {
            return (filter, [])
        }
        let name = String(filter[..<colon])
        let argsString = String(filter[filter.index(after: colon)...])
        var args: [String] = []
        var current = ""
        var inQuote = false
        for char in argsString {
            if char == "\"" { inQuote.toggle() }
            else if char == "," && !inQuote { args.append(current); current = "" }
            else { current.append(char) }
        }
        if !current.isEmpty || argsString.hasSuffix(",") { args.append(current) }
        args = args.map { $0.trimmingCharacters(in: .whitespaces) }
        return (name, args)
    }

    // MARK: - Date reformatting

    private static let inputDateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "MMMM d, yyyy",
            "MMM d, yyyy",
            "d MMMM yyyy",
            "dd/MM/yyyy",
            "MM/dd/yyyy",
        ]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()

    private static func reformatDate(_ value: String, to format: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // ISO8601 first (most common from meta tags / schema.org)
        if let date = ISO8601DateFormatter().date(from: trimmed) {
            return formatDate(date, format: format)
        }
        for formatter in inputDateFormatters {
            if let date = formatter.date(from: trimmed) {
                return formatDate(date, format: format)
            }
        }
        return trimmed  // unparsable — return as-is rather than dropping data
    }

    private static func formatDate(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Translate common moment.js-style tokens users may paste from Obsidian templates
        let translated = format
            .replacingOccurrences(of: "YYYY", with: "yyyy")
            .replacingOccurrences(of: "DD", with: "dd")
        f.dateFormat = translated
        return f.string(from: date)
    }

    // MARK: - YAML frontmatter

    /// Render properties to YAML frontmatter, Obsidian-style. Empty template
    /// list or all-empty values produce no frontmatter block.
    static func renderFrontmatter(properties: [ClipProperty], variables: [String: String]) -> String {
        var lines: [String] = []
        for property in properties {
            let rendered = render(property.valueTemplate, variables: variables)
            let name = property.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let key = needsYAMLEscaping(name) ? "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"" : name
            switch property.type {
            case .multitext:
                let items = splitMultitext(rendered)
                if items.isEmpty { continue }
                var block = "\(key):\n"
                for item in items {
                    block += "  - \"\(item.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
                }
                lines.append(block.trimmingCharacters(in: .newlines))
            case .number:
                let numeric = rendered.filter { $0.isNumber || $0 == "." || $0 == "-" }
                if let value = Double(numeric), !numeric.isEmpty {
                    lines.append("\(key): \(value)")
                }
            case .checkbox:
                let checked = ["true", "1", "yes"].contains(rendered.lowercased())
                lines.append("\(key): \(checked)")
            case .date, .datetime:
                if !rendered.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("\(key): \(rendered)")
                }
            case .text:
                guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lines.append("\(key): \"\(rendered.replacingOccurrences(of: "\"", with: "\\\""))\"")
            }
        }
        guard !lines.isEmpty else { return "" }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }

    private static func needsYAMLEscaping(_ name: String) -> Bool {
        name.contains(where: { ":#{}[],&*?|<>!%@\\- ".contains($0) })
            || name.first?.isNumber == true
            || ["true", "false", "null", "yes", "no", "on", "off"].contains(name.lowercased())
    }

    private static func splitMultitext(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON array form
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]"),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return array.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Utilities

    static func safeFileName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        result = result.components(separatedBy: forbidden).joined()
        result = result.replacingOccurrences(of: "\n", with: " ")
        if result.count > 200 { result = String(result.prefix(200)) }
        return result.isEmpty ? "Untitled" : result
    }
}
