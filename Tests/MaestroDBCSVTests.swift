import Foundation
import Testing
@testable import SwiftMaestro

// MARK: - MaestroDB CSV + Coercion tests
//
// Covers the two riskiest Phase 2 surfaces: the RFC 4180 parser/serializer
// and the coercion every value flows through (agent tools + CSV import).
// Integration tests open throwaway databases in temp dirs — the shared
// singleton (and the user's real maestrodb.sqlite) is never touched.

@Suite("MaestroDBCSV")
struct MaestroDBCSVTests {

    // MARK: - Parser

    @Test func parseSimple() throws {
        let parsed = try MaestroDBCSV.parse("Name,Age\nAda,36\nGrace,45\n")
        #expect(parsed.headers == ["Name", "Age"])
        #expect(parsed.rows == [["Ada", "36"], ["Grace", "45"]])
    }

    @Test func parseQuotedCommaAndEscapedQuote() throws {
        let parsed = try MaestroDBCSV.parse("Name,Note\n\"Smith, Jane\",\"said \"\"hi\"\" twice\"\n")
        #expect(parsed.rows == [["Smith, Jane", "said \"hi\" twice"]])
    }

    @Test func parseEmbeddedNewlineInQuotes() throws {
        let parsed = try MaestroDBCSV.parse("Name,Note\nAda,\"line one\nline two\"\nGrace,plain\n")
        #expect(parsed.rows.count == 2)
        #expect(parsed.rows[0] == ["Ada", "line one\nline two"])
        #expect(parsed.rows[1] == ["Grace", "plain"])
    }

    @Test func parseCRLFAndLoneCR() throws {
        let crlf = try MaestroDBCSV.parse("A,B\r\n1,2\r\n3,4\r\n")
        #expect(crlf.rows == [["1", "2"], ["3", "4"]])
        let cr = try MaestroDBCSV.parse("A,B\r1,2\r")
        #expect(cr.rows == [["1", "2"]])
    }

    @Test func parseSkipsBlankLinesAndBOM() throws {
        let parsed = try MaestroDBCSV.parse("\u{FEFF}A,B\n\n1,2\n\n")
        #expect(parsed.headers == ["A", "B"])
        #expect(parsed.rows == [["1", "2"]])
    }

    @Test func parseNormalisesUnevenRows() throws {
        let parsed = try MaestroDBCSV.parse("A,B,C\n1,2\n3,4,5,6\n")
        #expect(parsed.rows == [["1", "2", ""], ["3", "4", "5"]])
    }

    @Test func parseTrimsHeaderWhitespace() throws {
        let parsed = try MaestroDBCSV.parse(" Name , Age \nAda,36\n")
        #expect(parsed.headers == ["Name", "Age"])
    }

    @Test func parseEmptyThrows() {
        #expect(throws: MaestroDBCSV.CSVError.self) {
            _ = try MaestroDBCSV.parse("")
        }
        #expect(throws: MaestroDBCSV.CSVError.self) {
            _ = try MaestroDBCSV.parse(" , \n")
        }
    }

    // MARK: - Serialize / round-trip

    @Test func escapeQuotesOnlyWhenNeeded() {
        #expect(MaestroDBCSV.escape("plain") == "plain")
        #expect(MaestroDBCSV.escape("a,b") == "\"a,b\"")
        #expect(MaestroDBCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(MaestroDBCSV.escape("two\nlines") == "\"two\nlines\"")
    }

    @Test func serializeParseRoundTrip() throws {
        let headers = ["Name", "Note", "Count"]
        let rows = [
            ["Smith, Jane", "said \"hi\"\ntwice", "3"],
            ["", "", ""],
            ["☃︎ unicode", "café", "1,000"],
        ]
        let text = MaestroDBCSV.serialize(headers: headers, rows: rows)
        let parsed = try MaestroDBCSV.parse(text)
        #expect(parsed.headers == headers)
        #expect(parsed.rows == rows)
    }

    // MARK: - Type inference

    @Test func inferCheckboxFromBoolTokensOnly() {
        #expect(MaestroDBCSV.inferType(values: ["true", "false", "yes", ""]) == .checkbox)
    }

    @Test func inferZeroOneStaysNumber() {
        // Pure 0/1 columns are more often counts than booleans.
        #expect(MaestroDBCSV.inferType(values: ["0", "1", "1", "0"]) == .number)
    }

    @Test func inferNumberAllowsThousandsSeparators() {
        #expect(MaestroDBCSV.inferType(values: ["1,000", "2.5", "-3"]) == .number)
    }

    @Test func inferDateFromISO() {
        #expect(MaestroDBCSV.inferType(values: ["2026-08-02", "2025-01-31"]) == .date)
    }

    @Test func inferLongTextFromLongValues() {
        let long = String(repeating: "x", count: 120)
        #expect(MaestroDBCSV.inferType(values: ["short", long]) == .longText)
        #expect(MaestroDBCSV.inferType(values: ["has\nnewline"]) == .longText)
    }

    @Test func inferTextFallbackAndEmpty() {
        #expect(MaestroDBCSV.inferType(values: ["mixed", "42"]) == .text)
        #expect(MaestroDBCSV.inferType(values: ["", ""]) == .text)
    }
}

