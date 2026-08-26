import Foundation

// MARK: - Lightroom Catalog CSV Parser
//
// Minimal RFC4180 parser for Lightroom catalog exports: quoted fields,
// escaped quotes (""), embedded commas and newlines inside quotes. Streaming
// over a scalar view keeps 160K-row files fast without a third-party CSV
// dependency (project policy: avoid new packages when Foundation suffices).

enum LightroomCSVParser {

    /// Parse CSV text into rows of string fields. The first row is whatever
    /// the file contains (callers treat it as the header when present).
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String()
        var inQuotes = false
        var iterator = text.makeIterator()

        func endField() {
            row.append(field)
            field = String()
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    // Peek: doubled quote = escaped quote, else end of quotes.
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                endField()
                            // NB: "\r\n" is a SINGLE Character (grapheme
                            // cluster) — it never matches "\r" or "\n"
                            // separately and must be handled as one case.
                            } else if next == "\r\n" || next == "\n" || next == "\r" {
                                endRow()
                            } else {
                                field.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"": inQuotes = true
                case ",": endField()
                // NB: "\r\n" is a SINGLE Character (grapheme cluster) — it
                // never matches "\r" or "\n" separately; it must be its own
                // case or CRLF files parse as one giant row. Lone "\r"
                // covers legacy Mac line endings.
                case "\r\n", "\n", "\r": endRow()
                default: field.append(char)
                }
            }
        }
        // Trailing field/row when the file doesn't end with a newline.
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        // Drop a fully-empty trailing row (file ended with \n).
        if let last = rows.last, last.count == 1, last[0].isEmpty {
            rows.removeLast()
        }
        return rows
    }

    /// Map header names → column indices (case-insensitive, trimmed), so the
    /// importer tolerates column reordering and extra columns.
    static func headerIndex(_ header: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            map[name.trimmingCharacters(in: .whitespaces).lowercased()] = index
        }
        return map
    }
}
