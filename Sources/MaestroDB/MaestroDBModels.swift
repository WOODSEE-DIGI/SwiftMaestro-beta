import Foundation

// MARK: - MaestroDB Models
//
// Dynamic-schema database (Airtable-style): users define their own bases,
// tables, and typed fields. Values are stored as TEXT per (row, field) cell;
// typed parsing happens at the model layer. The schema covers every field
// type from day one — relation/attachment arrive UI-side later without
// migration.

/// A top-level database ("base" in Airtable terms).
struct MaestroBase: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var icon: String          // SF Symbol name
    var createdAt: Date
}

/// A table inside a base.
struct DBTable: Identifiable, Hashable, Sendable {
    let id: String
    let baseID: String
    var name: String
    var position: Int
}

/// Field (column) types. Raw values are persisted — never reorder/rename.
enum DBFieldType: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, longText, number, checkbox, date
    case select, multiSelect
    case url, email, phone
    case rating
    case relation      // value = linked row id (config: {"table": "<tableID>"})
    case attachment    // value = file path (MaestroDAM-aware later)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .longText: return "Long text"
        case .number: return "Number"
        case .checkbox: return "Checkbox"
        case .date: return "Date"
        case .select: return "Single select"
        case .multiSelect: return "Multi select"
        case .url: return "URL"
        case .email: return "Email"
        case .phone: return "Phone"
        case .rating: return "Rating"
        case .relation: return "Link to table"
        case .attachment: return "Attachment"
        }
    }

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .longText: return "text.alignleft"
        case .number: return "number"
        case .checkbox: return "checkmark.square"
        case .date: return "calendar"
        case .select: return "list.bullet.circle"
        case .multiSelect: return "list.bullet.indent"
        case .url: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .rating: return "star"
        case .relation: return "arrow.triangle.branch"
        case .attachment: return "paperclip"
        }
    }

    /// Types offered in the "Add field" UI. Relation (single-link) and
    /// attachment (file reference) editors shipped in Phase 3.
    static var uiSupported: [DBFieldType] {
        [.text, .longText, .number, .checkbox, .date, .select, .multiSelect, .url, .email, .phone, .rating, .relation, .attachment]
    }
}

/// A field (column) definition on a table.
struct DBField: Identifiable, Hashable, Sendable {
    let id: String
    let tableID: String
    var name: String
    var type: DBFieldType
    var position: Int
    /// Select/multiSelect option labels, in order.
    var options: [String]
    /// Type-specific config (e.g. relation target table id).
    var config: [String: String]
}

/// A row: ordered cells keyed by field id.
struct DBRow: Identifiable, Sendable {
    let id: String
    let tableID: String
    var position: Int
    var createdAt: Date
    var updatedAt: Date
    var values: [String: String]   // fieldID → raw text value

    func value(for fieldID: String) -> String { values[fieldID] ?? "" }

    // MARK: Typed accessors

    func bool(for fieldID: String) -> Bool { values[fieldID] == "1" }

    func number(for fieldID: String) -> Double? {
        guard let raw = values[fieldID], !raw.isEmpty else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    func date(for fieldID: String) -> Date? {
        guard let raw = values[fieldID], !raw.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    func rating(for fieldID: String) -> Int {
        Int(values[fieldID] ?? "") ?? 0
    }

    func multiValues(for fieldID: String) -> [String] {
        guard let raw = values[fieldID], !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }

    /// The best short display string for a field (grid/kanban title cells).
    func display(for field: DBField) -> String {
        let raw = value(for: field.id)
        switch field.type {
        case .checkbox: return bool(for: field.id) ? "✓" : ""
        case .rating:
            let n = rating(for: field.id)
            return n > 0 ? String(repeating: "★", count: n) : ""
        case .multiSelect: return multiValues(for: field.id).joined(separator: ", ")
        case .date:
            guard let d = date(for: field.id) else { return "" }
            return d.formatted(date: .abbreviated, time: .omitted)
        default: return raw
        }
    }

    /// Typed setter helpers (produce the canonical stored strings).
    static func store(_ value: Bool) -> String { value ? "1" : "0" }
    static func store(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }
    static func store(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    static func store(multi values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