@Suite("MaestroDBCoercion")
struct MaestroDBCoercionTests {

    @Test func checkboxVariants() {
        for token in ["true", "TRUE", "yes", "1", "x", "✓"] {
            #expect(MaestroDBCoercion.canonical(token, for: .checkbox) == "1")
        }
        for token in ["false", "no", "0"] {
            #expect(MaestroDBCoercion.canonical(token, for: .checkbox) == "0")
        }
        #expect(MaestroDBCoercion.canonical("maybe", for: .checkbox) == nil)
        #expect(MaestroDBCoercion.canonical("", for: .checkbox) == "")
    }

    @Test func numberParsing() {
        #expect(MaestroDBCoercion.canonical("1,000", for: .number) == "1000")
        #expect(MaestroDBCoercion.canonical("2.5", for: .number) == "2.5")
        #expect(MaestroDBCoercion.canonical("abc", for: .number) == nil)
    }

    @Test func ratingClampedToOneThroughFive() {
        #expect(MaestroDBCoercion.canonical("3", for: .rating) == "3")
        #expect(MaestroDBCoercion.canonical("0", for: .rating) == nil)
        #expect(MaestroDBCoercion.canonical("6", for: .rating) == nil)
        #expect(MaestroDBCoercion.canonical("4.5", for: .rating) == nil)
    }

