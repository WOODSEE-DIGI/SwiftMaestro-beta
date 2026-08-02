import Foundation

// MARK: - MaestroDB CSV
//
// One CSV engine shared by the UI Import/Export menu and the db_import_csv /
// db_export_csv agent tools, so a file means the same thing from either
// surface. Parser is a real RFC 4180 state machine (quoted fields, escaped
// quotes, embedded newlines, CRLF) — never a naive split(",").

enum MaestroDBCSV {

    // MARK: - Model

    struct Parsed: Sendable {
        var headers: [String]
        /// Data rows, each normalised to exactly `headers.count` cells
        /// (short rows padded with "", long rows truncated).
        var rows: [[String]]
    }

    struct ImportReport: Sendable {
        var rowsAdded = 0
        var fieldsCreated: [String] = []
        var optionsAdded = 0
        var cellsSkipped = 0
    }

    enum CSVError: Error, LocalizedError {
        case emptyFile
        case noHeaderRow
        case tableNotFound(String)

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "The CSV file is empty."
            case .noHeaderRow: return "The CSV has no header row."
            case .tableNotFound(let name): return "No table named '\(name)'."
            }
        }
    }

    // MARK: - Parse (RFC 4180)

    /// Parse CSV text into headers + rows. Tolerates CRLF, lone CR, a BOM,
    /// blank lines, and uneven row lengths. Quoted fields may contain commas,
    /// newlines, and ""-escaped quotes.
    static func parse(_ text: String) throws -> Parsed {
        var input = text
        if input.hasPrefix("\u{FEFF}") { input.removeFirst() } // BOM

        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var afterQuote = false
        var fieldStarted = false

        func endField() {
            record.append(field)
            field = ""
            fieldStarted = false
            afterQuote = false
        }
        func endRecord() {
            endField()
            // Skip blank lines (a record that is a single empty field and
            // was never quoted/started).
            let isBlank = record.count == 1 && record[0].isEmpty
            if !isBlank { records.append(record) }
            record = []
        }

        var index = input.startIndex
        while index < input.endIndex {
            let char = input[index]

            if inQuotes {
                if char == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex && input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                        continue
                    }
                    inQuotes = false
                    afterQuote = true
                } else {
                    field.append(char)
                }
            } else if afterQuote {
                // Lenient: a well-formed file has , / newline / EOF here.
                // Anything else is appended rather than failing the import.
                if char == "," {
                    endField()
                } else if char == "\n" || char == "\r" || char == "\r\n" {
                    endRecord()
                } else {
                    field.append(char)
                    afterQuote = false
                }
            } else {
                if char == "\"" && !fieldStarted {
                    inQuotes = true
                    fieldStarted = true
                } else if char == "," {
                    endField()
                } else if char == "\n" || char == "\r" || char == "\r\n" {
                    // NOTE: CRLF arrives as ONE Character (grapheme cluster),
                    // not two — comparing against "\r" alone never matches.
                    endRecord()
                } else {
                    field.append(char)
                    fieldStarted = true
                }
            }
            index = input.index(after: index)
        }
        // Final record (file may not end with a newline).
        if inQuotes { /* unterminated quote — accept what we have */ }
        if !field.isEmpty || !record.isEmpty || fieldStarted {
            endRecord()
        }

        guard let headers = records.first else { throw CSVError.emptyFile }
        let cleanedHeaders = headers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cleanedHeaders.contains(where: { !$0.isEmpty }) else {
            throw CSVError.noHeaderRow
        }

        let rows = records.dropFirst().map { row -> [String] in
            var cells = Array(row.prefix(cleanedHeaders.count))
            while cells.count < cleanedHeaders.count { cells.append("") }
            return cells
        }
        return Parsed(headers: cleanedHeaders, rows: rows)
    }

    // MARK: - Serialize

    /// Escape one cell per RFC 4180: quote when it contains a comma, quote,
    /// or newline; double internal quotes.
    static func escape(_ cell: String) -> String {
        guard cell.contains(",") || cell.contains("\"") || cell.contains("\n") || cell.contains("\r") else {
            return cell
        }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func serialize(headers: [String], rows: [[String]]) -> String {
        var lines = [headers.map(escape).joined(separator: ",")]
        for row in rows {
            var cells = Array(row.prefix(headers.count))
            while cells.count < headers.count { cells.append("") }
            lines.append(cells.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Export (DB → CSV text)

    /// Render a table as CSV: header row of field NAMES, one line per row,
    /// values in the round-trippable text form from MaestroDBCoercion.
    static func exportCSV(fields: [DBField], rows: [DBRow]) -> String {
        let headers = fields.map(\.name)
        let body = rows.map { row in
            fields.map { MaestroDBCoercion.csvText(row.value(for: $0.id), for: $0.type) }
        }
        return serialize(headers: headers, rows: body)
    }

    // MARK: - Type inference (new-table imports)

    /// Sniff a column of raw strings and pick the best field type.
    /// Conservative: only promotes to checkbox/number/date when EVERY
    /// non-empty value agrees; pure 0/1 columns stay numbers (they're more
    /// often counts than booleans); long values become longText.
    static func inferType(values: [String]) -> DBFieldType {
        let sample = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sample.isEmpty else { return .text }

        let boolish = sample.allSatisfy { MaestroDBCoercion.coerceBool($0) != nil }
        let hasNonNumericBool = sample.contains {
            Double($0.replacingOccurrences(of: ",", with: "")) == nil
        }
        if boolish && hasNonNumericBool { return .checkbox }

        if sample.allSatisfy({ Double($0.replacingOccurrences(of: ",", with: "")) != nil }) {
            return .number
        }
        if sample.allSatisfy({ MaestroDBCoercion.parseDate($0) != nil }) {
            return .date
        }
        if sample.contains(where: { $0.count > 100 || $0.contains("\n") }) {
            return .longText
        }
        return .text
    }

    // MARK: - Import (CSV → DB)

    /// Import parsed rows into an EXISTING table. Headers are matched to
    /// fields case-insensitively; unmatched columns become new fields with
    /// inferred types. Select options are auto-added. Cells whose value
    /// can't be coerced to the field type are skipped (counted in the
    /// report), never silently mangled.
    @discardableResult
    static func importRows(
        _ parsed: Parsed, into tableID: String, database: MaestroDBDatabase
    ) throws -> ImportReport {
        var report = ImportReport()
        var fields = try database.fields(tableID: tableID)

        // Resolve header → field, creating fields for unknown columns.
        var columnFields: [DBField?] = []
        for (columnIndex, header) in parsed.headers.enumerated() {
            guard !header.isEmpty else {
                columnFields.append(nil)
                continue
            }
            if let existing = fields.first(where: {
                $0.name.caseInsensitiveCompare(header) == .orderedSame
            }) {
                columnFields.append(existing)
            } else {
                let columnValues = parsed.rows.map { $0[columnIndex] }
                let inferred = inferType(values: columnValues)
                let created = try database.addField(
                    tableID: tableID, name: header, type: inferred)
                fields.append(created)
                columnFields.append(created)
                report.fieldsCreated.append(header)
            }
        }

        for rowCells in parsed.rows {
            var values: [String: String] = [:]
            for (columnIndex, cell) in rowCells.enumerated() {
                guard var field = columnFields[columnIndex] else { continue }
                let raw = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                guard let canonical = MaestroDBCoercion.canonical(raw, for: field.type) else {
                    report.cellsSkipped += 1
                    continue
                }
                if canonical.isEmpty { continue }
                // Select options auto-add (same behaviour as the UI's
                // "Add option…" cell flow and the kanban bridge).
                if field.type == .select, !field.options.contains(canonical) {
                    try database.addFieldOption(field.id, option: canonical)
                    field.options.append(canonical)
                    report.optionsAdded += 1
                }
                if field.type == .multiSelect {
                    for option in MaestroDBCoercion.coerceMulti(canonical) ?? []
                    where !field.options.contains(option) {
                        try database.addFieldOption(field.id, option: option)
                        field.options.append(option)
                        report.optionsAdded += 1
                    }
                }
                values[field.id] = canonical
            }
            _ = try database.addRow(tableID: tableID, values: values)
            report.rowsAdded += 1
        }
        return report
    }

    /// Create a NEW table from a parsed CSV: column types inferred from the
    /// data, then rows imported through the same path as `importRows`.
    @discardableResult
    static func createTable(
        from parsed: Parsed, baseID: String, name: String, database: MaestroDBDatabase
    ) throws -> (table: DBTable, report: ImportReport) {
        let table = try database.createTable(baseID: baseID, name: name)
        for (columnIndex, header) in parsed.headers.enumerated() where !header.isEmpty {
            let columnValues = parsed.rows.map { $0[columnIndex] }
            _ = try database.addField(
                tableID: table.id, name: header, type: inferType(values: columnValues))
        }
        var report = ImportReport(fieldsCreated: parsed.headers.filter { !$0.isEmpty })
        let rowReport = try importRows(parsed, into: table.id, database: database)
        report.rowsAdded = rowReport.rowsAdded
        report.optionsAdded = rowReport.optionsAdded
        report.cellsSkipped = rowReport.cellsSkipped
        return (table, report)
    }
}
