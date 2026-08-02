import Foundation

// MARK: - MaestroDB Value Coercion
//
// One canonical "raw string → stored string" path per field type, shared by
// the agent tools (db_add_row/db_update_row) and CSV import so a value means
// the same thing no matter which surface wrote it. Never throws — an
// uncoercible value returns nil and the caller decides whether that's an
// error (tools: report it) or a skip (CSV import: leave the cell empty).

enum MaestroDBCoercion {

    /// Coerce a human/agent-supplied raw string into the canonical stored
    /// string for the field type (the same strings DBRow.store produces).
    /// Empty input always succeeds as "" (clears the cell).
    static func canonical(_ raw: String, for type: DBFieldType) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch type {
        case .text, .longText, .url, .email, .phone:
            return trimmed

        case .number:
            guard let number = Double(trimmed.replacingOccurrences(of: ",", with: "")) else { return nil }
            return DBRow.store(number)

        case .checkbox:
            return coerceBool(trimmed).map(DBRow.store)

        case .date:
            return parseDate(trimmed).map(DBRow.store)

        case .select:
            // Stored verbatim; option auto-adding is the caller's job.
            return trimmed

        case .multiSelect:
            return coerceMulti(trimmed).map(DBRow.store(multi:))

        case .rating:
            guard let value = Int(trimmed), (1...5).contains(value) else { return nil }
            return String(value)

        case .relation, .attachment:
            // Schema-ready, editor-less: store the raw reference verbatim.
            return trimmed
        }
    }

    /// Lenient checkbox: true/false, yes/no, 1/0, x, checked.
    static func coerceBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "y", "x", "✓", "✔", "checked": return true
        case "0", "false", "no", "n", "unchecked": return false
        default: return nil
        }
    }

    /// Multi-select accepts a JSON array (`["a","b"]`) or a separator-split
    /// string (semicolon preferred — comma splits collide with CSV quoting
    /// but still work when the whole cell was quoted).
    static func coerceMulti(_ raw: String) -> [String]? {
        if raw.hasPrefix("["),
           let data = raw.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            return array.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let separator: Character = raw.contains(";") ? ";" : ","
        let parts = raw.split(separator: separator).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }

    /// Dates: ISO8601 (canonical), then common CSV-friendly formats.
    static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: raw) { return date }

        let formats = [
            "yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "d MMM yyyy",
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    // MARK: - Export (canonical → CSV cell text)

    /// Human-friendly, round-trippable CSV representation of a stored value.
    /// Numbers/dates/multiSelect/checkbox all re-import losslessly through
    /// `canonical(_:for:)`.
    static func csvText(_ stored: String, for type: DBFieldType) -> String {
        guard !stored.isEmpty else { return "" }
        switch type {
        case .checkbox:
            return stored == "1" ? "true" : "false"
        case .multiSelect:
            // JSON array re-imports exactly; a plain comma-joined string would
            // split wrongly when an option itself contains a comma.
            return stored
        case .date:
            // Stored value is already ISO8601 — pass through.
            return stored
        default:
            return stored
        }
    }
}