    @Test func dateFormats() {
        // Every accepted input must produce a canonical ISO8601 string that
        // DBRow.date(for:) can read back.
        let inputs = ["2026-08-02", "2026-08-02T14:30:00Z", "02/08/2026", "2 Aug 2026"]
        for input in inputs {
            let canonical = MaestroDBCoercion.canonical(input, for: .date)
            #expect(canonical != nil, "\(input) should parse")
            if let canonical {
                #expect(ISO8601DateFormatter().date(from: canonical) != nil,
                        "\(input) → \(canonical) should be valid ISO8601")
            }
        }
        #expect(MaestroDBCoercion.canonical("not a date", for: .date) == nil)
    }

    @Test func multiSelectJSONAndSemicolon() {
        #expect(MaestroDBCoercion.canonical("[\"a\",\"b\"]", for: .multiSelect) == "[\"a\",\"b\"]")
        #expect(MaestroDBCoercion.canonical("a; b", for: .multiSelect) == "[\"a\",\"b\"]")
        #expect(MaestroDBCoercion.canonical("", for: .multiSelect) == "")
    }

    @Test func csvTextRoundTrips() {
        // Every exported form must re-import to an equivalent stored value.
        let cases: [(DBFieldType, String)] = [
            (.text, "hello world"),
            (.number, "42"),
            (.checkbox, "1"),
            (.date, "2026-08-02T00:00:00Z"),
            (.multiSelect, "[\"a\",\"b\"]"),
        ]
        for (type, stored) in cases {
            let exported = MaestroDBCoercion.csvText(stored, for: type)
            let reimported = MaestroDBCoercion.canonical(exported, for: type)
            #expect(reimported != nil, "\(type.rawValue): exported '\(exported)' should re-import")
            if type == .checkbox { #expect(reimported == stored) }
            if type == .multiSelect { #expect(reimported == stored) }
        }
    }
}

@Suite("MaestroDBCSV import/export (integration)")
struct MaestroDBCSVImportTests {

    /// Throwaway database in a unique temp directory.
    private func makeTempDB() throws -> (MaestroDBDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maestrodb-test-\(UUID().uuidString)", isDirectory: true)
        let db = try MaestroDBDatabase.open(
            dir.appendingPathComponent("test.sqlite"))
        return (db, dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func createTableInfersTypesAndImportsRows() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }

        let base = try db.createBase(name: "Test Base")
        let csv = "Job,Delivered,Priority,Shoot date\n"
            + "Brand shoot,false,4,2026-08-02\n"
            + "Portraits,true,5,2026-08-10\n"
        let parsed = try MaestroDBCSV.parse(csv)
        let (table, report) = try MaestroDBCSV.createTable(
            from: parsed, baseID: base.id, name: "Jobs", database: db)

        #expect(report.rowsAdded == 2)
        let fields = try db.fields(tableID: table.id)
        try #require(fields.count == 4)
        #expect(fields.map(\.name) == ["Job", "Delivered", "Priority", "Shoot date"])
        #expect(fields[0].type == .text)
        #expect(fields[1].type == .checkbox)
        #expect(fields[2].type == .number)
        #expect(fields[3].type == .date)

        let rows = try db.rows(tableID: table.id)
        try #require(rows.count == 2)
        #expect(rows[0].value(for: fields[0].id) == "Brand shoot")
        #expect(rows[0].bool(for: fields[1].id) == false)
        #expect(rows[1].bool(for: fields[1].id) == true)
        #expect(rows[0].date(for: fields[3].id) != nil)
    }

    @Test func importIntoExistingTableMatchesFieldsAndAutoAddsOptions() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }

        let base = try db.createBase(name: "B")
        let table = try db.createTable(baseID: base.id, name: "Jobs")
        let job = try db.addField(tableID: table.id, name: "Job", type: .text)
        let status = try db.addField(
            tableID: table.id, name: "Status", type: .select, options: ["Booked"])

        // Header case differs + one unknown column (→ new inferred field).
        let parsed = try MaestroDBCSV.parse(
            "job,STATUS,Client\nWebsite,Delivered,Acme Corp\n")
        let report = try MaestroDBCSV.importRows(parsed, into: table.id, database: db)

        try #require(report.rowsAdded == 1)
        #expect(report.fieldsCreated == ["Client"])
        #expect(report.optionsAdded == 1)

        let fields = try db.fields(tableID: table.id)
        #expect(fields.first(where: { $0.id == status.id })?.options == ["Booked", "Delivered"])
        let rows = try db.rows(tableID: table.id)
        try #require(rows.count == 1)
        #expect(rows[0].value(for: job.id) == "Website")
        #expect(rows[0].value(for: status.id) == "Delivered")
        let client = try #require(fields.first(where: { $0.name == "Client" }))
        #expect(rows[0].value(for: client.id) == "Acme Corp")
    }

    @Test func uncoercibleCellsAreSkippedNotMangled() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }

        let base = try db.createBase(name: "B")
        let table = try db.createTable(baseID: base.id, name: "T")
        let number = try db.addField(tableID: table.id, name: "Amount", type: .number)

        let parsed = try MaestroDBCSV.parse("Amount\nnot-a-number\n42\n")
        let report = try MaestroDBCSV.importRows(parsed, into: table.id, database: db)

        #expect(report.rowsAdded == 2)          // both rows exist…
        #expect(report.cellsSkipped == 1)        // …but the bad cell was skipped
        let rows = try db.rows(tableID: table.id)
        try #require(rows.count == 2)
        #expect(rows[0].value(for: number.id).isEmpty)
        #expect(rows[1].value(for: number.id) == "42")
    }

    @Test func exportRoundTripsLosslessly() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }

        let base = try db.createBase(name: "B")
        let table = try db.createTable(baseID: base.id, name: "Jobs")
        let job = try db.addField(tableID: table.id, name: "Job", type: .text)
        let done = try db.addField(tableID: table.id, name: "Done", type: .checkbox)
        let tags = try db.addField(tableID: table.id, name: "Tags", type: .multiSelect,
                                   options: ["urgent", "remote"])
        _ = try db.addRow(tableID: table.id, values: [
            job.id: "Smith, Jane job",
            done.id: "1",
            tags.id: DBRow.store(multi: ["urgent", "remote"]),
        ])

        let csv = MaestroDBCSV.exportCSV(
            fields: try db.fields(tableID: table.id),
            rows: try db.rows(tableID: table.id))

        // Re-import into a fresh table in the same base.
        let parsed = try MaestroDBCSV.parse(csv)
        let (copy, report) = try MaestroDBCSV.createTable(
            from: parsed, baseID: base.id, name: "Jobs Copy", database: db)
        try #require(report.rowsAdded == 1)

        let copyFields = try db.fields(tableID: copy.id)
        let copyRows = try db.rows(tableID: copy.id)
        try #require(copyRows.count == 1)
        try #require(copyFields.count == 3)
        #expect(copyRows[0].value(for: copyFields[0].id) == "Smith, Jane job")
        // Export wrote "true"; import coerces back to canonical "1".
        #expect(copyRows[0].bool(for: copyFields[1].id) == true)
        #expect(copyRows[0].multiValues(for: copyFields[2].id) == ["urgent", "remote"])
    }
}
